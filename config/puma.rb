# frozen_string_literal: true

# Puma configuration for Enkihost Sinatra
max_threads_count = Integer(ENV.fetch("MAX_THREADS") { ENV.fetch("RAILS_MAX_THREADS", 5) })
min_threads_count = Integer(ENV.fetch("MIN_THREADS") { max_threads_count })
threads min_threads_count, max_threads_count

rack_env = ENV.fetch("RACK_ENV") { ENV.fetch("RAILS_ENV", "development") }
environment rack_env

port ENV.fetch("PORT", 3000)
pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

plugin :tmp_restart
