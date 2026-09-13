class AddDeploymentTypeToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :deployment_type, :string
  end
end
