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
    # Uses DockerService.cleanup_app_resources to remove containers, volumes, and images
    if defined?(DockerService)
      begin
        DockerService.cleanup_app_resources(app_id)
      rescue => e
        Rails.logger.error "CleanupJob: Docker error during cleanup: #{e.message}"
      end
    end
  end
end
