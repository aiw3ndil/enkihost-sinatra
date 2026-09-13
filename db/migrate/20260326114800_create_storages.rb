class CreateStorages < ActiveRecord::Migration[7.1]
  def change
    create_table :storages do |t|
      t.references :app, null: false, foreign_key: true
      t.string :name
      t.string :source
      t.string :destination
      t.boolean :is_directory, default: true

      t.timestamps
    end
  end
end
