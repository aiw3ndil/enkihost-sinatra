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

  # Download / import the database of a PostgreSQL addon
  get_action '/api/v1/apps/:app_id/addons/:id/download', :download do
    download
  end
  get_action '/apps/:app_id/addons/:id/download', :download do
    download
  end

  post_action '/api/v1/apps/:app_id/addons/:id/import', :import do
    import
  end
  post_action '/apps/:app_id/addons/:id/import', :import do
    import
  end

  get_action '/api/v1/apps/:app_id/addons/:id/import', :import_status do
    import_status
  end
  get_action '/apps/:app_id/addons/:id/import', :import_status do
    import_status
  end

  MAX_IMPORT_BYTES = Integer(ENV.fetch('MAX_DB_IMPORT_MB', 2048)) * 1024 * 1024

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

    def download
      set_postgresql_addon
      format = params[:format].presence || 'custom'
      halt 422, { error: 'format must be custom or sql' }.to_json unless DatabaseTransferService::DUMP_FORMATS.key?(format)

      service = DatabaseTransferService.new(@addon)
      halt 409, { error: 'The database is not running' }.to_json unless service.ready?

      extension = DatabaseTransferService::DUMP_FORMATS[format][:extension]
      filename = "#{@app.name}-#{@addon.name}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}".gsub(/[^\w.-]/, '_')
      content_type 'application/octet-stream'
      attachment "#{filename}.#{extension}"
      body service.dump_body(format)
    end

    def import
      set_postgresql_addon
      file = params[:file]
      unless file.is_a?(Hash) && file[:tempfile]
        halt 422, { error: 'Upload the dump as multipart form field "file"' }.to_json
      end

      tempfile = file[:tempfile]
      size = File.size(tempfile.path)
      halt 422, { error: 'The uploaded file is empty' }.to_json if size.zero?
      if size > MAX_IMPORT_BYTES
        halt 413, { error: "The dump is larger than the #{MAX_IMPORT_BYTES >> 20} MB import limit" }.to_json
      end
      if @addon.database_imports.in_progress.where('created_at > ?', 6.hours.ago).exists?
        halt 409, { error: 'An import is already running for this database' }.to_json
      end

      service = DatabaseTransferService.new(@addon)
      halt 409, { error: 'The database is not running' }.to_json unless service.ready?

      format = DatabaseTransferService.detect_format(tempfile.path)
      db_import = @addon.database_imports.create!(filename: file[:filename].to_s[0, 255], format: format, size: size)
      begin
        service.stage(tempfile.path, db_import)
      rescue DatabaseTransferService::Error => e
        db_import.update!(status: :failed, log: e.message, finished_at: Time.current)
        halt 500, { error: e.message }.to_json
      end

      DatabaseImportJob.perform_later(db_import.id)
      status 202
      db_import.to_json
    rescue DatabaseTransferService::Error => e
      halt 422, { error: e.message }.to_json
    end

    def import_status
      set_postgresql_addon
      db_import = @addon.database_imports.order(created_at: :desc).first
      db_import ? db_import.to_json : 'null'
    end

    private

    def set_postgresql_addon
      set_app
      @addon = @app.addons.find(params[:id])
      halt 422, { error: 'Only PostgreSQL databases can be downloaded or imported' }.to_json unless @addon.postgresql?
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Addon not found' }.to_json
    end

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
