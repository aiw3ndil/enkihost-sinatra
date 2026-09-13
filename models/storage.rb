class Storage < ApplicationRecord
  belongs_to :app

  validates :name, presence: true
  validates :source, presence: true
  validates :destination, presence: true
  validate :validate_storage_limit, on: :create

  delegate :user, to: :app, allow_nil: true

  # Ensure destination starts with /
  before_validation :ensure_absolute_destination

  private

  def validate_storage_limit
    return unless user

    max_count = user.limits[:max_storages]
    return if max_count.nil? || max_count == Float::INFINITY

    # Count of existing storages across all user's apps
    current_count = Storage.joins(:app).where(apps: { user_id: user.id }).count

    if current_count >= max_count
      errors.add(:base, "You have reached the maximum number of storage volumes for your #{user.plan.capitalize} plan.")
    end
  end

  def ensure_absolute_destination
    return if destination.blank?
    self.destination = "/#{destination}" unless destination.start_with?('/')
  end
end
