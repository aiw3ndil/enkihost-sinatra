# frozen_string_literal: true

require 'faraday'
require 'uri'

module Api
  module V1
    class GoogleController < Api::V1::ApplicationController
      skip_before_action :authenticate_request!, only: %i[callback connect]

      get_action '/api/v1/google/connect', :connect do
        connect
      end
      post_action '/api/v1/google/connect', :connect do
        connect
      end

      get_action '/api/v1/google/callback', :callback do
        callback
      end
      post_action '/api/v1/google/callback', :callback do
        callback
      end

      helpers do
        def connect
          client_id = ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.google_client_id
          if client_id.blank?
            warn '[GoogleController#connect] GOOGLE_CLIENT_ID is missing!'
            status 500
            return { error: 'Google configuration missing on server' }.to_json
          end

          redirect_uri = google_callback_uri
          secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
          if secret.blank? || secret.length < 16
            status 500
            return { error: 'Security configuration missing or invalid on server' }.to_json
          end

          state_param = params[:state]
          state_param = nil if state_param.blank? || state_param == 'undefined'
          frontend_redirect = state_param.presence || default_frontend_redirect

          begin
            state = JWT.encode({
              redirect_to: frontend_redirect,
              redirect_uri: redirect_uri,
              exp: (Time.now + 600).to_i
            }, secret, 'HS256')
          rescue StandardError => e
            status 500
            return { error: "Failed to generate secure state: #{e.message}" }.to_json
          end

          query = URI.encode_www_form({
            client_id: client_id,
            redirect_uri: redirect_uri,
            response_type: 'code',
            scope: 'openid email profile',
            access_type: 'offline',
            prompt: 'consent',
            state: state
          })

          auth_url = "https://accounts.google.com/o/oauth2/v2/auth?#{query}"
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
                params[:redirect_uri] ||= json_params['redirect_uri'] || json_params[:redirect_uri]
              end
            rescue StandardError => e
              warn "[GoogleController#callback] Body parsing error: #{e.message}"
            end
          end

          frontend_redirect = nil
          redirect_uri_from_state = nil

          if state.present?
            begin
              secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
              decoded_state = JWT.decode(state, secret, true, { algorithm: 'HS256' })
              frontend_redirect = decoded_state[0]['redirect_to']
              redirect_uri_from_state = decoded_state[0]['redirect_uri']
            rescue StandardError => e
              warn "[GoogleController#callback] State decoding warning: #{e.message}"
              frontend_redirect = state if state.start_with?('http://', 'https://', '/')
            end
          end

          client_id = ENV['GOOGLE_CLIENT_ID'] || Rails.application.credentials.google_client_id
          client_secret = ENV['GOOGLE_CLIENT_SECRET'] || Rails.application.credentials.google_client_secret

          if client_id.blank? || client_secret.blank?
            status 500
            return { error: 'Google configuration missing on server' }.to_json
          end

          # Determine callback redirect URI used during authorization
          target_redirect_uri = params[:redirect_uri].presence || redirect_uri_from_state.presence || google_callback_uri

          begin
            response = Faraday.post('https://oauth2.googleapis.com/token', {
              client_id: client_id,
              client_secret: client_secret,
              code: code,
              redirect_uri: target_redirect_uri,
              grant_type: 'authorization_code'
            }, { 'Accept' => 'application/json', 'Content-Type' => 'application/x-www-form-urlencoded' })

            data = JSON.parse(response.body)
          rescue StandardError => e
            status 502
            return { error: "Failed to communicate with Google: #{e.message}" }.to_json
          end

          access_token = data['access_token']

          if access_token.blank?
            status 422
            return { error: 'Failed to obtain access token from Google', details: data }.to_json
          end

          begin
            userinfo = Faraday.get('https://www.googleapis.com/oauth2/v3/userinfo') do |req|
              req.headers['Authorization'] = "Bearer #{access_token}"
            end
            profile = JSON.parse(userinfo.body)
          rescue StandardError => e
            status 502
            return { error: "Failed to fetch Google user profile: #{e.message}" }.to_json
          end

          if profile['email'].blank?
            status 422
            return { error: 'Google account has no email associated' }.to_json
          end

          user = User.find_for_google_oauth(
            uid: profile['sub'],
            email: profile['email'],
            name: profile['name'],
            access_token: access_token,
            refresh_token: data['refresh_token']
          )

          new_jti = User.generate_jti
          user.update_column(:jti, new_jti)
          user.jti = new_jti
          new_token = generate_jwt_for(user)

          # Dual response: JSON for API/AJAX callers, redirect for browser navigations
          is_api_request = request.request_method == 'POST' ||
                           request.media_type == 'application/json' ||
                           (request.accept.any? { |a| a.to_s.include?('application/json') } rescue false)

          if is_api_request
            status 200
            headers['Authorization'] = "Bearer #{new_token}"
            user_data = if defined?(UserSerializer)
                          UserSerializer.new(user).serializable_hash.dig(:data, :attributes)
                        else
                          { id: user.id, email: user.email, name: user.name }
                        end
            {
              status: 200,
              message: 'Logged in successfully.',
              token: new_token,
              auth_token: new_token,
              data: user_data,
              user: user_data
            }.to_json
          else
            target_redirect = frontend_redirect.presence || default_frontend_redirect
            redirect "#{target_redirect}?token=#{new_token}&auth_token=#{new_token}"
          end
        end

        private

        def google_callback_uri
          uri = params[:redirect_uri]
          return uri if uri.present? && uri != 'undefined'

          ENV['GOOGLE_REDIRECT_URI'].presence || 'https://api.enkihost.com/api/v1/google/callback'
        end

        def default_frontend_redirect
          "#{ENV['FRONTEND_URL'] || 'https://enkihost.com'}/auth/callback"
        end
      end
    end
  end
end
