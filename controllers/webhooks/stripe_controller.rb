# frozen_string_literal: true

module Webhooks
  class StripeController < ::ApplicationController
    skip_before_action :authenticate_request!, only: [:create]

    post_action '/webhooks/stripe', :create do
      create
    end

    helpers do
      def create
        request.body.rewind if request.body.respond_to?(:rewind)
        payload = request.body.read
        sig_header = request.env['HTTP_STRIPE_SIGNATURE']

        result = StripeService.handle_webhook(payload, sig_header)

        if result[:status] == 200
          status 200
          ''
        else
          status(result[:status] || 400)
          { error: result[:error] }.to_json
        end
      rescue StandardError => e
        warn "Stripe Webhook Error: #{e.message}"
        status 400
        { error: e.message }.to_json
      end
    end
  end
end
