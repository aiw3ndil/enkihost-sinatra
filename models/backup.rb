class Backup < ApplicationRecord
  belongs_to :user
  belongs_to :addon, optional: true
end
