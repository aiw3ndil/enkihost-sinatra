# frozen_string_literal: true

module Api
  module V1
    # God mode console: every user's apps and databases, and entering their dashboard as them.
    class AdminController < Api::V1::ApplicationController
      IMPERSONATION_TTL = 3600

      get_action '/api/v1/admin/overview', :overview do
        overview
      end

      post_action '/api/v1/admin/impersonate/:user_id', :impersonate do
        impersonate
      end

      helpers do
        def overview
          require_god_mode!

          users = User.includes(apps: %i[addons latest_deployment]).order(:id)
          users.map do |user|
            {
              id: user.id,
              name: user.name,
              email: user.email,
              plan: user.plan,
              god_mode: user.god_mode,
              created_at: user.created_at,
              apps: user.apps.map do |app|
                {
                  id: app.id,
                  name: app.name,
                  kind: app.kind,
                  subdomain: app.subdomain,
                  runtime_status: app.runtime_status,
                  last_deployment_status: app.latest_deployment&.status,
                  last_deployed_at: app.latest_deployment&.created_at
                }
              end,
              # Only metadata: the credentials in addon config stay out of the overview.
              databases: user.apps.flat_map do |app|
                app.addons.map do |addon|
                  { id: addon.id, name: addon.name, kind: addon.kind, status: addon.status, app_id: app.id, app_name: app.name }
                end
              end
            }
          end.to_json
        end

        def impersonate
          require_god_mode!

          user = User.find_by(id: params[:user_id])
          halt 404, { error: 'User not found' }.to_json unless user
          halt 422, { error: 'God mode users cannot be impersonated' }.to_json if user.god_mode?

          Impersonation.create!(
            impersonator: current_user,
            user: user,
            ip_address: request.ip,
            user_agent: request.user_agent
          )
          warn "[impersonation] god=#{current_user.id} started impersonating user=#{user.id}"

          {
            token: generate_jwt_for(user, impersonator: current_user, expires_in: IMPERSONATION_TTL),
            expires_in: IMPERSONATION_TTL,
            data: UserSerializer.new(user).serializable_hash.dig(:data, :attributes)
          }.to_json
        end

        def require_god_mode!
          user_not_authorized unless current_user&.god_mode? && !impersonating?
        end
      end
    end
  end
end
