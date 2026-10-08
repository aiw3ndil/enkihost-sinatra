require 'open3'
require 'shellwords'
require 'net/http'

class DockerService
  def initialize(deployment)
    @deployment = deployment
    @app = deployment.app
    @build_path = self.class.repo_cache_path(@app.id)
  end

  # Persistent per-app checkout: each deploy only fetches what changed.
  def self.repo_cache_path(app_id)
    Rails.root.join('tmp', 'repos', app_id.to_s)
  end

  def build
    with_build_lock do
      sync_repository
      generate_dockerfile
      build_image
    end
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

    # 4. Remove the cached repository checkout
    begin
      FileUtils.rm_rf(repo_cache_path(app_id))
      FileUtils.rm_f("#{repo_cache_path(app_id)}.lock")
    rescue StandardError => e
      warn "[DockerService] Error removing cached repository: #{e.message}"
    end

    # 5. Remove Docker build images for this app (enkihost-#{app_id}-*)
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
    env_args = @app.environment_variables.flat_map do |ev|
      value = ev.value
      if value.nil?
        log("WARNING: environment variable #{ev.key} could not be decrypted; not set. Re-save it in the app settings.")
        next []
      end
      ["-e", "#{ev.key}=#{value}"]
    end

    # Force production mode for Rails/Sinatra to ensure they use fixed DATABASE_URL
    if %w[rails sinatra].include?(@app.kind)
      env_args += ["-e", "RAILS_ENV=production", "-e", "RACK_ENV=production"]
    end

    # Ensure network exists - we use 'coolify' to match the existing proxy on this server
    system("#{docker_bin} network create #{proxy_network}") rescue nil

    # Addon environment variables. A running addon's URL wins over a user-defined
    # variable (it is appended last, and docker keeps the last -e for a key), but an
    # addon without a URL must never override the user's value with an empty one.
    @app.addons.running.each do |addon|
      env_key = { 'postgresql' => 'DATABASE_URL', 'redis' => 'REDIS_URL' }[addon.kind]
      next if env_key.nil?

      url = addon.config['url']
      if url.blank?
        log("WARNING: addon #{addon.id} (#{addon.kind}) has no URL in its config; #{env_key} not set from addon")
        next
      end

      # The app must share a network with the addon to resolve its hostname. Addons
      # provisioned without COOLIFY_TOKEN live on 'enkihost-proxy' instead of 'coolify'.
      addon_container = addon.config['host'].presence || "enkihost-addon-#{addon.id}"
      system("#{docker_bin} network connect #{proxy_network} #{addon_container} >/dev/null 2>&1")

      log("#{env_key} set from addon #{addon.id} (host: #{addon_container})")
      env_args += ["-e", "#{env_key}=#{url}"]
    end

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
    
    wait_for_readiness(container_name, proxy_network, internal_port)

    log("Container #{container_name} started and healthy! Access it at http://#{domain}")
  end

  STARTUP_TIMEOUT = 60      # seconds to wait for the container to reach 'running'
  STABILITY_WINDOW = 25     # seconds it must then stay running without restarting

  # The container is ready as soon as it answers HTTP on its internal port. A container
  # that crashes on boot is 'running' for a moment before restarting, so if the probe
  # cannot reach it (e.g. the worker is not on the proxy network) we fall back to
  # requiring it to stay up for STABILITY_WINDOW seconds. Otherwise the deployment
  # fails with the container logs, and the previous container is left untouched.
  def wait_for_readiness(container_name, network, port)
    log("Waiting for container #{container_name} to be ready...")

    deadline = Time.current + STARTUP_TIMEOUT
    running_since = nil

    loop do
      status, restarts = `#{docker_bin} inspect -f '{{.State.Status}} {{.RestartCount}}' #{container_name} 2>/dev/null`.strip.split(' ')

      if status == 'running' && restarts.to_i.zero?
        running_since ||= Time.current
        if http_responding?(container_name, network, port)
          log("Container is answering HTTP on port #{port} after #{(Time.current - running_since).round}s.")
          break
        elsif Time.current - running_since >= STABILITY_WINDOW
          log("Container has been running for #{STABILITY_WINDOW}s without restarts.")
          break
        end
      elsif restarts.to_i.positive? || %w[restarting exited dead].include?(status)
        fail_readiness(container_name, "Container crashed during startup (status: #{status || 'unknown'}, restarts: #{restarts.to_i})")
      elsif Time.current > deadline
        fail_readiness(container_name, "Container did not start within #{STARTUP_TIMEOUT}s (status: #{status || 'unknown'})")
      end

      sleep 1
    end
  end

  # Any HTTP response (including redirects and errors) means the server has booted.
  def http_responding?(container_name, network, port)
    ip = `#{docker_bin} inspect -f '{{with index .NetworkSettings.Networks "#{network}"}}{{.IPAddress}}{{end}}' #{container_name} 2>/dev/null`.strip
    return false if ip.blank?

    Net::HTTP.start(ip, port, open_timeout: 1, read_timeout: 2) { |http| http.head('/') }
    true
  rescue StandardError
    false
  end

  def fail_readiness(container_name, reason)
    log("ERROR: #{reason}. Last container logs:")
    container_logs, _status = Open3.capture2e(docker_bin, "logs", "--tail", "40", container_name)
    log(sanitize_message(container_logs.presence || "(no logs)"))

    system("#{docker_bin} rm -f #{container_name} >/dev/null 2>&1")
    raise reason
  end

  def force_rebuild?
    return true if ENV['FORCE_REBUILD'] == 'true'

    @app.environment_variables.any? { |ev| ev.key == 'ENKIHOST_FORCE_REBUILD' && ev.value.to_s.downcase == 'true' }
  end

  # The checkout is shared by all deployments of the app, so concurrent builds of
  # the same app wait for each other instead of overwriting the working tree.
  def with_build_lock
    FileUtils.mkdir_p(@build_path.dirname)
    File.open("#{@build_path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        log("Waiting for another build of this app to finish...")
        lock.flock(File::LOCK_EX)
      end
      yield
    end
  end

  # Fetches the branch tip into the cached checkout and resets the working tree to it,
  # dropping any files generated by the previous build. The authenticated URL is passed
  # to `git fetch` directly so the token is never stored in .git/config. If updating the
  # cache fails, it is discarded and the repository is fetched again from scratch.
  def sync_repository(fresh: false)
    url = CoolifyService.new.clean_repo_url(@app)
    cached = !fresh && Dir.exist?(File.join(@build_path, '.git'))

    if cached
      log("Updating cached repository: #{@app.repository_url} (branch: #{@app.branch})...")
    else
      FileUtils.rm_rf(@build_path)
      FileUtils.mkdir_p(@build_path)
      log("Cloning repository: #{@app.repository_url} (branch: #{@app.branch})...")
      system_cmd_array(["git", "init", "-q"])
    end

    # Set GIT_TERMINAL_PROMPT=0 to avoid hanging on private repositories
    env = { 'GIT_TERMINAL_PROMPT' => '0', 'GIT_SSH_COMMAND' => 'ssh -o BatchMode=yes' }
    log_cmd = "git fetch --depth 1 --no-tags #{@app.repository_url} #{@app.branch}"
    system_cmd_array(["git", "fetch", "--depth", "1", "--no-tags", url, @app.branch], env, log_cmd)
    system_cmd_array(["git", "reset", "--hard", "-q", "FETCH_HEAD"])
    system_cmd_array(["git", "clean", "-ffdxq"])

    commit = `git -C #{Shellwords.escape(@build_path.to_s)} rev-parse --short HEAD 2>/dev/null`.strip
    log("Repository at commit #{commit}") if commit.present?
  rescue StandardError => e
    raise unless cached

    log("Cached repository could not be updated (#{sanitize_message(e.message)}). Cloning from scratch...")
    sync_repository(fresh: true)
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

    # Keep .git out of the build context: it is sent to the daemon on every build
    # and would change the context checksum without affecting the image.
    dockerignore_path = File.join(@build_path, '.dockerignore')
    unless File.exist?(dockerignore_path)
      File.write(dockerignore_path, default_dockerignore)
      log("Generated default .dockerignore")
    end
  end

  def build_image
    image_tag = "enkihost-#{@app.id}-#{@deployment.id}"
    cmd = [docker_bin, "build", "-t", image_tag, "."]

    # Docker reuses cached layers by default. A clean rebuild can be forced platform-wide
    # (FORCE_REBUILD=true) or per app (ENKIHOST_FORCE_REBUILD=true env variable).
    if force_rebuild?
      cmd.insert(2, "--no-cache", "--pull")
      log("Building Docker image: #{image_tag} (force rebuild, no cache)...")
    else
      log("Building Docker image: #{image_tag}...")
    end

    system_cmd_array(cmd)
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

  def default_dockerignore
    <<~IGNORE
      .git
      log/*
      tmp/*
      node_modules
    IGNORE
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
