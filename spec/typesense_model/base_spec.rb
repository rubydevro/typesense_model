# frozen_string_literal: true

RSpec.describe TypesenseModel::Base do
  let(:model_class) do
    Class.new(described_class) do
      collection_name "products"
      define_schema do
        field :id, :string
        field :title, :string
        field :price, :float, sort: true
        field :brand, :string, facet: true
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
    allow(collections).to receive(:[]).and_return(collection)
    allow(collection).to receive(:documents).and_return(documents)
  end

  describe "collection naming" do
    it "defaults to the underscored, pluralized class name" do
      klass = Class.new(described_class) do
        def self.name = "BlogPost"
      end
      expect(klass.collection_name).to eq("blog_posts")
    end
  end

  describe "attribute access" do
    subject(:record) { model_class.new("id" => "1", "title" => "Shoe") }

    it "reads attributes via method_missing" do
      expect(record.title).to eq("Shoe")
      expect(record.id).to eq("1")
    end

    it "writes attributes via method_missing" do
      record.title = "Boot"
      expect(record.title).to eq("Boot")
    end

    it "returns nil for unknown attributes" do
      expect(record.nope).to be_nil
    end

    it "responds_to known attributes" do
      expect(record).to respond_to(:title)
      expect(record).to respond_to(:title=)
    end

    it "stringifies keys on initialize" do
      expect(model_class.new(title: "X").attributes).to eq("title" => "X")
    end
  end

  describe ".find" do
    it "returns a model instance when found" do
      allow(collection).to receive(:documents).and_return(documents)
      doc = double("document")
      allow(documents).to receive(:[]).with("1").and_return(doc)
      allow(doc).to receive(:retrieve).and_return("id" => "1", "title" => "Shoe")

      record = model_class.find("1")
      expect(record).to be_a(model_class)
      expect(record.title).to eq("Shoe")
    end

    it "returns nil when not found" do
      doc = double("document")
      allow(documents).to receive(:[]).with("404").and_return(doc)
      allow(doc).to receive(:retrieve).and_raise(Typesense::Error::ObjectNotFound.new("not found"))

      expect(model_class.find("404")).to be_nil
    end
  end

  describe "#sanitize_document (via .import)" do
    it "keeps only schema fields plus id and coerces id to string" do
      expect(documents).to receive(:import).with(
        [{ "id" => "7", "title" => "Shoe" }], {}
      ).and_return([{ "success" => true }])

      model_class.import([{ "id" => 7, "title" => "Shoe", "ignored" => "x" }])
    end
  end

  describe ".import" do
    it "tallies successes and failures with error details" do
      allow(documents).to receive(:import).and_return([
        { "success" => true },
        { "success" => false, "code" => 400, "error" => "bad", "document" => "{}" }
      ])

      result = model_class.import([{ "id" => 1 }, { "id" => 2 }])
      expect(result[:success]).to eq(1)
      expect(result[:failed]).to eq(1)
      expect(result[:errors].first).to include(code: 400, error: "bad")
    end

    it "guards against a non-array response shape" do
      allow(documents).to receive(:import).and_return("unexpected error string")

      result = model_class.import([{ "id" => 1 }, { "id" => 2 }])
      expect(result[:success]).to eq(0)
      expect(result[:failed]).to eq(2)
      expect(result[:errors].first[:error]).to match(/Unexpected import response/)
    end
  end

  describe ".delete_by" do
    it "returns the typesense response" do
      allow(documents).to receive(:delete).with({ filter_by: "price:>100" }).and_return("num_deleted" => 3)
      expect(model_class.delete_by("price:>100")).to eq("num_deleted" => 3)
    end

    it "returns zero deletions when the collection is missing" do
      allow(documents).to receive(:delete).and_raise(Typesense::Error::ObjectNotFound.new("missing"))
      expect(model_class.delete_by("price:>100")).to eq("num_deleted" => 0)
    end
  end

  describe ".update_collection diffing" do
    def stub_live_fields(fields)
      allow(model_class).to receive(:collection_exists?).and_return(true)
      allow(model_class).to receive(:retrieve_collection).and_return("fields" => fields)
    end

    it "creates the collection when it does not exist" do
      allow(model_class).to receive(:collection_exists?).and_return(false)
      expect(model_class).to receive(:create_collection)
      model_class.update_collection
    end

    it "sends no update when the live schema already matches" do
      stub_live_fields([
        { "name" => "title", "type" => "string" },
        { "name" => "price", "type" => "float", "sort" => true },
        { "name" => "brand", "type" => "string", "facet" => true }
      ])

      expect(collection).not_to receive(:update)
      model_class.update_collection
    end

    it "adds a field that is missing in the live collection" do
      stub_live_fields([
        { "name" => "title", "type" => "string" },
        { "name" => "price", "type" => "float", "sort" => true }
      ])

      expect(collection).to receive(:update) do |arg|
        expect(arg[:fields]).to include(hash_including(name: "brand"))
      end
      model_class.update_collection
    end

    it "drops a field that no longer exists in the schema" do
      stub_live_fields([
        { "name" => "title", "type" => "string" },
        { "name" => "price", "type" => "float", "sort" => true },
        { "name" => "brand", "type" => "string", "facet" => true },
        { "name" => "legacy", "type" => "string" }
      ])

      expect(collection).to receive(:update).with(
        fields: [{ "name" => "legacy", "drop" => true }]
      )
      model_class.update_collection
    end

    it "expresses a changed field as drop-then-readd" do
      stub_live_fields([
        { "name" => "title", "type" => "string" },
        { "name" => "price", "type" => "int32" }, # type changed (float vs int32) and sort differs
        { "name" => "brand", "type" => "string", "facet" => true }
      ])

      expect(collection).to receive(:update) do |arg|
        names = arg[:fields]
        expect(names).to include({ "name" => "price", "drop" => true })
        expect(names).to include(hash_including(name: "price", type: "float"))
      end
      model_class.update_collection
    end

    it "never drops or re-adds the implicit id field" do
      stub_live_fields([
        { "name" => "id", "type" => "string" },
        { "name" => "title", "type" => "string" },
        { "name" => "price", "type" => "float", "sort" => true },
        { "name" => "brand", "type" => "string", "facet" => true }
      ])

      expect(collection).not_to receive(:update)
      model_class.update_collection
    end
  end

  describe ".default_query_by" do
    it "lists indexed string fields excluding id" do
      expect(model_class.default_query_by).to eq("title,brand")
    end
  end

  describe ".multi_search" do
    it "builds per-search payloads with defaults and wraps each result" do
      ms = double("multi_search")
      allow(client).to receive(:multi_search).and_return(ms)

      expect(ms).to receive(:perform) do |body, _common|
        expect(body[:searches]).to eq([
          { collection: "products", q: "shoe", query_by: "title,brand" },
          { collection: "products", q: "*", query_by: "title", filter_by: "price:>10" }
        ])
        { "results" => [{ "found" => 1, "hits" => [] }, { "found" => 0, "hits" => [] }] }
      end

      results = model_class.multi_search([
        { q: "shoe" },
        { query_by: "title", filter_by: "price:>10" }
      ])

      expect(results.size).to eq(2)
      expect(results.first).to be_a(TypesenseModel::SearchResults)
      expect(results.first.total_hits).to eq(1)
    end
  end

  describe "synonyms" do
    let(:synonyms_api) { double("synonyms") }

    before { allow(collection).to receive(:synonyms).and_return(synonyms_api) }

    it "upserts a synonym" do
      expect(synonyms_api).to receive(:upsert).with("coat", { "synonyms" => %w[coat jacket] })
      model_class.upsert_synonym("coat", { "synonyms" => %w[coat jacket] })
    end

    it "retrieves synonyms" do
      allow(synonyms_api).to receive(:retrieve).and_return("synonyms" => [])
      expect(model_class.synonyms).to eq("synonyms" => [])
    end

    it "deletes a synonym and returns false when missing" do
      item = double("synonym")
      allow(synonyms_api).to receive(:[]).with("missing").and_return(item)
      allow(item).to receive(:delete).and_raise(Typesense::Error::ObjectNotFound.new("nope"))
      expect(model_class.delete_synonym("missing")).to be(false)
    end
  end

  describe "overrides" do
    let(:overrides_api) { double("overrides") }

    before { allow(collection).to receive(:overrides).and_return(overrides_api) }

    it "upserts an override" do
      rule = { "rule" => { "query" => "shoe", "match" => "exact" } }
      expect(overrides_api).to receive(:upsert).with("promote", rule)
      model_class.upsert_override("promote", rule)
    end
  end

  describe "#save" do
    it "upserts attributes and refreshes from the response" do
      record = model_class.new("id" => "1", "title" => "Shoe")
      expect(documents).to receive(:upsert).with({ "id" => "1", "title" => "Shoe" })
        .and_return({ "id" => "1", "title" => "Shoe" })

      expect(record.save).to eq(record)
    end
  end

  describe "#delete (instance)" do
    it "returns false without an id" do
      expect(model_class.new.delete).to be(false)
    end

    it "delegates to the class delete" do
      record = model_class.new("id" => "9")
      doc = double("document")
      allow(documents).to receive(:[]).with("9").and_return(doc)
      allow(doc).to receive(:delete).and_return("id" => "9")

      expect(record.delete).to be(true)
    end
  end
end
