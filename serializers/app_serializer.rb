class AppSerializer
  include JSONAPI::Serializer
  attributes :id, :name, :subdomain, :kind, :build_pack, :deployment_type, :repository_url, :branch, 
             :port, :cpu_limit, :memory_limit, :runtime_status, :coolify_uuid, :webhook_url, :webhook_secret,
             :last_deployment_status, :created_at, :updated_at

  attribute :user_plan do |object|
    object.user.plan
  end

  attribute :last_deployment do |object|
    deployment = object.latest_deployment
    if deployment
      {
        id: deployment.id,
        status: deployment.status,
        created_at: deployment.created_at
      }
    else
      nil
    end
  end

  attribute :last_deployed_at do |object|
    object.latest_deployment&.created_at
  end

  attribute :last_deployer do |object|
    object.latest_deployment ? object.user.email : nil
  end
end
