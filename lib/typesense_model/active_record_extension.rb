module TypesenseModel
  module ActiveRecordExtension
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      # Usage: uses_typesense collection: 'plugs', model_json: :as_json, schema: ->(s) { s.field :id, :string }
      def uses_typesense(collection: nil, model_json: :as_json_typesense, schema: nil, &block)
        @_typesense_collection_name = collection || name.underscore.pluralize
        @_typesense_model_json_method = model_json

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

    # Instance methods for callbacks
    def sync_to_typesense
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
    rescue => e
      Rails.logger.error "Failed to sync #{self.class.name}##{id} to Typesense: #{e.message}" if defined?(Rails)
    end

    def remove_from_typesense
      return unless self.class.respond_to?(:typesense_model_json_method)
      
      proxy = TypesenseProxy.for(self.class)
      proxy.client.collections[proxy.collection_name].documents[id].delete
    rescue => e
      Rails.logger.error "Failed to remove #{self.class.name}##{id} from Typesense: #{e.message}" if defined?(Rails)
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

    # Simple adapter that maps an AR model class into a TypesenseModel::Base-like class
    class TypesenseProxy < TypesenseModel::Base
      class << self
        def for(ar_class)
          @ar_class = ar_class
          collection_name(ar_class.respond_to?(:typesense_collection_name) ? ar_class.typesense_collection_name : ar_class.name.underscore.pluralize)

          if ar_class.respond_to?(:typesense_schema) && ar_class.typesense_schema
            @_schema_definition = ar_class.typesense_schema
          end

          self
        end

        def ar_class
          @ar_class
        end

        def client
          TypesenseModel.configuration.client
        end
      end
    end
  end
end

