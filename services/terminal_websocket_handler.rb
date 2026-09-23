# frozen_string_literal: true

require 'faye/websocket'
require 'json'
require 'jwt'
require 'pty'
require 'rack/utils'

# Handles interactive terminal WebSocket connections via ActionCable protocol
class TerminalWebsocketHandler
  def self.call(env)
    new(env).response
  end

  def initialize(env)
    @env = env
    @user = nil
    @app = nil
    @identifier = nil
    @master = nil
    @pid = nil
    @reader_thread = nil
  end

  def response
    unless Faye::WebSocket.websocket?(@env)
      return [400, { 'Content-Type' => 'application/json' }, [{ error: 'WebSocket upgrade required' }.to_json]]
    end

    ws = Faye::WebSocket.new(@env, nil, { ping: 25 })

    ws.on :open do |_event|
      handle_open(ws)
    end

    ws.on :message do |event|
      handle_message(ws, event.data)
    end

    ws.on :close do |_event|
      handle_close
    end

    ws.rack_response
  end

  private

  def handle_open(ws)
    @user = authenticate_user
    unless @user
      ws.send({ type: 'disconnect', reason: 'unauthorized', message: 'Authentication required' }.to_json)
      ws.close
      return
    end

    # Send ActionCable welcome handshake
    ws.send({ type: 'welcome' }.to_json)
  end

  def handle_message(ws, raw_data)
    data = JSON.parse(raw_data) rescue nil
    return unless data.is_a?(Hash)

    command = data['command']
    identifier = data['identifier']

    case command
    when 'subscribe'
      handle_subscribe(ws, identifier)
    when 'message'
      handle_client_message(data['data'])
    end
  rescue StandardError => e
    warn "[TerminalWS] Error handling message: #{e.message}"
  end

  def handle_subscribe(ws, identifier_str)
    @identifier = identifier_str
    params = JSON.parse(identifier_str) rescue {}

    channel = params['channel']
    app_id = params['app_id']

    unless channel == 'TerminalChannel' && app_id.present?
      ws.send({ identifier: identifier_str, type: 'reject_subscription' }.to_json)
      return
    end

    # Verify authorization
    begin
      @app = @user.apps.find(app_id)
    rescue ActiveRecord::RecordNotFound
      ws.send({ identifier: identifier_str, type: 'reject_subscription' }.to_json)
      ws.send({ identifier: identifier_str, message: { data: "\r\n\x1b[31mError: App not found or unauthorized.\x1b[0m\r\n" } }.to_json)
      ws.close
      return
    ensure
      ActiveRecord::Base.connection_handler.clear_active_connections! if defined?(ActiveRecord::Base)
    end

    container_name = @app.current_container_name
    unless container_name.present?
      ws.send({ identifier: identifier_str, message: { data: "\r\n\x1b[31mError: No successful deployment found for this app.\x1b[0m\r\n" } }.to_json)
      ws.close
      return
    end

    docker_bin = find_docker_bin

    # Check if container is running
    is_running = `#{docker_bin} inspect -f '{{.State.Running}}' #{container_name} 2>/dev/null`.strip == 'true' rescue false
    unless is_running
      ws.send({ identifier: identifier_str, message: { data: "\r\n\x1b[31mError: Container #{container_name} is not running.\x1b[0m\r\n" } }.to_json)
      ws.close
      return
    end

    # Detect shell
    has_bash = system("#{docker_bin} exec #{container_name} which bash >/dev/null 2>&1")
    shell = has_bash ? 'bash' : 'sh'
    login_flag = (shell == 'bash' ? '--login' : '-l')

    # Open PTY
    @master, slave = PTY.open
    command = "#{docker_bin} exec -it #{container_name} #{shell} #{login_flag}"
    @pid = spawn(command, in: slave, out: slave, err: slave, pgroup: true)
    slave.close

    # Acknowledge subscription
    ws.send({ identifier: identifier_str, type: 'confirm_subscription' }.to_json)
    ws.send({ identifier: identifier_str, message: { data: "\x1b[1;32m✓ Connected to container (#{container_name})! Ready for input.\x1b[0m\r\n" } }.to_json)

    # Spawn background reader thread
    @reader_thread = Thread.new do
      begin
        loop do
          rs, = IO.select([@master], nil, nil, 1.0)
          if rs
            begin
              chunk = @master.readpartial(4096)
              ws.send({ identifier: @identifier, message: { data: chunk } }.to_json)
            rescue EOFError, Errno::EIO
              ws.send({ identifier: @identifier, message: { data: "\r\n\x1b[33mTerminal session closed.\x1b[0m\r\n" } }.to_json)
              ws.close rescue nil
              break
            end
          end

          # Check if child process is still alive
          begin
            Process.getpgid(@pid)
          rescue Errno::ESRCH
            ws.send({ identifier: @identifier, message: { data: "\r\n\x1b[33mProcess exited.\x1b[0m\r\n" } }.to_json)
            ws.close rescue nil
            break
          end
        end
      rescue StandardError => e
        warn "[TerminalWS] Reader thread exception: #{e.message}"
      ensure
        cleanup_process
      end
    end
  end

  def handle_client_message(data_payload)
    parsed = data_payload.is_a?(String) ? (JSON.parse(data_payload) rescue {}) : data_payload
    return unless parsed.is_a?(Hash)

    action = parsed['action']
    case action
    when 'send_input'
      input = parsed['input']
      if input && @master
        begin
          @master.syswrite(input)
          @master.flush rescue nil
        rescue StandardError => e
          warn "[TerminalWS] PTY write error: #{e.message}"
        end
      end
    when 'receive'
      # Handle resize event if needed
    end
  end

  def handle_close
    @reader_thread&.kill rescue nil
    @reader_thread = nil
    cleanup_process
  end

  def cleanup_process
    if @pid
      begin
        Process.kill('TERM', @pid)
        Process.wait(@pid)
      rescue StandardError
        # Process already exited
      end
      @pid = nil
    end

    if @master
      begin
        @master.close
      rescue StandardError
        # Master IO already closed
      end
      @master = nil
    end
  end

  def authenticate_user
    query_params = Rack::Utils.parse_nested_query(@env['QUERY_STRING'] || '')
    token = query_params['token'].presence || @env['HTTP_AUTHORIZATION']&.split(' ')&.last
    return nil unless token.present?

    secret = ENV['JWT_SECRET_KEY'] || Rails.application.secret_key_base
    if token.count('.') == 2
      decoded, _ = JWT.decode(token, secret, true, { algorithm: 'HS256' })
      if decoded && (decoded['sub'] || decoded['jti'])
        user = User.find_by(id: decoded['sub']) || User.find_by(jti: decoded['jti'])
        return user if user
      end
    end

    User.find_by(jti: token)
  rescue StandardError => e
    warn "[TerminalWS] Auth error: #{e.message}"
    nil
  ensure
    ActiveRecord::Base.connection_handler.clear_active_connections! if defined?(ActiveRecord::Base)
  end

  def find_docker_bin
    if ENV['DOCKER_BINARY'].present? && File.executable?(ENV['DOCKER_BINARY'])
      return ENV['DOCKER_BINARY']
    end

    which_docker = `which docker`.strip rescue nil
    return which_docker if which_docker.present? && File.executable?(which_docker)

    ['/usr/bin/docker', '/usr/local/bin/docker', '/bin/docker'].find { |p| File.executable?(p) } || 'docker'
  end
end
