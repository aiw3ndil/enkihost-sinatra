# frozen_string_literal: true

require_relative 'config/environment'
require 'rack/cors'

class EnkihostApp < Sinatra::Base
  configure do
    set :host_authorization, { permitted_hosts: [] } if respond_to?(:host_authorization)
  end

  use Rack::Cors do
    allow do
      origins do |source, _env|
        # Allow requests from any origin while supporting credentials: true
        true
      end

      resource '*',
               headers: :any,
               methods: %i[get post put patch delete options head],
               expose: %w[Authorization],
               credentials: true,
               max_age: 600
    end
  end

  # Fallback OPTIONS handler for direct preflight requests
  options '*' do
    status 200
    ''
  end

  # Normalize consecutive slashes in PATH_INFO (e.g. //api/v1/... -> /api/v1/...)
  use Rack::Config do |env|
    env['PATH_INFO'] = env['PATH_INFO'].squeeze('/') if env['PATH_INFO']
  end

  # Rack middleware to guarantee ActiveRecord connections are ALWAYS released back to the pool
  class ConnectionPoolCleaner
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    ensure
      ActiveRecord::Base.connection_handler.clear_active_connections! if defined?(ActiveRecord::Base)
    end
  end

  use ConnectionPoolCleaner

  after do
    ActiveRecord::Base.connection_handler.clear_active_connections! if defined?(ActiveRecord::Base)
  end

  # Health check route matching Rails `get "up"`
  get '/up' do
    content_type :json
    status 200
    { status: 'ok' }.to_json
  end

  # Root route matching Rails root
  get '/' do
    content_type :json
    status 200
    { status: 'online', app: 'Enkihost Sinatra API' }.to_json
  end

  # Mount Auth & User Controllers
  use Users::RegistrationsController
  use Users::SessionsController
  use MeController

  # Mount Resource Controllers
  use AppsController
  use DeploymentsController
  use AddonsController
  use DomainsController
  use EnvironmentVariablesController
  use StoragesController

  # Mount API v1 Specialized Controllers
  use Api::V1::DatabasesController
  use Api::V1::GithubController
  use Api::V1::GoogleController
  use Api::V1::PaymentsController
  use Api::V1::BackupConfigurationsController
  use Api::V1::BackupsController

  # Mount Webhooks Controllers
  use Webhooks::GithubController
  use Webhooks::GitlabHooksController
  use Webhooks::StripeController
end
