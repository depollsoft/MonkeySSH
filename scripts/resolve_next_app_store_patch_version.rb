# frozen_string_literal: true

module AppStorePatchVersion
  class ResolutionError < StandardError; end

  STORE_LISTING_EDITABLE_STATES = %w[
    PREPARE_FOR_SUBMISSION
    READY_FOR_REVIEW
    DEVELOPER_REJECTED
    REJECTED
    METADATA_REJECTED
    INVALID_BINARY
  ].freeze

  READY_FOR_REVIEW_STATE = 'READY_FOR_REVIEW'

  REVIEW_LOCKED_STATES = %w[
    WAITING_FOR_REVIEW
    IN_REVIEW
  ].freeze

  REVIEW_CANCELLATION_TIMEOUT_SECONDS = 900
  VERSION_PREPARATION_TIMEOUT_SECONDS = 120
  POLL_INTERVAL_SECONDS = 10

  Version = Struct.new(:major, :minor, :patch) do
    def to_s
      "#{major}.#{minor}.#{patch}"
    end
  end

  module_function

  def resolve(base_version:, app_store_versions:, requested_version: nil)
    base = parse!(base_version, label: 'base version')
    parsed_versions = app_store_versions.each_with_object([]) do |entry, result|
      version = parse(entry.fetch(:version))
      next if version.nil?

      result << [version, entry.fetch(:state)]
    end

    requested = requested_version.to_s.strip
    unless requested.empty?
      return resolve_requested(
        requested_version: requested,
        parsed_versions: parsed_versions
      )
    end

    newer_version = parsed_versions.map(&:first).find do |version|
      version.major > base.major ||
        (version.major == base.major && version.minor > base.minor)
    end
    if newer_version
      raise ResolutionError,
            "App Store version #{newer_version} does not match " \
            "the requested #{base.major}.#{base.minor}.x version line"
    end

    editable_versions = parsed_versions.select do |_version, state|
      STORE_LISTING_EDITABLE_STATES.include?(state)
    end
    editable = editable_versions
               .map(&:first)
               .select { |version| same_version_line?(version, base) }
               .max_by(&:patch)
    existing_patches = parsed_versions
                       .map(&:first)
                       .select { |version| same_version_line?(version, base) }
                       .map(&:patch)
    return editable.to_s if editable && editable.patch >= base.patch && editable.patch == existing_patches.max

    next_patch = if existing_patches.empty?
                   base.patch
                 else
                   [base.patch, existing_patches.max + 1].max
                 end

    Version.new(base.major, base.minor, next_patch).to_s
  end

  def parse(value)
    match = /\A(\d+)\.(\d+)\.(\d+)\z/.match(value.to_s.strip)
    return if match.nil?

    Version.new(*match.captures.map(&:to_i))
  end

  def parse!(value, label:)
    parse(value) || raise(
      ResolutionError,
      "#{label.capitalize} must use numeric x.y.z format; received #{value.inspect}"
    )
  end

  def same_version_line?(left, right)
    left.major == right.major && left.minor == right.minor
  end

  def store_listing_editable?(state)
    STORE_LISTING_EDITABLE_STATES.include?(state)
  end

  def version_editable_for_delivery?(state)
    store_listing_editable?(state) && state != READY_FOR_REVIEW_STATE
  end

  def review_locked?(state)
    REVIEW_LOCKED_STATES.include?(state)
  end

  def resolve_requested(requested_version:, parsed_versions:)
    requested = parse!(requested_version, label: 'requested version')
    newer_version = parsed_versions
                    .map(&:first)
                    .find { |version| newer_than?(version, requested) }
    if newer_version
      raise ResolutionError,
            "Requested version #{requested} is older than App Store version " \
            "#{newer_version}"
    end

    existing = parsed_versions.find { |version, _state| version == requested }
    if existing
      state = existing.last
      unless store_listing_editable?(state) || review_locked?(state)
        raise ResolutionError,
              "Requested version #{requested} has already been used " \
              "and is in state #{state}"
      end
    end

    requested.to_s
  end

  def newer_than?(left, right)
    (
      [left.major, left.minor, left.patch] <=>
      [right.major, right.minor, right.patch]
    ).positive?
  end

  def prepare_version!(
    app:,
    app_store_versions:,
    resolved_version:,
    platform:,
    version_loader:,
    version_creator:,
    review_submission_items_loader: nil,
    review_submission_item_deleter: nil,
    review_cancellation_timeout_seconds: REVIEW_CANCELLATION_TIMEOUT_SECONDS,
    version_preparation_timeout_seconds: VERSION_PREPARATION_TIMEOUT_SECONDS,
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
    sleeper: ->(seconds) { sleep seconds },
    logger: ->(message) { puts message }
  )
    existing = app_store_versions.find do |version|
      version.version_string == resolved_version
    end
    if existing
      return :existing if version_editable_for_delivery?(existing.app_version_state)

      unless existing.app_version_state == READY_FOR_REVIEW_STATE ||
             review_locked?(existing.app_version_state)
        raise ResolutionError,
              "App Store version #{resolved_version} cannot be prepared from " \
              "state #{existing.app_version_state}"
      end
    end

    submission = app.get_in_progress_review_submission(
      platform: platform,
      includes: 'appStoreVersionForReview'
    )
    if existing && review_locked?(existing.app_version_state) && submission.nil?
      raise ResolutionError,
            "App Store version #{resolved_version} is review-locked but no " \
            'active review submission was found'
    end
    if existing && submission &&
       submission.app_store_version_for_review&.id != existing.id
      raise ResolutionError,
            'The active review submission belongs to a different App Store version'
    end

    version_to_advance = if submission
                           cancel_review!(
                             app: app,
                             submission: submission,
                             platform: platform,
                             version_loader: version_loader,
                             timeout_seconds: review_cancellation_timeout_seconds,
                             clock: clock,
                             sleeper: sleeper,
                             logger: logger
                           )
                         elsif existing
                           existing
                         else
                           latest_editable_version(
                             app_store_versions: app_store_versions
                           )
                         end

    if version_to_advance&.app_version_state == READY_FOR_REVIEW_STATE
      version_to_advance = detach_ready_review_submission!(
        app: app,
        version: version_to_advance,
        platform: platform,
        version_loader: version_loader,
        review_submission_items_loader: review_submission_items_loader,
        review_submission_item_deleter: review_submission_item_deleter,
        timeout_seconds: version_preparation_timeout_seconds,
        clock: clock,
        sleeper: sleeper,
        logger: logger
      )
    end

    if version_to_advance
      if version_to_advance.version_string != resolved_version
        version_to_advance.update(
          attributes: { version_string: resolved_version }
        )
      end
    else
      version_creator.call(app.id, resolved_version, platform)
    end

    wait_for_prepared_version!(
      app: app,
      resolved_version: resolved_version,
      platform: platform,
      timeout_seconds: version_preparation_timeout_seconds,
      clock: clock,
      sleeper: sleeper
    )
    logger.call("Prepared editable App Store version #{resolved_version}")
    :prepared
  end

  def detach_ready_review_submission!(
    app:,
    version:,
    platform:,
    version_loader:,
    review_submission_items_loader:,
    review_submission_item_deleter:,
    timeout_seconds:,
    clock:,
    sleeper:,
    logger:
  )
    if review_submission_items_loader.nil? || review_submission_item_deleter.nil?
      raise ResolutionError,
            'Review submission item callbacks are required to detach a ' \
            "#{READY_FOR_REVIEW_STATE} App Store version"
    end

    ready_submissions = if app.respond_to?(:get_review_submissions)
                          app.get_review_submissions(
                            filter: {
                              state: READY_FOR_REVIEW_STATE,
                              platform: platform
                            }
                          )
                        else
                          [app.get_ready_review_submission(platform: platform)].compact
                        end
    if ready_submissions.empty?
      raise ResolutionError,
            "App Store version #{version.version_string} is in " \
            "#{READY_FOR_REVIEW_STATE} but no #{READY_FOR_REVIEW_STATE} " \
            'review submission was found'
    end

    matching_items = ready_submissions.flat_map do |ready_submission|
      review_submission_items_loader.call(ready_submission.id).select do |item|
        item.app_store_version&.id == version.id
      end
    end
    if matching_items.empty?
      raise ResolutionError,
            "App Store version #{version.version_string} is in " \
            "#{READY_FOR_REVIEW_STATE} but was not attached to any " \
            "#{READY_FOR_REVIEW_STATE} review submission"
    end

    logger.call(
      "Removing App Store version #{version.version_string} from ready " \
      'review submission before editing screenshots and metadata'
    )
    matching_items.each do |item|
      review_submission_item_deleter.call(item.id)
    end

    deadline = clock.call + timeout_seconds
    loop do
      reloaded = version_loader.call(version.id)
      if reloaded.nil?
        raise ResolutionError,
              'App Store version disappeared while detaching ready review submission'
      end
      return reloaded if version_editable_for_delivery?(reloaded.app_version_state)

      if clock.call >= deadline
        raise ResolutionError,
              'Timed out waiting for App Store version ' \
              "#{version.version_string} to leave #{READY_FOR_REVIEW_STATE}; " \
              "version state is #{reloaded.app_version_state}"
      end

      sleeper.call(POLL_INTERVAL_SECONDS)
    end
  end

  def cancel_review!(
    app:,
    submission:,
    platform:,
    version_loader:,
    timeout_seconds:,
    clock:,
    sleeper:,
    logger:
  )
    version = submission.app_store_version_for_review
    if version.nil?
      raise ResolutionError,
            'Active App Store review did not include its app version'
    end

    logger.call(
      'Canceling the current App Store review before advancing the patch version'
    )
    submission.cancel_submission

    deadline = clock.call + timeout_seconds
    loop do
      active_submission = app.get_in_progress_review_submission(
        platform: platform
      )
      version = version_loader.call(version.id)
      if version.nil?
        raise ResolutionError,
              'App Store version disappeared during review cancellation'
      end
      unlocked = store_listing_editable?(version.app_version_state)
      break if active_submission.nil? && unlocked

      if clock.call >= deadline
        raise ResolutionError,
              'Timed out waiting for App Store review cancellation; ' \
              "version state is #{version.app_version_state}"
      end

      sleeper.call(POLL_INTERVAL_SECONDS)
    end
    logger.call('App Store review cancellation completed')
    version
  end

  def latest_editable_version(app_store_versions:)
    app_store_versions
      .select do |version|
        parsed = parse(version.version_string)
        parsed &&
          store_listing_editable?(version.app_version_state)
      end
      .max_by do |version|
        parsed = parse(version.version_string)
        [parsed.major, parsed.minor, parsed.patch]
      end
  end

  def wait_for_prepared_version!(
    app:,
    resolved_version:,
    platform:,
    timeout_seconds:,
    clock:,
    sleeper:
  )
    deadline = clock.call + timeout_seconds
    loop do
      prepared_version = app.get_app_store_versions(
        filter: { platform: platform },
        includes: nil
      ).find { |version| version.version_string == resolved_version }
      prepared = prepared_version &&
                 version_editable_for_delivery?(prepared_version.app_version_state)
      return if prepared

      if clock.call >= deadline
        raise ResolutionError,
              "Timed out preparing editable App Store version #{resolved_version}"
      end

      sleeper.call(POLL_INTERVAL_SECONDS)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require 'spaceship'

  base_version, bundle_id, output_path, requested_version, mode = ARGV
  mode = 'prepare' if mode.to_s.empty?
  if [base_version, bundle_id, output_path].any? { |value| value.to_s.empty? }
    warn 'Usage: resolve_next_app_store_patch_version.rb ' \
         'BASE_VERSION BUNDLE_ID OUTPUT_PATH [VERSION_OVERRIDE] ' \
         '[resolve|prepare]'
    exit 2
  end
  unless %w[resolve prepare].include?(mode)
    raise AppStorePatchVersion::ResolutionError,
          "Unsupported mode #{mode.inspect}; expected resolve or prepare"
  end

  token = Spaceship::ConnectAPI::Token.create(
    key_id: ENV.fetch('APP_STORE_CONNECT_API_KEY_ID'),
    issuer_id: ENV.fetch('APP_STORE_CONNECT_API_ISSUER_ID'),
    key: ENV.fetch('APP_STORE_CONNECT_API_KEY_CONTENT')
  )
  Spaceship::ConnectAPI.token = token

  app = Spaceship::ConnectAPI::App.find(bundle_id)
  raise AppStorePatchVersion::ResolutionError, "App #{bundle_id} was not found" if app.nil?

  platform = Spaceship::ConnectAPI::Platform::IOS
  app_store_versions = app.get_app_store_versions(
    filter: { platform: platform },
    includes: nil
  )
  versions = app_store_versions.map do |version|
    {
      version: version.version_string,
      state: version.app_version_state
    }
  end

  resolved_version = AppStorePatchVersion.resolve(
    base_version: base_version,
    app_store_versions: versions,
    requested_version: requested_version
  )
  if mode == 'prepare'
    AppStorePatchVersion.prepare_version!(
      app: app,
      app_store_versions: app_store_versions,
      resolved_version: resolved_version,
      platform: platform,
      version_loader: lambda do |version_id|
        Spaceship::ConnectAPI::AppStoreVersion.get(
          app_store_version_id: version_id,
          includes: nil
        )
      end,
      version_creator: lambda do |app_id, version_string, version_platform|
        Spaceship::ConnectAPI.post_app_store_version(
          app_id: app_id,
          attributes: {
            versionString: version_string,
            platform: version_platform
          }
        )
      end,
      review_submission_items_loader: lambda do |review_submission_id|
        Spaceship::ConnectAPI::ReviewSubmissionItem.all(
          review_submission_id: review_submission_id,
          includes: 'appStoreVersion'
        )
      end,
      review_submission_item_deleter: lambda do |review_submission_item_id|
        Spaceship::ConnectAPI.tunes_request_client.delete(
          "v1/reviewSubmissionItems/#{review_submission_item_id}"
        )
      end
    )
  end

  File.write(output_path, "#{resolved_version}\n")
  puts "#{mode.capitalize}d App Store release marketing version #{resolved_version}"
end
