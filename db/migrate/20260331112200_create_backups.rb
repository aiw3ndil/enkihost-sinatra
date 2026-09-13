class CreateBackups < ActiveRecord::Migration[7.1]
  def change
    create_table :backups do |t|
      t.string :status
      t.string :filename
      t.integer :size
      t.string :s3_key

      t.timestamps
    end
  end
end
