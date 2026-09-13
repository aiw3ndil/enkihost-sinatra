class AddonSerializer
  include JSONAPI::Serializer
  attributes :id, :kind, :name, :status, :config
end
