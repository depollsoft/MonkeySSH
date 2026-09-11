# frozen_string_literal: true

require_relative 'resolve_next_app_store_patch_version'

module StoreMetadata
  module_function

  # Read only. A metadata sync must not wait for, create, or cancel a release.
  def editable_version!(app, requested_version: '')
    raise 'App Store application was not found' unless app

    version = app.get_edit_app_store_version(platform: 'IOS')
    unless version && AppStorePatchVersion.store_listing_editable?(version.app_version_state)
      raise 'No editable iOS version. Prepare an editable version in App Store Connect before syncing metadata.'
    end
    unless requested_version.to_s.empty? || version.version_string == requested_version
      raise "Editable iOS version #{version.version_string} does not match requested #{requested_version}."
    end
    version.version_string
  end

  def include_media?(options)
    options[:skip_media].to_s != 'true'
  end
end
