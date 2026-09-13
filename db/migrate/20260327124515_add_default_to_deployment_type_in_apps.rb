class AddDefaultToDeploymentTypeInApps < ActiveRecord::Migration[7.1]
  def up
    change_column_default :apps, :deployment_type, from: nil, to: 'coolify'
    # Use raw SQL to avoid constant loading issues with App model during early boot
    execute "UPDATE apps SET deployment_type = 'coolify' WHERE deployment_type IS NULL"
  end

  def down
    change_column_default :apps, :deployment_type, from: 'coolify', to: nil
  end
end
