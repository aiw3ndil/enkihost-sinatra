class BackupConfiguration < ApplicationRecord
  belongs_to :user

  encrypts :s3_access_key_id
  encrypts :s3_secret_access_key

  def s3_access_key_id
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading s3_access_key_id for user #{user_id}: #{e.message}"
    nil
  end

  def s3_secret_access_key
    super
  rescue ActiveRecord::Encryption::Errors::Decryption, StandardError => e
    warn "ActiveRecord::Encryption error reading s3_secret_access_key for user #{user_id}: #{e.message}"
    nil
  end

  validates :s3_bucket, presence: true
end
