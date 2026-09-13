class AddRuntimeStatusToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :runtime_status, :string
  end
end
