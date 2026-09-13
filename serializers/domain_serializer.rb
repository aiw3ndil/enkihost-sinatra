class DomainSerializer
  include JSONAPI::Serializer
  attributes :id, :fqdn, :created_at
end
