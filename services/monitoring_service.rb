class MonitoringService
  def self.check_all
    App.find_each do |app|
      new(app).check
    end
  end

  def initialize(app)
    @app = app
    @container_name = app.current_container_name
  end

  def check
    return @app.update!(runtime_status: :down) unless @container_name

    # Use docker inspect to get status and restart count
    inspect_json = `docker inspect #{@container_name}` rescue nil
    
    if inspect_json.blank? || inspect_json == "[]\n"
      return @app.update!(runtime_status: :down)
    end

    begin
      data = JSON.parse(inspect_json).first
      state = data.dig('State')
      status = state.dig('Status') # running, restarting, exited, paused, dead
      restart_count = state.dig('RestartCount').to_i

      if status == 'restarting' || restart_count > 5
        @app.update!(runtime_status: :restarting)
      elsif status == 'running'
        @app.update!(runtime_status: :running)
      else
        @app.update!(runtime_status: :down)
      end
    rescue StandardError => e
      Rails.logger.error("MonitoringService Error for App #{@app.id}: #{e.message}")
      @app.update!(runtime_status: :down)
    end
  end
end
