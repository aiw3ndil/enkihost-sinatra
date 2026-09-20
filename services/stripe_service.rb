# frozen_string_literal: true

require 'stripe'

class StripeService
  def initialize
    api_key = ENV['STRIPE_SECRET_KEY']
    raise 'Stripe configuration missing on server (STRIPE_SECRET_KEY is not set)' if api_key.blank?

    Stripe.api_key = api_key
  end

  def create_customer(user)
    return user.stripe_customer_id if user.stripe_customer_id.present?

    customer = Stripe::Customer.create({
      email: user.email,
      metadata: { user_id: user.id }
    })

    user.update!(stripe_customer_id: customer.id)
    customer.id
  end

  def create_checkout_session(user, plan_name, success_url, cancel_url, price_id_param = nil)
    customer_id = create_customer(user)
    price_id = price_id_param.presence ||
               case plan_name
               when 'ignite' then ENV['STRIPE_PRICE_IGNITE_ID']
               when 'blaze' then ENV['STRIPE_PRICE_BLAZE_ID']
               else raise "Invalid plan: #{plan_name}"
               end

    raise "Stripe price ID for plan #{plan_name} is not configured" if price_id.blank?

    # If a Product ID (prod_...) was provided instead of a Price ID (price_...), resolve its price automatically
    if price_id.start_with?('prod_')
      product = Stripe::Product.retrieve(price_id)
      resolved_price = if product.default_price.is_a?(String)
                         product.default_price
                       elsif product.default_price.respond_to?(:id)
                         product.default_price.id
                       else
                         nil
                       end
      price_id = resolved_price.presence || Stripe::Price.list(product: price_id, active: true, limit: 1).data.first&.id
      raise "No active price found for Stripe product #{product.id}" if price_id.blank?
    end

    subscription_data = {}
    trial_days = ENV.fetch('STRIPE_IGNITE_TRIAL_DAYS', '14').to_i
    if plan_name == 'ignite' && trial_days.positive?
      subscription_data[:trial_period_days] = trial_days
    end

    session_params = {
      customer: customer_id,
      payment_method_types: ['card'],
      line_items: [{
        price: price_id,
        quantity: 1
      }],
      mode: 'subscription',
      success_url: success_url,
      cancel_url: cancel_url,
      metadata: {
        user_id: user.id,
        plan_name: plan_name
      }
    }
    session_params[:subscription_data] = subscription_data unless subscription_data.empty?

    Stripe::Checkout::Session.create(session_params)
  end

  def self.handle_webhook(payload, sig_header)
    endpoint_secret = ENV['STRIPE_WEBHOOK_SECRET']
    event = nil

    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, endpoint_secret
      )
    rescue JSON::ParserError
      return { status: 400, error: 'Invalid payload' }
    rescue Stripe::SignatureVerificationError
      return { status: 400, error: 'Invalid signature' }
    end

    case event.type
    when 'checkout.session.completed'
      handle_checkout_completed(event.data.object)
    when 'customer.subscription.deleted'
      handle_subscription_deleted(event.data.object)
    else
      Rails.logger.info "Unhandled event type: #{event.type}"
    end

    { status: 200 }
  end

  private

  def self.handle_checkout_completed(session)
    user_id = session.metadata.user_id
    plan_name = session.metadata.plan_name
    subscription_id = session.subscription

    user = User.find_by(id: user_id)
    if user
      user.update!(
        plan: plan_name,
        stripe_subscription_id: subscription_id
      )
      Rails.logger.info "User #{user.id} upgraded to #{plan_name}"
    end
  end

  def self.handle_subscription_deleted(subscription)
    user = User.find_by(stripe_subscription_id: subscription.id)
    if user
      user.update!(
        plan: 'spark',
        stripe_subscription_id: nil
      )
      Rails.logger.info "User #{user.id} subscription deleted, downgraded to spark"
    end
  end
end
