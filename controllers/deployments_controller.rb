# frozen_string_literal: true

class DeploymentsController < ApplicationController
  get_action '/api/v1/apps/:app_id/deployments', :index do
    index
  end
  get_action '/apps/:app_id/deployments', :index do
    index
  end

  get_action '/api/v1/apps/:app_id/deployments/:id', :show do
    show
  end
  get_action '/apps/:app_id/deployments/:id', :show do
    show
  end

  post_action '/api/v1/apps/:app_id/deployments', :create do
    create
  end
  post_action '/apps/:app_id/deployments', :create do
    create
  end

  helpers do
    def index
      set_app
      @deployments = @app.deployments.order(created_at: :desc)
      DeploymentSerializer.new(@deployments).serializable_hash[:data].map { |d| d[:attributes] }.to_json
    end

    def show
      set_app
      @deployment = @app.deployments.find(params[:id])
      DeploymentSerializer.new(@deployment).serializable_hash.dig(:data, :attributes).to_json
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Deployment not found' }.to_json
    end

    def create
      set_app
      @deployment = @app.deployments.build(deployment_params)
      @deployment.status = :queued

      if @deployment.save
        DeploymentJob.perform_later(@deployment.id) if defined?(DeploymentJob)
        status 201
        DeploymentSerializer.new(@deployment).serializable_hash.dig(:data, :attributes).to_json
      else
        status 422
        { errors: @deployment.errors.full_messages }.to_json
      end
    end

    private

    def set_app
      @app = current_user.apps.find(params[:app_id])
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
    end

    def deployment_params
      source = params[:deployment].is_a?(Hash) ? params[:deployment] : params
      permitted = %i[commit_sha]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered
    end
  end
end
