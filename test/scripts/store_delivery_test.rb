# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../scripts/store_metadata'
require_relative '../../scripts/testflight_delivery'

class StoreDeliveryTest < Minitest::Test
  Version = Struct.new(:version_string, :app_version_state)
  App = Struct.new(:version) do
    def get_edit_app_store_version(platform:)
      raise 'wrong platform' unless platform == 'IOS'

      version
    end
  end

  def test_editable_version_is_selected_without_mutating_the_store
    assert_equal '1.2.3', StoreMetadata.editable_version!(App.new(Version.new('1.2.3', 'PREPARE_FOR_SUBMISSION')))
  end

  def test_missing_or_locked_version_fails_immediately
    [nil, App.new(nil), App.new(Version.new('1.2.3', 'WAITING_FOR_REVIEW')),
     App.new(Version.new('1.2.3', 'READY_FOR_DISTRIBUTION'))].each do |app|
      assert_raises(RuntimeError) { StoreMetadata.editable_version!(app) }
    end
  end

  def test_requested_version_must_match
    app = App.new(Version.new('1.2.3', 'PREPARE_FOR_SUBMISSION'))
    assert_equal '1.2.3', StoreMetadata.editable_version!(app, requested_version: '1.2.3')
    assert_raises(RuntimeError) { StoreMetadata.editable_version!(app, requested_version: '1.2.4') }
  end

  def test_copy_only_sync_preserves_existing_media
    assert StoreMetadata.include_media?({})
    assert StoreMetadata.include_media?(skip_media: false)
    refute StoreMetadata.include_media?(skip_media: true)
    refute StoreMetadata.include_media?(skip_media: 'true')
  end

  def test_followup_round_trip_preserves_notes_and_checks_exact_build_identity
    data = TestflightDelivery.metadata(app_identifier: 'app.private', version: '1.2.3',
                                      build_number: 123, changelog: 'Changes',
                                      localized_build_info: {'en-US': {whats_new: 'New stuff'}})
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'metadata.json')
      File.write(path, JSON.generate(data))
      expected = {app_identifier: 'app.private', version: '1.2.3', build_number: '123'}
      assert_equal data, TestflightDelivery.read(path, **expected)
      [{app_identifier: 'app.production'}, {version: '1.2.4'}, {build_number: '124'}].each do |change|
        assert_raises(RuntimeError) { TestflightDelivery.read(path, **expected.merge(change)) }
      end
    end
  end

  def test_upload_never_waits_for_notes_or_submits_for_review
    options = TestflightDelivery.upload_options
    assert options[:skip_waiting_for_build_processing]
    assert options[:skip_submission]
    refute options[:distribute_external]
    assert_nil options[:changelog]
    assert_nil options[:localized_build_info]
  end

  def test_invalid_version_metadata_is_rejected
    [{version: ''}, {version: 'garbage'}, {build_number: '0'}, {build_number: '../123'}].each do |invalid|
      assert_raises(RuntimeError) do
        TestflightDelivery.metadata(**{app_identifier: 'app.private', version: '1.2.3',
                                      build_number: '123', changelog: '', localized_build_info: {}}.merge(invalid))
      end
    end
  end
end

# Evaluate the real Fastfile with only its external actions replaced. This
# checks the lane handoff and match options without credentials or Xcode.
class FastfileHarness
  attr_reader :lanes, :calls

  def initialize
    @lanes = {}
    @calls = []
    file = File.expand_path('../../ios/fastlane/Fastfile', __dir__)
    instance_eval(File.read(file), file)
    @lanes[:get_api_key] = proc { {} }
    @lanes[:check_match_persistence] = proc {}
    @lanes[:testflight_release_notes] = proc { ['Changes', {'en-US': {whats_new: 'Changes'}}] }
    @lanes[:resolved_ipa_path] = proc { |options| options.fetch(:ipa_path) }
    @lanes[:sync_metadata] = proc { |options| @calls << [:sync_metadata, options] }
  end

  def default_platform(*) = nil
  def desc(*) = nil
  def before_all(*) = nil
  def platform(*) = yield
  def lane(name, &block) = @lanes[name] = block
  alias private_lane lane

  def method_missing(name, *args)
    return instance_exec(*args, &@lanes.fetch(name)) if @lanes.key?(name)
    return @calls << [name, args.first] if %i[pilot match].include?(name)

    super
  end

  def respond_to_missing?(name, *) = @lanes.key?(name) || super
end

