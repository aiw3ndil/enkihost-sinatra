class StripeService
  def initialize
    Stripe.api_key = ENV['STRIPE_SECRET_KEY']
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

  def create_checkout_session(user, plan_name, success_url, cancel_url)
    customer_id = create_customer(user)
    price_id = case plan_name
               when 'ignite' then ENV['STRIPE_PRICE_IGNITE_ID']
               when 'blaze' then ENV['STRIPE_PRICE_BLAZE_ID']
               else raise "Invalid plan: #{plan_name}"
               end

    Stripe::Checkout::Session.create({
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
    })
  end

  def self.handle_webhook(payload, sig_header)
    endpoint_secret = ENV['STRIPE_WEBHOOK_SECRET']
    event = nil

    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, endpoint_secret
      )
    rescue JSON::ParserError
      # Invalid payload
      return { status: 400, error: 'Invalid payload' }
    rescue Stripe::SignatureVerificationError
      # Invalid signature
      return { status: 400, error: 'Invalid signature' }
    end

    # Handle the event
    case event.type
    when 'checkout.session.completed'
      handle_checkout_completed(event.data.object)
    when 'customer.subscription.deleted'
      handle_subscription_deleted(event.data.object)
    # Add more event types here as needed
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
        plan: 'spark', # Downgrade to free tier
        stripe_subscription_id: nil
      )
      Rails.logger.info "User #{user.id} subscription deleted, downgraded to spark"
    end
  end
end
