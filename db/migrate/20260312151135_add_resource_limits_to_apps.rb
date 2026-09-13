class AddResourceLimitsToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :cpu_limit, :string
    add_column :apps, :memory_limit, :string
  end
end
