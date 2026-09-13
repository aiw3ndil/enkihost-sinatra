class DeploymentSerializer
  include JSONAPI::Serializer
  attributes :id, :status, :log, :commit_sha, :created_at
end
