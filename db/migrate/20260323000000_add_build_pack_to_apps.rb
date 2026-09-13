class AddBuildPackToApps < ActiveRecord::Migration[7.1]
  def change
    unless column_exists?(:apps, :build_pack)
      add_column :apps, :build_pack, :string, default: 'nixpacks'
    end
  end
end
