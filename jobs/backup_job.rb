require 'shellwords'

class BackupJob < ApplicationJob
  queue_as :default

  def perform(user_id = nil, addon_id = nil)
    if user_id.blank?
      Rails.logger.warn "BackupJob: called without user_id, skipping."
      return
    end

    user = User.find_by(id: user_id)
    unless user
      Rails.logger.warn "BackupJob: User #{user_id} not found, skipping."
      return
    end

    addon = user.addons.find_by(id: addon_id) if addon_id
    
    Rails.logger.info "Starting PostgreSQL backup job for user #{user.id}..."
    
    script_path = Rails.root.join("bin", "backup_db.sh")
    
    unless File.exist?(script_path)
      Rails.logger.error "Backup script not found at #{script_path}"
      return
    end

    # Create a record in the DB
    backup_record = user.backups.create!(status: "pending", filename: "pending...", addon: addon)

    # Fetch user's S3 config
    config = user.backup_configuration
    
    env_vars = {
      "DATABASE_URL" => addon&.database_url || ENV['DATABASE_URL'],
      "S3_BUCKET" => config&.s3_bucket || ENV['BACKUP_S3_BUCKET'],
      "AWS_ACCESS_KEY_ID" => config&.s3_access_key_id || ENV['AWS_ACCESS_KEY_ID'],
      "AWS_SECRET_ACCESS_KEY" => config&.s3_secret_access_key || ENV['AWS_SECRET_ACCESS_KEY'],
      "AWS_DEFAULT_REGION" => config&.s3_region || ENV['AWS_DEFAULT_REGION'] || 'us-east-1',
      "BACKUP_S3_ENDPOINT" => config&.s3_endpoint || ENV['BACKUP_S3_ENDPOINT']
    }

    # Execute the backup script with custom env vars
    env_string = env_vars.map { |k, v| "#{k}=#{Shellwords.escape(v.to_s)}" }.join(" ")
    output = `#{env_string} #{script_path} 2>&1`
    status = $?

    if status.success?
      filename = output.match(/Backup created: (.*)/)&.captures&.first || "unknown"
      
      backup_record.update!(
        status: "success",
        filename: filename,
        s3_key: "backups/#{filename}"
      )
      
      Rails.logger.info "PostgreSQL backup completed successfully for user #{user.id}."
    else
      backup_record.update!(status: "failed")
      Rails.logger.error "PostgreSQL backup failed for user #{user.id} with status #{status.exitstatus}."
      Rails.logger.error output
    end
  end
end
