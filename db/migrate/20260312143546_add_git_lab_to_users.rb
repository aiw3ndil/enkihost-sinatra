class AddGitLabToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :gitlab_token, :string
    add_column :users, :gitlab_username, :string
  end
end
