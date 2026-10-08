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

  # Seconds from the start of the build until the deployment finished (or until now
  # while it is still running). Nil for deployments that never started.
  def duration_seconds
    return nil if started_at.nil?

    ((finished_at || Time.current) - started_at).round
  end

  private

  def set_default_status
    self.status ||= 'queued'
  end
end
