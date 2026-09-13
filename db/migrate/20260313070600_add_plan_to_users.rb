class AddPlanToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :plan, :string, default: 'spark'
  end
end
