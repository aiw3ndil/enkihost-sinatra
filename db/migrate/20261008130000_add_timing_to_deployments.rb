class AddTimingToDeployments < ActiveRecord::Migration[7.1]
  def up
    add_column :deployments, :started_at, :datetime
    add_column :deployments, :finished_at, :datetime

    # Approximate timings for finished deployments: the final status update is the
    # last write that touches updated_at (log appends use update_all).
    execute <<~SQL
      UPDATE deployments
      SET started_at = created_at, finished_at = updated_at
      WHERE status IN ('success', 'failed')
    SQL
  end

  def down
    remove_column :deployments, :finished_at
    remove_column :deployments, :started_at
  end
end
