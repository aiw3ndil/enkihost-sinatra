# A database dump uploaded by the user and restored into a PostgreSQL addon.
class DatabaseImport < ApplicationRecord
  belongs_to :addon

  enum status: {
    pending: 'pending',
    running: 'running',
    success: 'success',
    failed: 'failed'
  }

  scope :in_progress, -> { where(status: %w[pending running]) }

  def as_json(*)
    super(only: %i[id addon_id status filename format size log started_at finished_at created_at])
  end
end
