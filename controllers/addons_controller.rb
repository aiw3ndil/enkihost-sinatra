# frozen_string_literal: true

class AddonsController < ApplicationController
  # Index
  get_action '/api/v1/apps/:app_id/addons', :index do
    index
  end
  get_action '/apps/:app_id/addons', :index do
    index
  end

  # Create
  post_action '/api/v1/apps/:app_id/addons', :create do
    create
  end
  post_action '/apps/:app_id/addons', :create do
    create
  end

  # Destroy
  delete_action '/api/v1/apps/:app_id/addons/:id', :destroy do
    destroy
  end
  delete_action '/apps/:app_id/addons/:id', :destroy do
    destroy
  end

  # Start/Stop/Restart
  post_action '/api/v1/apps/:app_id/addons/:id/start', :start do
    start
  end
  post_action '/apps/:app_id/addons/:id/start', :start do
    start
  end

  post_action '/api/v1/apps/:app_id/addons/:id/stop', :stop do
    stop
  end
  post_action '/apps/:app_id/addons/:id/stop', :stop do
    stop
  end

  post_action '/api/v1/apps/:app_id/addons/:id/restart', :restart do
    restart
  end
  post_action '/apps/:app_id/addons/:id/restart', :restart do
    restart
  end

  helpers do
    def index
      set_app
      @addons = @app.addons
      AddonSerializer.new(@addons).serializable_hash[:data].map { |addon| addon[:attributes] }.to_json
    end

    def create
      set_app
      Addon.transaction do
        current_user.lock!
        @addon = @app.addons.build(addon_params)

        if @addon.save
          AddonService.new(@addon).provision if defined?(AddonService)
          status 201
          AddonSerializer.new(@addon).serializable_hash.dig(:data, :attributes).to_json
        else
          status 422
          { errors: @addon.errors.full_messages }.to_json
        end
      end
    end

    def destroy
      set_app
      @addon = @app.addons.find(params[:id])
      AddonService.new(@addon).deprovision if defined?(AddonService)
      @addon.destroy
      status 204
      ''
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Addon not found' }.to_json
    end

    def start
      set_app
      @addon = @app.addons.find(params[:id])
      AddonService.new(@addon).start if defined?(AddonService)
      @addon.update!(status: :running)
      AddonSerializer.new(@addon).serializable_hash.dig(:data, :attributes).to_json
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Addon not found' }.to_json
    end

    def stop
      set_app
      @addon = @app.addons.find(params[:id])
      AddonService.new(@addon).stop if defined?(AddonService)
      @addon.update!(status: :stopped)
      AddonSerializer.new(@addon).serializable_hash.dig(:data, :attributes).to_json
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Addon not found' }.to_json
    end

    def restart
      set_app
      @addon = @app.addons.find(params[:id])
      AddonService.new(@addon).restart if defined?(AddonService)
      @addon.update!(status: :running)
      AddonSerializer.new(@addon).serializable_hash.dig(:data, :attributes).to_json
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Addon not found' }.to_json
    end

    private

    def set_app
      @app = current_user.apps.find(params[:app_id])
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
    end

    def addon_params
      source = params[:addon].is_a?(Hash) ? params[:addon] : params
      permitted = %i[kind name]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered
    end
  end
end
