# frozen_string_literal: true

require 'sidekiq'

module SafeJob
  def self.included(base)
    base.include Sidekiq::Job
    base.extend ClassMethods
  end

  module ClassMethods
    def perform_later(*args)
      perform_async(*args)
    end

    def perform_async(*args)
      super
    rescue StandardError => e
      warn "[SafeJob Fallback] Redis unavailable (#{e.class}: #{e.message}). Executing #{self} in background thread."
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          new.perform(*args)
        end
      rescue StandardError => err
        warn "[SafeJob Fallback Error] #{err.class}: #{err.message}\n#{err.backtrace&.first(5)&.join("\n")}"
      end
    end

    def perform_at(timestamp, *args)
      super
    rescue StandardError => e
      warn "[SafeJob Fallback] Redis unavailable (#{e.class}: #{e.message}). Scheduling #{self} in background thread."
      delay = timestamp.to_f - Time.now.to_f
      Thread.new do
        sleep [delay, 0].max if delay > 0
        ActiveRecord::Base.connection_pool.with_connection do
          new.perform(*args)
        end
      rescue StandardError => err
        warn "[SafeJob Fallback Error] #{err.class}: #{err.message}\n#{err.backtrace&.first(5)&.join("\n")}"
      end
    end

    def perform_in(delay, *args)
      super
    rescue StandardError => e
      warn "[SafeJob Fallback] Redis unavailable (#{e.class}: #{e.message}). Scheduling #{self} in background thread."
      delay = delay.to_f
      Thread.new do
        sleep [delay, 0].max if delay > 0
        ActiveRecord::Base.connection_pool.with_connection do
          new.perform(*args)
        end
      rescue StandardError => err
        warn "[SafeJob Fallback Error] #{err.class}: #{err.message}\n#{err.backtrace&.first(5)&.join("\n")}"
      end
    end
  end
end
