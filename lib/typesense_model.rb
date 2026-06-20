# frozen_string_literal: true

require "logger"
require "typesense"
require "active_support/core_ext/string/inflections"
require "typesense_model/version"
require "typesense_model/base"
require "typesense_model/search"
require "typesense_model/schema"
require "typesense_model/configuration"
require "typesense_model/active_record_extension"

module TypesenseModel
  class Error < StandardError; end
  
  class << self
    attr_accessor :configuration
    attr_writer :logger
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration) if block_given?
  end

  # Logger used for non-fatal failures (e.g. background sync errors). Defaults to
  # Rails.logger when available, otherwise a STDERR logger. Assign your own with
  # TypesenseModel.logger = ...
  def self.logger
    @logger ||= if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger
    else
      Logger.new($stderr)
    end
  end
end 

# Auto-include into ActiveRecord. Prefer the Rails load hook so this works
# regardless of gem load order; fall back to a direct include if ActiveRecord
# is already loaded (e.g. non-Rails usage).
if defined?(ActiveSupport)
  ActiveSupport.on_load(:active_record) do
    include TypesenseModel::ActiveRecordExtension
  end

  # Define the async sync job only once ActiveJob is loaded, so we never depend
  # on it at load time (it's optional — only needed for `async: true`).
  ActiveSupport.on_load(:active_job) do
    require "typesense_model/sync_job"
  end
elsif defined?(ActiveRecord::Base)
  ActiveRecord::Base.include(TypesenseModel::ActiveRecordExtension)
end