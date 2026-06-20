# frozen_string_literal: true

module TypesenseModel
  class Base
    class << self
      attr_accessor :_collection_name, :_schema_definition

      def collection_name(name = nil)
        if name
          @_collection_name = name
        else
          @_collection_name ||= self.name.underscore.pluralize
        end
      end

      def define_schema(&block)
        @_schema_definition = Schema.new
        @_schema_definition.instance_eval(&block)
      end

      def schema_definition
        @_schema_definition
      end

      def create(attributes = {})
        new(attributes).save
      end

      def find(id)
        response = client.collections[collection_name].documents[id].retrieve
        new(response)
      rescue Typesense::Error::ObjectNotFound
        nil
      end

      def search(query, options = {})
        Search.new(self, query, options).execute
      end

      # Perform several searches in a single request.
      #
      # @param searches [Array<Hash>] each a set of Typesense search params;
      #   `collection` defaults to this model's collection, and `q`/`query_by`
      #   fall back the same way as #search (pass `query_by` explicitly when
      #   targeting a different collection).
      # @param common_params [Hash] params applied to every search.
      # @return [Array<SearchResults>] one result set per search, in order.
      def multi_search(searches, common_params = {})
        payload = Array(searches).map do |params|
          params = params.transform_keys(&:to_sym)
          {
            collection: params[:collection] || collection_name,
            q: params[:q] || '*',
            query_by: params[:query_by] || default_query_by
          }.merge(params.except(:collection, :q, :query_by))
        end

        response = client.multi_search.perform({ searches: payload }, common_params)
        (response['results'] || []).map { |result| SearchResults.new(result, self) }
      end

      # Comma-separated list of indexed string fields (excluding id) used as the
      # default `query_by` when a search doesn't specify one.
      def default_query_by
        return '' unless schema_definition

        schema_definition.fields
          .select { |f| f[:index] && f[:type] == 'string' && f[:name] != 'id' }
          .map { |f| f[:name] }
          .join(',')
      end

      # Create the collection in Typesense
      def create_collection(force = false)
        delete_collection if force
        return if collection_exists? 
        
        schema = schema_definition.to_hash.merge(
          name: collection_name
        )

        client.collections.create(schema)
      end

      # Delete the collection from Typesense
      def delete_collection
        client.collections[collection_name].delete if collection_exists?
      end

      # Check if collection exists
      def collection_exists?
        client.collections[collection_name].retrieve
        true
      rescue Typesense::Error::ObjectNotFound
        false
      end

      # Update the collection schema in Typesense to match the model schema.
      #
      # Typesense only accepts a `fields` diff on update: a field can be added,
      # or dropped (`drop: true`), and a change is expressed as a drop followed
      # by a re-add. Re-sending an existing, unchanged field raises an error, so
      # we diff the desired schema against the live collection and send only the
      # additions, modifications, and removals. The implicit `id` field cannot
      # be altered and is always skipped.
      def update_collection
        return create_collection unless collection_exists?

        live_fields = (retrieve_collection&.dig('fields') || []).each_with_object({}) do |f, h|
          h[f['name'].to_s] = f
        end

        desired_fields = (schema_definition.to_hash[:fields] || []).reject do |f|
          (f[:name] || f['name']).to_s == 'id'
        end

        changes = []
        desired_names = []

        desired_fields.each do |field|
          name = (field[:name] || field['name']).to_s
          desired_names << name
          existing = live_fields[name]

          if existing.nil?
            changes << field
          elsif field_changed?(field, existing)
            changes << { 'name' => name, 'drop' => true }
            changes << field
          end
        end

        # Drop fields that exist in Typesense but are no longer in the schema.
        live_fields.each_key do |name|
          next if name == 'id' || name == '.*'
          changes << { 'name' => name, 'drop' => true } unless desired_names.include?(name)
        end

        return retrieve_collection if changes.empty?

        client.collections[collection_name].update(fields: changes)
      end

      # Create or update collection
      def create_or_update_collection
        collection_exists? ? update_collection : create_collection
      end

      # Retrieve collection details
      def retrieve_collection
        return nil unless collection_exists?
        client.collections[collection_name].retrieve
      end

      # Get collection stats
      def collection_stats
        return nil unless collection_exists?
        client.collections[collection_name].stats
      end

      # Get number of documents in collection
      def count
        collection_stats&.dig('num_documents') || 0
      end

      # Import multiple records
      # @return [Hash] { success: Integer, failed: Integer }
      def import(documents, options = {})
        sanitized_documents = Array(documents).map { |doc| sanitize_document(doc) }

        response = client.collections[collection_name]
          .documents
          .import(sanitized_documents, options)

        # Typesense returns one result hash per document. Guard against an
        # unexpected non-array shape (e.g. an error payload) so we never blow up
        # in the tally below.
        unless response.is_a?(Array)
          return { success: 0, failed: sanitized_documents.size,
                   errors: [{ code: nil, error: "Unexpected import response: #{response.inspect}", document: nil }] }
        end

        results = response.each_with_object({ success: 0, failed: 0, errors: [] }) do |result, counts|
          if result['success']
            counts[:success] += 1
          else
            counts[:failed] += 1
            counts[:errors] << {
              code: result['code'],
              error: result['error'],
              document: result['document']
            }
          end
        end

        results
      end

      # Import records from an ActiveRecord model
      # @param model_class [Class] The ActiveRecord model class to import from
      # @param batch_size [Integer] Number of records to fetch per batch
      # @param transform_method [Symbol, Proc] Method or Proc to transform records
      # @param preloads [Array, Symbol, Hash, nil] Associations to preload to avoid N+1
      # @param import_options [Hash] Options to pass to the import method
      # @return [Hash] { success: Integer, failed: Integer }
      def import_from_model(model_class, batch_size, transform_method = :as_json, preloads = nil, import_options = {})
        total_results = { success: 0, failed: 0, errors: [] }

        transformer = transform_method.is_a?(Proc) ? transform_method : ->(record) { record.send(transform_method) }

        relation = model_class.all
        relation = relation.preload(preloads) if preloads

        relation.find_in_batches(batch_size: batch_size) do |batch|
          documents = batch.map(&transformer)
          results = import(documents, import_options)

          total_results[:success] += results[:success]
          total_results[:failed] += results[:failed]
          total_results[:errors].concat(results[:errors]) if results[:errors].is_a?(Array)
        end

        total_results
      end

      # Delete a record by ID
      def delete(id)
        client.collections[collection_name]
          .documents[id]
          .delete
      rescue Typesense::Error::ObjectNotFound
        false
      end

      # Delete multiple records by query. Returns the Typesense response
      # (e.g. { "num_deleted" => N }); when the collection is missing, returns
      # { "num_deleted" => 0 } for symmetry with the singular #delete.
      def delete_by(filter_by)
        client.collections[collection_name]
          .documents
          .delete({ filter_by: filter_by })
      rescue Typesense::Error::ObjectNotFound
        { "num_deleted" => 0 }
      end

      # --- Synonyms -------------------------------------------------------
      # Thin wrappers over the Typesense synonyms API for this collection.
      def upsert_synonym(id, synonym)
        client.collections[collection_name].synonyms.upsert(id, synonym)
      end

      def synonyms
        client.collections[collection_name].synonyms.retrieve
      end

      def delete_synonym(id)
        client.collections[collection_name].synonyms[id].delete
      rescue Typesense::Error::ObjectNotFound
        false
      end

      # --- Overrides (curation) ------------------------------------------
      # Thin wrappers over the Typesense overrides API for this collection.
      def upsert_override(id, override)
        client.collections[collection_name].overrides.upsert(id, override)
      end

      def overrides
        client.collections[collection_name].overrides.retrieve
      end

      def delete_override(id)
        client.collections[collection_name].overrides[id].delete
      rescue Typesense::Error::ObjectNotFound
        false
      end

      private

      def client
        TypesenseModel.configuration.client
      end

      # Keep only fields defined in schema (plus 'id'), and coerce id to string
      def sanitize_document(document)
        return document unless schema_definition

        allowed = schema_definition.fields.map { |f| f[:name] } + ['id']
        sanitized = document.select { |k, _| allowed.include?(k.to_s) }
        sanitized['id'] = sanitized['id'].to_s if sanitized.key?('id')
        sanitized
      end

      # Field attributes that meaningfully affect the Typesense schema. Used to
      # decide whether a live field differs from the desired definition.
      FIELD_DIFF_ATTRS = %i[type facet optional index sort].freeze

      # Numeric/boolean types are sortable by default in Typesense; strings are not.
      DEFAULT_SORTABLE_TYPES = %w[int32 int64 float bool].freeze

      def field_changed?(desired, existing)
        FIELD_DIFF_ATTRS.any? do |attr|
          desired_field_value(desired, attr) != existing_field_value(existing, attr)
        end
      end

      def desired_field_value(field, attr)
        value = field.fetch(attr) { field[attr.to_s] }
        attr == :type ? value.to_s : value
      end

      # Resolve a live field's attribute, applying Typesense defaults when the
      # retrieved schema omits the key, so unchanged fields don't look modified.
      def existing_field_value(field, attr)
        type = field['type'].to_s
        return type if attr == :type
        return field[attr.to_s] if field.key?(attr.to_s)

        case attr
        when :facet, :optional then false
        when :index then true
        when :sort then DEFAULT_SORTABLE_TYPES.include?(type)
        end
      end
    end

    attr_accessor :attributes

    def initialize(attributes = {})
      @attributes = attributes.transform_keys(&:to_s)
    end

    def save
      response = self.class.send(:client).collections[self.class.collection_name].documents.upsert(attributes)
      
      @attributes = response.transform_keys(&:to_s)
      self
    end

    def id
      attributes['id']
    end

    # Delete the current record from Typesense. Returns true if a document was
    # removed, false if there was no id or nothing to delete.
    def delete
      return false unless id

      response = self.class.delete(id)
      !response.nil? && response != false
    end

    def method_missing(method_name, *args)
      attribute_name = method_name.to_s
      
      # Handle setters (e.g., name=)
      if attribute_name.end_with?('=')
        attribute_name = attribute_name.chop # Remove the '=' from the end
        return set_attribute(attribute_name, args.first)
      end
      
      # Handle getters (e.g., name)
      if attributes.key?(attribute_name)
        return attributes[attribute_name]
      end
      
      nil
    end

    def respond_to_missing?(method_name, include_private = false)
      attribute_name = method_name.to_s
      return true if attribute_name.end_with?('=') && attributes.key?(attribute_name.chop)
      return true if attributes.key?(attribute_name)
      super
    end

    private

    def set_attribute(name, value)
      attributes[name.to_s] = value
    end

    def client
      self.class.send(:client)
    end
  end
end 