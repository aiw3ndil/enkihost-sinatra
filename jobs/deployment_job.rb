class DeploymentJob < ApplicationJob
  queue_as :default

  def perform(deployment_id)
    deployment = Deployment.find(deployment_id).reload
    return unless deployment.queued?

    deployment.update!(status: :building, log: "Starting REAL deployment for #{deployment.app.name}...\n")
    broadcast_status(deployment)
    log_update(deployment, "Status updated to building. Checking for COOLIFY_TOKEN...")
    
    begin
      # FORCE LOCAL for private repositories if there are sync issues, or respect setting.
      # If deployment_type is missing (stale DB), it will fall through to 'else' which is LOCAL.
      use_coolify = false
      begin
        use_coolify = deployment.app.coolify? && ENV['COOLIFY_TOKEN'].present?
      rescue => e
        log_update(deployment, "⚠️ Warning: Could not determine deployment type from DB (#{e.message}). Defaulting to LOCAL for safety.")
        use_coolify = false
      end

      if use_coolify
        log_update(deployment, "Coolify deployment requested. Initializing CoolifyService...")
        coolify = CoolifyService.new
        log_update(deployment, "Calling create_application...")
        result = coolify.create_application(deployment.app, deployment)
        
        coolify_uuid = result[:coolify_uuid]
        deployment_uuid = result[:deployment_uuid]
        
        log_update(deployment, "Coolify application: #{coolify_uuid}, Deployment: #{deployment_uuid}")
        
        if deployment_uuid.blank?
          log_update(deployment, "ERROR: Could not retrieve Deployment UUID from Coolify. API Response was: #{result.to_json}")
          raise "Deployment UUID missing"
        end

        log_update(deployment, "Monitoring logs...")

        # Poll logs for up to 20 minutes (120 * 10 seconds)
        success = false
        last_log_count = 0
        current_remote_status = nil
        
        120.times do |i|
          status_data = coolify.get_deployment_logs(deployment_uuid)
          
          if status_data.nil?
            log_update(deployment, "Waiting for deployment data to be available (Attempt #{i+1})...") if i % 6 == 0
          else
            status = status_data['status'] || 'in_progress'
            
            if status != current_remote_status
              log_update(deployment, "Coolify status changed: #{current_remote_status} -> #{status}")
              current_remote_status = status
            end

            logs = status_data['logs'] || []

            if logs.is_a?(Array) && logs.any?
              all_messages = logs.map { |l| l.is_a?(Hash) ? l['message'] : l.to_s }
              if all_messages.size > last_log_count
                new_lines = all_messages[last_log_count..-1]
                log_update(deployment, "[Coolify] #{new_lines.join("\n[Coolify] ")}")
                last_log_count = all_messages.size
              end
            elsif logs.is_a?(String) && logs.present?
              if logs.length > last_log_count
                new_content = logs[last_log_count..-1]
                log_update(deployment, "[Coolify]\n#{new_content}")
                last_log_count = logs.length
              end
            end

            if %w[finished success completed].include?(status)
              log_update(deployment, "Coolify reports SUCCESS. Finalizing deployment...")
              deployment.update!(status: :success)
              broadcast_status(deployment) # Update UI immediately
              success = true
              break
            elsif %w[failed error cancelled].include?(status)
              log_update(deployment, "BUILD FAILED. Coolify reported status: #{status}")
              
              # Extract as much log information as possible from the failure
              error_msg = status_data['error'] || status_data['message']
              
              if error_msg.present?
                log_update(deployment, "ERROR FROM COOLIFY: #{error_msg}")
              end

              # Try to get the last few log lines which often contain the actual error
              if status_data['logs'].is_a?(Array) && status_data['logs'].any?
                last_logs = status_data['logs'].last(10).map{|l| l.is_a?(Hash) ? l['message'] : l.to_s}.join("\n")
                log_update(deployment, "LAST BUILD LOGS:\n#{last_logs}")
              end

              # CRITICAL: Also fetch application/container logs if the app became unhealthy
              if deployment.app.coolify_uuid.present?
                app_logs_data = coolify.get_application_logs(deployment.app.coolify_uuid)
                if app_logs_data.present?
                  # Handle both Hash (JSON) and String responses
                  logs_string = if app_logs_data.is_a?(Hash)
                                  app_logs_data['logs'] || app_logs_data['message'] || app_logs_data.to_s
                                elsif app_logs_data.is_a?(Array)
                                  app_logs_data.map { |l| l.is_a?(Hash) ? l['message'] : l.to_s }.join("\n")
                                else
                                  app_logs_data.to_s
                                end
                  
                  log_update(deployment, "--- RUNTIME CONTAINER LOGS (Post-Failure) ---\n#{logs_string.split("\n").last(20).join("\n")}")
                end
              end

              # If it's a repository error (exit code 128), it's likely a corrupted URL in Coolify
              if logs_string.present? && (logs_string.include?("Command execution failed (exit code 128)") || (logs_string.include?("repository") && logs_string.include?("not found")))
                log_update(deployment, "  ! Detected repository corruption in Coolify. Clearing UUID to force recreation next time.")
                deployment.app.update!(coolify_uuid: nil)
              end

              raise "Coolify build failed: #{error_msg || status}"
            end
          end
          sleep 10
        end
        
        raise "Coolify deployment timed out after 20 minutes" if !success && deployment_uuid.present?
      else
        log_update(deployment, "Local deployment requested. Initializing DockerService...")
        docker_service = DockerService.new(deployment)
        docker_service.build
        docker_service.run_container
        deployment.update!(status: :success)
      end

      deployment.app.update!(runtime_status: :running)
      broadcast_status(deployment)
      
      app = deployment.app.reload
      domain = app.domains.first&.fqdn || "#{app.subdomain}.enkihost.com"
      
      log_update(deployment, "Deployment successful! App is now running at https://#{domain}")
      DeploymentMailer.success(deployment).deliver_later

    rescue StandardError => e
      log_update(deployment, "ERROR during deployment: #{e.message}")
      deployment.update!(status: :failed)
      broadcast_status(deployment)
      DeploymentMailer.failure(deployment).deliver_later
    end
  end

  private

  def log_update(deployment, message)
    timestamped_message = "\n[#{Time.current}] #{message}"
    Deployment.where(id: deployment.id).update_all(
      "log = COALESCE(log, '') || #{Deployment.connection.quote(timestamped_message)}"
    )
    # Standardize broadcast as a hash
    begin
      LogsChannel.broadcast_to(deployment.app, { message: timestamped_message })
    rescue => e
      Rails.logger.error "ActionCable Broadcast Error: #{e.message}"
    end
  end

  def broadcast_status(deployment)
    begin
      LogsChannel.broadcast_to(
        deployment.app, 
        type: 'status_update',
        status: deployment.status,
        deployment_id: deployment.id
      )
    rescue => e
      Rails.logger.error "ActionCable Broadcast Error: #{e.message}"
    end
  end
end
