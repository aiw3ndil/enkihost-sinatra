# frozen_string_literal: true

require_relative 'application_job'

# Suspends or resumes a user's apps and databases after their plan changes.
class PlanEnforcementJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    PlanEnforcementService.new(user).call if user
  end
end
