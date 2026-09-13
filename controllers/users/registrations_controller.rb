# frozen_string_literal: true

module Users
  class RegistrationsController < ::ApplicationController
    skip_before_action :authenticate_request!, only: %i[create info]

    post_action '/api/v1/signup', :create do
      create
    end

    get_action '/api/v1/signup', :info do
      info
    end

    helpers do
      def create
        user_data = params[:user] || params
        email = user_data[:email]
        password = user_data[:password]
        password_confirmation = user_data[:password_confirmation] || password
        name = user_data[:name]

        user = User.new(
          email: email&.downcase,
          password: password,
          password_confirmation: password_confirmation,
          name: name,
          plan: 'spark'
        )

        if user.save
          token = generate_jwt_for(user)
          headers['Authorization'] = "Bearer #{token}"
          status 200
          {
            status: 200,
            message: 'Signed up successfully.',
            token: token,
            data: UserSerializer.new(user).serializable_hash.dig(:data, :attributes)
          }.to_json
        else
          status 422
          {
            status: 422,
            message: "User couldn't be created successfully. #{user.errors.full_messages.to_sentence}",
            errors: user.errors.full_messages
          }.to_json
        end
      end

      def info
        status 200
        { error: 'Signup must use POST /api/v1/signup with JSON body {"user":{"email":..., "password":...}}' }.to_json
      end
    end
  end
end
