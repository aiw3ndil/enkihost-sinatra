# frozen_string_literal: true

require_relative 'application_job'

class SendDeploymentEmailJob < ApplicationJob
  queue_as :mailers

  def perform(action, deployment_id)
    DeploymentMailer.deliver_now(action, deployment_id)
  end
end
