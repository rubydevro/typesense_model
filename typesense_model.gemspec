# frozen_string_literal: true

require_relative 'lib/typesense_model/version'

Gem::Specification.new do |spec|
  spec.name          = "typesense_model"
  spec.version       = TypesenseModel::VERSION
  spec.authors       = ["Emanuel Comsa"]
  spec.email         = ["office@rubydev.ro"]

  spec.summary       = "ActiveModel-like interface for Typesense"
  spec.description   = "A Ruby gem that provides an ActiveModel-like interface for working with Typesense search engine"
  spec.homepage      = "https://github.com/rubydevro/typesense_model"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 3.1.0")

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "CHANGELOG.md", "MIT-LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "typesense", "~> 2.1.0"
  spec.add_dependency "activesupport", ">= 6.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
