# frozen_string_literal: true

require_relative 'safe_job'

class ApplicationJob
  include SafeJob

  def self.queue_as(queue_name)
    sidekiq_options queue: queue_name
  end
end
