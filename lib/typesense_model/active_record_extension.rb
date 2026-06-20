# frozen_string_literal: true

module TypesenseModel
  module ActiveRecordExtension
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      # Usage: uses_typesense collection: 'plugs', model_json: :as_json, schema: ->(s) { s.field :id, :string }
      def uses_typesense(collection: nil, model_json: :as_json_typesense, schema: nil, async: false, &block)
        @_typesense_collection_name = collection || name.underscore.pluralize
        @_typesense_model_json_method = model_json
        @_typesense_async = async

        if schema
          @_typesense_schema = Schema.new
          schema.call(@_typesense_schema)
        elsif block_given?
          @_typesense_schema = Schema.new
          @_typesense_schema.instance_eval(&block)
        end

        define_singleton_method(:typesense_collection_name) do
          @_typesense_collection_name
        end

        define_singleton_method(:typesense_schema) do
          @_typesense_schema
        end

        define_singleton_method(:typesense_model_json_method) do
          @_typesense_model_json_method
        end

        define_singleton_method(:typesense_async?) do
          @_typesense_async
        end

        define_singleton_method(:search) do |query, options = {}|
          proxy = TypesenseProxy.for(self)
          proxy.search(query, options)
        end

        define_method(:typesense_model) do
          TypesenseProxy.for(self.class).find(id)
        end

        # Add callbacks for automatic syncing
        after_save :sync_to_typesense
        after_destroy :remove_from_typesense
      end

      # Import all records of this AR model into Typesense
      # @param batch_size [Integer] number of records per batch
      # @param transform [Symbol, Proc, nil] method or proc to generate document JSON
      # @param preloads [Array, Symbol, Hash, nil] associations to preload to avoid N+1
      # @param import_options [Hash] options passed to Typesense import
      # @return [Hash] { success: Integer, failed: Integer }
      def import_all_to_typesense(batch_size: 1000, transform: nil, preloads: nil, import_options: {})
        proxy = TypesenseProxy.for(self)
        # Ensure collection exists and schema is up-to-date before import
        proxy.create_collection unless proxy.collection_exists?
        transformer = transform || (respond_to?(:typesense_model_json_method) ? typesense_model_json_method : :as_json_typesense)
        proxy.import_from_model(self, batch_size, transformer, preloads, import_options)
      end
    end

    # Enqueue an async sync via ActiveJob. Kept as a module method so it can be
    # stubbed in tests and so the job lookup lives in one place.
    def self.enqueue_sync(class_name, id, action)
      unless defined?(ActiveJob::Base) && defined?(TypesenseModel::SyncJob)
        raise TypesenseModel::Error, "async: true requires ActiveJob to be available"
      end
      TypesenseModel::SyncJob.perform_later(class_name, id, action.to_s)
    end

    # Instance methods for callbacks
    def sync_to_typesense
      return unless self.class.respond_to?(:typesense_model_json_method)

      if self.class.respond_to?(:typesense_async?) && self.class.typesense_async?
        ActiveRecordExtension.enqueue_sync(self.class.name, id.to_s, :upsert)
      else
        sync_to_typesense_now
      end
    end

    # Synchronously write this record's document to Typesense.
    def sync_to_typesense_now
      return unless self.class.respond_to?(:typesense_model_json_method)

      json_method = self.class.typesense_model_json_method
      document_data = if json_method.is_a?(Proc)
        json_method.call(self)
      else
        respond_to?(json_method) ? send(json_method) : as_json_typesense
      end
      
      proxy = TypesenseProxy.for(self.class)
      sanitized = proxy.send(:sanitize_document, stringify_keys(document_data))
      proxy.client.collections[proxy.collection_name].documents.upsert(sanitized)
    rescue Typesense::Error => e
      TypesenseModel.logger.error("Failed to sync #{self.class.name}##{id} to Typesense: #{e.message}")
    end

    def remove_from_typesense
      return unless self.class.respond_to?(:typesense_model_json_method)

      if self.class.respond_to?(:typesense_async?) && self.class.typesense_async?
        ActiveRecordExtension.enqueue_sync(self.class.name, id.to_s, :remove)
      else
        remove_from_typesense_now
      end
    end

    # Synchronously delete this record's document from Typesense.
    def remove_from_typesense_now
      return unless self.class.respond_to?(:typesense_model_json_method)

      proxy = TypesenseProxy.for(self.class)
      proxy.client.collections[proxy.collection_name].documents[id].delete
    rescue Typesense::Error => e
      TypesenseModel.logger.error("Failed to remove #{self.class.name}##{id} from Typesense: #{e.message}")
    end

    # Default JSON method for Typesense
    def as_json_typesense
      as_json
    end

    private

    def stringify_keys(hash)
      return hash unless hash.is_a?(Hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    # Adapter that maps an AR model class into a TypesenseModel::Base-like class.
    #
    # A dedicated proxy subclass is built and memoized per AR model so that the
    # collection name and schema never clobber each other across models or
    # threads -- each subclass carries its own class-level state.
    class TypesenseProxy < TypesenseModel::Base
      class << self
        PROXY_MUTEX = Mutex.new

        def for(ar_class)
          @proxies ||= {}
          return @proxies[ar_class.name] if @proxies.key?(ar_class.name)

          PROXY_MUTEX.synchronize do
            @proxies[ar_class.name] ||= build_proxy(ar_class)
          end
        end

        def client
          TypesenseModel.configuration.client
        end

        private

        def build_proxy(ar_class)
          resolved_collection =
            if ar_class.respond_to?(:typesense_collection_name)
              ar_class.typesense_collection_name
            else
              ar_class.name.underscore.pluralize
            end
          resolved_schema = ar_class.typesense_schema if ar_class.respond_to?(:typesense_schema)

          Class.new(self) do
            @ar_class = ar_class
            collection_name(resolved_collection)
            @_schema_definition = resolved_schema

            class << self
              attr_reader :ar_class
            end
          end
        end
      end
    end
  end
end

