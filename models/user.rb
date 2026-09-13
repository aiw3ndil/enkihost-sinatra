# frozen_string_literal: true

require 'bcrypt'
require 'securerandom'

class User < ApplicationRecord
  attr_accessor :password_confirmation

  has_many :apps, dependent: :destroy
  has_many :deployments, through: :apps
  has_many :addons, through: :apps
  has_many :backups, dependent: :destroy
  has_one :backup_configuration, dependent: :destroy

  PLAN_LIMITS = {
    'spark' => {
      max_apps: 1,
      allowed_kinds: ['jekyll'],
      max_postgresql: 1,
      max_redis: 1,
      cpu_limit: '0.1',
      memory_limit: '512m',
      postgresql_limit: '128m',
      redis_limit: '64m',
      custom_domains: false,
      ha: false,
      autoscaling: false,
      max_storages: 1
    },
    'ignite' => {
      max_apps: 2,
      allowed_kinds: ['rails', 'sinatra', 'jekyll'],
      max_postgresql: 1,
      max_redis: 1,
      cpu_limit: '1.0',
      memory_limit: '2g',
      postgresql_limit: '1g',
      redis_limit: '1g',
      custom_domains: true,
      ha: false,
      autoscaling: false,
      max_storages: 5
    },
    'blaze' => {
      max_apps: 5,
      allowed_kinds: ['rails', 'sinatra', 'jekyll'],
      max_postgresql: 5,
      max_redis: 5,
      cpu_limit: '2.0',
      memory_limit: '4g',
      postgresql_limit: '2g',
      redis_limit: '2g',
      custom_domains: true,
      ha: true,
      autoscaling: true,
      max_storages: 20
    }
  }.freeze

  GOD_MODE_LIMITS = {
    max_apps: Float::INFINITY,
    allowed_kinds: ['rails', 'sinatra', 'jekyll'],
    max_postgresql: Float::INFINITY,
    max_redis: Float::INFINITY,
    cpu_limit: '8.0',
    memory_limit: '16g',
    postgresql_limit: '10g',
    redis_limit: '10g',
    custom_domains: true,
    ha: true,
    autoscaling: true,
    max_storages: Float::INFINITY
  }.freeze

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :plan, presence: true, inclusion: { in: PLAN_LIMITS.keys }
  validates :jti, presence: true
  validates :password, length: { minimum: 6, maximum: 128 }, allow_nil: true

  # Encryption setup (ActiveRecord::Encryption)
  encrypts :github_token rescue nil
  encrypts :gitlab_token rescue nil
  encrypts :google_token rescue nil

  before_validation :set_jti

  def password
    @password
  end

  def password=(new_password)
    @password = new_password
    self.encrypted_password = BCrypt::Password.create(new_password) if new_password.present?
  end

  def authenticate(unencrypted_password)
    return false if encrypted_password.blank?

    BCrypt::Password.new(encrypted_password) == unencrypted_password && self
  rescue BCrypt::Errors::InvalidHash
    false
  end

  def limits
    return GOD_MODE_LIMITS if god_mode?

    # Fallback to spark if plan is missing or invalid
    PLAN_LIMITS[plan] || PLAN_LIMITS['spark']
  end

  def postgresql_count
    addons.where(kind: 'postgresql').count
  end

  def redis_count
    addons.where(kind: 'redis').count
  end

  def self.generate_jti
    SecureRandom.uuid
  end

  # Finds an existing user or creates a new one from Google OAuth data.
  # Used both for signup (no account yet) and login (existing account, same email).
  def self.find_for_google_oauth(uid:, email:, name:, access_token:, refresh_token: nil)
    email = email&.downcase

    user = find_by(google_uid: uid) || find_by(email: email)

    if user.nil?
      temp_password = SecureRandom.hex(20)
      user = create!(
        email: email,
        password: temp_password,
        password_confirmation: temp_password,
        plan: 'spark'
      )
    end

    user.google_uid = uid
    user.google_token = access_token
    user.google_username = name if name.present?
    user.save!

    user
  end

  def github_connected
    github_token.present?
  end

  private

  def set_jti
    self.jti ||= self.class.generate_jti
  end
end
