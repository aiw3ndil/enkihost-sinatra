# frozen_string_literal: true

# Puma configuration for Enkihost Sinatra
max_threads_count = Integer(ENV.fetch("MAX_THREADS") { ENV.fetch("RAILS_MAX_THREADS", 5) })
min_threads_count = Integer(ENV.fetch("MIN_THREADS") { max_threads_count })
threads min_threads_count, max_threads_count

rack_env = ENV.fetch("RACK_ENV") { ENV.fetch("RAILS_ENV", "development") }
environment rack_env

port_num = Integer(ENV.fetch("PORT", 4567))
bind "tcp://0.0.0.0:#{port_num}"

pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

# Timeouts to prevent slow client attacks and hung connections
persistent_timeout Integer(ENV.fetch("PERSISTENT_TIMEOUT", 20))
first_data_timeout Integer(ENV.fetch("FIRST_DATA_TIMEOUT", 30))

# Cluster mode: multi-process workers for production CPU core utilization
workers_count = Integer(ENV.fetch("WEB_CONCURRENCY", 2))
if rack_env == "production" && workers_count > 1
  workers workers_count
  preload_app!

  worker_timeout Integer(ENV.fetch("WORKER_TIMEOUT", 60))
  worker_boot_timeout Integer(ENV.fetch("WORKER_BOOT_TIMEOUT", 60))

  before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
  end

  # Puma 7+ / 8 uses before_worker_boot
  if respond_to?(:before_worker_boot)
    before_worker_boot do
      ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
    end
  else
    on_worker_boot do
      ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
    end
  end
end

lowlevel_error_handler do |ex, env|
  [500, { "Content-Type" => "application/json" }, ['{"error":"Internal Server Error","status":500}']]
end

plugin :tmp_restart
