# frozen_string_literal: true

class DomainsController < ApplicationController
  get_action '/api/v1/apps/:app_id/domains', :index do
    index
  end
  get_action '/apps/:app_id/domains', :index do
    index
  end

  post_action '/api/v1/apps/:app_id/domains', :create do
    create
  end
  post_action '/apps/:app_id/domains', :create do
    create
  end

  delete_action '/api/v1/apps/:app_id/domains/:id', :destroy do
    destroy
  end
  delete_action '/apps/:app_id/domains/:id', :destroy do
    destroy
  end

  helpers do
    def index
      set_app
      @domains = @app.domains
      DomainSerializer.new(@domains).serializable_hash[:data].map { |d| d[:attributes] }.to_json
    end

    def create
      set_app
      @domain = @app.domains.build(domain_params)

      if @domain.save
        SyncAppSettingsJob.perform_later(@app.id) if defined?(SyncAppSettingsJob)
        status 201
        DomainSerializer.new(@domain).serializable_hash.dig(:data, :attributes).to_json
      else
        status 422
        { errors: @domain.errors.full_messages }.to_json
      end
    end

    def destroy
      set_app
      @domain = @app.domains.find(params[:id])
      @domain.destroy
      SyncAppSettingsJob.perform_later(@app.id) if defined?(SyncAppSettingsJob)
      status 204
      ''
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Domain not found' }.to_json
    end

    private

    def set_app
      @app = current_user.apps.find(params[:app_id])
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
    end

    def domain_params
      source = params[:domain].is_a?(Hash) ? params[:domain] : params
      permitted = %i[fqdn]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered
    end
  end
end
