# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../scripts/preview_release_notes'

class PreviewReleaseNotesTest < Minitest::Test
  ENV_KEYS = %w[
    FLUTTY_PR_NUMBER
    FLUTTY_PR_TITLE
    FLUTTY_BRANCH_NAME
    FLUTTY_BUILD_NAME
    FLUTTY_VERSION_CODENAME
    FLUTTY_SOURCE_SHA
    FLUTTY_LAST_COMMIT
    FLUTTY_PR_COMMITS
    GITHUB_REPOSITORY
    GITHUB_SERVER_URL
  ].freeze

  def setup
    @original_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def teardown
    ENV_KEYS.each do |key|
      value = @original_env[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def test_includes_pr_identity_branch_and_explicit_last_commit
    ENV['FLUTTY_PR_NUMBER'] = '794'
    ENV['FLUTTY_PR_TITLE'] = 'Distribute builds through Firebase'
    ENV['FLUTTY_BRANCH_NAME'] = 'main'
    ENV['FLUTTY_LAST_COMMIT'] = 'abc1234 fix: include release context'

    notes = PreviewReleaseNotes.current

    assert_equal 'Main build: PR #794: Distribute builds through Firebase', notes.lines.first.strip
    assert_includes notes, 'Branch: main'
    assert_includes notes, 'Last commit: abc1234 fix: include release context'
  end

  def test_uses_newest_pr_commit_when_explicit_commit_is_missing
    ENV['FLUTTY_PR_NUMBER'] = '794'
    ENV['FLUTTY_PR_TITLE'] = 'Distribute builds through Firebase'
    ENV['FLUTTY_BRANCH_NAME'] = 'feature/firebase'
    ENV['FLUTTY_PR_COMMITS'] = <<~COMMITS
      def5678 fix: newest change
      abc1234 feat: earlier change
    COMMITS

    notes = PreviewReleaseNotes.current

    assert_includes notes, 'Last commit: def5678 fix: newest change'
    assert_equal 'PR #794: Distribute builds through Firebase', notes.lines.first.strip
    assert_includes notes, 'Branch: feature/firebase'
    refute_includes notes, 'Main build:'
  end

  def test_supports_direct_branch_push_without_a_pr
    ENV['FLUTTY_BRANCH_NAME'] = 'main'
    ENV['FLUTTY_LAST_COMMIT'] = 'abc1234 chore: direct push'

    notes = PreviewReleaseNotes.current

    assert_equal "Branch: main\nLast commit: abc1234 chore: direct push", notes
  end

  def test_keeps_required_metadata_within_upload_limit
    ENV['FLUTTY_PR_NUMBER'] = '794'
    ENV['FLUTTY_PR_TITLE'] = 'T' * 400
    ENV['FLUTTY_LAST_COMMIT'] = "abc1234 #{'C' * 400}"

    notes = PreviewReleaseNotes.current(max_length: 500)

    assert_operator notes.length, :<=, 500
    assert_match(/^PR #794: /, notes)
    assert_match(/\nLast commit: abc1234 /, notes)
  end

  def test_main_origin_and_pr_survive_long_titles_and_commit_messages
    ENV['FLUTTY_PR_NUMBER'] = '794'
    ENV['FLUTTY_PR_TITLE'] = 'T' * 400
    ENV['FLUTTY_BRANCH_NAME'] = 'main'
    ENV['FLUTTY_LAST_COMMIT'] = "abc1234 #{'C' * 400}"

    notes = PreviewReleaseNotes.current(max_length: 500)

    assert_operator notes.length, :<=, 500
    assert_match(/^Main build: PR #794: /, notes)
    assert_match(/\nLast commit: abc1234 /, notes)
  end
end
