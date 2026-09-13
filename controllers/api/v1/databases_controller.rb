# frozen_string_literal: true

module Api
  module V1
    class DatabasesController < Api::V1::ApplicationController
      get_action '/api/v1/databases', :index do
        index
      end

      get_action '/databases', :index do
        index
      end

      helpers do
        def index
          @addons = Addon.joins(:app).where(apps: { user_id: current_user.id })
          data = AddonSerializer.new(@addons).serializable_hash[:data]
          if data.is_a?(Array)
            data.map { |addon| addon[:attributes] }.to_json
          elsif data.nil?
            [].to_json
          else
            [data[:attributes]].to_json
          end
        end
      end
    end
  end
end
