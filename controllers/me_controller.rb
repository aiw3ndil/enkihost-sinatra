# frozen_string_literal: true

class MeController < ApplicationController
  # Rutas tanto con /api/v1/me como /me
  get_action '/api/v1/me', :show do
    show
  end

  get_action '/me', :show do
    show
  end

  put_action '/api/v1/me', :update do
    update
  end

  put_action '/me', :update do
    update
  end

  patch_action '/api/v1/me', :update do
    update
  end

  patch_action '/me', :update do
    update
  end

  put_action '/api/v1/me/password', :update_password do
    update_password
  end

  put_action '/me/password', :update_password do
    update_password
  end

  helpers do
    def show
      UserSerializer.new(current_user).serializable_hash.dig(:data, :attributes).to_json
    end

    def update
      if current_user.update(user_params)
        UserSerializer.new(current_user).serializable_hash.dig(:data, :attributes).to_json
      else
        status 422
        { errors: current_user.errors.full_messages }.to_json
      end
    end

    def update_password
      current_password = password_params[:current_password]
      new_password = password_params[:password]

      unless current_user.authenticate(current_password)
        status 422
        return { errors: ['Current password is incorrect'] }.to_json
      end

      current_user.password = new_password
      current_user.password_confirmation = password_params[:password_confirmation]

      if current_user.save
        status 200
        { message: 'Password updated successfully' }.to_json
      else
        status 422
        { errors: current_user.errors.full_messages }.to_json
      end
    end

    private

    def user_params
      source = params[:user].is_a?(Hash) ? params[:user] : params
      permitted = %i[name email]
      filtered = {}
      permitted.each do |k|
        filtered[k] = source[k] if source.key?(k)
        filtered[k] = source[k.to_s] if source.key?(k.to_s)
      end
      filtered
    end

    def password_params
      params[:user].is_a?(Hash) ? params[:user] : params
    end
  end
end
