# frozen_string_literal: true

class StoragesController < ApplicationController
  get_action '/api/v1/apps/:app_id/storages', :index do
    index
  end
  get_action '/apps/:app_id/storages', :index do
    index
  end

  post_action '/api/v1/apps/:app_id/storages', :create do
    create
  end
  post_action '/apps/:app_id/storages', :create do
    create
  end

  delete_action '/api/v1/apps/:app_id/storages/:id', :destroy do
    destroy
  end
  delete_action '/apps/:app_id/storages/:id', :destroy do
    destroy
  end

  helpers do
    def index
      set_app
      @storages = @app.storages
      StorageSerializer.new(@storages).serializable_hash[:data].map { |s| s[:attributes] }.to_json
    end

    def create
      set_app
      @storage = @app.storages.new(storage_params)

      if @storage.save
        CoolifyService.new.sync_storages(@app) if defined?(CoolifyService)
        status 201
        StorageSerializer.new(@storage).serializable_hash.dig(:data, :attributes).to_json
      else
        status 422
        { errors: @storage.errors.full_messages }.to_json
      end
    end

    def destroy
      set_app
      @storage = @app.storages.find(params[:id])
      @storage.destroy
      status 204
      ''
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Storage not found' }.to_json
    end

    private

    def set_app
      @app = current_user.apps.find(params[:app_id])
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
    end

    def storage_params
      source = params[:storage].is_a?(Hash) ? params[:storage] : params
      permitted = %i[name source destination is_directory]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered
    end
  end
end
