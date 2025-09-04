require "typesense"
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
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration) if block_given?
  end
end 

# Auto-include into ActiveRecord if available
if defined?(ActiveRecord::Base)
  ActiveRecord::Base.include(TypesenseModel::ActiveRecordExtension)
end