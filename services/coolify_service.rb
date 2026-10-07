require 'open3'
require 'base64'

class CoolifyService
  def initialize
    raw_url = ENV['COOLIFY_URL'].presence || 'https://coolify.enkilabs.site'
    base_url = raw_url.gsub(/\/+$/, '')
    @url = base_url.include?('/api/v1') ? base_url : "#{base_url}/api/v1"
    @token = ENV['COOLIFY_TOKEN']
    @project_uuid = ENV['COOLIFY_PROJECT_UUID']
    @server_uuid = ENV['COOLIFY_SERVER_UUID']
    @destination_uuid = ENV['COOLIFY_DESTINATION_UUID']
    
    @conn = Faraday.new(url: @url) do |f|
      f.request :json
      f.response :json
      f.headers['Authorization'] = "Bearer #{@token}"
      f.options[:timeout] = 30 
    end
  end

  def create_application(app, deployment)
    coolify_uuid = app.coolify_uuid

    if coolify_uuid.present?
      log(deployment, "Updating settings for #{coolify_uuid}...")
      sync_settings(app, deployment)
    else
      log(deployment, "Creating new app in Coolify...")
      # Para la creación inicial usamos un payload mínimo
      create_payload = prepare_create_payload(app, deployment)
      response = @conn.post('applications/public', create_payload)
      
      if response.success?
        coolify_uuid = response.body['uuid']
        app.update!(coolify_uuid: coolify_uuid)
        
        # Después de crear, hacemos el PATCH completo con dominios y YAML
        log(deployment, "Applying full settings (domains, YAML) via PATCH...")
        sync_settings(app, deployment)
      else
        raise "Coolify creation failed: #{response.body.to_json}"
      end
    end

    # 2. Sincronizar variables de entorno
    sync_environment_variables(coolify_uuid, prepare_env_vars(app), deployment)
    
    # 3. Sincronizar Storages (Volúmenes)
    sync_storages(app, deployment)
    
    # 4. Disparar el despliegue real
    log(deployment, "Triggering deployment...")
    deploy_response = @conn.post("deploy", { uuid: coolify_uuid, force: true })
    
    if deploy_response.success?
      body = deploy_response.body
      deployment_uuid = body['deployment_uuid'] || body['uuid']
      
      if deployment_uuid.blank? && body['deployments'].is_a?(Array)
        deployment_uuid = body['deployments'].first&.dig('deployment_uuid') || body['deployments'].first&.dig('uuid')
      end
      
      return { coolify_uuid: coolify_uuid, deployment_uuid: deployment_uuid }
    else
      raise "Coolify deployment failed: #{deploy_response.body.to_json}"
    end
  end

  def sync_settings(app, deployment = nil, instant_deploy: false)
    return false unless app.coolify_uuid.present?

    # Obtenemos la lista de dominios limpia y formateada
    fqdns = app.domains.pluck(:fqdn).presence || ["#{app.subdomain}.enkihost.com"]
    domain_string = fqdns.map { |d| d.to_s.strip.start_with?('http') ? d : "https://#{d}" }.join(',')

    # Construimos el Patch Payload enfocado en la API v4
    patch_payload = {
      instant_deploy: instant_deploy,
      ports_exposes: app.port.to_s.presence || "3000",
      force_domain_override: true,
      git_repository: clean_repo_url(app, deployment),
      git_branch: app.branch || 'main'
    }
    
    if app.build_pack == 'docker_compose'
      # NOTA: Regresamos al Hash porque el String JSON dio error de validación.
      raw_content = app.respond_to?(:generate_docker_compose_with_labels) ? app.generate_docker_compose_with_labels : app.docker_compose_raw
      
      if raw_content.present?
        patch_payload[:docker_compose_raw] = raw_content
        
        service_name = app.respond_to?(:docker_compose_service_name) ? app.docker_compose_service_name : 'web'
        log(deployment || app.deployments.last, "Syncing domains for service '#{service_name}' (and fallback)...")
        
        # Enviamos tanto para el detectado como para 'app'/'web' por compatibilidad con el panel v4
        patch_payload[:docker_compose_domains] = { 
          service_name => { name: service_name, domain: domain_string },
          'app' => { name: 'app', domain: domain_string },
          'web' => { name: 'web', domain: domain_string }
        }
      else
        log(deployment || app.deployments.last, "⚠️ Skipping domains sync: docker_compose_raw is missing.")
      end
    else
      # Para Nixpacks/Static/Dockerfile usamos el campo 'domains' estándar
      patch_payload[:domains] = domain_string
    end
    
    # Sincronizamos también los Storages (volúmenes)
    sync_storages(app, deployment)
    
    response = @conn.patch("applications/#{app.coolify_uuid}", patch_payload)
    
    if response.success?
      log(deployment || app.deployments.last, "✅ Sincronización entregada a Coolify.")
    else
      error_msg = response.body.to_json
      log(deployment || app.deployments.last, "⚠️ Error en la sincronización (PATCH): #{response.status} - #{error_msg}")
      Rails.logger.error "Coolify sync_settings failed: #{response.status} - #{response.body.to_json}"
    end
    
    response.success?
  end

  def get_deployment_logs(deployment_uuid)
    return nil if deployment_uuid.blank?
    response = @conn.get("deployments/#{deployment_uuid}")
    response.success? ? response.body : nil
  end

  def get_application_logs(coolify_uuid)
    return nil if coolify_uuid.blank?
    response = @conn.get("applications/#{coolify_uuid}/logs")
    response.success? ? response.body : nil
  end

  def get_resource_usage(coolify_uuid)
    return nil if coolify_uuid.blank?
    # Typical Coolify v4 stats endpoint
    response = @conn.get("applications/#{coolify_uuid}/stats")
    
    if response.success?
      stats = response.body
      {
        cpu_usage: stats['cpu_usage'] || "0%",
        memory_usage: stats['memory_usage'] || "0B / 0B",
        online: stats['status'] == 'running'
      }
    else
      # Fallback if endpoint doesn't exist or fails
      { cpu_usage: "0%", memory_usage: "0B / 0B", online: false }
    end
  end

  def delete_application(coolify_uuid)
    return nil if coolify_uuid.blank?
    @conn.delete("applications/#{coolify_uuid}")
  end

  def add_storage(app, storage_record, deployment = nil)
    return false if app.coolify_uuid.blank?

    payload = {
      type: 'persistent', # Por ahora solo soportamos volúmenes persistentes
      name: storage_record.name,
      host_path: storage_record.source,
      mount_path: storage_record.destination
    }

    response = @conn.post("applications/#{app.coolify_uuid}/storages", payload)

    if response.success?
      log(deployment || app.deployments.last, "✅ Storage '#{storage_record.name}' mounted at '#{storage_record.destination}' successfully.")
    else
      log(deployment || app.deployments.last, "⚠️ Failed to add storage: #{response.body.to_json}")
    end

    response.success?
  end

  def list_storages(coolify_uuid)
    return [] if coolify_uuid.blank?
    response = @conn.get("applications/#{coolify_uuid}/storages")
    response.success? ? (response.body['persistent_storages'] || []) : []
  end

  def sync_storages(app, deployment = nil)
    return false if app.coolify_uuid.blank?

    # 1. Asegurar volumen por defecto si no hay ninguno
    if app.storages.empty?
      app.storages.create!(
        name: "storage-#{app.id}",
        source: "storage-#{app.id}",
        destination: "/app/storage",
        is_directory: true
      )
    end

    # 2. Para aplicaciones de Docker Compose, los volúmenes ya se inyectan en el YAML (App#generate_docker_compose_with_labels)
    # Por lo tanto, no llamamos al API de /storages que da 404 para Compose.
    return true if app.build_pack == 'docker_compose'

    # 3. Para otros build packs (Dockerfile, Nixpacks) usamos el API de /storages si está disponible
    existing_storages = list_storages(app.coolify_uuid)
    
    app.storages.each do |storage|
      # Verificamos si ya existe por mount_path (que es lo que importa en el contenedor)
      exists = existing_storages.any? { |s| s['mount_path'] == storage.destination }
      
      if exists
        log(deployment || app.deployments.last, "ℹ️ Storage at '#{storage.destination}' already exists.")
      else
        add_storage(app, storage, deployment)
      end
    end
    
    true
  end

  def clean_repo_url(app, deployment = nil)
    url = app.repository_url.to_s.strip
    return "" if url.blank?
    
    path = extract_repo_path(url)
    return url if path.blank?

    if url.include?('gitlab.com')
      token = app.user.gitlab_token.to_s.gsub(%r{https?://}, '').split('@').last || ""
      # Ensure token doesn't contain Gitlab domain
      token = token.split('/').first if token.include?('gitlab.com')
      
      if app.user.gitlab_token.present?
        log(deployment, "ℹ️ Injecting GitLab token for private repository.")
        "https://oauth2:#{app.user.gitlab_token.to_s.split('@').last.split('/').last}@gitlab.com/#{path}"
      else
        "https://gitlab.com/#{path}"
      end
    else
      # GitHub cleaning
      # If the user pasted a full URL as a token, we extract only the alphanumeric part or the last part
      raw_token = app.user&.github_token.to_s.strip
      clean_token = if raw_token.present?
                      raw_token.gsub(%r{https?://}, '').split('@').first&.split('/')&.last
                    end
      
      if clean_token.present? && clean_token.length > 5
        log(deployment, "ℹ️ Injecting GitHub token for private repository.")
        # Standard tokenized URL
        final_url = "https://#{clean_token}@github.com/#{path}"
        
        # Log obfuscated URL for debugging
        obfuscated_url = "https://***token***@github.com/#{path}"
        log(deployment, "ℹ️ Final Repository URL: #{obfuscated_url}")
        
        final_url
      else
        log(deployment, "⚠️ No valid Git token found. Private repositories may fail.") if deployment
        "https://github.com/#{path}"
      end
    end
  end

  def extract_repo_path(url)
    return "" if url.blank?
    # Strip everything and keep only owner/repo
    parts = url.to_s.gsub(/\.git$/, '').split('/').reject(&:blank?)
    return "" if parts.size < 2
    parts.last(2).join('/')
  end

  private

  def prepare_create_payload(app, deployment = nil)
    {
      project_uuid: @project_uuid,
      server_uuid: @server_uuid,
      destination_uuid: @destination_uuid,
      environment_name: 'production',
      git_repository: clean_repo_url(app, deployment),
      git_branch: app.branch || 'main',
      name: "enkihost-app-#{app.id}",
      build_pack: app.build_pack == 'docker_compose' ? 'dockercompose' : app.build_pack,
      instant_deploy: false,
      connect_to_docker_network: true
    }
  end

  def prepare_env_vars(app)
    vars = []
    if app.kind == 'rails'
      vars << { key: 'PORT', value: '3000' }
      vars << { key: 'RAILS_ENV', value: 'production' }
    end
    app.environment_variables.each { |ev| vars << { key: ev.key, value: ev.value } }
    vars
  end

  def sync_environment_variables(coolify_uuid, vars, deployment)
    vars.each do |v|
      @conn.post("applications/#{coolify_uuid}/envs", { 
        key: v[:key], 
        value: v[:value].to_s, 
        is_literal: true, 
        is_preview: false 
      })
    end
  end

  def log(deployment, message)
    return unless deployment
    # Using sanitize_sql for safety if available, otherwise manual escaping
    safe_msg = message.to_s.gsub("'", "''")
    Deployment.where(id: deployment.id).update_all("log = COALESCE(log, '') || '\n[#{Time.current.utc}] COOLIFY: #{safe_msg}'")
  end
end