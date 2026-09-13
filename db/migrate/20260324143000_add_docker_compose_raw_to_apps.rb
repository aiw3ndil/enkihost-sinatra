class AddDockerComposeRawToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :docker_compose_raw, :text
  end
end
