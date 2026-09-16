# frozen_string_literal: true

require 'enkimail'
require 'mail'

class DeploymentMailer
  class MessageDelivery
    def initialize(action, deployment_id)
      @action = action.to_sym
      @deployment_id = deployment_id
    end

    def deliver_later
      SendDeploymentEmailJob.perform_later(@action.to_s, @deployment_id)
    rescue StandardError => e
      warn "[DeploymentMailer] Error enqueuing email: #{e.message}. Fallback to deliver_now."
      deliver_now
    end

    def deliver_now
      DeploymentMailer.deliver_now(@action, @deployment_id)
    end
  end

  class << self
    def success(deployment)
      MessageDelivery.new(:success, deployment.id)
    end

    def failure(deployment)
      MessageDelivery.new(:failure, deployment.id)
    end

    def deliver_now(action, deployment_id)
      api_key = ENV['ENKIMAIL_API_KEY']
      if api_key.nil? || api_key.strip.empty?
        puts "[DeploymentMailer] ENKIMAIL_API_KEY not configured. Skipping email."
        return false
      end

      deployment = Deployment.find_by(id: deployment_id)
      unless deployment
        puts "[DeploymentMailer] Deployment #{deployment_id} not found."
        return false
      end

      app = deployment.app
      user = app&.user
      unless user&.email.present?
        puts "[DeploymentMailer] No user email found for deployment #{deployment_id}."
        return false
      end

      from_address = ENV['ENKIMAIL_FROM_EMAIL'] || ENV['MAILER_SENDER'] || 'notifications@enkihost.com'
      domain = app.domains.first&.fqdn || "#{app.subdomain}.enkihost.com"
      app_name = app.name || 'Application'

      subject, body_text, html_body = build_email_content(action, app_name, domain, user.name, deployment)

      raw_base_url = ENV['ENKIMAIL_BASE_URL'].presence || 'https://api.enkimail.com'
      # Prevent HTTP 307 redirects (http:// -> https:// or apex enkimail.com -> api.enkimail.com)
      base_url = raw_base_url.sub(%r{\Ahttp://api\.enkimail\.com}i, 'https://api.enkimail.com')
      base_url = base_url.sub(%r{\Ahttps?://(?:www\.)?enkimail\.com/?\z}i, 'https://api.enkimail.com')

      # Ensure Mail defaults are set with Enkimail::DeliveryMethod
      Mail.defaults do
        delivery_method Enkimail::DeliveryMethod,
                        api_key: api_key,
                        base_url: base_url
      end

      response = Mail.deliver do
        to user.email
        from from_address
        subject subject

        text_part do
          body body_text
        end

        html_part do
          content_type 'text/html; charset=UTF-8'
          body html_body
        end
      end

      puts "[DeploymentMailer] Email sent successfully for deployment #{deployment.id} to #{user.email}"
      response
    rescue StandardError => e
      warn "[DeploymentMailer] Failed to send email: #{e.class} - #{e.message}"
      nil
    end

    private

    def build_email_content(action, app_name, domain, user_name, deployment)
      name = user_name.presence || 'Developer'

      if action.to_sym == :success
        subject = "✅ [EnkiHost] Deployment successful: #{app_name}"
        body_text = <<~TEXT
          Hi #{name},

          Great news! Your deployment ##{deployment.id} for "#{app_name}" was successful.
          App URL: https://#{domain}

          Best regards,
          The EnkiHost Team
        TEXT

        html_body = <<~HTML
          <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 580px; margin: 0 auto; padding: 24px; border: 1px solid #e2e8f0; border-radius: 8px;">
            <h2 style="color: #0f172a; margin-top: 0;">Deployment Successful 🎉</h2>
            <p style="color: #334155; font-size: 15px;">Hi <strong>#{name}</strong>,</p>
            <p style="color: #334155; font-size: 15px;">Your deployment for <strong>#{app_name}</strong> (##{deployment.id}) has finished successfully.</p>
            <div style="margin: 24px 0;">
              <a href="https://#{domain}" style="background-color: #2563eb; color: #ffffff; padding: 10px 20px; text-decoration: none; border-radius: 6px; font-weight: 500; display: inline-block;">Open Application</a>
            </div>
            <p style="color: #64748b; font-size: 13px;">URL: <a href="https://#{domain}" style="color: #2563eb;">https://#{domain}</a></p>
            <hr style="border: none; border-top: 1px solid #e2e8f0; margin: 24px 0;" />
            <p style="color: #94a3b8; font-size: 12px; margin-bottom: 0;">EnkiHost Cloud Platform</p>
          </div>
        HTML
      else
        subject = "❌ [EnkiHost] Deployment failed: #{app_name}"
        body_text = <<~TEXT
          Hi #{name},

          Unfortunately, your deployment ##{deployment.id} for "#{app_name}" failed.
          Please check the build logs in your dashboard.

          Best regards,
          The EnkiHost Team
        TEXT

        html_body = <<~HTML
          <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 580px; margin: 0 auto; padding: 24px; border: 1px solid #fee2e2; border-radius: 8px;">
            <h2 style="color: #b91c1c; margin-top: 0;">Deployment Failed ⚠️</h2>
            <p style="color: #334155; font-size: 15px;">Hi <strong>#{name}</strong>,</p>
            <p style="color: #334155; font-size: 15px;">Your deployment for <strong>#{app_name}</strong> (##{deployment.id}) encountered an error during build or startup.</p>
            <p style="color: #334155; font-size: 14px;">Please visit your EnkiHost dashboard to view the error logs.</p>
            <hr style="border: none; border-top: 1px solid #fee2e2; margin: 24px 0;" />
            <p style="color: #94a3b8; font-size: 12px; margin-bottom: 0;">EnkiHost Cloud Platform</p>
          </div>
        HTML
      end

      [subject, body_text, html_body]
    end
  end
end
