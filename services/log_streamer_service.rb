require 'open3'

class LogStreamerService
  def initialize(app)
    @app = app
    @container_name = app.current_container_name
  end

  def stream
    return unless @container_name

    # In a real system, this would be triggered from the channel's subscribe hook
    # in a separate thread. We use -f to follow and -t for timestamps.
    cmd = "docker logs -f -t --tail 100 #{@container_name}"

    Open3.popen3(cmd) do |_stdin, stdout, stderr, _wait_thr|
      # In a real environment, we'd broadcast each line via ActionCable
      # For now, we simulate the logic.
      stdout.each_line do |line|
        LogsChannel.broadcast_to(@app, { message: line })
      end

      stderr.each_line do |line|
        LogsChannel.broadcast_to(@app, { message: "ERROR: #{line}" })
      end
    end
  rescue StandardError => e
    Rails.logger.error("LogStreamerService Error: #{e.message}")
  end
end
