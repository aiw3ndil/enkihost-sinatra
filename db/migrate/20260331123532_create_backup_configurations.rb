class CreateBackupConfigurations < ActiveRecord::Migration[7.1]
  def change
    create_table :backup_configurations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :s3_access_key_id
      t.string :s3_secret_access_key
      t.string :s3_bucket
      t.string :s3_region
      t.string :s3_endpoint

      t.timestamps
    end
  end
end
