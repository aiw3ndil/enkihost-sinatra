class Deployment < ApplicationRecord
  belongs_to :app

  enum status: {
    queued: 'queued',
    building: 'building',
    success: 'success',
    failed: 'failed'
  }

  validates :status, presence: true, inclusion: { in: statuses.keys }

  before_validation :set_default_status, on: :create

  private

  def set_default_status
    self.status ||= 'queued'
  end
end
