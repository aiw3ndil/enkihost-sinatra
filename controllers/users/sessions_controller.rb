# frozen_string_literal: true

module Users
  class SessionsController < ::ApplicationController
    skip_before_action :authenticate_request!, only: %i[create info]

    post_action '/api/v1/login', :create do
      create
    end

    get_action '/api/v1/login', :info do
      info
    end

    delete_action '/api/v1/logout', :destroy do
      destroy
    end

    helpers do
      def create
        email = params[:user]&.dig(:email) || params[:email]
        password = params[:user]&.dig(:password) || params[:password]

        user = User.find_by(email: email&.downcase)
        if user&.authenticate(password)
          token = generate_jwt_for(user)
          headers['Authorization'] = "Bearer #{token}"
          status 200
          {
            status: 200,
            message: 'Logged in successfully.',
            token: token,
            data: UserSerializer.new(user).serializable_hash.dig(:data, :attributes)
          }.to_json
        else
          status 401
          { status: 401, error: 'Invalid email or password.' }.to_json
        end
      end

      def info
        status 200
        { error: 'Login must use POST /api/v1/login with JSON body {"user":{"email":..., "password":...}}' }.to_json
      end

      def destroy
        if current_user
          current_user.update_column(:jti, User.generate_jti)
          status 200
          { status: 200, message: 'Logged out successfully.' }.to_json
        else
          status 401
          { status: 401, message: "Couldn't find an active session." }.to_json
        end
      end
    end
  end
end
