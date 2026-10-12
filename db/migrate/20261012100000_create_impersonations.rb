class CreateImpersonations < ActiveRecord::Migration[7.1]
  def change
    create_table :impersonations do |t|
      t.references :impersonator, null: false, foreign_key: { to_table: :users }
      t.references :user, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.datetime :created_at, null: false
    end
  end
end
