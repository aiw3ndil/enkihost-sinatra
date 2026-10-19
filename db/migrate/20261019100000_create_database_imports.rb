class CreateDatabaseImports < ActiveRecord::Migration[7.1]
  def change
    create_table :database_imports do |t|
      t.references :addon, null: false, foreign_key: true
      t.string :status, null: false, default: 'pending'
      t.string :filename
      t.string :format
      t.bigint :size
      t.text :log
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
  end
end
