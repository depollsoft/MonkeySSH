# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'resolve_next_app_store_patch_version'

class FakeAppStoreVersion
  attr_accessor :app_version_state, :version_string
  attr_reader :id

  def initialize(id:, version_string:, state:)
    @id = id
    @version_string = version_string
    @app_version_state = state
  end

  def update(attributes:)
    self.version_string = attributes.fetch(:version_string)
    self
  end
end

class FakeReviewSubmission
  attr_reader :app_store_version_for_review

  def initialize(version:, unlock_on_cancel: true)
    @app_store_version_for_review = version
    @unlock_on_cancel = unlock_on_cancel
    @canceled = false
  end

  def cancel_submission
    @canceled = true
    return unless @unlock_on_cancel

    app_store_version_for_review.app_version_state = 'READY_FOR_REVIEW'
  end

  def canceled?
    @canceled
  end
end

class FakeAppStoreApp
  attr_reader :id, :versions

  def initialize(versions:, submission: nil)
    @id = 'app-id'
    @versions = versions
    @submission = submission
  end

  def get_in_progress_review_submission(platform:, includes: nil)
    return if @submission&.canceled?

    @submission
  end

  def get_app_store_versions(filter:, includes:)
    versions
  end
end

class AppStorePatchVersionTest < Minitest::Test
  def test_increments_the_latest_used_patch
    assert_equal(
      '0.2.3',
      resolve(
        '0.2.0',
        [
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.2', 'REPLACED_WITH_NEW_VERSION')
        ]
      )
    )
  end

  def test_reuses_the_current_editable_patch
    assert_equal(
      '0.2.1',
      resolve(
        '0.2.0',
        [
          version('0.1.9', 'REJECTED'),
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.1', 'PREPARE_FOR_SUBMISSION')
        ]
      )
    )
  end

  def test_ignores_a_stale_editable_patch_below_a_used_patch
    %w[READY_FOR_DISTRIBUTION REPLACED_WITH_NEW_VERSION IN_REVIEW].each do |state|
      entries = [
        version('0.2.1', 'REJECTED'),
        version('0.2.3', state)
      ]
      [entries, entries.reverse].each do |versions|
        assert_equal('0.2.4', resolve('0.2.0', versions), state)
      end
    end
  end

  def test_stale_editable_patch_does_not_override_the_base_floor
    assert_equal(
      '0.2.5',
      resolve(
        '0.2.5',
        [version('0.2.1', 'REJECTED'), version('0.2.3', 'READY_FOR_DISTRIBUTION')]
      )
    )
  end

  def test_advances_past_the_current_patch_during_review
    assert_equal(
      '0.2.2',
      resolve(
        '0.2.0',
        [
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.1', 'IN_REVIEW')
        ]
      )
    )
  end

  def test_advances_past_the_current_patch_waiting_for_review
    assert_equal(
      '0.2.2',
      resolve(
        '0.2.0',
        [
          version('0.2.0', 'READY_FOR_DISTRIBUTION'),
          version('0.2.1', 'WAITING_FOR_REVIEW')
        ]
      )
    )
  end

  def test_uses_the_base_patch_as_a_floor
    assert_equal(
      '0.2.5',
      resolve(
        '0.2.5',
        [version('0.2.0', 'READY_FOR_DISTRIBUTION')]
      )
    )
  end

  def test_keeps_a_new_major_minor_version_line_at_its_base_patch
    assert_equal(
      '0.3.0',
      resolve(
        '0.3.0',
        [version('0.2.9', 'READY_FOR_DISTRIBUTION')]
      )
    )
  end

  def test_ignores_a_stale_editable_version_from_an_older_version_line
    assert_equal(
      '0.2.1',
      resolve(
        '0.2.0',
        [
          version('0.1.9', 'REJECTED'),
          version('0.2.0', 'READY_FOR_DISTRIBUTION')
        ]
      )
    )
  end

  def test_rejects_an_editable_version_from_a_newer_version_line
    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve(
        '0.2.0',
        [version('0.3.0', 'PREPARE_FOR_SUBMISSION')]
      )
    end

    assert_includes(error.message, 'does not match the requested 0.2.x')
  end

  def test_rejects_a_locked_version_from_a_newer_version_line
    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve(
        '0.2.0',
        [version('0.3.0', 'WAITING_FOR_REVIEW')]
      )
    end

    assert_includes(error.message, 'does not match the requested 0.2.x')
  end

  def test_rejects_a_non_numeric_base_version
    assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve('0.2', [])
    end
  end

  def test_uses_an_exact_requested_version
    assert_equal(
      '0.4.7',
      resolve(
        '0.2.0',
        [version('0.2.1', 'READY_FOR_DISTRIBUTION')],
        requested_version: '0.4.7'
      )
    )
  end

  def test_allows_an_exact_requested_version_that_is_under_review
    assert_equal(
      '0.2.1',
      resolve(
        '0.2.0',
        [version('0.2.1', 'WAITING_FOR_REVIEW')],
        requested_version: '0.2.1'
      )
    )
  end

  def test_rejects_an_exact_requested_version_that_was_released
    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve(
        '0.2.0',
        [version('0.2.1', 'READY_FOR_DISTRIBUTION')],
        requested_version: '0.2.1'
      )
    end

    assert_includes(error.message, 'has already been used')
  end

  def test_rejects_an_exact_requested_version_older_than_app_store
    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      resolve(
        '0.2.0',
        [version('0.3.0', 'READY_FOR_DISTRIBUTION')],
        requested_version: '0.2.9'
      )
    end

    assert_includes(error.message, 'older than App Store version 0.3.0')
  end

  def test_store_listing_is_editable_before_review_submission
    assert(AppStorePatchVersion.store_listing_editable?('PREPARE_FOR_SUBMISSION'))
    assert(AppStorePatchVersion.store_listing_editable?('READY_FOR_REVIEW'))
  end

  def test_store_listing_is_locked_after_review_submission
    refute(AppStorePatchVersion.store_listing_editable?('WAITING_FOR_REVIEW'))
    refute(AppStorePatchVersion.store_listing_editable?('IN_REVIEW'))
  end

  def test_prepare_cancels_review_and_advances_exact_version
    reviewed = fake_version('0.2.1', 'WAITING_FOR_REVIEW')
    submission = FakeReviewSubmission.new(version: reviewed)
    app = FakeAppStoreApp.new(
      versions: [reviewed],
      submission: submission
    )

    result = prepare(
      app: app,
      versions: [reviewed],
      resolved_version: '0.2.2'
    )

    assert_equal(:prepared, result)
    assert(submission.canceled?)
    assert_equal('0.2.2', reviewed.version_string)
    assert_equal('READY_FOR_REVIEW', reviewed.app_version_state)
  end

  def test_prepare_cancels_review_for_same_exact_version
    reviewed = fake_version('0.2.1', 'WAITING_FOR_REVIEW')
    submission = FakeReviewSubmission.new(version: reviewed)
    app = FakeAppStoreApp.new(
      versions: [reviewed],
      submission: submission
    )

    result = prepare(
      app: app,
      versions: [reviewed],
      resolved_version: '0.2.1'
    )

    assert_equal(:prepared, result)
    assert(submission.canceled?)
    assert_equal('0.2.1', reviewed.version_string)
    assert_equal('READY_FOR_REVIEW', reviewed.app_version_state)
    assert_equal([reviewed], app.versions)
  end

  def test_prepare_creates_version_when_no_editable_version_exists
    released = fake_version('0.2.0', 'READY_FOR_DISTRIBUTION')
    app = FakeAppStoreApp.new(versions: [released])
    created = nil

    result = prepare(
      app: app,
      versions: [released],
      resolved_version: '0.2.1',
      creator: lambda do |_app_id, version_string, _platform|
        created = fake_version(version_string, 'PREPARE_FOR_SUBMISSION')
        app.versions << created
      end
    )

    assert_equal(:prepared, result)
    assert_equal('0.2.1', created.version_string)
  end

  def test_prepare_updates_an_editable_version_for_exact_override
    editable = fake_version('0.2.1', 'PREPARE_FOR_SUBMISSION')
    app = FakeAppStoreApp.new(versions: [editable])

    result = prepare(
      app: app,
      versions: [editable],
      resolved_version: '0.4.0'
    )

    assert_equal(:prepared, result)
    assert_equal('0.4.0', editable.version_string)
  end

  def test_prepare_times_out_when_review_does_not_unlock
    reviewed = fake_version('0.2.1', 'WAITING_FOR_REVIEW')
    submission = FakeReviewSubmission.new(
      version: reviewed,
      unlock_on_cancel: false
    )
    app = FakeAppStoreApp.new(
      versions: [reviewed],
      submission: submission
    )
    ticks = [0, 2]

    error = assert_raises(AppStorePatchVersion::ResolutionError) do
      prepare(
        app: app,
        versions: [reviewed],
        resolved_version: '0.2.2',
        review_timeout: 1,
        clock: -> { ticks.shift || 2 }
      )
    end

    assert_includes(error.message, 'Timed out waiting for App Store review')
  end

  private

  def resolve(base_version, versions, requested_version: nil)
    AppStorePatchVersion.resolve(
      base_version: base_version,
      app_store_versions: versions,
      requested_version: requested_version
    )
  end

  def version(value, state)
    { version: value, state: state }
  end

  def fake_version(value, state)
    FakeAppStoreVersion.new(
      id: "version-#{value}",
      version_string: value,
      state: state
    )
  end

  def prepare(
    app:,
    versions:,
    resolved_version:,
    creator: nil,
    review_timeout: 10,
    clock: -> { 0 }
  )
    creator ||= lambda do |_app_id, version_string, _platform|
      app.versions << fake_version(version_string, 'PREPARE_FOR_SUBMISSION')
    end
    AppStorePatchVersion.prepare_version!(
      app: app,
      app_store_versions: versions,
      resolved_version: resolved_version,
      platform: 'IOS',
      version_loader: lambda do |version_id|
        app.versions.find { |item| item.id == version_id }
      end,
      version_creator: creator,
      review_cancellation_timeout_seconds: review_timeout,
      version_preparation_timeout_seconds: 10,
      clock: clock,
      sleeper: ->(_seconds) {},
      logger: ->(_message) {}
    )
  end
end
