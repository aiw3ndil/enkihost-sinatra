class AddCoolifyUuidToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :coolify_uuid, :string
    add_index :apps, :coolify_uuid
  end
end
