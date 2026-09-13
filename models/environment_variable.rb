class EnvironmentVariable < ApplicationRecord
  belongs_to :app

  # Use ActiveRecord Encryption with fallbacks from application.rb
  encrypts :value rescue nil

  validates :key, presence: true, 
                 uniqueness: { scope: :app_id },
                 format: { with: /\A[A-Z0-9_]+\z/ }
  validates :value, presence: true
end
