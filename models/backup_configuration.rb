class BackupConfiguration < ApplicationRecord
  belongs_to :user

  encrypts :s3_access_key_id
  encrypts :s3_secret_access_key

  validates :s3_bucket, presence: true
end
