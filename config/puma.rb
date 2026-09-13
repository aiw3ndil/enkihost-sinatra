# frozen_string_literal: true

# Puma configuration for Enkihost Sinatra
max_threads_count = Integer(ENV.fetch("MAX_THREADS") { ENV.fetch("RAILS_MAX_THREADS", 5) })
min_threads_count = Integer(ENV.fetch("MIN_THREADS") { max_threads_count })
threads min_threads_count, max_threads_count

rack_env = ENV.fetch("RACK_ENV") { ENV.fetch("RAILS_ENV", "development") }
environment rack_env

port_num = Integer(ENV.fetch("PORT", 4567))
port port_num

pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

# Cluster mode: multi-process workers for production CPU core utilization
workers_count = Integer(ENV.fetch("WEB_CONCURRENCY", 2))
if rack_env == "production" && workers_count > 1
  workers workers_count
  preload_app!

  before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
  end

  on_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
  end
end

plugin :tmp_restart
