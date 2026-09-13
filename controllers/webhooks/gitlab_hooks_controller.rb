# frozen_string_literal: true

module Webhooks
  class GitlabHooksController < ::ApplicationController
    skip_before_action :authenticate_request!, only: [:create]

    post_action '/webhooks/gitlab/:app_id', :create do
      create
    end

    helpers do
      def create
        set_app
        verify_token!

        request.body.rewind if request.body.respond_to?(:rewind)
        payload_body = request.body.read
        event = request.env['HTTP_X_GITLAB_EVENT']
        payload = JSON.parse(payload_body)

        handle_push_event(payload) if event == 'Push Hook'

        status 200
        ''
      rescue StandardError => e
        warn "GitLab Webhook Error: #{e.message}"
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
            log: "Auto-deployment triggered by GitLab push to #{branch}\n"
          )
          DeploymentJob.perform_later(deployment.id) if defined?(DeploymentJob)
        end
      end

      def verify_token!
        provided_token = request.env['HTTP_X_GITLAB_TOKEN'].to_s
        expected_token = @app.webhook_secret.to_s

        unless Rack::Utils.secure_compare(provided_token, expected_token)
          raise "GitLab token didn't match!"
        end
      end
    end
  end
end
