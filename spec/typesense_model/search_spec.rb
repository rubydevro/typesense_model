# frozen_string_literal: true

RSpec.describe TypesenseModel::Search do
  let(:model_class) do
    Class.new(TypesenseModel::Base) do
      collection_name "products"
      define_schema do
        field :id, :string
        field :title, :string
        field :brand, :string
        field :price, :float
        field :secret, :string, index: false
      end
    end
  end

  let(:client) { instance_double("Typesense::Client") }
  let(:collections) { double("collections") }
  let(:collection) { double("collection") }
  let(:documents) { double("documents") }

  before do
    stub_typesense_client(client)
    allow(client).to receive(:collections).and_return(collections)
    allow(collections).to receive(:[]).with("products").and_return(collection)
    allow(collection).to receive(:documents).and_return(documents)
  end

  describe "#execute" do
    it "builds default search parameters and queries only indexed string fields (excluding id)" do
      expect(documents).to receive(:search).with(
        hash_including(q: "shoes", query_by: "title,brand", per_page: 10, page: 1)
      ).and_return("hits" => [], "found" => 0)

      described_class.new(model_class, "shoes").execute
    end

    it "honors caller-provided query_by, per_page and page and passes through extra options" do
      expect(documents).to receive(:search).with(
        hash_including(q: "shoes", query_by: "title", per_page: 25, page: 2, filter_by: "price:>10")
      ).and_return("hits" => [], "found" => 0)

      described_class.new(model_class, "shoes",
        query_by: "title", per_page: 25, page: 2, filter_by: "price:>10").execute
    end

    it "returns a SearchResults wrapping the response" do
      allow(documents).to receive(:search).and_return("hits" => [], "found" => 0)

      result = described_class.new(model_class, "shoes").execute
      expect(result).to be_a(TypesenseModel::SearchResults)
    end
  end
end

RSpec.describe TypesenseModel::SearchResults do
  let(:model_class) { Class.new(TypesenseModel::Base) { collection_name "products" } }

  let(:response) do
    {
      "found" => 2,
      "hits" => [
        { "document" => { "id" => "1", "title" => "A" }, "highlights" => [{ "field" => "title" }], "text_match" => 99 },
        { "document" => { "id" => "2", "title" => "B" } }
      ],
      "facet_counts" => [
        { "field_name" => "brand", "counts" => [{ "value" => "Nike", "count" => 3 }] }
      ]
    }
  end

  subject(:results) { described_class.new(response, model_class) }

  it "exposes hits and total_hits" do
    expect(results.hits.size).to eq(2)
    expect(results.total_hits).to eq(2)
    expect(results.size).to eq(2)
  end

  it "iterates yielding model instances built from documents" do
    titles = results.map(&:title)
    expect(titles).to eq(%w[A B])
    expect(results.first).to be_a(model_class)
  end

  it "is Enumerable" do
    expect(results.to_a.size).to eq(2)
  end

  describe "#hits_with_meta" do
    it "pairs each record with its highlights and relevance score" do
      meta = results.hits_with_meta
      expect(meta.first[:record]).to be_a(model_class)
      expect(meta.first[:record].title).to eq("A")
      expect(meta.first[:highlights]).to eq([{ "field" => "title" }])
      expect(meta.first[:text_match]).to eq(99)
      expect(meta.last[:highlights]).to eq([])
      expect(meta.last[:text_match]).to be_nil
    end
  end

  describe "#grouped_hits" do
    subject(:results) { described_class.new(grouped_response, model_class) }

    let(:grouped_response) do
      {
        "found" => 3,
        "grouped_hits" => [
          { "group_key" => ["Nike"], "hits" => [{ "document" => { "id" => "1", "title" => "A" } }] },
          { "group_key" => ["Adidas"], "hits" => [{ "document" => { "id" => "2", "title" => "B" } }] }
        ]
      }
    end

    it "returns groups with their records" do
      groups = results.grouped_hits
      expect(groups.map { |g| g[:group_key] }).to eq([["Nike"], ["Adidas"]])
      expect(groups.first[:hits].first).to be_a(model_class)
      expect(groups.first[:hits].first.title).to eq("A")
    end

    it "returns an empty array when the response is not grouped" do
      expect(described_class.new({}, model_class).grouped_hits).to eq([])
    end
  end

  describe "facets" do
    it "returns facet counts and a specific facet" do
      expect(results.facet("brand")["field_name"]).to eq("brand")
      expect(results.facet_values("brand")).to eq([{ "value" => "Nike", "count" => 3 }])
    end

    it "returns empty facet_values for an unknown field" do
      expect(results.facet_values("missing")).to eq([])
    end
  end

  describe "pagy compatibility" do
    it "responds to count/offset/limit with arbitrary args" do
      expect(results.count).to eq(2)
      expect(results.count(1, 2)).to eq(2)
      expect(results.offset(10)).to eq(results)
      expect(results.limit(10)).to eq(results)
    end
  end

  context "with an empty response" do
    subject(:results) { described_class.new({}, model_class) }

    it "returns sane defaults" do
      expect(results.hits).to eq([])
      expect(results.total_hits).to eq(0)
      expect(results.facets).to eq([])
    end
  end
end
