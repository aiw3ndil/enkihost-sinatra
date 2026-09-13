class SyncAppSettingsJob < ApplicationJob
  queue_as :default

  def perform(app_id)
    app = App.find(app_id)
    return if app.coolify_uuid.blank?

    # We can create a dummy deployment or just log to a specific sync log
    # For now, we'll just use the service directly. 
    # If the user has a running deployment, this might be redundant but safe.
    CoolifyService.new.sync_settings(app)
  end
end
