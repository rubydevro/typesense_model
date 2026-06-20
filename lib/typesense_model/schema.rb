# frozen_string_literal: true

module TypesenseModel
  class Schema
    attr_reader :fields, :collection_name, :default_sorting_field

    def initialize(collection_name = nil)
      @fields = []
      @collection_name = collection_name
      @default_sorting_field = nil
    end

    def field(name, type, options = {})
      @fields << {
        name: name.to_s,
        type: type.to_s,
        facet: options[:facet] || false,
        optional: options[:optional] || false,
        index: options[:index].nil? ? true : options[:index],
        sort: options[:sort] || false
      }

      # Set as default sorting field if specified
      @default_sorting_field = name.to_s if options[:default_sort]
    end

    def to_hash
      {
        name: @collection_name,
        fields: @fields,
        default_sorting_field: @default_sorting_field
      }.compact
    end
  end
end 