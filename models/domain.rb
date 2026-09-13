class Domain < ApplicationRecord
  belongs_to :app

  validates :fqdn, presence: true, 
                  uniqueness: true,
                  format: { with: /\A([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}\z/i }

  validate :validate_custom_domain_allowed

  private

  def validate_custom_domain_allowed
    return unless app&.user
    return if fqdn&.end_with?('.enkihost.com')

    return if fqdn&.end_with?(".enkihost.com")

    unless app.user.limits[:custom_domains]
      errors.add(:base, "Custom domains are not allowed on the #{app.user.plan.capitalize} plan.")
    end
  end
end