class FastfileDeliveryTest < Minitest::Test
  def setup
    @harness = FastfileHarness.new
    @env = ENV.to_h
  end

  def teardown
    ENV.replace(@env)
  end

  def test_ci_beta_upload_passes_notes_to_followup_instead_of_waiting_on_mac
    Dir.mktmpdir do |dir|
      ENV['FLUTTY_TESTFLIGHT_METADATA_PATH'] = File.join(dir, 'followup.json')
      ENV['FLUTTY_BUILD_NAME'] = '1.2.3'
      ENV['BUILD_NUMBER'] = '123'
      @harness.beta(scheme: 'Private', ipa_path: '/tmp/test.ipa', skip_metadata: true)
      data = JSON.parse(File.read(ENV.fetch('FLUTTY_TESTFLIGHT_METADATA_PATH')))
      assert_equal 'xyz.depollsoft.monkeyssh.private', data['app_identifier']
      assert_equal 'Changes', data['changelog']
      assert_equal 'Changes', data.dig('localized_build_info', 'en-US', 'whats_new')
      pilot = @harness.calls.assoc(:pilot).last
      assert pilot[:skip_waiting_for_build_processing]
      assert_nil pilot[:changelog]
      assert_nil pilot[:localized_build_info]
      refute @harness.calls.assoc(:sync_metadata)
    end
  end

  def test_ci_beta_preserves_explicit_metadata_sync
    Dir.mktmpdir do |dir|
      ENV['FLUTTY_TESTFLIGHT_METADATA_PATH'] = File.join(dir, 'followup.json')
      ENV['FLUTTY_BUILD_NAME'] = '1.2.3'
      ENV['BUILD_NUMBER'] = '123'
      @harness.beta(scheme: 'Private', ipa_path: '/tmp/test.ipa', skip_metadata: false)
      assert_equal '1.2.3', @harness.calls.assoc(:sync_metadata).last[:app_version]
    end
  end

  def test_local_beta_still_waits_and_sets_notes
    ENV.delete('FLUTTY_TESTFLIGHT_METADATA_PATH')
    @harness.beta(scheme: 'Private', ipa_path: '/tmp/test.ipa', skip_metadata: true)
    pilot = @harness.calls.assoc(:pilot).last
    refute pilot[:skip_waiting_for_build_processing]
    assert_equal 'Changes', pilot[:changelog]
  end

  def test_readonly_adhoc_signing_never_requests_profile_regeneration
    @harness.sync_certs(app_identifier: ['app', 'app.extension'], type: 'adhoc', readonly: true)
    options = @harness.calls.assoc(:match).last
    assert options[:readonly]
    refute options[:force_for_new_devices]
  end

  def test_trusted_adhoc_writer_can_refresh_devices
    @harness.sync_certs(app_identifier: ['app', 'app.extension'], type: 'adhoc', readonly: false)
    assert @harness.calls.assoc(:match).last[:force_for_new_devices]
  end

  def test_only_writable_signing_receives_the_repository_write_credential
    ENV['MATCH_GIT_WRITE_BASIC_AUTHORIZATION'] = 'test-write-authorization'
    @harness.sync_certs(app_identifier: ['app'], type: 'adhoc', readonly: false)
    options = @harness.calls.assoc(:match).last
    assert_equal 'test-write-authorization', options[:git_basic_authorization]

    @harness.calls.clear
    @harness.sync_certs(app_identifier: ['app'], type: 'adhoc', readonly: true)
    options = @harness.calls.assoc(:match).last
    refute options.key?(:git_basic_authorization)
  end

  def test_followup_waits_for_and_updates_only_the_requested_build
    with_followup do |path|
      processed = Struct.new(:app_version, :version).new('1.2.3', '123')
      watcher = lambda do |**options|
        assert_equal 'app-id', options[:app_id]
        assert_equal '1.2.3', options[:app_version]
        assert_equal '123', options[:build_version]
        assert_equal 1200, options[:timeout_duration]
        refute options[:select_latest]
        refute options[:return_spaceship_testflight_build]
        assert options[:wait_for_build_beta_detail_processing]
        processed
      end
      with_stub(FastlaneCore::BuildWatcher, :wait_for_build_processing_to_be_complete, watcher) do
        @harness.finish_testflight(scheme: 'Private', metadata_path: path)
      end
      pilot = @harness.calls.assoc(:pilot).last
      assert pilot[:distribute_only]
      assert_equal 'ios', pilot[:app_platform]
      refute pilot[:distribute_external]
      assert_equal '123', pilot[:build_number]
      assert_equal 'Changes', pilot[:changelog]
    end
  end

  def test_followup_accepts_apples_normalized_marketing_version
    with_followup(version: '1.2.0') do |path|
      processed = Struct.new(:app_version, :version).new('1.2', '123')
      with_stub(FastlaneCore::BuildWatcher, :wait_for_build_processing_to_be_complete, processed) do
        @harness.finish_testflight(scheme: 'Private', metadata_path: path)
      end
      pilot = @harness.calls.assoc(:pilot).last
      assert_equal '1.2', pilot[:app_version]
      assert_equal '123', pilot[:build_number]
    end
  end

  def test_followup_rejects_a_different_processed_build
    with_followup do |path|
      processed = Struct.new(:app_version, :version).new('1.2.3', '124')
      with_stub(FastlaneCore::BuildWatcher, :wait_for_build_processing_to_be_complete, processed) do
        assert_raises(RuntimeError) { @harness.finish_testflight(scheme: 'Private', metadata_path: path) }
      end
      refute @harness.calls.assoc(:pilot)
    end
  end

  private

  def with_stub(object, name, value)
    original = object.method(name)
    replacement = value.is_a?(Proc) ? value : proc { |*| value }
    object.define_singleton_method(name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def with_followup(version: '1.2.3')
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'metadata.json')
      ENV['FLUTTY_BUILD_NAME'] = version
      ENV['BUILD_NUMBER'] = '123'
      File.write(path, JSON.generate(TestflightDelivery.metadata(
        app_identifier: 'xyz.depollsoft.monkeyssh.private', version: version,
        build_number: '123', changelog: 'Changes', localized_build_info: {},
      )))
      with_stub(Spaceship::ConnectAPI::App, :find, Struct.new(:id).new('app-id')) { yield path }
    end
  end
end

# External API boundaries only. Lane code above is loaded from the Fastfile.
module Spaceship
  module ConnectAPI
    class App
      def self.find(*) = raise('App Store API must be stubbed')
    end
  end
end

module FastlaneCore
  class BuildWatcher
    def self.wait_for_build_processing_to_be_complete(**) = raise('Build polling must be stubbed')
  end
end
$LOADED_FEATURES << 'fastlane_core/build_watcher.rb'

module UI
  def self.user_error!(message) = raise(message)
end
