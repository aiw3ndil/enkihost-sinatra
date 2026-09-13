class CreateEnvironmentVariables < ActiveRecord::Migration[7.1]
  def change
    create_table :environment_variables do |t|
      t.references :app, null: false, foreign_key: true
      t.string :key
      t.text :value

      t.timestamps
    end
  end
end
