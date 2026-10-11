# frozen_string_literal: true

require 'uri'

module Api
  module V1
    class GitlabController < Api::V1::ApplicationController
      skip_before_action :authenticate_request!, only: %i[callback connect]

      # Support both GET and POST for connect
      get_action '/api/v1/gitlab/connect', :connect do
        connect
      end
      post_action '/api/v1/gitlab/connect', :connect do
        connect
      end

      get_action '/api/v1/gitlab/callback', :callback do
        callback
      end
      post_action '/api/v1/gitlab/callback', :callback do
        callback
      end

      get_action '/api/v1/gitlab/repositories', :repositories do
        repositories
      end

      helpers do
        def repositories
          authenticate_request!
          unless current_user.gitlab_connected
            status 401
            return { error: 'GitLab not connected' }.to_json
          end

          begin
            service = GitlabService.new(current_user)
            unless current_user.gitlab_connected
              status 401
              return { error: 'GitLab session expired. Please reconnect.', message: 'GitLab session expired. Please reconnect.' }.to_json
            end

            service.projects.to_json
          rescue Gitlab::Error::Unauthorized
            current_user.disconnect_gitlab!
            status 401
            { error: 'GitLab session expired. Please reconnect.', message: 'GitLab session expired. Please reconnect.' }.to_json
          rescue StandardError => e
            warn "[GitlabController#repositories] Error: #{e.message}"
            status 500
            { error: "Failed to fetch repositories: #{e.message}", message: "Failed to fetch repositories: #{e.message}" }.to_json
          end
        end

        def connect
          user = current_user
          unless user
            status 401
            return { error: 'Authentication required' }.to_json
          end

          json_params = json_body
          code = params[:code] || json_params['code']
          token_param = params[:personal_access_token] || params[:token] ||
                        json_params['personal_access_token'] || json_params['token']
          redirect_uri_param = params[:redirect_uri] || json_params['redirect_uri']
          redirect_uri = GitlabService.redirect_uri(redirect_uri_param == 'undefined' ? nil : redirect_uri_param)

          # If Personal Access Token provided, connect immediately
          return connect_with_token(user, token_param) if token_param.present?

          if ENV['GITLAB_CLIENT_ID'].blank? || ENV['GITLAB_CLIENT_SECRET'].blank?
            warn '[GitlabController#connect] GITLAB_CLIENT_ID or GITLAB_CLIENT_SECRET is missing!'
            status 500
            return { error: 'GitLab configuration missing on server (GITLAB_CLIENT_ID or GITLAB_CLIENT_SECRET)' }.to_json
          end

          # If authorization code is provided, exchange it directly
          return exchange_and_connect(user, code, redirect_uri) if code.present?

          secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
          if secret.blank? || secret.length < 16
            status 500
            return { error: 'Security configuration missing or invalid on server' }.to_json
          end

          state = JWT.encode({
            user_id: user.id,
            exp: (Time.now + 600).to_i,
            redirect_uri: redirect_uri
          }, secret, 'HS256')

          { url: GitlabService.authorize_url(state, redirect_uri) }.to_json
        end

        def callback
          json_params = json_body
          code = params[:code] || json_params['code']
          state = params[:state] || json_params['state']

          if code.blank?
            status 422
            error_reason = params[:error_description] || params[:error] || 'Missing authorization code'
            return { error: "GitLab authorization failed: #{error_reason}" }.to_json
          end

          user = current_user
          redirect_uri = GitlabService.redirect_uri

          if state.present?
            begin
              secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
              state_payload = JWT.decode(state, secret, true, { algorithm: 'HS256' })[0]
              user ||= User.find_by(id: state_payload['user_id'])
              redirect_uri = state_payload['redirect_uri'] if state_payload['redirect_uri'].present?
            rescue StandardError => e
              warn "[GitlabController#callback] State decoding warning: #{e.message}"
            end
          end

          unless user
            status 401
            return { error: 'User could not be authenticated from session or state' }.to_json
          end

          exchange_and_connect(user, code, redirect_uri, is_callback: true)
        end

        def exchange_and_connect(user, code, redirect_uri, is_callback: false)
          begin
            data = GitlabService.exchange_code(code, redirect_uri)
            gitlab_user = GitlabService.client_for_token(data['access_token']).user
          rescue GitlabService::OAuthError => e
            warn "[GitlabController#exchange_and_connect] GitLab OAuth exchange failed: #{e.message}"
            status 422
            return {
              error: "Failed to obtain access token from GitLab: #{e.message}",
              message: "Failed to obtain access token from GitLab: #{e.message}"
            }.to_json
          rescue StandardError => e
            status 500
            return { error: "Failed to connect GitLab: #{e.message}" }.to_json
          end

          user.jti = User.generate_jti
          user.store_gitlab_oauth!(data, username: gitlab_user.username)
          new_token = generate_jwt_for(user)

          if is_callback && request.request_method == 'GET'
            frontend_url = ENV['FRONTEND_URL'] || 'https://enkihost.com'
            # The frontend callback page stores the session token and returns to the new app wizard.
            redirect "#{frontend_url}/callback/gitlab?token=#{new_token}"
          else
            connected_response(user, new_token)
          end
        end

        def connect_with_token(user, pat_token)
          token = pat_token.to_s.strip
          if token.blank?
            status 422
            return { error: 'GitLab token cannot be blank' }.to_json
          end

          begin
            gitlab_user = GitlabService.client_for_token(token).user
          rescue Gitlab::Error::Unauthorized
            status 401
            return { error: 'Invalid GitLab Personal Access Token. Please check token permissions.' }.to_json
          rescue StandardError => e
            status 500
            return { error: "Failed to verify GitLab token: #{e.message}" }.to_json
          end

          # Personal access tokens are not refreshed, so no refresh token or expiry is stored.
          user.update!(
            gitlab_token: token,
            gitlab_refresh_token: nil,
            gitlab_token_expires_at: nil,
            gitlab_username: gitlab_user.username,
            jti: User.generate_jti
          )
          new_token = generate_jwt_for(user)

          headers['Authorization'] = "Bearer #{new_token}"
          connected_response(user, new_token)
        end

        def connected_response(user, new_token)
          status 200
          {
            status: 200,
            success: true,
            message: 'GitLab connected successfully',
            gitlab_connected: true,
            gitlab_username: user.gitlab_username,
            token: new_token,
            auth_token: new_token,
            user: {
              id: user.id,
              email: user.email,
              name: user.name,
              gitlab_connected: true,
              gitlab_username: user.gitlab_username
            }
          }.to_json
        end

        def json_body
          return {} unless request.body

          body_str = request.body.read
          request.body.rewind if request.body.respond_to?(:rewind)
          parsed = body_str.present? ? JSON.parse(body_str) : {}
          parsed.is_a?(Hash) ? parsed : {}
        rescue StandardError => e
          warn "[GitlabController] Body parsing error: #{e.message}"
          {}
        end
      end
    end
  end
end
