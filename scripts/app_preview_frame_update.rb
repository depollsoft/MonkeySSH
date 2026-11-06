# frozen_string_literal: true

# Fastlane 2.241.1 uploads an App Preview, polls until it has a video URL, and
# then always sets its poster frame, even with no time code. App Store Connect
# can publish the URL before the asset reaches COMPLETE and then rejects the
# update ("Asset Not in Complete state! can't update Image!"), which fails the
# whole release (v0.12.0's iPhone preview, 2026-11-06; the iPad one in the same
# run got through). Skip an update that only clears the poster frame, and retry
# a real one while the asset finishes processing.
module AppPreviewFrameUpdate
  NOT_COMPLETE = 'Asset Not in Complete state'
  ATTEMPTS = 10
  RETRY_DELAY = 15

  def self.install!(preview_class, error_class, sleeper: ->(seconds) { sleep(seconds) })
    preview_class.prepend(override(error_class, sleeper))
  end

  def self.override(error_class, sleeper)
    Module.new do
      define_method(:update) do |client: nil, attributes: nil|
        attributes = (attributes || {}).dup
        if attributes.key?(:previewFrameTimeCode) && attributes[:previewFrameTimeCode].nil?
          attributes.delete(:previewFrameTimeCode)
          return self if attributes.empty?
        end
        attempt = 1
        begin
          super(client: client, attributes: attributes)
        rescue error_class => e
          raise unless e.message.include?(NOT_COMPLETE) && attempt < ATTEMPTS

          attempt += 1
          sleeper.call(RETRY_DELAY)
          retry
        end
      end
    end
  end
end
