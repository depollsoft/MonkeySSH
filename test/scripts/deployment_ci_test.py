"""Exercise independent build identity and deployment workflow handoffs."""

import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import fetch_pr_commits
from metadata_changes import classify
from preview_build_number import build_number


class PreviewVersionTest(unittest.TestCase):
    def test_same_event_is_stable_for_both_platforms_and_retries(self):
        event = {'pull_request': {'updated_at': '2026-09-07T12:34:56Z'}}
        self.assertEqual(build_number(event), 178878449)
        self.assertEqual(build_number(event), build_number(event))
        self.assertEqual(build_number(event), build_number({
            'pull_request': {'updated_at': '2026-09-07T05:34:56-07:00'}}))

    def test_invalid_or_ambiguous_event_does_not_guess_a_version(self):
        for value in ['invalid', '2026-09-07T12:34:56', '1960-01-01T00:00:00Z',
                      '3000-01-01T00:00:00Z']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                build_number({'pull_request': {'updated_at': value}})

    def compute_version(self, source, **inputs):
        action = json.loads(subprocess.check_output(
            ['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
             str(ROOT / '.github/actions/compute-version/action.yml')], text=True))
        step = action['runs']['steps'][0]
        output = Path(source) / 'output'
        output.write_text('')
        event = Path(source) / 'event.json'
        event.write_text(json.dumps({'pull_request': {'updated_at': '2026-09-07T12:34:56Z'}}))
        result = subprocess.run(['bash', '-e', '-c', step['run']], capture_output=True, text=True, env={
            **os.environ, 'SOURCE': str(source), 'BUILD_NAME': inputs.get('name', ''),
            'BUILD_NUMBER': inputs.get('number', ''), 'GITHUB_OUTPUT': str(output),
            'GITHUB_EVENT_PATH': str(event),
            'BUILD_NUMBER_SCRIPT': str(ROOT / 'scripts/preview_build_number.py')})
        return result, dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_compute_version_action_resolves_and_validates_once(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            shutil.copytree(ROOT / 'scripts', source / 'scripts')
            (source / 'assets').mkdir()
            (source / 'assets/version_codenames.json').write_text(
                json.dumps({'codenames': [{'major': 1, 'name': 'Fox'}]}))
            (source / 'pubspec.yaml').write_text('name: app\nversion: 1.2.3+9\n')
            result, outputs = self.compute_version(source, number='pull-request')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs, {'build-name': '1.2.3', 'build-number': '178878449',
                                       'build-codename': 'Fox', 'build-display': '1.2.3 "Fox"'})
            result, outputs = self.compute_version(source, name='2.0.0-pr.4', number='42')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs['build-display'], '2.0.0-pr.4')
            self.assertEqual(outputs['build-number'], '42')
            _, outputs = self.compute_version(source)
            self.assertRegex(outputs['build-number'], r'^[1-9][0-9]{8,9}$')
            for inputs in [{'name': '1.2'}, {'name': '1.2.3;x'}, {'number': '0'},
                           {'number': '2147483648'}, {'number': 'abc'}]:
                with self.subTest(**inputs):
                    result, outputs = self.compute_version(source, **inputs)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(outputs, {})
            (source / 'pubspec.yaml').write_text('name: app\nversion: latest\n')
            self.assertNotEqual(self.compute_version(source)[0].returncode, 0)

    def test_every_build_workflow_uses_the_shared_version_action(self):
        for name in ['preview.yml', 'preview-ios.yml', 'preview-deploy.yml', 'deploy-private.yml',
                     'release.yml']:
            with self.subTest(workflow=name):
                text = (ROOT / '.github/workflows' / name).read_text()
                self.assertIn('uses: ./.github/actions/compute-version', text)
                self.assertNotIn('version_codename.py "', text)


