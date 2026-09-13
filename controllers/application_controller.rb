# frozen_string_literal: true

require 'sinatra/base'
require 'pundit'
require 'json'
require 'jwt'

class ApplicationController < Sinatra::Base
  include Pundit::Authorization if defined?(Pundit::Authorization)

  configure do
    set :show_exceptions, false
    set :raise_errors, false
    set :host_authorization, { permitted_hosts: [] } if respond_to?(:host_authorization)
  end

  class << self
    def skipped_actions
      @skipped_actions ||= Hash.new { |h, k| h[k] = [] }
    end

    def skip_before_action(filter, only: [])
      Array(only).each do |action|
        skipped_actions[filter] << action.to_sym
      end
    end

    def action_skipped?(filter, action_name)
      skipped_actions[filter].include?(action_name.to_sym)
    end

    def action_map
      @action_map ||= {}
    end

    def register_action(verb, path, action_name)
      pattern = path.is_a?(String) && path.include?(':') ? Mustermann.new(path) : path
      action_map[[verb.to_s.upcase, pattern]] = action_name.to_sym
    end

    def post_action(path, action_name, &block)
      register_action('POST', path, action_name)
      post(path, &block)
    end

    def get_action(path, action_name, &block)
      register_action('GET', path, action_name)
      get(path, &block)
    end

    def patch_action(path, action_name, &block)
      register_action('PATCH', path, action_name)
      patch(path, &block)
    end

    def put_action(path, action_name, &block)
      register_action('PUT', path, action_name)
      put(path, &block)
    end

    def delete_action(path, action_name, &block)
      register_action('DELETE', path, action_name)
      delete(path, &block)
    end
  end

  options '*' do
    status 200
    ''
  end

  helpers do
    def current_user
      @current_user ||= authenticate_user
    end

    def authenticate_request!
      user_not_authenticated unless current_user
    end

    def authenticate_user!
      authenticate_request!
    end

    def authenticate_user
      auth_header = request.env['HTTP_AUTHORIZATION']
      token = auth_header&.split(' ')&.last
      return nil unless token.present?

      # 1. If token is in standard JWT format (3 dot-separated parts), decode it first
      if token.count('.') == 2
        secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
        decoded, _ = JWT.decode(token, secret, true, { algorithm: 'HS256' })
        if decoded && (decoded['sub'] || decoded['jti'])
          return User.find_by(id: decoded['sub']) || User.find_by(jti: decoded['jti']) if defined?(User)
        end
      end

      # 2. Fallback to direct JTI match (for non-JWT tokens or legacy auth)
      User.find_by(jti: token) if defined?(User)
    rescue JWT::DecodeError
      # If JWT decoding fails, try direct JTI lookup as fallback
      User.find_by(jti: token) if defined?(User)
    rescue StandardError => e
      warn "Authentication error: #{e.message}"
      nil
    end

    def generate_jwt_for(user)
      secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
      payload = {
        sub: user.id,
        jti: user.jti,
        scp: 'user',
        exp: (Time.now + 86400 * 7).to_i
      }
      JWT.encode(payload, secret, 'HS256')
    end

    def user_not_authenticated
      halt 401, { 'Content-Type' => 'application/json' }, { error: 'Not Authorized' }.to_json
    end

    def user_not_authorized
      halt 403, { 'Content-Type' => 'application/json' }, { error: 'You are not authorized to perform this action.' }.to_json
    end

    def render_json(data, status: 200)
      status status
      data.to_json
    end

    def pundit_user
      current_user
    end

    def current_action
      method = request.request_method
      path = request.path_info
      self.class.action_map.each do |(verb, pattern), act|
        next unless verb == method
        return act if pattern.is_a?(String) ? pattern == path : pattern === path
      end
      nil
    end

    def action_name
      (current_action || :show).to_s
    end

    def handles_route?
      route_entries = self.class.routes[request.request_method] || []
      route_entries.any? { |pattern, *| pattern === request.path_info }
    end
  end

  if defined?(Pundit::NotAuthorizedError)
    error Pundit::NotAuthorizedError do
      user_not_authorized
    end
  end

  # Global exception rescue matching Rails ApplicationController rescue_from
  error StandardError do
    e = env['sinatra.error']
    warn "GLOBAL EXCEPTION: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
    content_type :json
    status 500
    {
      status: 500,
      error: 'Internal Server Error',
      message: e.message,
      type: e.class.name
    }.to_json
  end

  before do
    return if request.request_method == 'OPTIONS'

    pass unless handles_route?

    content_type :json

    if request.media_type == 'application/json' && request.body
      body = request.body.read
      request.body.rewind if request.body.respond_to?(:rewind)
      unless body.to_s.strip.empty?
        begin
          parsed = JSON.parse(body)
          if parsed.is_a?(Hash)
            parsed.each do |k, v|
              params[k.to_sym] = v
              params[k.to_s] = v
            end
          end
        rescue JSON::ParserError
          halt 400, { error: 'Invalid JSON' }.to_json
        end
      end
    end

    action_name = current_action
    if action_name && self.class.action_skipped?(:authenticate_request!, action_name)
      # Action skipped
    else
      authenticate_request!
    end
  end

  after do
    ActiveRecord::Base.connection_handler.clear_active_connections! if defined?(ActiveRecord::Base)
  end
end
