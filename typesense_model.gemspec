require_relative 'lib/typesense_model/version'

Gem::Specification.new do |spec|
  spec.name          = "typesense_model"
  spec.version       = TypesenseModel::VERSION
  spec.authors       = ["Emanuel Comsa"]
  spec.email         = ["office@rubydev.ro"]

  spec.summary       = "ActiveModel-like interface for Typesense"
  spec.description   = "A Ruby gem that provides an ActiveModel-like interface for working with Typesense search engine"
  spec.homepage      = "https://github.com/iplaydit/typesense-rails"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["{lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  
  spec.add_dependency "typesense", "~> 2.1.0"
  spec.add_dependency "activesupport", ">= 5.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end 