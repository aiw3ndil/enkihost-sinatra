class AddSuspendedAtToAppsAndAddons < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :suspended_at, :datetime
    add_column :addons, :suspended_at, :datetime
  end
end
