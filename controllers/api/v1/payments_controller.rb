# frozen_string_literal: true

module Api
  module V1
    class PaymentsController < Api::V1::ApplicationController
      post_action '/api/v1/payments/create_checkout_session', :create_checkout_session do
        create_checkout_session
      end

      helpers do
        def create_checkout_session
          plan_name = params[:plan_id] || params[:plan_name]

          unless %w[ignite blaze].include?(plan_name)
            status 422
            return { error: 'Invalid plan selected' }.to_json
          end

          frontend_url = ENV['FRONTEND_URL'] || 'https://enkihost.com'
          success_url = ENV['STRIPE_SUCCESS_URL'] || "#{frontend_url}/dashboard/billing/success"
          cancel_url = ENV['STRIPE_CANCEL_URL'] || "#{frontend_url}/dashboard/billing/cancel"

          begin
            stripe_service = StripeService.new
            session = stripe_service.create_checkout_session(current_user, plan_name, success_url, cancel_url)

            {
              url: session.url,
              session_id: session.id
            }.to_json
          rescue StandardError => e
            warn "Stripe Checkout Session Error: #{e.message}"
            status 500
            { error: e.message }.to_json
          end
        end
      end
    end
  end
end
