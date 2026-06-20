# frozen_string_literal: true

# Loaded only when ActiveJob is available (see typesense_model.rb). Performs the
# Typesense sync/remove off the request cycle when a model opts into
# `uses_typesense(async: true)`.
module TypesenseModel
  class SyncJob < ActiveJob::Base
    def perform(class_name, id, action)
      klass = class_name.constantize

      case action.to_s
      when "remove"
        proxy = ActiveRecordExtension::TypesenseProxy.for(klass)
        proxy.delete(id)
      else
        record = klass.respond_to?(:find_by) ? klass.find_by(id: id) : nil
        record&.sync_to_typesense_now
      end
    rescue Typesense::Error => e
      TypesenseModel.logger.error("Async Typesense #{action} failed for #{class_name}##{id}: #{e.message}")
    end
  end
end
