class CreateDomains < ActiveRecord::Migration[7.1]
  def change
    create_table :domains do |t|
      t.references :app, null: false, foreign_key: true
      t.string :fqdn

      t.timestamps
    end
    add_index :domains, :fqdn
  end
end
