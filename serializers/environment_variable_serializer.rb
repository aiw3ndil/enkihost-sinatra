class EnvironmentVariableSerializer
  include JSONAPI::Serializer
  attributes :id, :key, :value
end
