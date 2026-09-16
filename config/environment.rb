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
require 'enkimail'
require 'mail'

# Configure Mail with Enkimail delivery method
if ENV['ENKIMAIL_API_KEY'].present?
  raw_base_url = ENV['ENKIMAIL_BASE_URL'].presence || 'https://api.enkimail.com'
  base_url = raw_base_url.sub(%r{\Ahttp://api\.enkimail\.com}i, 'https://api.enkimail.com')
  base_url = base_url.sub(%r{\Ahttps?://(?:www\.)?enkimail\.com/?\z}i, 'https://api.enkimail.com')

  Mail.defaults do
    delivery_method Enkimail::DeliveryMethod,
                    api_key: ENV['ENKIMAIL_API_KEY'],
                    base_url: base_url
  end
end

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
      config: OpenStruct.new(
        load_database_yaml: (
          db_file = File.expand_path('database.yml', __dir__)
          File.exist?(db_file) ? (YAML.safe_load(ERB.new(File.read(db_file)).result, aliases: true) rescue {}) : {}
        ),
        paths: { 'db/migrate' => ['db/migrate'] }
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
  env_primary = ENV['AR_PRIMARY_KEY'] || ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
  env_deterministic = ENV['AR_DETERMINISTIC_KEY'] || ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
  env_salt = ENV['AR_SALT'] || ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
  fallback_key = '9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c'

  primary_key = env_primary.presence || fallback_key
  deterministic_key = env_deterministic.presence || fallback_key
  key_derivation_salt = env_salt.presence || 'salt_enkihost_prod_2026_secure_!!'

  primary_key = primary_key.ljust(32, '0') if primary_key.bytesize < 32
  deterministic_key = deterministic_key.ljust(32, '0') if deterministic_key.bytesize < 32
  key_derivation_salt = key_derivation_salt.ljust(32, '0') if key_derivation_salt.bytesize < 32

  ActiveRecord::Encryption.configure(
    primary_key: primary_key,
    deterministic_key: deterministic_key,
    key_derivation_salt: key_derivation_salt,
    support_unencrypted_data: true
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

  # Rails ActiveJob compatibility wrapper for Sidekiq
  # Resolves `uninitialized constant Sidekiq::ActiveJob (NameError)` for legacy or queued ActiveJob payloads
  module Sidekiq
    module ActiveJob
      class Wrapper
        include Sidekiq::Job

        def perform(job_data = {})
          return unless job_data.is_a?(Hash)

          job_class_name = job_data['job_class'] || job_data[:job_class]
          return unless job_class_name

          klass = Object.const_get(job_class_name) rescue nil
          unless klass
            warn "[Sidekiq::ActiveJob::Wrapper] Unknown job class #{job_class_name}, skipping."
            return
          end

          args = job_data['arguments'] || job_data[:arguments] || []
          job_inst = klass.new
          if job_inst.respond_to?(:perform)
            job_inst.perform(*args)
          end
        rescue ArgumentError => e
          warn "[Sidekiq::ActiveJob::Wrapper] ArgumentError executing #{job_data['job_class']}: #{e.message} - discarding malformed job"
        rescue StandardError => e
          warn "[Sidekiq::ActiveJob::Wrapper] Error executing #{job_data['job_class']}: #{e.class}: #{e.message}"
          raise e
        end
      end
    end
  end
end

# Require controllers in dependency order
app_controller = File.expand_path('../controllers/application_controller.rb', __dir__)
require app_controller if File.exist?(app_controller)

api_app_controller = File.expand_path('../controllers/api/v1/application_controller.rb', __dir__)
require api_app_controller if File.exist?(api_app_controller)

Dir[File.expand_path('../controllers/**/*.rb', __dir__)].each do |file|
  require file unless file == app_controller || file == api_app_controller
end
