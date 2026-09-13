class AddPortToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :port, :integer
  end
end
