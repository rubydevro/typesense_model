# frozen_string_literal: true

# End-to-end specs that talk to a real Typesense server. They only run when
# TYPESENSE_INTEGRATION is set (see .github/workflows/ci.yml); otherwise skipped.
RSpec.describe "Typesense integration", :integration,
               if: ENV["TYPESENSE_INTEGRATION"] do
  # These specs intentionally hit a live server, so disable the unit-test
  # configuration reset and point at the real instance.
  before do
    TypesenseModel.configure do |c|
      c.api_key = ENV.fetch("TYPESENSE_API_KEY", "test-key")
      c.host = ENV.fetch("TYPESENSE_HOST", "localhost")
      c.port = Integer(ENV.fetch("TYPESENSE_PORT", "8108"))
      c.protocol = ENV.fetch("TYPESENSE_PROTOCOL", "http")
    end
  end

  let(:model_class) do
    Class.new(TypesenseModel::Base) do
      collection_name "integration_products"
      define_schema do
        field :id, :string
        field :title, :string
        field :brand, :string, facet: true
        field :price, :float, sort: true
      end
    end
  end

  after { model_class.delete_collection }

  it "creates, imports, searches, updates the schema and deletes" do
    model_class.create_collection(true)
    expect(model_class.collection_exists?).to be(true)

    result = model_class.import([
      { "id" => "1", "title" => "Running Shoe", "brand" => "Nike", "price" => 99.0 },
      { "id" => "2", "title" => "Hiking Boot", "brand" => "Salomon", "price" => 149.0 }
    ])
    expect(result[:success]).to eq(2)
    expect(model_class.count).to eq(2)

    found = model_class.search("shoe", query_by: "title")
    expect(found.total_hits).to eq(1)
    expect(found.first.title).to eq("Running Shoe")

    # update_collection should add a new field without recreating the collection.
    model_class.define_schema do
      field :id, :string
      field :title, :string
      field :brand, :string, facet: true
      field :price, :float, sort: true
      field :color, :string, optional: true
    end
    model_class.update_collection
    field_names = model_class.retrieve_collection["fields"].map { |f| f["name"] }
    expect(field_names).to include("color")

    model_class.delete("1")
    expect(model_class.count).to eq(1)
  end
end
