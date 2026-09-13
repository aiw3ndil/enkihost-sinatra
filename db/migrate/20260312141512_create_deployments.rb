class CreateDeployments < ActiveRecord::Migration[7.1]
  def change
    create_table :deployments do |t|
      t.references :app, null: false, foreign_key: true
      t.string :status
      t.text :log
      t.string :commit_sha

      t.timestamps
    end
  end
end
