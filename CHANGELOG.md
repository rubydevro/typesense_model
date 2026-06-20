# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- RSpec test suite covering schema, search, base (including the
  `update_collection` schema-diff logic) and the ActiveRecord extension.
- GitHub Actions CI: unit specs across Ruby 3.1–3.3 plus an integration job
  against a live Typesense service container.
- `Gemfile`, `Rakefile` and `.rspec` for a standard Bundler/RSpec dev workflow.
- Highlighting and match metadata on search results (`highlights`, `text_match`,
  `hits_with_meta`) and grouped results support (`grouped_hits`).
- `Base.multi_search` for issuing several searches in a single request.
- Configurable `TypesenseModel.logger` used by the sync callbacks.

### Changed
- `activesupport` requirement raised to `>= 6.0`; minimum Ruby raised to `3.1`.
- Sync/remove callbacks now log failures via `TypesenseModel.logger` even outside
  Rails (previously errors were silently swallowed in non-Rails contexts) and
  rescue `Typesense::Error` specifically instead of all exceptions.
- `Configuration#client` and `TypesenseProxy.for` memoization are now
  thread-safe.

### Fixed
- The gem now requires ActiveSupport string inflections, so standalone (non-Rails)
  usage of `collection_name` defaults no longer raises `NoMethodError`.
- The instance `#delete` method was defined under `private` and silently returned
  `nil` via `method_missing`; it is now public and returns a proper boolean.
- Gemspec `homepage`/`source_code_uri`/`changelog_uri` corrected to the real
  repository; added `rubygems_mfa_required` metadata.

## [0.2.0]

- ActiveRecord integration via `uses_typesense` with auto-sync callbacks.
- Standalone `TypesenseModel::Base` models.
- Schema definition, diff-based `update_collection`, bulk import and search with
  Pagy-compatible results.
