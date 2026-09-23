class Addon < ApplicationRecord
  belongs_to :app

  enum kind: {
    postgresql: 'postgresql',
    redis: 'redis'
  }

  enum status: {
    creating: 'creating',
    running: 'running',
    failed: 'failed',
    stopped: 'stopped'
  }

  # Use ActiveRecord Encryption with fallbacks from application.rb
  encrypts :config rescue nil
  serialize :config, coder: JSON

  def config
    raw = super
    if raw.is_a?(String)
      begin
        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : { 'url' => raw }
      rescue JSON::ParserError
        { 'url' => raw }
      end
    elsif raw.is_a?(Hash)
      raw
    else
      {}
    end
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading addon config #{id}: #{e.message}"
    {}
  end

  validates :kind, presence: true, inclusion: { in: kinds.keys }
  validates :status, presence: true, inclusion: { in: statuses.keys }
  validates :name, presence: true, uniqueness: { scope: :app_id }
  validate :validate_addon_limit, on: :create

  delegate :user, to: :app, allow_nil: true

  before_validation :set_default_status, on: :create
  after_destroy :cleanup_addon

  private

  def cleanup_addon
    Thread.new do
      begin
        AddonService.new(self).deprovision
      rescue StandardError => e
        Rails.logger.error "ERROR during addon cleanup for addon #{id}: #{e.message}"
      ensure
        ActiveRecord::Base.connection_pool.release_connection
      end
    end
  end

  def validate_addon_limit
    return unless user && kind

    limit_key = "max_#{kind}".to_sym
    max_count = user.limits[limit_key]
    
    return if max_count == Float::INFINITY

    # Count of existing add-ons of this kind across all user's apps
    current_count = Addon.joins(:app).where(apps: { user_id: user.id }, kind: kind).count

    if current_count >= max_count
      errors.add(:base, "You have reached the maximum number of #{kind.capitalize} add-ons for your #{user.plan.capitalize} plan.")
    end
  end

  def set_default_status
    self.status ||= 'creating'
  end
end
