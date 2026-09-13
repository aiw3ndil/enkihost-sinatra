class AddUserAndAddonToBackups < ActiveRecord::Migration[7.1]
  def change
    add_reference :backups, :user, null: true, foreign_key: true
    add_reference :backups, :addon, null: true, foreign_key: true

    # Clean up existing backups that don't have a user
    # (Since they are now invalid and can't be easily associated)
    reversible do |dir|
      dir.up do
        execute "DELETE FROM backups WHERE user_id IS NULL"
      end
    end

    change_column_null :backups, :user_id, false
  end
end
