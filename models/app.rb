class App < ApplicationRecord
  belongs_to :user
  has_many :deployments, dependent: :destroy
  has_one :latest_deployment, -> { order(id: :desc) }, class_name: 'Deployment'
  has_many :environment_variables, dependent: :destroy
  has_many :addons, dependent: :destroy
  has_many :domains, dependent: :destroy
  has_many :storages, dependent: :destroy

  enum runtime_status: {
    running: 'running',
    down: 'down',
    restarting: 'restarting'
  }

  enum kind: {
    rails: 'rails',
    sinatra: 'sinatra',
    jekyll: 'jekyll'
  }

  enum build_pack: {
    nixpacks: 'nixpacks',
    dockerfile: 'dockerfile',
    docker_compose: 'docker_compose'
  }
  
  enum deployment_type: {
    coolify: 'coolify',
    local: 'local'
  }

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :kind, presence: true, inclusion: { in: kinds.keys }
  validates :build_pack, presence: true, inclusion: { in: build_packs.keys }
  validates :deployment_type, presence: true, inclusion: { in: deployment_types.keys }
  validates :repository_url, presence: true

  validates :branch, presence: true
  validates :subdomain, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ }
  validates :runtime_status, presence: true, inclusion: { in: runtime_statuses.keys }
  validates :port, numericality: { only_integer: true, allow_nil: true }
  validate :validate_app_limit, on: :create

  before_validation :set_default_branch
  before_validation :normalize_repository_url
  before_validation :generate_subdomain, on: :create
  before_validation :generate_webhook_secret
  before_validation :set_default_limits
  before_validation :set_default_runtime_status, on: :create
  before_validation :set_default_deployment_type, on: :create
  after_create :create_default_domain

  def current_container_name
    # In a real system, we'd query the Docker API. 
    # For now, we find the latest successful deployment.
    latest_deployment = deployments.success.order(id: :desc).first
    return nil unless latest_deployment

    "enkihost-app-#{id}-#{latest_deployment.id}"
  end

  def fetch_live_stats
    if coolify_uuid.present?
      CoolifyService.new.get_resource_usage(coolify_uuid)
    elsif (container_name = current_container_name)
      DockerService.get_container_stats(container_name)
    else
      { cpu_usage: "0%", memory_usage: "0B / 0B", online: false }
    end
  end

  def webhook_url
    # Base URL for the API webhooks
    "https://api.enkihost.com/api/v1/apps/#{id}/webhook?secret=#{webhook_secret}"
  end

  def last_deployment_status
    latest_deployment&.status || 'never_deployed'
  end

  private

  def create_default_domain
    domain = domains.create(fqdn: "#{subdomain}.enkihost.com")
    unless domain.persisted?
      Rails.logger.error "Failed to create default domain for app #{id}: #{domain.errors.full_messages.join(', ')}"
    end
  end

  def docker_compose_service_name
    return 'web' if docker_compose_raw.blank?

    begin
      parsed = YAML.safe_load(docker_compose_raw)
      services = parsed['services']
      return 'web' unless services.is_a?(Hash) && services.any?

      service_with_port = services.find do |_, config|
        config.is_a?(Hash) && (config['ports'].present? || config['expose'].present?)
      end
      return service_with_port.first if service_with_port

      # Fallback a nombres comunes si no hay puertos declarados explícitamente
      %w[app api backend web].each do |name|
        return name if services.key?(name)
      end
      
      services.keys.first || 'web'
    rescue StandardError => e
      Rails.logger.error "Error parsing docker_compose_raw for app #{id}: #{e.message}"
      'web'
    end
  end

  def generate_docker_compose_with_labels
    return docker_compose_raw if docker_compose_raw.blank? || build_pack != 'docker_compose'

    begin
      parsed = YAML.safe_load(docker_compose_raw)
      services = parsed['services']
      return docker_compose_raw unless services.is_a?(Hash)

      target_service = docker_compose_service_name
      config = services[target_service]
      return docker_compose_raw unless config.is_a?(Hash)

      config['labels'] ||= []
      # It could be a Hash or an Array in Docker Compose
      labels = config['labels']

      fqdns = domains.pluck(:fqdn).presence || ["#{subdomain}.enkihost.com"]
      domains_list = fqdns.map { |d| "`#{d.to_s.strip.gsub(/https?:\/\//, '')}`" }
      host_rule = "Host(#{domains_list.join(' || ')})"
      
      router_name = "enkihost-app-#{id}"
      
      new_labels = [
        "traefik.enable=true",
        "traefik.http.routers.#{router_name}.rule=#{host_rule}",
        "traefik.http.routers.#{router_name}.entrypoints=https",
        "traefik.http.routers.#{router_name}.tls=true",
        "traefik.http.routers.#{router_name}.tls.certresolver=letsencrypt"
      ]

      if labels.is_a?(Array)
        # Remove old traefik labels
        labels.reject! { |l| l.start_with?('traefik.') }
        labels.concat(new_labels)
      elsif labels.is_a?(Hash)
        labels.delete_if { |k, _| k.to_s.start_with?('traefik.') }
        new_labels.each do |l|
          key, val = l.split('=', 2)
          labels[key] = val
        end
      end

      config['labels'] = labels

      # Inyectar volúmenes persistentes si existen
      if storages.any?
        config['volumes'] ||= []
        parsed['volumes'] ||= {}
        
        storages.each do |storage|
          # En Docker Compose: 'fuente:destino'
          volume_def = "#{storage.source}:#{storage.destination}"
          
          # Añadir al servicio si no está ya
          unless config['volumes'].is_a?(Array) && config['volumes'].include?(volume_def)
            config['volumes'] = [config['volumes']] if config['volumes'].is_a?(String)
            config['volumes'] << volume_def
          end

          # Añadir declaración top-level si es un volumen nombrado (no empieza por /)
          unless storage.source.start_with?('/')
            parsed['volumes'][storage.source] ||= {}
          end
        end
      end

      # Inyectar build arguments si hay una sección 'build'
      if config['build'].is_a?(Hash) || config['build'].is_a?(String)
        # Si 'build' es un string (el context), lo convertimos a hash
        if config['build'].is_a?(String)
          config['build'] = { 'context' => config['build'] }
        end

        config['build']['args'] ||= []
        # Aseguramos que sea un array (Docker Compose permite hash también, pero array es más común para esto)
        if config['build']['args'].is_a?(Hash)
          config['build']['args'] = config['build']['args'].keys
        end

        # Recolectamos todas las variables de entorno que queremos pasar como build args
        build_args = []
        if kind == 'rails'
          build_args << 'PORT'
          build_args << 'RAILS_ENV'
        end
        
        environment_variables.each do |ev|
          build_args << ev.key
        end

        # Añadimos las que no estén ya
        build_args.uniq.each do |arg|
          unless config['build']['args'].include?(arg)
            config['build']['args'] << arg
          end
        end
      end

      YAML.dump(parsed)
    rescue StandardError => e
      Rails.logger.error "Error generating docker_compose_with_labels for app #{id}: #{e.message}"
      docker_compose_raw
    end
  end

  def set_default_branch
    self.branch ||= 'main'
  end

  def set_default_limits
    return unless user

    self.cpu_limit = user.limits[:cpu_limit]
    self.memory_limit = user.limits[:memory_limit]
  end

  def validate_app_limit
    return unless user
    return if persisted? # Only validate on create

    if user.apps.count >= user.limits[:max_apps]
      errors.add(:base, "You have reached the maximum number of applications for your #{user.plan.capitalize} plan.")
    end

    unless user.limits[:allowed_kinds].include?(kind)
      errors.add(:kind, "is not allowed on the #{user.plan.capitalize} plan (Allowed: #{user.limits[:allowed_kinds].join(', ')})")
    end
  end

  def set_default_runtime_status
    self.runtime_status ||= 'down'
  end

  def set_default_deployment_type
    self.deployment_type ||= 'local'
  end

  def generate_subdomain
    return if subdomain.present?

    self.subdomain = name.to_s.parameterize
    # Ensure it's unique if multiple users use same name
    if App.exists?(subdomain: subdomain)
      self.subdomain = "#{subdomain}-#{SecureRandom.hex(3)}"
    end
  end

  def generate_webhook_secret
    self.webhook_secret ||= SecureRandom.hex(24)
  end

  def normalize_repository_url
    return if repository_url.blank?
    
    url = repository_url.to_s.strip

    # 1. SSH format: git@github.com:owner/repo(.git)
    if url =~ %r{\Agit@(github|gitlab)\.com:([^/]+)/([^/\s]+?)(?:\.git)?\z}
      host = Regexp.last_match(1)
      owner = Regexp.last_match(2)
      repo = Regexp.last_match(3)
      self.repository_url = "https://#{host}.com/#{owner}/#{repo}"
      return
    end

    # 2. Standard HTTP/HTTPS or deep tree URL: (https://)(www.)github.com/owner/repo(...)
    if url =~ %r{(?:https?://)?(?:www\.)?(github|gitlab)\.com/([^/\s]+)/([^/\s#?]+)}
      host = Regexp.last_match(1)
      owner = Regexp.last_match(2)
      repo = Regexp.last_match(3).sub(/\.git\z/, '')
      self.repository_url = "https://#{host}.com/#{owner}/#{repo}"
      return
    end

    # 3. Simple owner/repo shorthand: owner/repo
    if url =~ %r{\A([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+?)(?:\.git)?\z}
      self.repository_url = "https://github.com/#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
      return
    end

    # 4. Fallback cleanup
    clean_url = url.sub(%r{/+\z}, '').sub(/\.git\z/, '')
    self.repository_url = clean_url
  end

  before_destroy :cleanup_all_associated_resources

  private

  def cleanup_all_associated_resources
    target_id = id
    target_coolify_uuid = coolify_uuid

    Rails.logger.info "[App##{target_id}] Cleaning up all Docker containers and associated databases..."

    # 1. Clean up all associated database/addon containers and volumes
    addons.each do |addon|
      begin
        AddonService.new(addon).deprovision if defined?(AddonService)
      rescue StandardError => e
        warn "[App##{target_id}] Error cleaning up database addon #{addon.id}: #{e.message}"
      end
    end

    # 2. Clean up all app Docker containers, volumes, and images
    if defined?(DockerService)
      begin
        DockerService.cleanup_app_resources(target_id)
      rescue StandardError => e
        warn "[App##{target_id}] Error cleaning up app Docker containers: #{e.message}"
      end
    end

    # 3. Clean up Coolify application if configured
    if target_coolify_uuid.present? && defined?(CoolifyService)
      begin
        CoolifyService.new.delete_application(target_coolify_uuid)
      rescue StandardError => e
        warn "[App##{target_id}] Error deleting Coolify application #{target_coolify_uuid}: #{e.message}"
      end
    end

    # 4. Also queue background job as redundancy
    begin
      CleanupAppResourcesJob.perform_later(target_id, target_coolify_uuid) if defined?(CleanupAppResourcesJob)
    rescue StandardError => e
      warn "[App##{target_id}] Could not enqueue CleanupAppResourcesJob: #{e.message}"
    end
  end
end
