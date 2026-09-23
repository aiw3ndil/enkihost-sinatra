# frozen_string_literal: true

class AddonSerializer
  include JSONAPI::Serializer
  attributes :id, :kind, :name, :status, :app_id, :created_at

  attribute :config do |addon|
    cfg = addon.config
    cfg = JSON.parse(cfg) rescue { 'url' => cfg } if cfg.is_a?(String)
    cfg = {} unless cfg.is_a?(Hash)

    if cfg['url'].blank?
      host = cfg['host'].presence || "enkihost-addon-#{addon.id}"
      prefix = addon.kind == 'redis' ? 'redis' : 'postgres'
      auth = cfg['user'].present? ? "#{cfg['user']}:#{cfg['password']}@" : ''
      port = cfg['port'] || (addon.kind == 'redis' ? 6379 : 5432)
      db_part = addon.kind == 'redis' ? '' : "/#{cfg['database'] || 'main'}"
      
      cfg['url'] = "#{prefix}://#{auth}#{host}:#{port}#{db_part}"
      cfg['host'] ||= host
      cfg['port'] ||= port
      cfg['user'] ||= 'enkihost' unless addon.kind == 'redis'
      cfg['database'] ||= 'main' unless addon.kind == 'redis'
    end
    cfg
  end
end
