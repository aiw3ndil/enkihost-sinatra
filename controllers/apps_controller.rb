# frozen_string_literal: true

class AppsController < ApplicationController
  # Index
  get_action '/api/v1/apps', :index do
    index
  end
  get_action '/apps', :index do
    index
  end

  # Show
  get_action '/api/v1/apps/:id', :show do
    show
  end
  get_action '/apps/:id', :show do
    show
  end

  # Create
  post_action '/api/v1/apps', :create do
    create
  end
  post_action '/apps', :create do
    create
  end

  # Update
  put_action '/api/v1/apps/:id', :update do
    update
  end
  put_action '/apps/:id', :update do
    update
  end
  patch_action '/api/v1/apps/:id', :update do
    update
  end
  patch_action '/apps/:id', :update do
    update
  end

  # Destroy
  delete_action '/api/v1/apps/:id', :destroy do
    destroy
  end
  delete_action '/apps/:id', :destroy do
    destroy
  end

  # Container actions
  post_action '/api/v1/apps/:id/start', :start do
    start
  end
  post_action '/apps/:id/start', :start do
    start
  end

  post_action '/api/v1/apps/:id/stop', :stop do
    stop
  end
  post_action '/apps/:id/stop', :stop do
    stop
  end

  post_action '/api/v1/apps/:id/restart', :restart do
    restart
  end
  post_action '/apps/:id/restart', :restart do
    restart
  end

  get_action '/api/v1/apps/:id/stats', :stats do
    stats
  end
  get_action '/apps/:id/stats', :stats do
    stats
  end

  helpers do
    def index
      @apps = current_user.apps.includes(:latest_deployment, :user)
      json_data = AppSerializer.new(@apps).serializable_hash[:data]
      if json_data.is_a?(Array)
        json_data.map { |app| app[:attributes] }.to_json
      elsif json_data.nil?
        [].to_json
      else
        [json_data[:attributes]].to_json
      end
    end

    def show
      set_app
      AppSerializer.new(@app).serializable_hash.dig(:data, :attributes).to_json
    end

    def create
      App.transaction do
        current_user.lock!
        @app = current_user.apps.build(app_params)

        if @app.save
          if @app.repository_url.to_s.include?('github.com') && current_user.github_token.present?
            begin
              setup_github_webhook(@app)
            rescue StandardError => e
              warn "Soft error in setup_github_webhook: #{e.message}"
            end
          end

          status 201
          {
            status: 'success',
            app_id: @app.id,
            name: @app.name,
            attributes: @app.attributes
          }.to_json
        else
          status 422
          error_sentence = @app.errors.full_messages.to_sentence
          {
            status: 422,
            error: error_sentence,
            message: error_sentence,
            errors: @app.errors.full_messages
          }.to_json
        end
      end
    rescue StandardError => e
      warn "[AppsController#create] CRITICAL ERROR: #{e.message}"
      status 500
      {
        status: 500,
        error: "Failed to create application: #{e.message}",
        message: "Failed to create application: #{e.message}"
      }.to_json
    end

    def update
      set_app
      if @app.update(app_params)
        if @app.coolify_uuid.present? && defined?(CoolifyService)
          begin
            CoolifyService.new.sync_settings(@app)
          rescue StandardError => e
            warn "Soft Update: Failed to sync settings for #{@app.id}: #{e.message}"
          end
        end

        AppSerializer.new(@app).serializable_hash.dig(:data, :attributes).to_json
      else
        status 422
        error_sentence = @app.errors.full_messages.to_sentence
        {
          status: 422,
          error: error_sentence,
          message: error_sentence,
          errors: @app.errors.full_messages
        }.to_json
      end
    end

    def destroy
      set_app
      @app.destroy
      status 204
      ''
    end

    def start
      set_app
      if (container_name = @app.current_container_name)
        system("docker start #{container_name}")
        @app.update!(runtime_status: :running)
        { status: 'running' }.to_json
      else
        status 422
        { error: 'No successful deployment found to start' }.to_json
      end
    end

    def stop
      set_app
      if (container_name = @app.current_container_name)
        system("docker stop #{container_name}")
        @app.update!(runtime_status: :down)
        { status: 'down' }.to_json
      else
        status 422
        { error: 'No successful deployment found to stop' }.to_json
      end
    end

    def restart
      set_app
      if (container_name = @app.current_container_name)
        system("docker restart #{container_name}")
        @app.update!(runtime_status: :running)
        { status: 'running' }.to_json
      else
        status 422
        { error: 'No successful deployment found to restart' }.to_json
      end
    end

    def stats
      set_app
      @app.fetch_live_stats.to_json
    end

    private

    def set_app
      @app = current_user.apps.includes(:latest_deployment, :user).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
    end

    def setup_github_webhook(app)
      repo_full_name = app.repository_url.match(%r{github\.com/([\w-]+/[\w-]+)})&.captures&.first
      return unless repo_full_name

      callback_url = "https://api.enkihost.com/webhooks/github/#{app.id}"
      app.update!(webhook_secret: SecureRandom.hex(20))

      if defined?(GithubService)
        github_service = GithubService.new(current_user)
        github_service.create_webhook(repo_full_name, callback_url, app.webhook_secret)
      end
    rescue StandardError => e
      warn "Failed to create GitHub Webhook for app #{app.id}: #{e.message}"
    end

    def app_params
      source = params[:app].is_a?(Hash) ? params[:app] : params
      permitted = %i[name kind repository_url branch build_pack port docker_compose_location docker_compose_raw]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered[:build_pack] = 'docker_compose' if filtered[:build_pack] == 'docker-compose'
      filtered
    end
  end
end
