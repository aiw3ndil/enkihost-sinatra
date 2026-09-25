class AddonService
  def initialize(addon)
    @addon = addon
    @app = addon.app
  end

  def provision
    case @addon.kind
    when 'postgresql'
      provision_postgresql
    when 'redis'
      provision_redis
    end
  rescue StandardError => e
    @addon.update!(status: :failed)
    raise e
  end

  def deprovision
    container_name = "enkihost-addon-#{@addon.id}"
    bin = docker_bin
    Rails.logger.info "[AddonService] Deprovisioning database/addon container: #{container_name}"
    system("#{bin} stop #{container_name} >/dev/null 2>&1")
    system("#{bin} rm -f #{container_name} >/dev/null 2>&1")
    system("#{bin} volume rm #{container_name}-data >/dev/null 2>&1")
  end

  def start
    bin = docker_bin
    system("#{bin} start enkihost-addon-#{@addon.id} >/dev/null 2>&1")
  end

  def stop
    bin = docker_bin
    system("#{bin} stop enkihost-addon-#{@addon.id} >/dev/null 2>&1")
  end

  def restart
    bin = docker_bin
    system("#{bin} restart enkihost-addon-#{@addon.id} >/dev/null 2>&1")
  end

  private

  def docker_bin
    defined?(DockerService) ? DockerService.docker_bin : 'docker'
  end

  def provision_postgresql
    password = SecureRandom.hex(16)
    user = 'enkihost'
    db_name = 'main'
    container_name = "enkihost-addon-#{@addon.id}"
    
    # Ensure network exists
    network_name = ENV['COOLIFY_TOKEN'].present? ? 'coolify' : 'enkihost-proxy'
    system("docker network create #{network_name}") rescue nil

    # Run Postgres container
    # We use alpine for smaller image size
    memory_limit = @addon.user.limits[:postgresql_limit]
    
    # Remove existing container if it exists to avoid name collision
    system("docker rm -f #{container_name} 2>/dev/null")

    cmd = "docker run -d \
      --name #{container_name} \
      --network #{network_name} \
      --memory #{memory_limit} \
      -e POSTGRES_USER=#{user} \
      -e POSTGRES_PASSWORD=#{password} \
      -e POSTGRES_DB=#{db_name} \
      --restart unless-stopped \
      postgres:alpine"
    
    unless system(cmd)
      raise "Failed to start PostgreSQL container"
    end

    url = "postgres://#{user}:#{password}@#{container_name}:5432/#{db_name}"
    @addon.update!(
      status: :running,
      config: {
        url: url,
        user: user,
        password: password,
        database: db_name,
        host: container_name,
        port: 5432
      }
    )
  end

  def provision_redis
    container_name = "enkihost-addon-#{@addon.id}"
    
    # Ensure network exists
    network_name = ENV['COOLIFY_TOKEN'].present? ? 'coolify' : 'enkihost-proxy'
    system("docker network create #{network_name}") rescue nil

    # Remove existing container if it exists to avoid name collision
    system("docker rm -f #{container_name} 2>/dev/null")

    # Run Redis container
    memory_limit = @addon.user.limits[:redis_limit]
    cmd = "docker run -d \
      --name #{container_name} \
      --network #{network_name} \
      --memory #{memory_limit} \
      --restart unless-stopped \
      redis:alpine"
    
    unless system(cmd)
      raise "Failed to start Redis container"
    end

    url = "redis://#{container_name}:6379"
    @addon.update!(
      status: :running,
      config: {
        url: url,
        host: container_name,
        port: 6379
      }
    )
  end
end
