# frozen_string_literal: true

require "typesense_model"

# ActiveJob is a dev dependency so the async sync path (TypesenseModel::SyncJob)
# can be exercised. Load it up front and use the test adapter so async specs are
# deterministic regardless of which spec file triggers the load.
require "active_job"
ActiveJob::Base.queue_adapter = :test
require "typesense_model/sync_job" unless defined?(TypesenseModel::SyncJob)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Ensure a configuration object exists for every example. Unit specs stub the
  # client (see #stub_typesense_client) so nothing ever hits a live server.
  config.before do
    TypesenseModel.configure do |c|
      c.api_key = "test-key"
      c.host = "localhost"
      c.port = 8108
      c.protocol = "http"
    end
  end

  config.after do
    TypesenseModel.configuration = nil
    # Reset the per-AR-class proxy memo so models built in one example never leak
    # into the next (they are keyed by class name, which repeats across examples).
    if defined?(TypesenseModel::ActiveRecordExtension::TypesenseProxy)
      TypesenseModel::ActiveRecordExtension::TypesenseProxy.instance_variable_set(:@proxies, {})
    end
  end

  config.include Module.new {
    # Returns a double standing in for Typesense::Client and wires it as the
    # memoized client on the current configuration.
    def stub_typesense_client(client = nil)
      client ||= instance_double("Typesense::Client")
      allow(TypesenseModel.configuration).to receive(:client).and_return(client)
      client
    end
  }
end
