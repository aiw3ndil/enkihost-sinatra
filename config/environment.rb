# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'development'

require 'bundler/setup'
require 'dotenv'
Dotenv.load

require 'active_record'
require 'sinatra/activerecord'
require 'securerandom'
require 'json'
require 'jsonapi/serializer'
require 'jwt'
require 'bcrypt'
require 'logger'
require 'pathname'
require 'ostruct'
require 'active_support/core_ext/string/inquiry'

# Provide minimal Rails compatibility shim for shared services/jobs
module Rails
  class Railtie
    def self.initializer(*); end
  end

  def self.version
    '7.1.0'
  end

  def self.logger
    @logger ||= Logger.new($stdout)
  end

  def self.root
    @root ||= Pathname.new(File.expand_path('..', __dir__))
  end

  def self.env
    (ENV['RACK_ENV'] || 'development').inquiry
  end

  def self.application
    @application ||= OpenStruct.new(
      credentials: OpenStruct.new(
        fetch: ->(key, default = nil) { ENV[key.to_s.upcase] || default }
      ),
      secret_key_base: ENV['SECRET_KEY_BASE'] || 'fallback_secret_key_base_for_enkihost_sinatra_api'
    )
  end
end

# Database connection setup
db_config_file = File.expand_path('database.yml', __dir__)
if File.exist?(db_config_file)
  require 'erb'
  db_configs = YAML.safe_load(ERB.new(File.read(db_config_file)).result, aliases: true)
  current_env = ENV['RACK_ENV'] || 'development'
  ActiveRecord::Base.configurations = db_configs
  ActiveRecord::Base.establish_connection(current_env.to_sym)
end

# Setup ActiveRecord Encryption with fallbacks
begin
  fallback_key = '9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c' # 32 bytes
  env_primary = ENV['AR_PRIMARY_KEY']
  env_deterministic = ENV['AR_DETERMINISTIC_KEY']

  ActiveRecord::Encryption.configure(
    primary_key: (env_primary || fallback_key).ljust(32, '0')[0..31],
    deterministic_key: (env_deterministic || fallback_key).ljust(32, '0')[0..31],
    key_derivation_salt: ENV['AR_SALT'] || 'salt_enkihost_prod_2026_secure_!!'
  )
rescue StandardError => e
  warn "ActiveRecord::Encryption config error: #{e.message}"
end

# Set default time zone if supported
Time.zone = 'UTC' if Time.respond_to?(:zone=)

# Require base model first
require_relative '../models/application_record'

# Require all models
Dir[File.expand_path('../models/*.rb', __dir__)].each do |file|
  require file unless file.end_with?('application_record.rb')
end

# Require all serializers
Dir[File.expand_path('../serializers/*.rb', __dir__)].each do |file|
  require file
end

# Require all services
Dir[File.expand_path('../services/*.rb', __dir__)].each do |file|
  require file
end

# Require all jobs
safe_job = File.expand_path('../jobs/safe_job.rb', __dir__)
require safe_job if File.exist?(safe_job)
app_job = File.expand_path('../jobs/application_job.rb', __dir__)
require app_job if File.exist?(app_job)
Dir[File.expand_path('../jobs/*.rb', __dir__)].each do |file|
  require file unless file == safe_job || file == app_job
end

# Configure Sidekiq if loaded
if defined?(Sidekiq)
  redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/1')
  Sidekiq.configure_server do |config|
    config.redis = { url: redis_url }
  end
  Sidekiq.configure_client do |config|
    config.redis = { url: redis_url }
  end
  Sidekiq.strict_args!(false) if Sidekiq.respond_to?(:strict_args!)
end

# Require controllers in dependency order
app_controller = File.expand_path('../controllers/application_controller.rb', __dir__)
require app_controller if File.exist?(app_controller)

api_app_controller = File.expand_path('../controllers/api/v1/application_controller.rb', __dir__)
require api_app_controller if File.exist?(api_app_controller)

Dir[File.expand_path('../controllers/**/*.rb', __dir__)].each do |file|
  require file unless file == app_controller || file == api_app_controller
end
