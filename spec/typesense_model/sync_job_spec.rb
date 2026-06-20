# frozen_string_literal: true

# ActiveJob and TypesenseModel::SyncJob are loaded in spec_helper.

# A named, constantize-able stand-in for an AR model with async syncing enabled.
class SyncJobProduct
  def self.after_save(*); end
  def self.after_destroy(*); end

  include TypesenseModel::ActiveRecordExtension

  uses_typesense collection: "sync_job_products", async: true do |s|
    s.field :id, :string
    s.field :title, :string
  end

  STORE = {}

  def self.find_by(id:)
    STORE[id.to_s]
  end

  attr_accessor :id, :title

  def initialize(id:, title:)
    @id = id
    @title = title
  end

  def as_json_typesense
    { "id" => id, "title" => title }
  end
end

RSpec.describe TypesenseModel::SyncJob do
  let(:client) { instance_double("Typesense::Client") }
  let(:collections) { double("collections") }
  let(:collection) { double("collection") }
  let(:documents) { double("documents") }

  before do
    stub_typesense_client(client)
    allow(client).to receive(:collections).and_return(collections)
    allow(collections).to receive(:[]).and_return(collection)
    allow(collection).to receive(:documents).and_return(documents)
    SyncJobProduct::STORE.clear
  end

  it "is wired up by the ActiveJob load hook" do
    expect(defined?(TypesenseModel::SyncJob)).to be_truthy
    expect(TypesenseModel::SyncJob.ancestors).to include(ActiveJob::Base)
  end

  describe "#perform upsert" do
    it "reloads the record and upserts its sanitized document" do
      SyncJobProduct::STORE["1"] = SyncJobProduct.new(id: "1", title: "Shoe")

      expect(documents).to receive(:upsert).with({ "id" => "1", "title" => "Shoe" })

      described_class.new.perform("SyncJobProduct", "1", "upsert")
    end

    it "does nothing when the record no longer exists" do
      expect(documents).not_to receive(:upsert)
      described_class.new.perform("SyncJobProduct", "404", "upsert")
    end
  end

  describe "#perform remove" do
    it "deletes the document by id via the proxy" do
      doc = double("document")
      allow(documents).to receive(:[]).with("9").and_return(doc)
      expect(doc).to receive(:delete)

      described_class.new.perform("SyncJobProduct", "9", "remove")
    end
  end

  describe "error handling" do
    # The remove path surfaces Typesense errors up to the job (Base#delete only
    # rescues ObjectNotFound), so the job's own rescue/logging engages here.
    it "logs Typesense errors from the job instead of raising" do
      doc = double("document")
      allow(documents).to receive(:[]).with("9").and_return(doc)
      allow(doc).to receive(:delete).and_raise(Typesense::Error.new("boom"))

      logger = instance_double(Logger)
      TypesenseModel.logger = logger
      expect(logger).to receive(:error).with(/Async Typesense remove failed/)

      expect { described_class.new.perform("SyncJobProduct", "9", "remove") }.not_to raise_error
    ensure
      TypesenseModel.logger = nil
    end
  end
end
