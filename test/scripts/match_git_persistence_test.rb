# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../scripts/match_git_persistence'

class MatchGitPersistenceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @remote = File.join(@root, 'remote.git')
    @checkout = File.join(@root, 'checkout')
    git('init', '--bare', '--initial-branch=master', @remote, directory: @root)
    git('clone', @remote, @checkout, directory: @root)
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.com')
    File.write(File.join(@checkout, 'profile'), 'original')
    File.write(File.join(@checkout, 'unrelated-profile'), 'original salt')
    git('add', 'profile', 'unrelated-profile')
    git('commit', '-m', 'Initial profile')
    git('push', 'origin', 'master')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_successful_push_is_accepted
    update_profile
    git('push', 'origin', 'master')
    MatchGitPersistence.verify!(@checkout, 'master', ['profile'])
  end

  def test_rejected_push_is_reported_even_if_fastlane_swallows_the_error
    hook = File.join(@remote, 'hooks', 'pre-receive')
    File.write(hook, "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, hook)
    update_profile
    _, result = Open3.capture2e('git', 'push', 'origin', 'master', chdir: @checkout)
    refute result.success?
    error = assert_raises(RuntimeError) { MatchGitPersistence.verify!(@checkout, 'master', ['profile']) }
    assert_match(/not persisted/, error.message)
  end

  def test_uncommitted_profile_is_rejected
    File.write(File.join(@checkout, 'profile'), 'uncommitted')
    assert_raises(RuntimeError) { MatchGitPersistence.verify!(@checkout, 'master', ['profile']) }
  end

  def test_reencrypted_unrelated_profiles_do_not_fail_successful_uploads
    File.write(File.join(@checkout, 'unrelated-profile'), 'different random salt')
    update_profile
    git('push', 'origin', 'master')
    MatchGitPersistence.verify!(@checkout, 'master', ['profile'])
  end

  def test_untracked_upload_and_uncommitted_index_are_rejected
    File.write(File.join(@checkout, 'new-profile'), 'new')
    assert_raises(RuntimeError) { MatchGitPersistence.verify!(@checkout, 'master', ['new-profile']) }
    git('add', 'new-profile')
    assert_raises(RuntimeError) { MatchGitPersistence.verify!(@checkout, 'master', ['profile']) }
  end

  private

  def update_profile
    File.write(File.join(@checkout, 'profile'), 'updated')
    git('add', 'profile')
    git('commit', '-m', 'Updated profile')
  end

  def git(*args, directory: @checkout)
    output, result = Open3.capture2e('git', *args, chdir: directory)
    raise output unless result.success?
  end
end
