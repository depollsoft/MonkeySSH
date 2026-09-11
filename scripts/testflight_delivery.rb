# frozen_string_literal: true

require 'json'

module TestflightDelivery
  module_function

  def metadata(app_identifier:, version:, build_number:, changelog:, localized_build_info:)
    raise 'Invalid TestFlight version' unless version.to_s.match?(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/)
    raise 'Invalid TestFlight build number' unless build_number.to_s.match?(/\A[1-9]\d{0,9}\z/)

    {app_identifier: app_identifier, app_version: version, build_number: build_number.to_s,
     changelog: changelog, localized_build_info: localized_build_info}
  end

  def read(path, app_identifier:, version:, build_number:)
    data = JSON.parse(File.read(path), symbolize_names: true)
    expected = [app_identifier, version, build_number.to_s]
    actual = data.values_at(:app_identifier, :app_version, :build_number)
    raise 'TestFlight follow-up does not match the requested app and build' unless actual == expected

    data
  end

  # Leaving both note fields out is necessary for pilot to return immediately
  # after upload. The Linux follow-up restores them for the exact processed build.
  def upload_options
    {skip_waiting_for_build_processing: true, skip_submission: true,
     distribute_external: false, changelog: nil, localized_build_info: nil}
  end
end
