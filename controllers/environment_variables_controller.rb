# frozen_string_literal: true

class EnvironmentVariablesController < ApplicationController
  # Export / Import must be defined before :id route
  get_action '/api/v1/apps/:app_id/environment_variables/export', :export do
    export
  end
  get_action '/apps/:app_id/environment_variables/export', :export do
    export
  end

  post_action '/api/v1/apps/:app_id/environment_variables/import', :import do
    import
  end
  post_action '/apps/:app_id/environment_variables/import', :import do
    import
  end

  get_action '/api/v1/apps/:app_id/environment_variables', :index do
    index
  end
  get_action '/apps/:app_id/environment_variables', :index do
    index
  end

  post_action '/api/v1/apps/:app_id/environment_variables', :create do
    create
  end
  post_action '/apps/:app_id/environment_variables', :create do
    create
  end

  delete_action '/api/v1/apps/:app_id/environment_variables/:id', :destroy do
    destroy
  end
  delete_action '/apps/:app_id/environment_variables/:id', :destroy do
    destroy
  end

  helpers do
    def index
      set_app
      @environment_variables = @app.environment_variables
      EnvironmentVariableSerializer.new(@environment_variables).serializable_hash[:data].map do |ev|
        ev[:attributes].merge(id: ev[:id])
      end.to_json
    end

    def export
      set_app
      content = @app.environment_variables.map { |ev| "#{ev.key}=#{ev.value}" }.join("\n")
      { content: content }.to_json
    end

    def import
      set_app
      content = params[:content]
      if content.blank?
        status 400
        return { error: 'No content provided' }.to_json
      end

      count = 0
      errors = []

      content.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        if line.include?('=')
          key, value = line.split('=', 2)
          key = key.strip
          value = value.strip.gsub(/^["']|["']$/, '')

          ev = @app.environment_variables.find_or_initialize_by(key: key)
          ev.value = value
          if ev.save
            count += 1
          else
            errors << "Failed to save #{key}: #{ev.errors.full_messages.join(', ')}"
          end
        end
      end

      { message: "Successfully imported #{count} variables", errors: errors }.to_json
    end

    def create
      set_app
      @environment_variable = @app.environment_variables.find_or_initialize_by(key: env_params[:key])
      @environment_variable.value = env_params[:value]

      if @environment_variable.save
        status 201
        EnvironmentVariableSerializer.new(@environment_variable).serializable_hash.dig(:data, :attributes).to_json
      else
        status 422
        { errors: @environment_variable.errors.full_messages }.to_json
      end
    end

    def destroy
      set_app
      @environment_variable = @app.environment_variables.find(params[:id])
      @environment_variable.destroy
      status 204
      ''
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'Environment variable not found' }.to_json
    end

    private

    def set_app
      @app = current_user.apps.find(params[:app_id])
    rescue ActiveRecord::RecordNotFound
      halt 404, { 'Content-Type' => 'application/json' }, { error: 'App not found' }.to_json
    end

    def env_params
      source = params[:environment_variable].is_a?(Hash) ? params[:environment_variable] : params
      permitted = %i[key value]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered
    end
  end
end
