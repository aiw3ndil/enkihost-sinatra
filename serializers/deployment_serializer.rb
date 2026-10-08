class DeploymentSerializer
  include JSONAPI::Serializer
  attributes :id, :status, :log, :commit_sha, :created_at, :started_at, :finished_at, :duration_seconds
end
