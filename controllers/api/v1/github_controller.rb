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
            client = Octokit::Client.new(access_token: current_user.github_token)
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
            current_user.update(github_token: nil, github_username: nil)
            status 401
            { error: 'GitHub session expired. Please reconnect.' }.to_json
          rescue StandardError => e
            warn "[GithubController#repositories] Error: #{e.message}"
            status 500
            { error: "Failed to fetch repositories: #{e.message}" }.to_json
          end
        end

        def connect
          user = current_user
          unless user
            status 401
            return { error: 'Authentication required' }.to_json
          end

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

          begin
            secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
            decoded_state = JWT.decode(state, secret, true, { algorithm: 'HS256' })
            state_payload = decoded_state[0]
            user_id = state_payload['user_id']

            expected_redirect_uri = params[:redirect_uri] || 'https://api.enkihost.com/api/v1/github/callback'
            if state_payload['redirect_uri'] != expected_redirect_uri
              status 401
              return { error: 'CSRF protection: State validation failed - redirect_uri mismatch' }.to_json
            end

            user = User.find(user_id)
          rescue JWT::ExpiredSignature
            status 401
            return { error: 'Invalid state: JWT expired' }.to_json
          rescue StandardError => e
            status 401
            return { error: "Invalid state: #{e.message}" }.to_json
          end

          client_id = ENV['GITHUB_CLIENT_ID'] || Rails.application.credentials.github_client_id
          client_secret = ENV['GITHUB_CLIENT_SECRET'] || Rails.application.credentials.github_client_secret

          begin
            response = Faraday.post('https://github.com/login/oauth/access_token', {
              client_id: client_id,
              client_secret: client_secret,
              code: code
            }, { 'Accept' => 'application/json' })

            data = JSON.parse(response.body)
            access_token = data['access_token']
          rescue StandardError => e
            status 422
            return { error: 'Failed to exchange authorization code for access token', details: e.message }.to_json
          end

          if access_token.present?
            begin
              client = Octokit::Client.new(access_token: access_token)
              github_user = client.user
            rescue StandardError => e
              status 500
              return { error: "Failed to fetch GitHub user info: #{e.message}" }.to_json
            end

            user.update!(github_token: access_token, github_username: github_user.login, jti: User.generate_jti)
            new_token = generate_jwt_for(user)

            frontend_url = ENV['FRONTEND_URL'] || 'https://enkihost.com'
            redirect "#{frontend_url}/settings?github=connected&token=#{new_token}&auth_token=#{new_token}"
          else
            status 422
            { error: 'Failed to obtain access token from GitHub', details: data }.to_json
          end
        end
      end
    end
  end
end
