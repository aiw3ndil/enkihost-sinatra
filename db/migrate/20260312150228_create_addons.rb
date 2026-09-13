class CreateAddons < ActiveRecord::Migration[7.1]
  def change
    create_table :addons do |t|
      t.references :app, null: false, foreign_key: true
      t.string :kind
      t.string :name
      t.string :status
      t.text :config

      t.timestamps
    end
  end
end
