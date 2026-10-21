class UserSerializer
  include JSONAPI::Serializer
  attributes :id, :name, :email, :plan, :limits, :god_mode, :created_at, :github_username, :gitlab_username, :google_username, :stripe_customer_id, :stripe_subscription_id

  attribute :apps_count do |user|
    user.apps.count
  end

  attribute :postgresql_count do |user|
    user.postgresql_count
  end

  attribute :redis_count do |user|
    user.redis_count
  end

  # Apps and databases stopped because they do not fit the current plan
  attribute :suspended_apps_count do |user|
    user.apps.where.not(suspended_at: nil).count
  end

  attribute :suspended_addons_count do |user|
    user.addons.where.not(suspended_at: nil).count
  end

  attribute :total_deployments_count do |user|
    user.deployments.count
  end

  attribute :github_connected do |user|
    user.github_connected
  end

  attribute :gitlab_connected do |user|
    user.gitlab_connected
  end

  attribute :google_connected do |user|
    user.google_token.present?
  end
end
