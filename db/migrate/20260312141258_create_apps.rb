class CreateApps < ActiveRecord::Migration[7.1]
  def change
    create_table :apps do |t|
      t.string :name
      t.string :kind
      t.string :repository_url
      t.string :branch
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
