class AppMonitorJob < ApplicationJob
  queue_as :default

  def perform(*args)
    MonitoringService.check_all
  end
end
