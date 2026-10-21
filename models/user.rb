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
  has_many :impersonations, dependent: :delete_all
  has_many :impersonations_performed, class_name: 'Impersonation', foreign_key: :impersonator_id, dependent: :delete_all

  PLAN_LIMITS = {
    'spark' => {
      max_apps: 3,
      allowed_kinds: ['jekyll'],
      max_postgresql: 0,
      max_redis: 0,
      cpu_limit: '0.25',
      memory_limit: '256m',
      postgresql_limit: '0m',
      redis_limit: '0m',
      custom_domains: false,
      ha: false,
      autoscaling: false,
      max_storages: 3
    },
    'ignite' => {
      max_apps: 2,
      allowed_kinds: ['rails', 'sinatra', 'jekyll'],
      max_postgresql: 2,
      max_redis: 2,
      cpu_limit: '1.0',
      memory_limit: '2g',
      postgresql_limit: '512m',
      redis_limit: '128m',
      custom_domains: true,
      ha: false,
      autoscaling: false,
      max_storages: 3
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
  encrypts :gitlab_refresh_token rescue nil
  encrypts :google_token rescue nil

  def github_token
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading github_token for user #{id}: #{e.message}"
    nil
  end

  def gitlab_token
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading gitlab_token for user #{id}: #{e.message}"
    nil
  end

  def gitlab_refresh_token
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading gitlab_refresh_token for user #{id}: #{e.message}"
    nil
  end

  def google_token
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading google_token for user #{id}: #{e.message}"
    nil
  end

  before_validation :set_jti
  # Downgrades suspend what no longer fits the plan; upgrades resume it
  after_commit :enforce_plan_limits, on: :update, if: -> { saved_change_to_plan? || saved_change_to_god_mode? }

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
    user.name = name if user.name.blank? && name.present?
    user.save!

    user
  end

  def github_connected
    github_token.present?
  end

  def gitlab_connected
    gitlab_token.present?
  end

  # Stores the token response of GitLab's OAuth token endpoint.
  def store_gitlab_oauth!(data, username: gitlab_username)
    update!(
      gitlab_token: data['access_token'],
      gitlab_refresh_token: data['refresh_token'],
      gitlab_token_expires_at: data['expires_in'] ? Time.now + data['expires_in'].to_i : nil,
      gitlab_username: username
    )
  end

  def disconnect_gitlab!
    update_columns(gitlab_token: nil, gitlab_refresh_token: nil, gitlab_token_expires_at: nil, gitlab_username: nil)
  end

  # Returns a usable GitLab token, refreshing the OAuth token when it is about to expire.
  # Personal access tokens have no expiry stored and are returned as they are.
  def fresh_gitlab_token!
    return gitlab_token unless gitlab_token_expires_at && gitlab_token_expires_at < Time.now + 300

    # The refresh token rotates on every use, so concurrent deploys must not refresh twice.
    with_lock do
      if gitlab_token_expires_at < Time.now + 300 && gitlab_refresh_token.present?
        store_gitlab_oauth!(GitlabService.refresh_token(gitlab_refresh_token))
      end
    end
    gitlab_token
  rescue GitlabService::OAuthError => e
    warn "GitLab token refresh failed for user #{id}: #{e.message}"
    disconnect_gitlab!
    nil
  end

  private

  def set_jti
    self.jti ||= self.class.generate_jti
  end

  def enforce_plan_limits
    PlanEnforcementJob.perform_later(id)
  end
end
