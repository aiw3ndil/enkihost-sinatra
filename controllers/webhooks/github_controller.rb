# frozen_string_literal: true

require 'openssl'

module Webhooks
  class GithubController < ::ApplicationController
    skip_before_action :authenticate_request!, only: [:create]

    post_action '/webhooks/github/:app_id', :create do
      create
    end

    helpers do
      def create
        set_app
        request.body.rewind if request.body.respond_to?(:rewind)
        payload_body = request.body.read

        verify_signature!(payload_body)

        event = request.env['HTTP_X_GITHUB_EVENT']
        payload = JSON.parse(payload_body)

        handle_push_event(payload) if event == 'push'

        status 200
        ''
      rescue StandardError => e
        warn "GitHub Webhook Error: #{e.message}"
        status 400
        { error: e.message }.to_json
      end

      private

      def set_app
        @app = App.find(params[:app_id])
      rescue ActiveRecord::RecordNotFound
        halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
      end

      def handle_push_event(payload)
        branch = payload.dig('ref')&.gsub('refs/heads/', '')
        commit_sha = payload.dig('after')

        if branch == @app.branch
          deployment = @app.deployments.create!(
            status: :queued,
            commit_sha: commit_sha,
            log: "Auto-deployment triggered by GitHub push to #{branch}\n"
          )
          DeploymentJob.perform_later(deployment.id) if defined?(DeploymentJob)
        end
      end

      def verify_signature!(payload_body)
        signature = 'sha256=' + OpenSSL::HMAC.hexdigest(
          OpenSSL::Digest.new('sha256'),
          @app.webhook_secret.to_s,
          payload_body
        )

        header_sig = request.env['HTTP_X_HUB_SIGNATURE_256'].to_s
        unless Rack::Utils.secure_compare(signature, header_sig)
          raise "Signatures didn't match!"
        end
      end
    end
  end
end
