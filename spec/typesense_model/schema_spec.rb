# frozen_string_literal: true

RSpec.describe TypesenseModel::Schema do
  subject(:schema) { described_class.new("products") }

  describe "#field" do
    it "stores a field with stringified name and type and default options" do
      schema.field(:title, :string)

      expect(schema.fields).to eq([
        { name: "title", type: "string", facet: false, optional: false, index: true, sort: false }
      ])
    end

    it "honors explicit options" do
      schema.field(:price, :float, facet: true, optional: true, index: false, sort: true)

      expect(schema.fields.first).to include(
        facet: true, optional: true, index: false, sort: true
      )
    end

    it "defaults index to true when not provided and respects an explicit false" do
      schema.field(:a, :string)
      schema.field(:b, :string, index: false)

      expect(schema.fields.map { |f| f[:index] }).to eq([true, false])
    end

    it "records the default sorting field when default_sort is set" do
      schema.field(:rank, :int32, default_sort: true)

      expect(schema.default_sorting_field).to eq("rank")
    end
  end

  describe "#to_hash" do
    it "builds a Typesense schema hash and omits nil keys" do
      schema.field(:title, :string)

      expect(schema.to_hash).to eq(
        name: "products",
        fields: [
          { name: "title", type: "string", facet: false, optional: false, index: true, sort: false }
        ]
      )
    end

    it "includes default_sorting_field when present" do
      schema.field(:rank, :int32, default_sort: true)

      expect(schema.to_hash[:default_sorting_field]).to eq("rank")
    end

    it "omits name when collection_name is nil" do
      bare = described_class.new
      bare.field(:title, :string)

      expect(bare.to_hash).not_to have_key(:name)
    end
  end
end
