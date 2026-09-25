require 'open3'
require 'shellwords'

class DockerService
  def initialize(deployment)
    @deployment = deployment
    @app = deployment.app
    @build_path = Rails.root.join('tmp', 'builds', @deployment.id.to_s)
  end

  def build
    prepare_build_directory
    clone_repository
    generate_dockerfile
    build_image
  end

  def run_container
    assign_port if @app.port.blank?
    if @app.user.present?
      @app.update(
        cpu_limit: @app.user.limits[:cpu_limit],
        memory_limit: @app.user.limits[:memory_limit]
      )
    end
    start_new_container
    stop_old_container
  ensure
    # cleanup_build_directory
  end

  def self.get_container_stats(container_name)
    return nil if container_name.blank?
    
    # Run docker stats without streaming to get a snapshot
    # Format: CPUPerc,MemUsage,MemPerc
    output = `#{docker_bin} stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}" #{container_name}`.strip rescue nil
    
    if output.present?
      cpu, mem, mem_perc = output.split(',')
      {
        cpu_usage: cpu,
        memory_usage: mem,
        memory_percentage: mem_perc,
        online: true
      }
    else
      { cpu_usage: "0%", memory_usage: "0B / 0B", online: false }
    end
  end

  def self.docker_bin
    @docker_bin ||= begin
      if ENV['DOCKER_BINARY'].present? && File.executable?(ENV['DOCKER_BINARY'])
        return ENV['DOCKER_BINARY']
      end

      which_docker = `which docker`.strip rescue nil
      if which_docker.present? && File.executable?(which_docker)
        return which_docker
      end

      common_paths = [
        "/usr/bin/docker",
        "/usr/local/bin/docker",
        "/bin/docker",
        "/snap/bin/docker"
      ]

      found_path = common_paths.find { |path| File.executable?(path) }
      return found_path if found_path

      "docker"
    end
  end

  def self.remove_container(container_name)
    return if container_name.blank?

    bin = docker_bin
    Rails.logger.info "DOCKER: Forcefully stopping and removing container #{container_name}..."
    system("#{bin} stop #{container_name} >/dev/null 2>&1")
    system("#{bin} rm -f #{container_name} >/dev/null 2>&1")

    # Also remove the named volume associated with the app if it was a default one
    app_id = container_name.match(/enkihost-app-(\d+)/)&.captures&.first
    if app_id
      system("#{bin} volume rm enkihost-app-#{app_id}-data >/dev/null 2>&1") rescue nil
    end
  end

  def self.cleanup_app_resources(app_id)
    return if app_id.blank?

    bin = docker_bin
    prefix = "enkihost-app-#{app_id}-"
    Rails.logger.info "[DockerService] Starting comprehensive Docker container cleanup for app #{app_id}..."

    # 1. Stop and remove all app deployment containers by name prefix
    begin
      out, _err, st = Open3.capture3("#{bin} ps -a --filter \"name=#{prefix}\" --format \"{{.Names}}\"")
      if st.success?
        containers = out.split("\n").map(&:strip).reject(&:blank?)
        containers.each do |c_name|
          if c_name.start_with?(prefix)
            Rails.logger.info "[DockerService] Removing app container: #{c_name}"
            system("#{bin} rm -f #{c_name} >/dev/null 2>&1")
          end
        end
      end
    rescue StandardError => e
      warn "[DockerService] Error removing app containers by name: #{e.message}"
    end

    # 2. Stop and remove any containers by label (enkihost.app_id=#{app_id})
    begin
      out, _err, st = Open3.capture3("#{bin} ps -a --filter \"label=enkihost.app_id=#{app_id}\" --format \"{{.ID}}\"")
      if st.success?
        ids = out.split("\n").map(&:strip).reject(&:blank?)
        ids.each do |c_id|
          Rails.logger.info "[DockerService] Removing labeled app container: #{c_id}"
          system("#{bin} rm -f #{c_id} >/dev/null 2>&1")
        end
      end
    rescue StandardError => e
      warn "[DockerService] Error removing containers by label: #{e.message}"
    end

    # 3. Remove app default volume
    begin
      system("#{bin} volume rm enkihost-app-#{app_id}-data >/dev/null 2>&1")
    rescue StandardError => e
      warn "[DockerService] Error removing app volume: #{e.message}"
    end

    # 4. Remove Docker build images for this app (enkihost-#{app_id}-*)
    begin
      out, _err, st = Open3.capture3("#{bin} images --filter \"reference=enkihost-#{app_id}-*\" --format \"{{.ID}}\"")
      if st.success?
        img_ids = out.split("\n").map(&:strip).reject(&:blank?)
        img_ids.each do |img_id|
          system("#{bin} rmi -f #{img_id} >/dev/null 2>&1")
        end
      end
    rescue StandardError => e
      warn "[DockerService] Error removing app images: #{e.message}"
    end
  end

  private

  def stop_old_container
    # Find all containers for this app that are NOT the current deployment
    current_container_name = "enkihost-app-#{@app.id}-#{@deployment.id}"
    log("Identifying conflicting or old containers to remove...")
    
    # 1. Filter by our own labeling system
    ids_by_label = `#{docker_bin} ps -a --filter "label=enkihost.app_id=#{@app.id}" --format "{{.ID}}"`.split("\n")
    
    # 2. Filter by Coolify UUID if present (to catch containers created by Coolify)
    ids_by_uuid = []
    if @app.coolify_uuid.present?
      ids_by_uuid = `#{docker_bin} ps -a --filter "name=#{@app.coolify_uuid}" --format "{{.ID}}"`.split("\n")
    end

    # 3. Filter by Host domain rule in Traefik labels (to catch ANY container squatting on our domains)
    ids_by_domain = []
    ([@app.subdomain + ".enkihost.com"] + @app.domains.pluck(:fqdn)).each do |domain|
      # Search for containers with this domain in their Traefik labels
      ids = `#{docker_bin} ps -a --format "{{.ID}} {{.Labels}}"`.split("\n")
              .select { |line| line.include?(domain) }
              .map { |line| line.split(" ").first }
      ids_by_domain.concat(ids)
    end

    # Combine all unique IDs
    all_conflicting_ids = (ids_by_label + ids_by_uuid + ids_by_domain).uniq.compact.reject(&:blank?)
    
    # We must NEVER remove the container we just started
    begin
      current_id = `#{docker_bin} inspect --format '{{.Id}}' #{current_container_name}`.strip
      all_conflicting_ids.reject! { |id| id == current_id || current_id.start_with?(id) }
    rescue
      # If current container not found yet, skip rejection
    end

    all_conflicting_ids.each do |id|
      # Get name for logging
      name = `#{docker_bin} inspect --format '{{.Name}}' #{id}`.strip.gsub(/^\//, '')
      log("Stopping and removing conflicting container: #{name} (#{id})...")
      system("#{docker_bin} stop #{id}")
      system("#{docker_bin} rm #{id}")
    end
  rescue StandardError => e
    log("Warning: Could not cleanup conflicting containers: #{e.message}")
  end

  def assign_port
    # Simple port assigner starting from 10000
    last_port = App.maximum(:port) || 10000
    @app.update!(port: last_port + 1)
    log("Assigned new port to app: #{@app.port}")
  end

  def start_new_container
    image_tag = "enkihost-#{@app.id}-#{@deployment.id}"
    container_name = "enkihost-app-#{@app.id}-#{@deployment.id}"
    
    internal_port = case @app.kind
                    when 'rails' then 3000
                    when 'sinatra' then 4567
                    when 'jekyll' then 80
                    end

    log("Starting new container #{container_name}...")
    
    # Configuration for the proxy network (matches Coolify's default)
    proxy_network = 'coolify'

    # Traefik labels + App ID label for identification
    base_domain = !Rails.env.production? ? "localhost" : "enkihost.com"
    domain = "#{@app.subdomain}.#{base_domain}"
    custom_domains = @app.domains.pluck(:fqdn)
    
    # Use array of domains with || for Traefik v3 compatibility
    # v3 expects Host() to have exactly one parameter
    all_domains = ([domain] + custom_domains).map { |d| "Host(\"#{d}\")" }.join(" || ")

    router_name = "enkihost-app-#{@app.id}-#{@deployment.id}"
    service_name = "enkihost-app-#{@app.id}-#{@deployment.id}"

    # Labels as an array of strings
    labels = [
      "traefik.enable=true",
      "traefik.http.routers.#{router_name}.rule=#{all_domains}",
      "traefik.http.routers.#{router_name}.priority=1000",
      "traefik.http.routers.#{router_name}.service=#{service_name}",
      "traefik.http.routers.#{router_name}.entrypoints=http",
      "traefik.http.services.#{service_name}.loadbalancer.server.port=#{internal_port}",
      "enkihost.app_id=#{@app.id}"
    ]

    if Rails.env.production?
      labels << "traefik.http.routers.#{router_name}.entrypoints=http,https"
      labels << "traefik.http.routers.#{router_name}.tls=true"
      labels << "traefik.http.routers.#{router_name}.tls.certresolver=letsencrypt"
    end

    # Environment variables
    env_args = @app.environment_variables.map do |ev|
      ["-e", "#{ev.key}=#{ev.value}"]
    end.flatten

    # Force production mode for Rails/Sinatra to ensure they use fixed DATABASE_URL
    if %w[rails sinatra].include?(@app.kind)
      env_args += ["-e", "RAILS_ENV=production", "-e", "RACK_ENV=production"]
    end

    # Addon environment variables
    @app.addons.running.each do |addon|
      case addon.kind
      when 'postgresql'
        env_args += ["-e", "DATABASE_URL=#{addon.config['url']}"]
      when 'redis'
        env_args += ["-e", "REDIS_URL=#{addon.config['url']}"]
      end
    end

    # Ensure network exists - we use 'coolify' to match the existing proxy on this server
    system("#{docker_bin} network create #{proxy_network}") rescue nil

    # Build full docker run command as array
    cmd_args = [
      docker_bin, "run", "-d", 
      "--name", container_name,
      "--network", proxy_network,
      "--cpus", @app.cpu_limit.to_s,
      "--memory", @app.memory_limit.to_s
    ]

    # Add volumes
    if @app.storages.any?
      @app.storages.each do |storage|
        cmd_args += ["-v", "#{storage.source}:#{storage.destination}"]
      end
    else
      # Default storage based on app kind and WORKDIR
      default_source = "enkihost-app-#{@app.id}-data"
      default_destination = case @app.kind
                            when 'rails' then "/rails/storage"
                            else "/app/storage"
                            end
      cmd_args += ["-v", "#{default_source}:#{default_destination}"]
    end
    
    # Add labels
    labels.each { |l| cmd_args += ["--label", l] }
    
    # Add environment variables
    cmd_args += env_args
    
    # Restart policy and image
    cmd_args += ["--restart", "unless-stopped", image_tag]
    
    # Log command without tokens (env vars already sanitized in system_cmd logs)
    system_cmd_array(cmd_args)
    
    wait_for_readiness(container_name)
    
    log("Container #{container_name} started and healthy! Access it at http://#{domain}")
  end

  def wait_for_readiness(container_name)
    log("Waiting for container #{container_name} to be ready...")
    
    max_retries = 30
    retries = 0
    
    loop do
      # Check if container is running
      is_running = `#{docker_bin} inspect -f '{{.State.Running}}' #{container_name}`.strip == 'true' rescue false
      
      if is_running
        log("Container is running.")
        break
      end
      
      retries += 1
      if retries >= max_retries
        log("ERROR: Container failed to become ready after 30 seconds.")
        # If the container didn't start, we should probably stop it and raise error
        system("#{docker_bin} stop #{container_name}") rescue nil
        system("#{docker_bin} rm #{container_name}") rescue nil
        raise "Container readiness timeout"
      end
      
      sleep 1
    end
  end

  def prepare_build_directory
    if Dir.exist?(@build_path)
      FileUtils.rm_rf(Dir.glob("#{@build_path}/*", File::FNM_DOTMATCH))
    else
      FileUtils.mkdir_p(@build_path)
    end
    log("Prepared build directory at #{@build_path}")
  end

  def clone_repository
    # Use the robust cleaning helper from CoolifyService
    url = CoolifyService.new.clean_repo_url(@app)
    log("Cloning repository: #{@app.repository_url} (branch: #{@app.branch})...")
    
    # Set GIT_TERMINAL_PROMPT=0 to avoid hanging on private repositories
    env = { 'GIT_TERMINAL_PROMPT' => '0', 'GIT_SSH_COMMAND' => 'ssh -o BatchMode=yes' }
    
    # Mask the token in the log command
    log_url = @app.repository_url
    log_cmd = "git clone --branch #{@app.branch} --depth 1 #{log_url} ."
    
    system_cmd_array(["git", "clone", "--branch", @app.branch, "--depth", "1", url, "."], env, log_cmd)
  end

  def generate_dockerfile
    if File.exist?(File.join(@build_path, "Dockerfile"))
      log("Using existing Dockerfile from repository")
      return
    end

    dockerfile_content = case @app.kind
                         when 'rails'
                           rails_dockerfile
                         when 'sinatra'
                           sinatra_dockerfile
                         when 'jekyll'
                           jekyll_dockerfile
                         end
    
    File.write(File.join(@build_path, 'Dockerfile'), dockerfile_content)
    log("Generated Dockerfile for #{@app.kind}")
  end

  def build_image
    image_tag = "enkihost-#{@app.id}-#{@deployment.id}"
    log("Building Docker image: #{image_tag}...")
    
    system_cmd_array([docker_bin, "build", "-t", image_tag, "."])
    log("Docker image built successfully: #{image_tag}")
  end

  def system_cmd_array(command_args, env = {}, log_command = nil)
    # Sanitize tokens in log output
    display_command = log_command || command_args.join(' ')
    display_command = sanitize_message(display_command)
    
    # Use popen2e with array to bypass shell
    Open3.popen2e(env, *command_args, chdir: @build_path) do |_stdin, stdout_and_stderr, wait_thr|
      buffer = ""
      last_flush = Time.current

      stdout_and_stderr.each_line do |line|
        buffer << sanitize_message(line)
        # Flush every 1KB or 2 seconds
        if buffer.size > 1024 || Time.current - last_flush > 2
          log(buffer)
          buffer = ""
          last_flush = Time.current
        end
      end
      
      log(buffer) unless buffer.empty?

      unless wait_thr.value.success?
        raise "Command failed: #{display_command}"
      end
    end
  end

  def sanitize_message(message)
    return message if message.blank?
    sanitized = message
    if @app.user.github_token.present?
      sanitized = sanitized.gsub(@app.user.github_token, '****')
    end
    if @app.user.gitlab_token.present?
      sanitized = sanitized.gsub(@app.user.gitlab_token, '****')
    end
    sanitized
  end

  # Keep old method for safety during transition (though we replaced all calls)
  def system_cmd(command, env = {}, log_command = nil)
    system_cmd_array(command.split(' '), env, log_command)
  end

  def log(message)
    timestamped_message = "\n[#{Time.current}] #{message}"
    # Use update_all with SQL concatenation to avoid loading the whole log into memory.
    Deployment.where(id: @deployment.id).update_all(
      "log = COALESCE(log, '') || #{Deployment.connection.quote(timestamped_message)}"
    )
    
    # Broadcast to frontend via ActionCable
    begin
      LogsChannel.broadcast_to(@app, { message: timestamped_message })
    rescue => e
      Rails.logger.error "ActionCable Broadcast Error in DockerService: #{e.message}"
    end
  end

  def docker_bin
    self.class.docker_bin
  end

  # Templates for Dockerfiles
  def rails_dockerfile
    <<~DOCKERFILE
      FROM ruby:3.3.10-slim
      RUN apt-get update -qq && apt-get install -y build-essential libpq-dev nodejs libyaml-dev
      WORKDIR /rails
      COPY Gemfile Gemfile.lock ./
      RUN bundle install
      COPY . .
      EXPOSE 3000
      CMD ["rails", "server", "-b", "0.0.0.0"]
    DOCKERFILE
  end

  def sinatra_dockerfile
    <<~DOCKERFILE
      FROM ruby:3.3.7-slim
      RUN apt-get update -qq && apt-get install -y build-essential libyaml-dev libpq-dev
      WORKDIR /app
      COPY Gemfile* ./
      RUN bundle install
      COPY . .
      EXPOSE 4567
      CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
    DOCKERFILE
  end

  def jekyll_dockerfile
    <<~DOCKERFILE
      FROM ruby:3.3.10-slim AS build
      RUN apt-get update -qq && apt-get install -y build-essential libyaml-dev
      WORKDIR /rails
      COPY Gemfile* ./
      RUN bundle install
      COPY . .
      RUN bundle exec jekyll build

      FROM nginx:alpine
      # Explicitly set Nginx config to ensure it listens on 80 and serves /usr/share/nginx/html
      RUN echo 'server { \
          listen 80; \
          server_name localhost; \
          location / { \
              root /usr/share/nginx/html; \
              index index.html index.htm; \
              try_files $uri $uri/ /index.html; \
          } \
      }' > /etc/nginx/conf.d/default.conf

      COPY --from=build /rails/_site /usr/share/nginx/html
      EXPOSE 80
      CMD ["nginx", "-g", "daemon off;"]
    DOCKERFILE
  end
end
