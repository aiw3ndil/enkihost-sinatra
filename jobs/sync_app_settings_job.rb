class SyncAppSettingsJob < ApplicationJob
  queue_as :default

  def perform(app_id)
    app = App.find_by(id: app_id)
    return unless app

    refresh_local_routing(app) if app.local?

    if app.coolify_uuid.present?
      # We can create a dummy deployment or just log to a specific sync log
      # For now, we'll just use the service directly. 
      # If the user has a running deployment, this might be redundant but safe.
      CoolifyService.new.sync_settings(app)
    end
  end

  private

  # Locally deployed containers carry their Traefik rules as labels, so a domain change
  # only takes effect once the container is recreated. While a deployment is in progress
  # its container may already have been started with the old domains, so try again later.
  def refresh_local_routing(app)
    if app.deployments.where(status: %w[queued building]).exists?
      self.class.perform_in(30, app.id)
      return
    end

    DockerService.refresh_routing(app)
  end
end
