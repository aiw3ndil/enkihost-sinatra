class CleanupAppResourcesJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 3

  def perform(app_id, coolify_uuid)
    # 1. Cleanup Coolify (Remote)
    if coolify_uuid.present?
      Rails.logger.info "CleanupJob: Deleting Coolify app #{coolify_uuid}..."
      begin
        response = CoolifyService.new.delete_application(coolify_uuid)
      rescue => e
        Rails.logger.error "CleanupJob: Coolify error: #{e.message}"
      end
    end

    # 2. Cleanup Docker (Local)
    # We find all containers matching the pattern enkihost-app-#{app_id}-*
    # This ensures any dangling deployment containers are removed.
    pattern = "enkihost-app-#{app_id}-"
    Rails.logger.info "CleanupJob: Searching and deleting containers matching #{pattern}*"
    
    begin
      # List all container IDs matching the name
      stdout, stderr, status = Open3.capture3("docker ps -a --filter \"name=#{pattern}\" --format \"{{.Names}}\"")
      if status.success?
        container_names = stdout.split("\n")
        container_names.each do |name|
          # Doube check the name starts with our pattern for safety
          if name.start_with?(pattern)
            Rails.logger.info "CleanupJob: Removing container #{name}..."
            DockerService.remove_container(name)
          end
        end
      else
        Rails.logger.error "CleanupJob: Error listing containers: #{stderr}"
      end
    rescue => e
      Rails.logger.error "CleanupJob: Docker error during search: #{e.message}"
    end
  end
end
