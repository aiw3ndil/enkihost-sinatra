class StorageSerializer
  include JSONAPI::Serializer
  attributes :id, :app_id, :name, :source, :destination, :is_directory, :created_at, :updated_at
end
