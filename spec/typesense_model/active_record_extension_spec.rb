# frozen_string_literal: true

# A minimal stand-in for an ActiveRecord model: it provides the class macros
# (`after_save`/`after_destroy`) that `uses_typesense` relies on, without pulling
# in a real database. This keeps the extension's own logic under test in isolation.
def build_ar_class(class_name, collection:, async: false, &schema)
  klass = Class.new do
    attr_accessor :id

    def self.after_save(*); end
    def self.after_destroy(*); end

    include TypesenseModel::ActiveRecordExtension
  end
  klass.define_singleton_method(:name) { class_name }
  klass.uses_typesense(collection: collection, model_json: :as_json_typesense, async: async, &schema)
  klass
end

RSpec.describe TypesenseModel::ActiveRecordExtension do
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

  describe "uses_typesense wiring" do
    it "registers after_save and after_destroy callbacks" do
      klass = Class.new do
        def self.after_save(*); end
        def self.after_destroy(*); end
        include TypesenseModel::ActiveRecordExtension
      end
      klass.define_singleton_method(:name) { "Widget" }

      expect(klass).to receive(:after_save).with(:sync_to_typesense)
      expect(klass).to receive(:after_destroy).with(:remove_from_typesense)
      klass.uses_typesense(collection: "widgets")
    end

    it "exposes collection name, schema and json method" do
      klass = build_ar_class("Product", collection: "products") do
        field :id, :string
        field :title, :string
      end

      expect(klass.typesense_collection_name).to eq("products")
      expect(klass.typesense_model_json_method).to eq(:as_json_typesense)
      expect(klass.typesense_schema).to be_a(TypesenseModel::Schema)
    end
  end

  describe "TypesenseProxy.for" do
    it "memoizes one proxy per AR class" do
      klass = build_ar_class("Product", collection: "products")
      proxy_a = TypesenseModel::ActiveRecordExtension::TypesenseProxy.for(klass)
      proxy_b = TypesenseModel::ActiveRecordExtension::TypesenseProxy.for(klass)

      expect(proxy_a).to be(proxy_b)
    end

    it "isolates collection name and schema per model" do
      products = build_ar_class("Product", collection: "products") do
        field :id, :string
        field :title, :string
      end
      users = build_ar_class("User", collection: "users") do
        field :id, :string
        field :email, :string
      end

      product_proxy = TypesenseModel::ActiveRecordExtension::TypesenseProxy.for(products)
      user_proxy = TypesenseModel::ActiveRecordExtension::TypesenseProxy.for(users)

      expect(product_proxy.collection_name).to eq("products")
      expect(user_proxy.collection_name).to eq("users")
      expect(product_proxy.schema_definition.fields.map { |f| f[:name] }).to eq(%w[id title])
      expect(user_proxy.schema_definition.fields.map { |f| f[:name] }).to eq(%w[id email])
    end
  end

  describe "#sync_to_typesense" do
    let(:klass) do
      build_ar_class("Product", collection: "products") do
        field :id, :string
        field :title, :string
      end
    end

    it "upserts the sanitized document" do
      record = klass.new
      record.id = 5
      def_singleton(record, :as_json_typesense, { "id" => 5, "title" => "Shoe", "ignored" => "x" })

      expect(documents).to receive(:upsert).with({ "id" => "5", "title" => "Shoe" })
      record.sync_to_typesense
    end

    it "logs via TypesenseModel.logger instead of raising when Typesense errors" do
      record = klass.new
      record.id = 5
      def_singleton(record, :as_json_typesense, { "id" => 5, "title" => "Shoe" })
      allow(documents).to receive(:upsert).and_raise(Typesense::Error.new("boom"))

      logger = instance_double(Logger)
      TypesenseModel.logger = logger
      expect(logger).to receive(:error).with(/Failed to sync/)

      expect { record.sync_to_typesense }.not_to raise_error
    ensure
      TypesenseModel.logger = nil
    end
  end

  describe "#remove_from_typesense" do
    let(:klass) { build_ar_class("Product", collection: "products") }

    it "deletes the document by id" do
      record = klass.new
      record.id = 9
      doc = double("document")
      allow(documents).to receive(:[]).with(9).and_return(doc)
      expect(doc).to receive(:delete)

      record.remove_from_typesense
    end
  end

  describe "async sync" do
    let(:klass) do
      build_ar_class("AsyncProduct", collection: "async_products", async: true) do
        field :id, :string
        field :title, :string
      end
    end

    it "marks the model as async" do
      expect(klass.typesense_async?).to be(true)
    end

    it "enqueues instead of upserting inline on save" do
      record = klass.new
      record.id = 7
      expect(TypesenseModel::ActiveRecordExtension)
        .to receive(:enqueue_sync).with("AsyncProduct", "7", :upsert)
      expect(documents).not_to receive(:upsert)

      record.sync_to_typesense
    end

    it "enqueues a remove on destroy" do
      record = klass.new
      record.id = 7
      expect(TypesenseModel::ActiveRecordExtension)
        .to receive(:enqueue_sync).with("AsyncProduct", "7", :remove)

      record.remove_from_typesense
    end

    it "enqueues a SyncJob via perform_later when ActiveJob is available" do
      expect(TypesenseModel::SyncJob).to receive(:perform_later).with("AsyncProduct", "7", "upsert")
      TypesenseModel::ActiveRecordExtension.enqueue_sync("AsyncProduct", "7", :upsert)
    end
  end

  # Defines a stub method returning `value` on a single instance.
  def def_singleton(obj, method, value)
    obj.define_singleton_method(method) { value }
  end
end
