#!/usr/bin/env python3
"""Classify a complete Git diff without requiring Flutter or full history."""

import os
from pathlib import Path
import subprocess


PLATFORMS = ('android', 'ios', 'macos', 'windows', 'linux')
OUTPUTS = ('run_check', 'go', 'tooling', *PLATFORMS)
PAYLOAD_SCRIPTS = {
    'scripts/build_monkeymux_assets.sh',
    'scripts/ensure_monkeymux_assets.sh',
    'scripts/deterministic_gzip.go',
    'scripts/verify_monkeymux_assets.py',
}

# These Dart paths exercise Windows filesystem behavior that Linux test shards
# cannot cover, even though they are outside the native windows/ directory.
WINDOWS_TEST_INPUTS = {
    'lib/domain/services/monkeymux_installer_service.dart',
    'lib/domain/services/monkeymux_windows_cleanup.dart',
    'lib/domain/services/windows_remote_powershell.dart',
    'test/domain/services/monkeymux_installer_service_test.dart',
    'test/domain/services/monkeymux_windows_cleanup_test.dart',
}

# Keep the non-required preview/deployment workflow triggers aligned with these
# inputs. The regression test checks all three YAML lists against this one.
MOBILE_PATHS = [
    'lib/**',
    'pubspec.yaml',
    'pubspec.lock',
    'assets/**',
    'remote/monkeymux/**',
    '!remote/monkeymux/**/*_test.go',
    'remote/monkeymux/conpty/**',
    '!remote/monkeymux/README.md',
    'third_party/**',
    'android/**',
    '!android/fastlane/metadata-*/**',
    'ios/**',
    '!ios/fastlane/metadata-*/**',
    *sorted(PAYLOAD_SCRIPTS),
    'scripts/cache_sqlite3_native_assets.sh',
    'scripts/version_codename.py',
    'scripts/preview_release_notes.rb',
    'scripts/preview_build_number.py',
    'scripts/store_metadata.rb',
    'scripts/match_git_persistence.rb',
    'scripts/testflight_delivery.rb',
    'Gemfile',
    'Gemfile.lock',
    '.github/workflows/build-deploy.yml',
    '.github/workflows/deploy-private.yml',
    '.github/workflows/firebase-distribution.yml',
    '.github/workflows/preview.yml',
    '.github/workflows/preview-ios.yml',
    '.github/actions/apple-cache-restore/**',
    '.github/actions/apple-cache-save/**',
]


def classify(paths):
    result = dict.fromkeys(OUTPUTS, False)
    for path in paths:
        daemon = path.startswith('remote/monkeymux/') and path != 'remote/monkeymux/README.md'
        # conpty/ files are packaged regardless of their extension. Unknown
        # daemon inputs remain conservative; only ordinary tests are excluded.
        payload = (
            daemon and (not path.endswith('_test.go')
                        or path.startswith('remote/monkeymux/conpty/'))
        ) or path in PAYLOAD_SCRIPTS
        workflow = path.startswith(('.github/workflows/', '.github/actions/'))
        tooling = (
            workflow
            or path.startswith(('scripts/', 'test/scripts/', '.github/'))
            or path in {'Gemfile', 'Gemfile.lock'}
            or '/fastlane/' in path
        )
        result['tooling'] |= tooling
        result['windows'] |= path in WINDOWS_TEST_INPUTS
        result['go'] |= daemon or payload or path == '.github/workflows/ci.yml'

        # Changes to the CI builder itself must exercise all its build jobs.
        # Other workflow/tooling edits use the independent tooling job.
        global_build = (
            payload
            or path.startswith('.github/actions/apple-cache-')
            or path.startswith(('assets/', 'third_party/'))
            or path in {
                'pubspec.yaml', 'pubspec.lock',
                '.github/workflows/ci.yml',
                'scripts/ci_changes.py',
                'scripts/cache_sqlite3_native_assets.sh',
            }
        )
        native = False
        for platform in PLATFORMS:
            platform_source = (
                path.startswith(f'{platform}/') and '/fastlane/' not in path
            )
            result[platform] |= global_build or platform_source
            native |= platform_source
        result['run_check'] |= (
            global_build or native or path.endswith('.dart')
            or path == 'analysis_options.yaml' or path.startswith('web/')
        )
    return result


def changed_paths(env):
    base = {
        'pull_request': env.get('PR_BASE_SHA'),
        'merge_group': env.get('MG_BASE_SHA'),
        'push': env.get('PUSH_BEFORE_SHA'),
    }.get(env.get('EVENT_NAME'))
    head = env.get('HEAD_SHA')
    if not base or base == '0' * 40 or not head:
        return None
    # Disabling rename detection includes both old and new paths. A move out
    # of a platform directory must still validate the platform losing a file.
    try:
        diff = subprocess.run(
            ['git', 'diff', '--name-only', '--no-renames', '-z', base, head, '--'],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError:
        return None
    return [os.fsdecode(path) for path in diff.stdout.split(b'\0') if path]


def main():
    paths = changed_paths(os.environ)
    if paths is None:
        print('::warning::Diff unavailable; running every CI check and platform.')
        result = dict.fromkeys(OUTPUTS, True)
    else:
        result = classify(paths)
    output = ''.join(f'{name}={str(value).lower()}\n' for name, value in result.items())
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as destination:
        destination.write(output)
    print(output, end='')


if __name__ == '__main__':
    main()
