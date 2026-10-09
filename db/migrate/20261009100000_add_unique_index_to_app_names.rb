class AddUniqueIndexToAppNames < ActiveRecord::Migration[7.1]
  def up
    # Rename existing duplicates (case-insensitive, per user) so the unique index can be built.
    execute <<~SQL
      UPDATE apps
      SET name = apps.name || '-' || apps.id
      FROM (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id, LOWER(name) ORDER BY id) AS position
        FROM apps
      ) ranked
      WHERE apps.id = ranked.id AND ranked.position > 1
    SQL

    add_index :apps, 'user_id, LOWER(name)', unique: true, name: 'index_apps_on_user_id_and_lower_name'
  end

  def down
    remove_index :apps, name: 'index_apps_on_user_id_and_lower_name'
  end
end
