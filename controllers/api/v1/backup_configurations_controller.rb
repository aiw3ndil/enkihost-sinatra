# frozen_string_literal: true

module Api
  module V1
    class BackupConfigurationsController < Api::V1::ApplicationController
      get_action '/api/v1/backup_configuration', :show do
        show
      end

      put_action '/api/v1/backup_configuration', :update do
        update
      end

      patch_action '/api/v1/backup_configuration', :update do
        update
      end

      helpers do
        def show
          config = current_user.backup_configuration || current_user.create_backup_configuration
          config.to_json
        end

        def update
          config = current_user.backup_configuration || current_user.build_backup_configuration

          if config.update(backup_config_params)
            config.to_json
          else
            status 422
            { errors: config.errors.full_messages }.to_json
          end
        end

        private

        def backup_config_params
          source = params[:backup_configuration].is_a?(Hash) ? params[:backup_configuration] : params
          permitted = %i[s3_access_key_id s3_secret_access_key s3_bucket s3_region s3_endpoint]
          filtered = {}
          permitted.each do |k|
            filtered[k] = source[k] if source.key?(k)
            filtered[k] = source[k.to_s] if source.key?(k.to_s)
          end
          filtered
        end
      end
    end
  end
end
