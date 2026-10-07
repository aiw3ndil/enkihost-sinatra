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
    cfg = if raw.is_a?(String)
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

    # With support_unencrypted_data, a config that can't be decrypted (different AR
    # encryption keys) comes back as the ciphertext JSON ({"p":..,"h":..}) instead of
    # raising. Rebuild it from the running container, which still holds the credentials.
    if ciphertext?(cfg)
      warn "ActiveRecord::Encryption could not decrypt addon config #{id}; recovering it from the container"
      cfg = recover_config_from_container || {}
    end
    cfg
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading addon config #{id}: #{e.message}"
    {}
  end

  def database_url
    config['url'].presence
  end

  validates :kind, presence: true, inclusion: { in: kinds.keys }
  validates :status, presence: true, inclusion: { in: statuses.keys }
  validates :name, presence: true, uniqueness: { scope: :app_id }
  validate :validate_addon_limit, on: :create

  delegate :user, to: :app, allow_nil: true

  before_validation :set_default_status, on: :create
  before_destroy :cleanup_addon

  private

  def ciphertext?(cfg)
    cfg.is_a?(Hash) && cfg.key?('p') && cfg.key?('h') && !cfg.key?('url')
  end

  def container_name
    "enkihost-addon-#{id}"
  end

  # Reads the credentials the container was started with and re-saves the config
  # encrypted with the current keys. Returns the recovered config, or nil.
  def recover_config_from_container
    return nil unless persisted?

    bin = defined?(DockerService) ? DockerService.docker_bin : 'docker'
    out = IO.popen([bin, 'inspect', '--format', '{{json .Config.Env}}', container_name], err: File::NULL, &:read)
    return nil unless $?.success?

    env = JSON.parse(out).to_h { |pair| pair.split('=', 2) }

    cfg = if postgresql?
            user = env['POSTGRES_USER'].presence || 'postgres'
            password = env['POSTGRES_PASSWORD']
            return nil if password.blank?

            database = env['POSTGRES_DB'].presence || user
            {
              'url' => "postgres://#{user}:#{password}@#{container_name}:5432/#{database}",
              'user' => user,
              'password' => password,
              'database' => database,
              'host' => container_name,
              'port' => 5432
            }
          elsif redis?
            { 'url' => "redis://#{container_name}:6379", 'host' => container_name, 'port' => 6379 }
          end
    return nil unless cfg

    update_column(:config, cfg)
    cfg
  rescue StandardError => e
    warn "[Addon##{id}] Could not recover config from container: #{e.message}"
    nil
  end

  def cleanup_addon
    if defined?(AddonService)
      begin
        AddonService.new(self).deprovision
      rescue StandardError => e
        warn "[Addon##{id}] Error during database deprovision: #{e.message}"
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
