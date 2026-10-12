# Audit trail of god mode users entering another user's dashboard.
class Impersonation < ApplicationRecord
  belongs_to :impersonator, class_name: 'User'
  belongs_to :user
end
