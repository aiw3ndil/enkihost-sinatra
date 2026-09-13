# frozen_string_literal: true

require 'aws-sdk-s3'

module Api
  module V1
    class BackupsController < Api::V1::ApplicationController
      get_action '/api/v1/backups', :index do
        index
      end

      post_action '/api/v1/backups', :create do
        create
      end

      get_action '/api/v1/backups/:id/download', :download do
        download
      end

      helpers do
        def index
          backups = current_user.backups.order(created_at: :desc).limit(10)
          backups.to_json
        end

        def create
          BackupJob.perform_later(current_user.id, params[:addon_id]) if defined?(BackupJob)
          status 202
          { message: 'Backup job queued' }.to_json
        end

        def download
          backup = current_user.backups.find(params[:id])

          if backup.status == 'success'
            config = current_user.backup_configuration

            s3 = Aws::S3::Resource.new(
              access_key_id: config&.s3_access_key_id || ENV['AWS_ACCESS_KEY_ID'],
              secret_access_key: config&.s3_secret_access_key || ENV['AWS_SECRET_ACCESS_KEY'],
              region: config&.s3_region || ENV['AWS_DEFAULT_REGION'] || 'us-east-1',
              endpoint: config&.s3_endpoint || ENV['BACKUP_S3_ENDPOINT']
            )

            bucket = s3.bucket(config&.s3_bucket || ENV['BACKUP_S3_BUCKET'])
            obj = bucket.object(backup.s3_key)

            url = obj.presigned_url(:get, expires_in: 3600)
            { url: url }.to_json
          else
            status 404
            { error: 'Backup not available' }.to_json
          end
        rescue ActiveRecord::RecordNotFound
          status 404
          { error: 'Backup not found' }.to_json
        end
      end
    end
  end
end
