# frozen_string_literal: true

require_relative 'config/environment'
require 'sinatra/activerecord'
require 'sinatra/activerecord/rake'

task :environment do
  # already loaded
end

namespace :db do
  task load_config: :environment
end

Dir.glob(File.expand_path('lib/tasks/*.rake', __dir__)).each { |r| import r }