class FetchPrCommitsTest(unittest.TestCase):
    def test_subjects_are_newest_first_and_capped_at_one_page(self):
        requests = []

        def urlopen(request):
            requests.append(request.full_url)
            page = [{'sha': f'{index:x}' * 40, 'commit': {'message': f'subject {index}\n\nbody'}}
                    for index in range(100)]
            return io.BytesIO(json.dumps(page).encode())

        commits = fetch_pr_commits.fetch_commits('owner/repo', '7', 'token', urlopen)
        self.assertEqual(len(commits), 100)
        self.assertEqual(requests, ['https://api.github.com/repos/owner/repo/pulls/7/commits?per_page=100&page=1'])
        self.assertEqual(fetch_pr_commits.env_block(commits[:2], 'EOF'),
                         'FLUTTY_PR_COMMITS<<EOF\n1111111 subject 1\n0000000 subject 0\nEOF\n')

    def test_failures_warn_without_failing_the_step(self):
        env = {key: value for key, value in os.environ.items() if key != 'GH_TOKEN'}
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/fetch_pr_commits.py')],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('Warning: failed to fetch PR commits', result.stderr)


class MetadataChangesTest(unittest.TestCase):
    def test_copy_only_changes_skip_all_media(self):
        for platform in ['ios', 'android']:
            result = classify([f'{platform}/fastlane/metadata-private/en-US/description.txt'])
            self.assertTrue(result[platform])
            self.assertFalse(any(result[key] for key in
                                 ['ios_screenshots', 'ios_app_previews', 'android_screenshots']))

    def test_icons_and_android_images_require_android_media(self):
        for path in ['assets/icons/icon.png', 'scripts/sync_play_store_icons.py',
                     'android/fastlane/metadata-production/android/en-US/images/icon.png']:
            result = classify([path])
            self.assertTrue(result['android_screenshots'])
            self.assertFalse(result['ios'])

    def test_missing_base_and_pipeline_edits_validate_all_media(self):
        for paths in [None, ['scripts/store_assets.sh'], ['scripts/validate_store_screenshots.py'],
                      ['.github/workflows/sync-metadata.yml'], ['scripts/store_media.py']]:
            result = classify(paths)
            self.assertTrue(all(result[key] for key in
                                ['ios', 'android', 'ios_screenshots', 'ios_app_previews', 'android_screenshots']))

    def test_manual_sync_limits_platform_and_listing(self):
        result = classify(None, 'ios', 'private')
        self.assertEqual(json.loads(result['apps']), ['private'])
        self.assertTrue(result['ios_app_previews'])
        self.assertFalse(result['android_screenshots'])
        self.assertFalse(result['android'])
        self.assertEqual(json.loads(classify([], app='both')['apps']), ['private', 'production'])

    def test_preflight_helper_change_syncs_ios_copy(self):
        self.assertTrue(classify(['scripts/store_metadata.rb'])['ios'])

    def test_invalid_selectors_fail(self):
        with self.assertRaises(ValueError):
            classify([], 'other')
        with self.assertRaises(ValueError):
            classify([], app='other')


class DeploymentContractsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = "require 'yaml'; require 'json'; puts JSON.generate(ARGV.to_h { |f| [File.basename(f), YAML.load_file(f)] })"
        cls.workflows = json.loads(subprocess.check_output(
            ['ruby', '-e', script, *map(str, (ROOT / '.github/workflows').glob('*.yml'))], text=True))

    def test_comment_helpers_are_loaded_from_the_workflow_revision(self):
        for filename, names in [('preview-deploy.yml', ['comment-start', 'comment-finish']),
                                ('preview-deploy-command.yml', ['dispatch'])]:
            for name in names:
                job = self.workflows[filename]['jobs'][name]
                self.assertEqual(job['permissions']['contents'], 'read')
                checkout, script = job['steps']
                self.assertEqual(checkout['with']['ref'], '${{ github.workflow_sha }}')
                self.assertFalse(checkout['with']['persist-credentials'])
                self.assertIn('scripts/preview_deploy_comments.cjs', script['with']['script'])
                self.assertIn('upsertStatusComment({', script['with']['script'])

    def test_source_builds_restore_workflow_tooling_after_the_source_checkout(self):
        workflow = self.workflows['build-deploy.yml']
        tooling = workflow['env']['WORKFLOW_TOOLING'].split()
        # Local actions and the scripts deploy steps run must come from the
        # workflow commit even when the build checks out an older PR head.
        for path in ['.github/actions', 'scripts/android_signing.sh', 'scripts/fetch_pr_commits.py']:
            self.assertIn(path, tooling)
        for platform in ['android', 'ios']:
            with self.subTest(platform=platform):
                steps = workflow['jobs'][f'build-{platform}']['steps']
                index = {s.get('name'): i for i, s in enumerate(steps)}
                preserve, restore = index['Preserve workflow tooling'], index['Restore workflow tooling']
                source = index[f'Checkout resolved source SHA for {"iOS" if platform == "ios" else "Android"} build']
                self.assertLess(preserve, source)
                self.assertLess(source, restore)
                for step in [steps[preserve], steps[restore]]:
                    self.assertNotIn('if', step)
                    self.assertIn('"$RUNNER_TEMP/workflow-tooling.tar"', step['run'])
                self.assertIn('$WORKFLOW_TOOLING', steps[preserve]['run'])
                local = [i for i, s in enumerate(steps) if s.get('uses', '').startswith('./.github/actions/')]
                self.assertGreater(min(local), restore)
                self.assertEqual(steps[0]['with']['ref'], '${{ github.sha }}')

    def test_firebase_config_action_writes_flavor_files_or_disables_firebase(self):
        action = json.loads(subprocess.check_output(
            ['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
             str(ROOT / '.github/actions/firebase-config/action.yml')], text=True))
        script = action['runs']['steps'][0]['run']
        for platform, flavor, config, required, destination, enabled in [
            ('android', 'private', '{}', 'true', 'android/app/src/private/google-services.json', 'true'),
            ('ios', 'production', '<plist/>', 'false', 'ios/Runner/Firebase/production/GoogleService-Info.plist', 'true'),
            ('android', 'production', '', 'false', None, 'false'),
        ]:
            with self.subTest(platform=platform, flavor=flavor), tempfile.TemporaryDirectory() as temp:
                env_file = Path(temp, 'env')
                subprocess.run(['bash', '-e', '-c', script], cwd=temp, check=True, env={
                    **os.environ, 'PLATFORM': platform, 'FLAVOR': flavor, 'CONFIG': config,
                    'REQUIRED': required, 'GITHUB_ENV': str(env_file)})
                self.assertEqual(env_file.read_text(), f'FLUTTY_FIREBASE_ENABLED={enabled}\n')
                if destination:
                    self.assertEqual(Path(temp, destination).read_text(), config)
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run(['bash', '-e', '-c', script], cwd=temp, capture_output=True, text=True,
                                    env={**os.environ, 'PLATFORM': 'ios', 'FLAVOR': 'private', 'CONFIG': '',
                                         'REQUIRED': 'true', 'GITHUB_ENV': str(Path(temp, 'env'))})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FIREBASE_IOS_PRIVATE_GOOGLE_SERVICE_INFO_PLIST', result.stdout)
            self.assertFalse(Path(temp, 'env').exists())

    def test_main_builds_once_per_platform_and_reuses_identical_binary(self):
        jobs = self.workflows['deploy-private.yml']['jobs']
        for platform, artifact in [('android', 'aab'), ('ios', 'ipa')]:
            producer = jobs[f'build-{platform}']['with']
            self.assertTrue(producer[f'build-{platform}-unsigned-{artifact}'])
            self.assertNotIn(f'{platform}-reuse-run-id', producer)
            consumers = [jobs[f'distribute-{platform}-{channel}'] for channel in ['store', 'firebase']]
            for consumer in consumers:
                self.assertEqual(consumer['needs'], ['compute-version', f'build-{platform}'])
                inputs = consumer['with']
                for field in ['source-ref', 'build-name', 'build-number', 'build-codename',
                              'pr-number', 'pr-title', 'enable-diagnostics', 'flavor']:
                    self.assertEqual(inputs[field], producer[field])
                self.assertEqual(inputs[f'{platform}-reuse-run-id'], '${{ github.run_id }}')
                self.assertEqual(inputs[f'{platform}-reuse-source-sha'], '${{ github.sha }}')
                self.assertTrue(inputs[f'{platform}-reuse-{artifact}-is-unsigned'])
            self.assertEqual(consumers[0]['with'][f'{platform}-reuse-{artifact}-artifact-name'],
                             consumers[1]['with'][f'{platform}-reuse-{artifact}-artifact-name'])
        firebase = self.workflows['firebase-distribution.yml']
        self.assertNotIn('push', firebase.get('on', firebase.get('true')))
        groups = [job['with']['deployment-concurrency-group'] for job in jobs.values() if 'uses' in job]
        self.assertEqual(len(groups), len(set(groups)))
        self.assertNotEqual(jobs['build-android']['with']['monkeymux-assets-artifact-name'],
                            jobs['build-ios']['with']['monkeymux-assets-artifact-name'])

    def test_platform_previews_start_on_same_event_and_use_same_version_function(self):
        for name in ['preview.yml', 'preview-ios.yml']:
            workflow = self.workflows[name]
            triggers = workflow.get('on', workflow.get('true'))
            self.assertIn('pull_request', triggers)
            self.assertNotIn('workflow_run', triggers)
            job = workflow['jobs']['compute-version']
            self.assertIn('head.repo.full_name == github.repository', job['if'])
            version_step = next(s for s in job['steps'] if s.get('id') == 'version')
            self.assertEqual(version_step['uses'], './.github/actions/compute-version')
            self.assertEqual(version_step['with'], {'source': 'source', 'build-number': 'pull-request'})
            checkouts = [step for step in job['steps'] if step.get('uses', '').startswith('actions/checkout@')]
            self.assertEqual([step['with']['ref'] for step in checkouts],
                             ['${{ github.sha }}', '${{ github.event.pull_request.head.sha }}'])
            self.assertEqual(checkouts[1]['with']['path'], 'source')
        self.assertIn('github.event.pull_request.updated_at', self.workflows['preview-ios.yml']['run-name'])

    def test_distribution_uses_workflow_identity_instead_of_custom_run_title(self):
        jobs = self.workflows['firebase-distribution.yml']['jobs']
        script = jobs['resolve-preview']['steps'][0]['with']['script']
        self.assertIn('github.rest.actions.getWorkflow', script)
        self.assertIn('workflow_id: workflowRun.workflow_id', script)
        self.assertIn('const sourceWorkflow = producerWorkflow.name', script)

    def test_processing_leaves_mac_but_remains_part_of_final_status(self):
        jobs = self.workflows['build-deploy.yml']['jobs']
        followup = jobs['finish-testflight']
        self.assertEqual(followup['runs-on'], 'ubuntu-latest')
        self.assertEqual(followup['needs'], 'build-ios')
        self.assertIn('finish-testflight', jobs['deploy-status-summary']['needs'])
        marker = jobs['record-private-deploy-build-number']
        self.assertNotIn('finish-testflight', marker['needs'])
        self.assertIn('always()', marker['if'])
        self.assertIn('outputs.store-uploaded', marker['if'])

    def test_copy_only_metadata_can_run_when_media_jobs_are_skipped(self):
        jobs = self.workflows['sync-metadata.yml']['jobs']
        restore = jobs['restore-store-assets']
        self.assertIn('outputs.ios_screenshots', restore['if'])
        self.assertNotIn("outputs.ios == 'true'", restore['if'])
        for platform in ['ios', 'android']:
            job = jobs[f'sync-{platform}']
            self.assertIn("needs.restore-store-assets.result == 'skipped'", job['if'])
            self.assertIn('!cancelled()', job['if'])
        self.assertEqual(jobs['sync-ios']['strategy']['matrix']['app'],
                         '${{ fromJSON(needs.preflight-ios.outputs.apps) }}')
        self.assertIn('preflight-ios', jobs['metadata-result']['needs'])

    def test_metadata_matrix_preserves_flavor_identity_media_and_deployment_status(self):
        jobs = self.workflows['sync-metadata.yml']['jobs']
        for platform, label, store, argument in [
            ('ios', 'iOS', 'App Store', 'app_identifier'),
            ('android', 'Android', 'Play Store', 'package_name'),
        ]:
            with self.subTest(platform=platform):
                job = jobs[f'sync-{platform}']
                self.assertEqual(job['env']['APP_IDENTIFIER'],
                                 "${{ matrix.app == 'private' && 'xyz.depollsoft.monkeyssh.private' || 'xyz.depollsoft.monkeyssh' }}")
                self.assertEqual(job['env']['APP_LABEL'],
                                 "${{ matrix.app == 'private' && 'Private' || 'Production' }}")
                steps = job['steps']
                sync = next(s for s in steps if s.get('id') == 'sync-metadata')
                self.assertNotIn('if', sync)
                self.assertIn(f'{argument}:"$APP_IDENTIFIER" skip_media:"$SKIP_MEDIA"', sync['run'])
                media = f"needs.changes.outputs.{platform}_screenshots == 'true'"
                if platform == 'ios':
                    media += " || needs.changes.outputs.ios_app_previews == 'true'"
                self.assertEqual(sync['env']['SKIP_MEDIA'], "${{ (" + media + ") && 'false' || 'true' }}")
                deployments = [s for s in steps if s.get('uses') == './.github/actions/deployment-status']
                self.assertEqual([s['with']['action'] for s in deployments], ['start', 'finish'])
                start, finish = deployments
                self.assertEqual(start['id'], 'start-metadata-deployment')
                self.assertNotIn('if', start)
                self.assertEqual(finish['if'], "always() && steps.start-metadata-deployment.outputs['deployment-id'] != ''")
                self.assertEqual(finish['with']['deployment-id'], "${{ steps.start-metadata-deployment.outputs['deployment-id'] }}")
                self.assertEqual(finish['with']['state'], "${{ steps.sync-metadata.outcome == 'success' && 'success' || 'failure' }}")
                for step in deployments:
                    self.assertTrue(step['continue-on-error'])
                    self.assertEqual(step['with']['environment'], label + ' ${{ env.APP_LABEL }} / ' + store + ' Metadata')
                    if platform == 'android':
                        self.assertEqual(step['with']['production-environment'], "${{ matrix.app == 'production' && 'true' || 'false' }}")
                        self.assertEqual(step['with']['environment-url'], "${{ matrix.app == 'production' && 'https://play.google.com/store/apps/details?id=xyz.depollsoft.monkeyssh' || '' }}")

    def test_missing_editable_app_store_version_warns_instead_of_failing(self):
        # A version in review or Ready for Distribution has no editable
        # metadata. That is the normal state between releases, so it must not
        # leave sync-metadata permanently red on main; only a real upload
        # failure or cancellation fails the run.
        gate = self.workflows['sync-metadata.yml']['jobs']['metadata-result']['steps'][0]
        self.assertEqual(gate['env']['BLOCKED'], '${{ needs.preflight-ios.outputs.blocked }}')
        blocked, failed = gate['run'].split('if [[ "$RESULTS"')
        self.assertIn('::warning::', blocked)
        self.assertNotIn('exit 1', blocked)
        self.assertIn('$GITHUB_STEP_SUMMARY', blocked)
        self.assertNotIn('BLOCKED', failed)
        self.assertIn('*failure*', failed)
        self.assertIn('*cancelled*', failed)
        self.assertIn('::error::', failed)
        self.assertIn('exit 1', failed)

    def test_published_validation_applies_to_the_same_artifact_snapshot(self):
        publisher = self.workflows['publish-store-assets.yml']['jobs']['sync-metadata']
        self.assertTrue(publisher['with']['use-validated-store-assets'])
        jobs = self.workflows['sync-metadata.yml']['jobs']
        restore = next(s for s in jobs['restore-store-assets']['steps'] if s.get('name') == 'Download published store assets')
        self.assertIn('download --run-id "$GITHUB_RUN_ID"', restore['run'])
        for job in ['validate_ios_screenshots', 'validate_android_screenshots', 'validate_ios_app_previews']:
            self.assertIn('!inputs.use-validated-store-assets', jobs[job]['if'])

    def test_store_and_profile_writers_share_locks(self):
        builds = self.workflows['build-deploy.yml']['jobs']
        metadata = self.workflows['sync-metadata.yml']['jobs']
        for platform, group in [('ios', 'app-store'), ('android', 'play-store')]:
            self.assertIn(group, builds[f'build-{platform}']['concurrency']['group'])
            self.assertEqual(metadata[f'sync-{platform}']['concurrency']['group'], group + '-${{ matrix.app }}')
        maintenance = self.workflows['regenerate-ios-profiles.yml']['concurrency']['group']
        self.assertIn(maintenance, builds['build-ios']['concurrency']['group'])

    def test_every_runner_job_has_a_bounded_timeout(self):
        for name, workflow in self.workflows.items():
            for job_name, job in workflow['jobs'].items():
                with self.subTest(workflow=name, job=job_name):
                    if 'runs-on' in job:
                        self.assertGreater(job['timeout-minutes'], 0)
                        self.assertLessEqual(job['timeout-minutes'], 30)


if __name__ == '__main__':
    unittest.main()
