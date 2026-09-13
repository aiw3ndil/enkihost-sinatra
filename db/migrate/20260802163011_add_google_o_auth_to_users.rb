class AddGoogleOAuthToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :google_uid, :string
    add_column :users, :google_token, :string
    add_column :users, :google_username, :string
    add_index :users, :google_uid
  end
end
