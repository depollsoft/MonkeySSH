# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../scripts/app_preview_frame_update'

class AppPreviewFrameUpdateTest < Minitest::Test
  class UnexpectedResponse < StandardError; end

  def preview_class(failures)
    Class.new do
      attr_reader :calls

      define_method(:initialize) do
        @calls = []
        @failures = failures.dup
      end

      def update(client: nil, attributes: nil)
        @calls << attributes
        failure = @failures.shift
        raise failure if failure

        :updated
      end
    end
  end

  def install(failures)
    klass = preview_class(failures)
    sleeps = []
    AppPreviewFrameUpdate.install!(klass, UnexpectedResponse, sleeper: ->(seconds) { sleeps << seconds })
    [klass.new, sleeps]
  end

  def not_complete
    UnexpectedResponse.new("The request cannot be fulfilled because of the state of another resource. - Asset Not in Complete state! can't update Image!")
  end

  def test_skips_an_update_that_only_clears_the_poster_frame
    preview, sleeps = install([])
    assert_same preview, preview.update(attributes: {previewFrameTimeCode: nil})
    assert_empty preview.calls
    assert_empty sleeps
  end

  def test_retries_a_frame_update_until_the_asset_is_complete
    preview, sleeps = install([not_complete, not_complete])
    assert_equal :updated, preview.update(attributes: {previewFrameTimeCode: '00:00:05:00'})
    assert_equal 3, preview.calls.size
    assert_equal [AppPreviewFrameUpdate::RETRY_DELAY] * 2, sleeps
  end

  def test_gives_up_after_the_attempt_limit
    preview, sleeps = install([not_complete] * AppPreviewFrameUpdate::ATTEMPTS)
    assert_raises(UnexpectedResponse) { preview.update(attributes: {previewFrameTimeCode: '00:00:05:00'}) }
    assert_equal AppPreviewFrameUpdate::ATTEMPTS, preview.calls.size
    assert_equal AppPreviewFrameUpdate::ATTEMPTS - 1, sleeps.size
  end

  def test_other_errors_and_other_attributes_pass_through
    preview, sleeps = install([UnexpectedResponse.new('Some other failure')])
    assert_raises(UnexpectedResponse) { preview.update(attributes: {previewFrameTimeCode: '00:00:05:00'}) }
    assert_empty sleeps
    preview, = install([])
    assert_equal :updated, preview.update(attributes: {previewFrameTimeCode: nil, uploaded: true})
    assert_equal [{uploaded: true}], preview.calls
  end
end
