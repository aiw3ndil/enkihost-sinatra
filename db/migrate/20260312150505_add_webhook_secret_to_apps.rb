class AddWebhookSecretToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :webhook_secret, :string
  end
end
