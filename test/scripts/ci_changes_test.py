"""Regression coverage for skipped jobs, native inputs, and shallow diffs."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import ci_changes as changes


class ClassificationTest(unittest.TestCase):
    def assert_platforms(self, paths, platforms):
        result = changes.classify(paths)
        self.assertEqual({p for p in changes.PLATFORMS if result[p]}, set(platforms))
        return result

    def test_documentation_is_a_noop(self):
        self.assertFalse(any(changes.classify(['README.md', 'docs/setup.md']).values()))

    def test_dart_changes_keep_analyzer_and_tests_without_native_builds(self):
        for path in ['lib/main.dart', 'test/widget/example_test.dart', 'analysis_options.yaml']:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['run_check'])

    def test_monkeymux_cleanup_changes_run_windows_coverage(self):
        for path in [
            'lib/domain/services/monkeymux_installer_service.dart',
            'lib/domain/services/monkeymux_windows_cleanup.dart',
            'lib/domain/services/windows_remote_powershell.dart',
            'test/domain/services/monkeymux_installer_service_test.dart',
            'test/domain/services/monkeymux_windows_cleanup_test.dart',
        ]:
            with self.subTest(path=path):
                result = self.assert_platforms([path], ['windows'])
                self.assertTrue(result['run_check'])
                self.assertFalse(result['go'])
                # These live outside windows/, but they are the reason the
                # Windows build runs, so they must survive the pull_request
                # gate that requires a native change.
                self.assertTrue(result['windows_native'])

    def test_release_and_workflow_tooling_do_not_require_flutter(self):
        for path in [
            '.github/workflows/security.yml', '.github/actions/deployment-status/action.yml',
            '.github/dependabot.yml', 'scripts/validate_app_store_metadata.py',
            'scripts/generate_store_screenshots.py', 'test/scripts/preview_release_notes_test.rb',
            'Gemfile.lock', 'ios/fastlane/Fastfile',
            'ios/fastlane/metadata-production/en-US/description.txt',
            'android/fastlane/metadata-private/android/en-US/title.txt',
        ]:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['tooling'])
                self.assertFalse(result['run_check'])

    def test_each_native_platform_is_checked_in_isolation(self):
        for platform in changes.PLATFORMS:
            with self.subTest(platform=platform):
                result = self.assert_platforms([f'{platform}/native/source'], [platform])
                self.assertTrue(result['run_check'])
                self.assertEqual({p for p in changes.PLATFORMS if result[f'{p}_native']},
                                 {platform})

    def test_shared_dependencies_assets_and_ci_changes_build_every_platform(self):
        for path in [
            'pubspec.yaml', 'pubspec.lock', 'assets/version_codenames.json',
            '.github/workflows/ci.yml', 'scripts/ci_changes.py',
            'scripts/cache_sqlite3_native_assets.sh',
            'third_party/permission_handler_apple/ios/Package.swift',
            'third_party/in_app_purchase_android/android/build.gradle',
        ]:
            with self.subTest(path=path):
                result = self.assert_platforms([path], changes.PLATFORMS)
                self.assertTrue(result['run_check'])

    def test_shared_inputs_are_not_native_changes(self):
        # `<platform>` fires on shared inputs; `<platform>_native` must not, or
        # the pull_request gate on the Apple/Windows builds means nothing.
        for path in ['pubspec.yaml', 'pubspec.lock', 'assets/version_codenames.json',
                     '.github/workflows/ci.yml', 'scripts/ci_changes.py',
                     'third_party/xterm/lib/src/terminal.dart',
                     'ios/fastlane/Fastfile', 'macos/fastlane/Deliverfile']:
            with self.subTest(path=path):
                result = changes.classify([path])
                self.assertFalse(any(result[f'{p}_native'] for p in changes.PLATFORMS))

    def test_dependency_locks_are_flagged_for_apple_cache_warming(self):
        # These are exactly the files the Apple compilation cache keys hash, so
        # a push that moves one still warms build-ios/build-macos from main.
        for path, platforms in [
            ('pubspec.lock', changes.PLATFORMS),
            ('ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved', ['ios']),
            ('macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved', ['macos']),
        ]:
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).exists(), path)
                result = self.assert_platforms([path], platforms)
                self.assertTrue(result['deps'])
        for path in ['pubspec.yaml', 'lib/main.dart', 'ios/Runner/AppDelegate.swift']:
            with self.subTest(path=path):
                self.assertFalse(changes.classify([path])['deps'])

    def test_helper_inputs_run_go_tests_without_the_platform_builds(self):
        # The payload ships as an opaque blob under assets/monkeymux/, so it
        # cannot break a native toolchain: go-test and the monkeymux-assets
        # build already validate it. It still needs the Dart checks.
        for path in [*changes.PAYLOAD_SCRIPTS, 'remote/monkeymux/go.mod',
                     'remote/monkeymux/conpty/ConPTY.dll', 'remote/monkeymux/main.go']:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['go'])
                self.assertTrue(result['run_check'])

    def test_daemon_tests_only_run_go_and_readme_is_documentation(self):
        for path in ['remote/monkeymux/main_test.go', 'remote/monkeymux/internal/example_test.go']:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['go'])
                self.assertFalse(result['run_check'])
        self.assertFalse(any(changes.classify(['remote/monkeymux/README.md']).values()))

    def test_daemon_packaging_exceptions_and_unknown_inputs_stay_conservative(self):
        for path in ['remote/monkeymux/conpty/example_test.go',
                     'remote/monkeymux/conpty/README.md', 'remote/monkeymux/unknown.input']:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['go'])
                self.assertTrue(result['run_check'])

    def test_mixed_daemon_and_application_changes_retain_their_coverage(self):
        result = self.assert_platforms(['remote/monkeymux/main_test.go', 'lib/main.dart'], [])
        self.assertTrue(result['go'])
        self.assertTrue(result['run_check'])
        result = self.assert_platforms(['remote/monkeymux/README.md', 'ios/native.swift'], ['ios'])
        self.assertFalse(result['go'])
        self.assertTrue(result['run_check'])
        result = self.assert_platforms(
            ['remote/monkeymux/main_test.go', 'remote/monkeymux/main.go'], [])
        self.assertTrue(result['go'])
        self.assertTrue(result['run_check'])

    def test_vendored_terminal_inputs_keep_test_coverage(self):
        for path in ['third_party/xterm/pubspec.yaml', 'third_party/xterm/pubspec.lock',
                     'third_party/xterm/lib/src/terminal.dart']:
            with self.subTest(path=path):
                result = changes.classify([path])
                self.assertTrue(result['run_check'])
                # terminal-test is gated on third_party alone: the vendored
                # package has no path dependency on lib/.
                self.assertTrue(result['third_party'])
        for path in ['lib/main.dart', 'test/widget/example_test.dart', 'pubspec.yaml',
                     'remote/monkeymux/main.go']:
            with self.subTest(path=path):
                self.assertFalse(changes.classify([path])['third_party'])


class GitDiffTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'ci-test@example.invalid')
        self.git('config', 'user.name', 'CI test')
        self.write('android/old.cpp', 'old source')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def write(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)

    def classify(self, event='pull_request', base=None):
        output = self.root / 'output'
        output.write_text('')
        env = {
            **os.environ, 'EVENT_NAME': event,
            'PR_BASE_SHA': base or self.base, 'MG_BASE_SHA': base or self.base,
            'PUSH_BEFORE_SHA': base or self.base, 'HEAD_SHA': self.git('rev-parse', 'HEAD'),
            'GITHUB_OUTPUT': str(output),
        }
        subprocess.run([sys.executable, str(ROOT / 'scripts/ci_changes.py')],
                       cwd=self.root, env=env, check=True, capture_output=True)
        return dict(line.split('=') for line in output.read_text().splitlines())

    def test_pr_push_and_merge_group_diff_include_both_sides_of_a_rename(self):
        (self.root / 'docs').mkdir()
        self.git('mv', 'android/old.cpp', 'docs/old.cpp')
        self.git('commit', '-qm', 'move')
        for event in ['pull_request', 'merge_group', 'push']:
            with self.subTest(event=event):
                result = self.classify(event)
                self.assertEqual(result['android'], 'true')
                self.assertEqual(result['ios'], 'false')

    def test_daemon_renames_classify_both_old_and_new_paths(self):
        # The payload never triggers the platform builds, so `run_check` and the
        # platform outputs diverge for every packaged daemon input.
        for source, target, run_check, go in [
            ('main.go', 'main_test.go', True, True),
            ('main_test.go', 'main.go', True, True),
            ('main_test.go', 'renamed_test.go', False, True),
            ('README.md', 'unknown.input', True, True),
            ('README.md', '../../docs/daemon.md', False, False),
        ]:
            with self.subTest(source=source, target=target):
                self.write('remote/monkeymux/' + source, 'fixture')
                self.git('add', '.')
                self.git('commit', '-qm', 'daemon input')
                base = self.git('rev-parse', 'HEAD')
                dest = self.root / 'remote/monkeymux' / target
                dest.parent.mkdir(parents=True, exist_ok=True)
                self.git('mv', 'remote/monkeymux/' + source, str(dest))
                self.git('commit', '-qm', 'rename daemon input')
                result = self.classify(base=base)
                self.assertEqual(result['go'], str(go).lower())
                self.assertEqual(result['run_check'], str(run_check).lower())
                for output in changes.PLATFORMS:
                    self.assertEqual(result[output], 'false')

    def resolve_security_commits(self, base, head):
        script = subprocess.check_output(['ruby', '-ryaml', '-e',
            "puts YAML.load_file(ARGV[0])['jobs']['dependency-review']['steps'].find { |s| s['id'] == 'comparison' }['run']",
            str(ROOT / '.github/workflows/security.yml')], text=True)
        output = self.root / 'security-output'
        output.write_text('')
        result = subprocess.run(['bash', '-e', '-c', script], cwd=self.root, capture_output=True,
                                text=True, env={**os.environ, 'BASE_SHA': base, 'HEAD_SHA': head,
                                                'GH_TOKEN': '', 'GITHUB_OUTPUT': str(output)})
        return result, dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_security_fetches_older_before_commit_in_shallow_multicommit_push(self):
        self.write('pubspec.lock', 'changed dependency')
        self.git('add', '.')
        self.git('commit', '-qm', 'dependency update')
        for index in range(3):
            self.write('docs/new.md', str(index))
            self.git('add', '.')
            self.git('commit', '-qm', 'documentation update')
        origin = self.root
        clone = origin / 'shallow'
        self.git('clone', '--depth=2', origin.as_uri(), str(clone))
        self.root = clone
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository'), 'true')
        self.assertNotEqual(subprocess.run(['git', 'cat-file', '-e', self.base], cwd=clone,
                                          capture_output=True).returncode, 0)
        head = self.git('rev-parse', 'HEAD')
        result, outputs = self.resolve_security_commits(self.base, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {'base': self.base, 'head': head})
        self.assertEqual(self.git('diff', '--name-only', outputs['base'], outputs['head']).splitlines(),
                         ['docs/new.md', 'pubspec.lock'])
        self.assertEqual(self.classify('push')['run_check'], 'true')
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository'), 'true')
        # A head that arrived after checkout must also be fetched explicitly.
        self.root = origin
        self.write('Gemfile.lock', 'another dependency')
        self.git('add', 'Gemfile.lock')
        self.git('commit', '-qm', 'new head')
        next_head = self.git('rev-parse', 'HEAD')
        self.root = clone
        result, outputs = self.resolve_security_commits(head, next_head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('diff', '--name-only', outputs['base'], outputs['head']), 'Gemfile.lock')
        result, _ = self.resolve_security_commits('f' * 40, next_head)
        self.assertNotEqual(result.returncode, 0)

    def test_security_first_push_resolves_parent_or_has_no_baseline(self):
        result, outputs = self.resolve_security_commits('0' * 40, self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs['base'], '')
        self.write('README.md', 'documentation')
        self.git('add', '.')
        self.git('commit', '-qm', 'second commit')
        result, outputs = self.resolve_security_commits('0' * 40, self.git('rev-parse', 'HEAD'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs['base'], self.base)

    def test_nul_separation_prevents_newlines_in_names_from_inventing_paths(self):
        self.write('docs/newline\nlib/fake.dart', 'documentation')
        self.git('add', '.')
        self.git('commit', '-qm', 'newline')
        # It is a .dart path, so analysis is conservative, but it must not
        # invent a native path from the newline inside a single filename.
        result = self.classify()
        self.assertEqual(result['android'], 'false')
        self.assertEqual(result['go'], 'false')

    def test_missing_shallow_base_and_first_push_fail_open(self):
        for base in ['0' * 40, 'f' * 40]:
            self.assertEqual(set(self.classify('push', base).values()), {'true'})

    def test_empty_diff_skips_every_job(self):
        self.assertEqual(set(self.classify().values()), {'false'})


class WorkflowContractsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = "require 'yaml'; require 'json'; puts JSON.generate(ARGV.to_h { |f| [File.basename(f), YAML.load_file(f)] })"
        cls.workflows = json.loads(subprocess.check_output(
            ['ruby', '-e', script, *map(str, (ROOT / '.github/workflows').glob('*.yml'))],
            text=True,
        ))

    def test_apple_cache_keys_limits_and_save_conditions(self):
        actions = json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
            'puts JSON.generate(ARGV.map { |f| YAML.load_file(f) })',
            *[str(ROOT / '.github/actions' / name / 'action.yml')
              for name in ['apple-cache-restore', 'apple-cache-save']]], text=True))
        restore, save = [action['runs']['steps'] for action in actions]
        keyed = {step['id']: step for step in restore if 'id' in step}
        suffix = "${{ runner.os }}-${{ runner.arch }}-${{ steps.toolchain.outputs.xcode }}-${{ inputs.flutter-version }}"
        self.assertEqual(keyed['compilation']['with']['key'], '${{ inputs.platform }}-compile-v1-' + suffix +
                         '-${{ inputs.configuration }}-${{ inputs.dependency-fingerprint }}')
        self.assertEqual(keyed['workspace']['with']['key'], 'spm-workspace-v1-' + suffix +
                         '-${{ inputs.platform }}-${{ inputs.dependency-fingerprint }}')
        spm_key = "spm-${{ runner.os }}-${{ hashFiles('ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}"
        self.assertEqual(keyed['swiftpm']['with']['key'], spm_key)
        self.assertEqual(keyed['swiftpm']['with']['restore-keys'], 'spm-${{ runner.os }}-')
        self.assertEqual(save[-1]['with']['key'], spm_key)
        self.assertEqual(restore[1]['run'], 'rm -rf ~/Library/Caches/org.swift.swiftpm/manifests')
        for kind in ['compilation', 'workspace']:
            step = next(step for step in save if step.get('with', {}).get('key') == '${{ inputs.' + kind + '-key }}')
            self.assertEqual(step['if'], "steps.sizes.outputs." + kind + " == 'true' && inputs." + kind + "-hit != 'true'")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'build/ios/SourcePackages').mkdir(parents=True)
            du = root / 'du'
            du.write_text('#!/bin/sh\nprintf "%s\\tcache\\n" "$TEST_CACHE_KIB"\n')
            du.chmod(0o755)
            for limit in [1048576, 2097152]:
                for size in [0, 1, limit, limit + 1]:
                    output = root / 'output'
                    output.write_text('')
                    subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', save[0]['run']],
                                   cwd=root, check=True, env={**os.environ,
                                       'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                       'PLATFORM': 'ios', 'TEST_CACHE_KIB': str(size),
                                       'COMPILATION_LIMIT_KIB': str(limit), 'WORKSPACE_LIMIT_KIB': '2097152',
                                       'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(root / 'summary')})
                    expected = ('compilation=true\n' if 0 < size <= limit else '') + (
                        'workspace=true\n' if 0 < size <= 2097152 else '')
                    self.assertEqual(output.read_text(), expected)
        for workflow, platform, configuration, limit in [('ci.yml', 'ios', 'production', 1048576),
                ('ci.yml', 'macos', 'release', 2097152), ('build-deploy.yml', 'ios', '${{ inputs.flavor }}', 1048576)]:
            steps = self.workflows[workflow]['jobs']['build-' + platform]['steps']
            caches = [step for step in steps if step.get('with', {}).get('phase') == 'build']
            self.assertEqual(caches[0]['with']['configuration'], configuration)
            self.assertEqual(caches[0]['with']['dependency-fingerprint'],
                             "${{ hashFiles('pubspec.lock', '" + platform + "/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}")
            self.assertEqual(caches[1]['with']['compilation-limit-kib'], limit)
            self.assertEqual(caches[1]['with']['workspace-limit-kib'], 2097152)
            for kind in ['compilation', 'workspace']:
                for field in ['key', 'hit']:
                    self.assertEqual(caches[1]['with'][kind + '-' + field], '${{ steps.apple-cache.outputs.' + kind + '-' + field + ' }}')
            if workflow == 'ci.yml':
                self.assertEqual(steps[-1]['if'], "steps.spm-cache.outputs.swiftpm-hit != 'true'")
            else:
                self.assertEqual(caches[0]['if'], "inputs.ios-reuse-ipa-artifact-name == '' && inputs.deploy-ios-to == 'none'")
                self.assertEqual(caches[1]['if'], "steps.apple-cache.outcome == 'success'")
                self.assertFalse(any(step.get('with', {}).get('phase') == 'swiftpm' and
                                     step.get('uses') == './.github/actions/apple-cache-save' for step in steps))

    def test_mobile_triggers_share_all_compile_and_packaging_inputs(self):
        for file, event in [('preview.yml', 'pull_request'), ('deploy-private.yml', 'push'),
                            ('preview-ios.yml', 'pull_request')]:
            with self.subTest(file=file):
                workflow = self.workflows[file]
                triggers = workflow.get('on', workflow.get('true'))
                self.assertEqual(triggers[event]['paths'], changes.MOBILE_PATHS)
                self.assertNotIn('**.dart', triggers[event]['paths'])
                self.assertIn('remote/monkeymux/**', triggers[event]['paths'])
                self.assertIn('third_party/**', triggers[event]['paths'])

    def test_daemon_test_jobs_receive_the_asset_manifest(self):
        jobs = self.workflows['ci.yml']['jobs']
        self.assertEqual(jobs['monkeymux-assets']['if'],
                         "needs.changes.outputs.run_check == 'true' || needs.changes.outputs.go == 'true'")
        self.assertIn('monkeymux-assets', jobs['go-test']['needs'])

    def test_tooling_discovers_all_python_suites_and_publication_validates_artifacts(self):
        steps = self.workflows['ci.yml']['jobs']['tooling']['steps']
        python = next(s['run'] for s in steps if "-p '*_test.py'" in s.get('run', ''))
        self.assertIn('pip install --quiet Pillow', python)
        self.assertIn('-m unittest discover -s test/scripts', python)
        publisher = self.workflows['publish-store-assets.yml']['jobs']['publish']['steps']
        commands = '\n'.join(s.get('run', '') for s in publisher)
        self.assertNotIn('unittest', commands)
        self.assertNotIn('scripts/validate_store_screenshots.py', commands)
        self.assertIn('--require-screenshots', commands)
        self.assertIn('scripts/validate_store_demo_videos.py', commands)

    def test_security_shallow_comparison_passes_the_resolved_baseline(self):
        jobs = self.workflows['security.yml']['jobs']
        steps = jobs['dependency-review']['steps']
        self.assertEqual(steps[0]['with']['fetch-depth'], 2)
        for name in ['Detect changed dependency lockfiles', 'Compare changed dependencies with OSV']:
            step = next(s for s in steps if s.get('name') == name)
            self.assertEqual(step['env']['BASE_SHA'], '${{ steps.comparison.outputs.base }}')
            self.assertNotIn('git rev-parse', step['run'])

    def test_gate_waits_for_independent_tooling_and_terminal_checks(self):
        jobs = self.workflows['ci.yml']['jobs']
        self.assertIn('tooling', jobs['ci']['needs'])
        self.assertIn('terminal-test', jobs['ci']['needs'])
        self.assertEqual(jobs['tooling']['needs'], 'changes')
        self.assertNotIn('monkeymux-assets', jobs['terminal-test']['needs'])
        # The gate itself must stay unconditional so it reports on pull_request,
        # merge_group and the cache-warm push run alike; `skipped` counts as
        # success there, which is what keeps the push run green.
        self.assertNotIn('push', jobs['ci']['if'])
        self.assertIn('skipped)', jobs['ci']['steps'][0]['run'])

    def test_push_to_main_only_warms_caches(self):
        jobs = self.workflows['ci.yml']['jobs']
        warm = {'changes', 'monkeymux-assets', 'ci', 'build-ios', 'build-macos'}
        for name, job in jobs.items():
            with self.subTest(job=name):
                if name in warm:
                    continue
                self.assertIn("github.event_name != 'push'", job['if'])
        # The payload cache is written from main, so that job keeps running.
        self.assertNotIn('push', jobs['monkeymux-assets']['if'])
        # The Apple compilation caches are keyed on the dependency lockfiles and
        # can only be written from main, so a lockfile bump still builds there.
        for platform in ['ios', 'macos']:
            condition = jobs[f'build-{platform}']['if']
            self.assertIn(
                "(github.event_name != 'push' || needs.changes.outputs.deps == 'true')",
                condition)

    def test_pull_requests_skip_apple_and_windows_builds_without_native_changes(self):
        jobs = self.workflows['ci.yml']['jobs']
        outputs = self.workflows['ci.yml']['jobs']['changes']['outputs']
        for platform in ['ios', 'macos', 'windows']:
            with self.subTest(platform=platform):
                self.assertEqual(outputs[f'{platform}_native'],
                                 '${{ steps.filter.outputs.' + platform + '_native }}')
                self.assertIn(
                    "(github.event_name != 'pull_request' || "
                    f"needs.changes.outputs.{platform}_native == 'true')",
                    jobs[f'build-{platform}']['if'])
        # Android and Linux do not use the 5-slot macOS pool and stay unchanged.
        for platform in ['android', 'linux']:
            self.assertNotIn('pull_request', jobs[f'build-{platform}']['if'])
        self.assertEqual(outputs['third_party'], '${{ steps.filter.outputs.third_party }}')
        self.assertEqual(outputs['deps'], '${{ steps.filter.outputs.deps }}')
        self.assertIn("needs.changes.outputs.third_party == 'true'",
                      jobs['terminal-test']['if'])

    def test_shards_use_the_whole_runner_and_no_build_artifacts_are_uploaded(self):
        jobs = self.workflows['ci.yml']['jobs']
        self.assertEqual(jobs['test']['strategy']['matrix']['shard-index'], [0, 1, 2, 3, 4, 5])
        self.assertIn('Shard ${{ matrix.shard-index }}/6', jobs['test']['name'])
        shard = next(s for s in jobs['test']['steps'] if s.get('name') == 'Run tests')
        self.assertIn('-j 4 --total-shards 6', shard['run'])
        # Nothing downstream consumes the compiled builds; only the diagnostics
        # logs are worth retaining.
        uploads = [step['with']['name'] for job in jobs.values()
                   for step in job.get('steps', [])
                   if step.get('uses', '').startswith('actions/upload-artifact@')
                   and 'name' in step.get('with', {})]
        self.assertEqual(sorted(uploads), [
            'ci-ios-build-log', 'ci-macos-build-log',
            'flutter-test-failures-${{ matrix.shard-index }}',
            'monkeymux-assets', 'terminal-test-failures',
        ])

    def test_flutter_setup_is_shared_and_pins_the_action(self):
        action = json.loads(subprocess.check_output(
            ['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
             str(ROOT / '.github/actions/flutter-setup/action.yml')], text=True))
        steps = action['runs']['steps']
        self.assertEqual(steps[0]['uses'],
                         'subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2')
        self.assertEqual(steps[1]['run'], 'flutter pub get')
        self.assertEqual(steps[2]['if'], "inputs.sqlite-targets != ''")
        self.assertEqual(action['inputs']['cache']['default'], 'true')
        self.assertEqual(action['inputs']['pub-cache']['default'], 'true')
        jobs = self.workflows['ci.yml']['jobs']
        users = {name for name, job in jobs.items() for step in job.get('steps', [])
                 if step.get('uses') == './.github/actions/flutter-setup'}
        self.assertEqual(users, {'check', 'test', 'build-android', 'build-ios',
                                 'build-macos', 'build-windows', 'build-linux'})
        for name, job in jobs.items():
            for step in job.get('steps', []):
                if step.get('uses', '').startswith('subosito/flutter-action@'):
                    # terminal-test runs pub get inside third_party/xterm, so it
                    # is the one job that is not the setup trio.
                    self.assertEqual(name, 'terminal-test')
        windows = next(s for s in jobs['build-windows']['steps']
                       if s.get('uses') == './.github/actions/flutter-setup')
        # The 2.1 GB SDK archive is what cancelled jobs; the 32 MB pub cache is safe.
        self.assertEqual(windows['with']['cache'], 'false')
        self.assertEqual(windows['with']['pub-cache'], 'true')

    def test_payload_cache_can_only_be_saved_by_push_to_main_ci(self):
        for filename, workflow in self.workflows.items():
            for job in workflow['jobs'].values():
                for step in job.get('steps', []):
                    if step.get('with', {}).get('path') != 'assets/monkeymux/':
                        continue
                    uses = step.get('uses', '')
                    if uses.startswith('actions/cache/save@'):
                        self.assertEqual(filename, 'ci.yml')
                        self.assertIn("github.event_name == 'push'", step['if'])
                        self.assertIn("github.ref == 'refs/heads/main'", step['if'])
                    self.assertFalse(uses.startswith('actions/cache@'))
                    if uses.startswith('actions/upload-artifact@'):
                        self.assertTrue(step['with']['include-hidden-files'])

    def test_deployment_source_is_an_immutable_commit(self):
        for job in self.workflows['deploy-private.yml']['jobs'].values():
            if 'uses' in job:
                self.assertEqual(job['with']['source-ref'], '${{ github.sha }}')
        for job in self.workflows['build-deploy.yml']['jobs'].values():
            for step in job.get('steps', []):
                if step.get('uses', '').startswith('actions/checkout@'):
                    self.assertNotEqual(step.get('with', {}).get('ref'), '${{ github.ref }}')

    def test_profile_maintenance_supports_both_distribution_types(self):
        workflow = self.workflows['regenerate-ios-profiles.yml']
        triggers = workflow.get('on', workflow.get('true'))
        self.assertEqual(triggers['workflow_dispatch']['inputs']['profile-type']['options'],
                         ['appstore', 'adhoc'])


if __name__ == '__main__':
    unittest.main()
