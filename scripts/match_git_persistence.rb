# frozen_string_literal: true

require 'open3'

# Fastlane 2.238.0 logs and swallows Git push failures. Check the local
# tracking ref after its push so an unpersisted profile cannot report success.
module MatchGitPersistence
  def self.verify!(directory, branch, files)
    # Encryption changes the salt of unrelated files too. Only the requested
    # upload paths must match HEAD; the remaining worktree may be modified.
    _, tracked = Open3.capture2e('git', 'ls-files', '--error-unmatch', '--', *files, chdir: directory)
    _, unchanged = Open3.capture2e('git', 'diff', '--quiet', 'HEAD', '--', *files, chdir: directory)
    _, index_clean = Open3.capture2e('git', 'diff', '--cached', '--quiet', chdir: directory)
    ahead, ahead_result = Open3.capture2('git', 'rev-list', '--count',
                                       "refs/remotes/origin/#{branch}..HEAD", chdir: directory)
    return if tracked.success? && unchanged.success? && index_clean.success? &&
              ahead_result.success? && ahead.strip == '0'

    raise 'Signing profiles were not persisted to the match repository. Check its write credentials and rerun profile regeneration.'
  end

  def upload_files(files_to_upload: [], custom_message: nil)
    super
    MatchGitPersistence.verify!(working_directory, branch, files_to_upload)
  end
end
