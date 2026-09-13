class EnvironmentVariable < ApplicationRecord
  belongs_to :app

  # Use ActiveRecord Encryption with fallbacks from application.rb
  encrypts :value rescue nil

  def value
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading env var #{key} (id: #{id}): #{e.message}"
    nil
  end

  validates :key, presence: true, 
                 uniqueness: { scope: :app_id },
                 format: { with: /\A[A-Z0-9_]+\z/ }
  validates :value, presence: true
end
