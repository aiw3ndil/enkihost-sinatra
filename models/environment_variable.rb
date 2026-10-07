class EnvironmentVariable < ApplicationRecord
  belongs_to :app

  # Use ActiveRecord Encryption with fallbacks from application.rb
  encrypts :value rescue nil

  def value
    raw = super
    # With support_unencrypted_data, a value that can't be decrypted (wrong key, or
    # encrypted twice) comes back as the ciphertext JSON instead of raising.
    if raw.is_a?(String) && raw.start_with?('{"p":')
      warn "ActiveRecord::Encryption could not decrypt env var #{key} (id: #{id}); returning nil"
      return nil
    end
    raw
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading env var #{key} (id: #{id}): #{e.message}"
    nil
  end

  validates :key, presence: true, 
                 uniqueness: { scope: :app_id },
                 format: { with: /\A[A-Z0-9_]+\z/ }
  validates :value, presence: true
end
