class AddGitlabOauthToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :gitlab_refresh_token, :string
    add_column :users, :gitlab_token_expires_at, :datetime
  end
end
