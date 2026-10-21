class Deployment < ApplicationRecord
  belongs_to :app

  enum status: {
    queued: 'queued',
    building: 'building',
    success: 'success',
    failed: 'failed'
  }

  validates :status, presence: true, inclusion: { in: statuses.keys }
  validate :app_not_suspended, on: :create

  before_validation :set_default_status, on: :create

  # Seconds from the start of the build until the deployment finished (or until now
  # while it is still running). Nil for deployments that never started.
  def duration_seconds
    return nil if started_at.nil?

    ((finished_at || Time.current) - started_at).round
  end

  private

  def app_not_suspended
    return unless app&.suspended?

    errors.add(:base, "#{app.name} is suspended because it does not fit the #{app.user.plan.capitalize} plan. Upgrade your plan to deploy it again.")
  end

  def set_default_status
    self.status ||= 'queued'
  end
end
