# frozen_string_literal: true

require 'octokit'
require 'faraday'
require 'uri'

module Api
  module V1
    class GithubController < Api::V1::ApplicationController
      skip_before_action :authenticate_request!, only: %i[callback connect]

      # Support both GET and POST for connect
      get_action '/api/v1/github/connect', :connect do
        connect
      end
      post_action '/api/v1/github/connect', :connect do
        connect
      end

      get_action '/api/v1/github/callback', :callback do
        callback
      end
      post_action '/api/v1/github/callback', :callback do
        callback
      end

      get_action '/api/v1/github/repositories', :repositories do
        repositories
      end

      helpers do
        def repositories
          authenticate_request!
          unless current_user.github_token.present?
            status 401
            return { error: 'GitHub not connected' }.to_json
          end

          begin
            client = Octokit::Client.new(
              access_token: current_user.github_token,
              connection_options: {
                request: { timeout: 10, open_timeout: 5 }
              }
            )
            repos = client.repositories(nil, sort: 'updated', direction: 'desc', per_page: 100)

            repos.map do |r|
              {
                id: r.id,
                name: r.name,
                full_name: r.full_name,
                html_url: r.html_url,
                default_branch: r.default_branch,
                private: r.private
              }
            end.to_json
          rescue Octokit::Unauthorized
            current_user.update_columns(github_token: nil, github_username: nil)
            status 401
            { error: 'GitHub session expired. Please reconnect.', message: 'GitHub session expired. Please reconnect.' }.to_json
          rescue StandardError => e
            warn "[GithubController#repositories] Error: #{e.message}"
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

          # Extract code from query params or JSON body
          code = params[:code]
          if code.blank? && request.body
            begin
              body_str = request.body.read
              request.body.rewind if request.body.respond_to?(:rewind)
              if body_str.present?
                json_params = JSON.parse(body_str)
                code ||= json_params['code'] || json_params[:code]
              end
            rescue StandardError => e
              warn "[GithubController#connect] Body parsing error: #{e.message}"
            end
          end

          # If authorization code is provided, exchange it directly
          if code.present?
            return exchange_and_connect(user, code)
          end

          # Otherwise, generate GitHub authorization URL
          client_id = ENV['GITHUB_CLIENT_ID'] || Rails.application.credentials.github_client_id
          if client_id.blank?
            warn '[GithubController#connect] GITHUB_CLIENT_ID is missing!'
            status 500
            return { error: 'GitHub configuration missing on server' }.to_json
          end

          redirect_uri_param = params[:redirect_uri]
          redirect_uri = if redirect_uri_param.present? && redirect_uri_param != 'undefined'
                           redirect_uri_param
                         else
                           'https://api.enkihost.com/api/v1/github/callback'
                         end

          scope = 'repo,user'
          secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
          if secret.blank? || secret.length < 16
            status 500
            return { error: 'Security configuration missing or invalid on server' }.to_json
          end

          begin
            state = JWT.encode({
              user_id: user.id,
              exp: (Time.now + 600).to_i,
              redirect_uri: redirect_uri
            }, secret, 'HS256')
          rescue StandardError => e
            status 500
            return { error: "Failed to generate secure state: #{e.message}" }.to_json
          end

          query = URI.encode_www_form({
            client_id: client_id,
            redirect_uri: redirect_uri,
            scope: scope,
            state: state
          })

          auth_url = "https://github.com/login/oauth/authorize?#{query}"
          { url: auth_url }.to_json
        end

        def callback
          code = params[:code]
          state = params[:state]

          if code.blank? && request.body
            begin
              body_str = request.body.read
              request.body.rewind if request.body.respond_to?(:rewind)
              if body_str.present?
                json_params = JSON.parse(body_str)
                code ||= json_params['code'] || json_params[:code]
                state ||= json_params['state'] || json_params[:state]
              end
            rescue StandardError => e
              warn "[GithubController#callback] Body parsing error: #{e.message}"
            end
          end

          user = current_user

          if state.present?
            begin
              secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
              decoded_state = JWT.decode(state, secret, true, { algorithm: 'HS256' })
              state_payload = decoded_state[0]
              user_id = state_payload['user_id']
              user ||= User.find_by(id: user_id)
            rescue StandardError => e
              warn "[GithubController#callback] State decoding warning: #{e.message}"
            end
          end

          unless user
            status 401
            return { error: 'User could not be authenticated from session or state' }.to_json
          end

          exchange_and_connect(user, code, is_callback: true)
        end

        def exchange_and_connect(user, code, is_callback: false)
          client_id = ENV['GITHUB_CLIENT_ID'] || Rails.application.credentials.github_client_id
          client_secret = ENV['GITHUB_CLIENT_SECRET'] || Rails.application.credentials.github_client_secret

          if client_id.blank? || client_secret.blank?
            status 500
            return { error: 'GitHub configuration missing on server (GITHUB_CLIENT_ID or GITHUB_CLIENT_SECRET)' }.to_json
          end

          begin
            response = Faraday.post('https://github.com/login/oauth/access_token', {
              client_id: client_id,
              client_secret: client_secret,
              code: code
            }, {
              'Accept' => 'application/json'
            }) do |req|
              req.options.timeout = 10
              req.options.open_timeout = 5
            end

            data = JSON.parse(response.body) rescue {}
            access_token = data['access_token']
          rescue StandardError => e
            status 422
            return { error: 'Failed to exchange authorization code for access token', details: e.message }.to_json
          end

          if access_token.present?
            begin
              client = Octokit::Client.new(
                access_token: access_token,
                connection_options: {
                  request: { timeout: 10, open_timeout: 5 }
                }
              )
              github_user = client.user
            rescue StandardError => e
              status 500
              return { error: "Failed to fetch GitHub user info: #{e.message}" }.to_json
            end

            user.update!(github_token: access_token, github_username: github_user.login, jti: User.generate_jti)
            new_token = generate_jwt_for(user)

            if is_callback && request.request_method == 'GET'
              frontend_url = ENV['FRONTEND_URL'] || 'https://enkihost.com'
              redirect "#{frontend_url}/dashboard/apps/new?step=2&github=connected&token=#{new_token}&auth_token=#{new_token}"
            else
              {
                success: true,
                message: 'GitHub connected successfully',
                token: new_token,
                auth_token: new_token,
                user: {
                  id: user.id,
                  email: user.email,
                  name: user.name,
                  github_connected: true,
                  github_username: user.github_username
                }
              }.to_json
            end
          else
            status 422
            { error: 'Failed to obtain access token from GitHub', details: data }.to_json
          end
        end
      end
    end
  end
end
