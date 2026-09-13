class UpdateDefaultDeploymentTypeToLocal < ActiveRecord::Migration[7.1]
  def up
    change_column_default :apps, :deployment_type, from: 'coolify', to: 'local'
    # Use raw SQL to avoid constant loading issues with App model during early boot
    execute "UPDATE apps SET deployment_type = 'local'"
  end

  def down
    change_column_default :apps, :deployment_type, from: 'local', to: 'coolify'
  end
end
