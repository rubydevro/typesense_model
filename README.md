# TypesenseModel

A Ruby gem that provides seamless Typesense integration for ActiveRecord models with automatic syncing and search capabilities.

## Installation

Add to your Gemfile:
```ruby
gem 'typesense_model'
```

Or install directly:
```bash
$ gem install typesense_model
```

## Configuration

Initialize Typesense connection in your Rails application:

```ruby
# config/initializers/typesense.rb
TypesenseModel.configure do |config|
  config.api_key = 'your_api_key'
  config.host = 'localhost'
  config.port = 8108
  config.protocol = 'http'
end
```

## ActiveRecord Integration

The gem automatically extends ActiveRecord models with Typesense capabilities. Simply add `uses_typesense` to any model:

```ruby
class Product < ApplicationRecord
  uses_typesense collection: 'products' do
    field :id, :string
    field :name, :string
    field :description, :string, optional: true, index: false
    field :price, :float, sort: true
    field :categories, "string[]", optional: true, facet: true
    field :tags, "string[]", optional: true, facet: true
    field :brand, :string, facet: true
    field :in_stock, :bool, facet: true
    field :created_at, :int64, sort: true
    field :updated_at, :int64, sort: true
  end

  # Optional: Custom JSON serialization for Typesense
  def as_json_typesense
    {
      id: id,
      name: name,
      description: description,
      price: price,
      categories: categories,
      tags: tags,
      brand: brand,
      in_stock: in_stock,
      created_at: created_at.to_i,
      updated_at: updated_at.to_i
    }
  end
end
```

## Features

### Automatic Syncing
When you save or destroy ActiveRecord records, they automatically sync to Typesense:

```ruby
# Create a product - automatically synced to Typesense
product = Product.create!(
  name: "iPhone 15",
  price: 999.99,
  categories: ["Electronics", "Phones"],
  brand: "Apple",
  in_stock: true
)

# Update a product - automatically synced to Typesense
product.update!(price: 899.99)

# Destroy a product - automatically removed from Typesense
product.destroy!
```

### Search Capabilities
Search your ActiveRecord models using Typesense:

```ruby
# Basic search
results = Product.search("iPhone")

# Advanced search with filters and sorting
results = Product.search("smartphone", 
  filter_by: "brand:Apple && price:< 1000",
  sort_by: "price:asc",
  per_page: 20,
  page: 1
)

# Search with facets
results = Product.search("phone")
results.facet_values("brand")  # Get brand facet counts
results.facet_values("categories")  # Get category facet counts
```

### Access Typesense Documents
Get the Typesense document for any ActiveRecord instance:

```ruby
product = Product.find(123)
typesense_doc = product.typesense_model
# Returns a TypesenseModel::Base instance with the Typesense document data
```

## Schema Options

Field options available in the schema definition:

- `optional: true` - Field is optional
- `index: false` - Field is not indexed (not searchable)
- `facet: true` - Field can be used for faceted search
- `sort: true` - Field can be used for sorting
- `default_sort: true` - Field is the default sorting field

## Custom JSON Serialization

You can customize how your model data is serialized for Typesense:

```ruby
class Product < ApplicationRecord
  uses_typesense collection: 'products', model_json: :to_typesense_hash do
    # schema definition
  end

  def to_typesense_hash
    {
      id: id,
      name: name,
      price: price,
      # Add computed fields
      searchable_text: "#{name} #{description} #{brand}".downcase,
      price_range: case price
        when 0..100 then "budget"
        when 101..500 then "mid-range"
        else "premium"
      end
    }
  end
end
```

Or use a Proc for dynamic serialization:

```ruby
class Product < ApplicationRecord
  uses_typesense collection: 'products', 
    model_json: ->(record) { record.as_json.merge(computed_field: record.compute_something) } do
    # schema definition
  end
end
```

## Collection Management

Create and manage Typesense collections:

```ruby
# Create the collection in Typesense
Product.search("") # This will create the collection if it doesn't exist

# Or explicitly create/update
proxy = TypesenseModel::ActiveRecordExtension::TypesenseProxy.for(Product)
proxy.create_collection
proxy.update_collection
proxy.delete_collection
```

## Import Existing Data

Import existing ActiveRecord records to Typesense without N+1 queries:

```ruby
# Basic import (default batch_size: 1000)
results = Product.import_all_to_typesense

# With preloads to avoid N+1
results = Product.import_all_to_typesense(preloads: [:brand, :images])

# With custom transformer and options
results = Product.import_all_to_typesense(
  preloads: { variants: [:prices, :stock_items] },
  transform: :to_typesense_hash,
  batch_size: 2000,
  import_options: { action: 'upsert' }
)

# results => { success: 500, failed: 0, errors: [...] }
```

## Advanced search

### Highlights, scores and grouped results

`search` returns a `SearchResults` that, beyond enumerating records, exposes the
search metadata Typesense returns:

```ruby
results = Product.search("running shoe")

# Each record paired with its highlights and relevance score
results.hits_with_meta.each do |hit|
  hit[:record]      # => Product-like document
  hit[:highlights]  # => [{ "field" => "title", ... }]
  hit[:text_match]  # => relevance score
end

# When searching with group_by:
grouped = Product.search("shoe", group_by: "brand")
grouped.grouped_hits.each do |group|
  group[:group_key] # => ["Nike"]
  group[:hits]      # => [records...]
end
```

Geo and vector search parameters are passed straight through as options, e.g.
`Product.search("*", filter_by: "location:(48.8,2.3,5 km)")`.

### Multi-search

Issue several queries in a single request:

```ruby
results = Product.multi_search([
  { q: "shoe" },
  { q: "boot", filter_by: "price:>100" }
])
results.first.total_hits
```

### Synonyms and overrides (curation)

```ruby
Product.upsert_synonym("coat-synonyms", synonyms: %w[coat jacket parka])
Product.upsert_override("promote-nike", rule: { query: "shoe", match: "exact" },
                                        includes: [{ id: "1", position: 1 }])
```

## Async syncing

Pass `async: true` to perform the Typesense write in an ActiveJob instead of
inline in the `after_save`/`after_destroy` callbacks:

```ruby
class Product < ApplicationRecord
  uses_typesense collection: "products", async: true do |s|
    s.field :id, :string
    s.field :title, :string
  end
end
```

Requires ActiveJob; the job (`TypesenseModel::SyncJob`) reloads the record and
syncs it on whatever queue adapter your app is configured with.

## Configuration

Failures in the background sync callbacks are logged rather than raised. By
default they go to `Rails.logger` (or `$stderr` outside Rails); override with:

```ruby
TypesenseModel.logger = MyLogger.new
```

## Development

After checking out the repo, install dependencies and run the test suite:

```bash
bundle install
bundle exec rake          # runs the unit specs (Typesense client is mocked)
```

Integration specs talk to a real Typesense server and are skipped by default.
To run them, start a local Typesense instance and set `TYPESENSE_INTEGRATION`:

```bash
TYPESENSE_INTEGRATION=1 TYPESENSE_API_KEY=test-key bundle exec rspec --tag integration
```

To build the gem locally:

```bash
gem build typesense_model.gemspec
```

## License

Available as open source under the MIT License.
Copyright (c) 2025 Ruby Dev SRL