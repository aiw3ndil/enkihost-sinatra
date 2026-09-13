class AddSubdomainToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :subdomain, :string
    add_index :apps, :subdomain
  end
end
