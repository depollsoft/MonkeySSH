"""Offline regression tests for the store-assets archive CLI."""

import hashlib
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/store_assets.sh'
MEDIA = 'ios/fastlane/screenshots/en-US/current.png'
MISSING = 'ios/fastlane/app-previews/en-US/preview.mov'
MANIFEST = 'store-assets-manifest.json'


class StoreAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dest = self.root / 'destination'
        self.dest.mkdir()
        self.stale = self.dest / 'ios/fastlane/screenshots/en-US/old.png'
        self.stale.parent.mkdir(parents=True)
        self.stale.write_bytes(b'keep until archive is validated')
        self.metadata = self.dest / 'ios/fastlane/metadata-production/name.txt'
        self.metadata.parent.mkdir(parents=True)
        self.metadata.write_text('MonkeySSH')

    def manifest(self, files):
        return {
            'version': 1,
            'file_count': len(files),
            'files': [
                {'path': path, 'size': len(data),
                 'sha256': hashlib.sha256(data).hexdigest()}
                for path, data in files.items()
            ],
        }

    def archive(self, files, manifest=None, links=()):
        archive = self.root / 'store-assets.tar.gz'
        with tarfile.open(archive, 'w:gz') as tf:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            if manifest is not None:
                data = json.dumps(manifest).encode()
                info = tarfile.TarInfo(MANIFEST)
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            for name, target, kind in links:
                info = tarfile.TarInfo(name)
                info.type = kind
                info.linkname = target
                tf.addfile(info)
        return archive

    def download(self, archive):
        return subprocess.run(
            ['bash', str(SCRIPT), 'download', '--archive', str(archive),
             '--output', str(self.dest)],
            capture_output=True, text=True, timeout=15,
        )

    def assert_rejected_without_changes(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.stale.read_bytes(), b'keep until archive is validated')
        self.assertEqual(self.metadata.read_text(), 'MonkeySSH')
        self.assertFalse((self.dest / MEDIA).exists())

    def conditional_download(self, archive, mode, gh_exit=0):
        # Partial publish calls cmd_download inside `if !`, where Bash disables
        # errexit throughout nested functions. No publish command is invoked.
        options = ['--archive', str(archive)]
        env = os.environ.copy()
        if mode != 'local':
            bindir = self.root / 'bin'
            bindir.mkdir(exist_ok=True)
            gh = bindir / 'gh'
            gh.write_text(
                '#!/bin/bash\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = --dir ]; then shift; dest="$1"; fi\n'
                '  shift\n'
                'done\n'
                'case "$TEST_LAYOUT" in\n'
                '  run-tree) tar -xzf "$TEST_ARCHIVE" -C "$dest" ;;\n'
                '  run-nested) mkdir -p "$dest/store-assets"; '
                'cp "$TEST_ARCHIVE" "$dest/store-assets/store-assets.tar.gz" ;;\n'
                '  *) cp "$TEST_ARCHIVE" "$dest/store-assets.tar.gz" ;;\n'
                'esac\n'
                'exit "$TEST_GH_EXIT"\n'
            )
            gh.chmod(0o755)
            env['PATH'] = str(bindir) + os.pathsep + env['PATH']
            env['TEST_ARCHIVE'] = str(archive)
            env['TEST_LAYOUT'] = mode
            env['TEST_GH_EXIT'] = str(gh_exit)
            options = ['--repo', 'offline/fixture']
            if mode.startswith('run'):
                options += ['--run-id', '123']
        return subprocess.run(
            ['bash', '-c',
             'source "$1" help >/dev/null; shift; '
             'if cmd_download "$@"; then exit 0; else exit 1; fi',
             'store-assets-test', str(SCRIPT), '--output', str(self.dest), *options],
            env=env, capture_output=True, text=True, timeout=15,
        )

    def test_conditional_download_propagates_extraction_failure(self):
        archive = self.archive({MEDIA: b'corrupt'}, self.manifest({MEDIA: b'expected'}))
        for mode in ['local', 'release', 'run', 'run-nested', 'run-tree']:
            with self.subTest(mode=mode):
                result = self.conditional_download(archive, mode)
                self.assert_rejected_without_changes(result)
                self.assertNotIn('Restored store assets', result.stdout)
                self.assertNotIn('Extracted ', result.stdout)

    def publish(self, generate, platform, *, missing_screenshots=False):
        events = self.root / 'publish-events'
        events.write_text('')
        env = dict(os.environ, TEST_EVENTS=str(events),
                   TEST_MISSING='true' if missing_screenshots else 'false')
        result = subprocess.run(
            ['bash', '-c', '''
source "$1" help >/dev/null
shift
repo_slug() { echo offline/fixture; }
require_command() { :; }
gh() { echo "gh $*" >> "$TEST_EVENTS"; }
cmd_download() { echo restore >> "$TEST_EVENTS"; }
python3() { echo "python $*" >> "$TEST_EVENTS"; }
validation_python() { echo python3; }
video_globs() { :; }
git() { echo fixture-commit; }
if [ "$TEST_MISSING" = true ]; then
  count_media_files() { echo 1; }
  assert_screenshots_present() {
    echo "validate $*" >> "$TEST_EVENTS"
    return 17
  }
else
  cmd_package() { echo "package $*" >> "$TEST_EVENTS"; }
fi
cmd_publish "$@"
''', 'store-assets-test', str(SCRIPT), '--generate', generate,
             '--platform', platform, '--no-workflow',
             '--output', str(self.root / 'store-assets.tar.gz')],
            env=env, capture_output=True, text=True, timeout=15,
        )
        return result, events.read_text().splitlines()

    def test_publish_restores_only_before_partial_generation(self):
        for generate in ('none', 'screenshots', 'videos', 'all'):
            for platform in ('ios', 'android', 'both'):
                with self.subTest(generate=generate, platform=platform):
                    result, events = self.publish(generate, platform)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    expected = []
                    if generate != 'none' and (generate != 'all' or platform != 'both'):
                        expected.append('restore')
                    if generate in ('screenshots', 'all'):
                        expected.append(f'python scripts/generate_store_screenshots.py {platform}')
                    if generate in ('videos', 'all'):
                        expected.append(f'python scripts/generate_store_demo_videos.py {platform}')
                    package = (
                        f'package -o {self.root}/store-assets.tar.gz '
                        '--platform both --require-screenshots'
                    )
                    if generate in ('videos', 'all'):
                        package += ' --require-videos'
                    expected.append(package)
                    self.assertEqual(
                        [event for event in events if event == 'restore'
                         or event.startswith('package ')
                         or (event.startswith('python ') and '--gallery-only' not in event)],
                        expected,
                    )

    def test_publish_local_media_fails_complete_validation_without_restoring(self):
        for platform in ('ios', 'android', 'both'):
            with self.subTest(platform=platform):
                result, events = self.publish('none', platform, missing_screenshots=True)
                self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                self.assertEqual(events, ['validate both'])

    def test_failed_workflow_download_does_not_install_partial_artifact(self):
        files = {MEDIA: b'new screenshot'}
        archive = self.archive(files, self.manifest(files))
        self.assert_rejected_without_changes(
            self.conditional_download(archive, 'run', gh_exit=17))

    def test_conditional_download_accepts_valid_archive(self):
        files = {MEDIA: b'new screenshot'}
        archive = self.archive(files, self.manifest(files))
        for mode in ['local', 'release', 'run', 'run-nested', 'run-tree']:
            with self.subTest(mode=mode):
                result = self.conditional_download(archive, mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.dest / MEDIA).read_bytes(), files[MEDIA])

    def test_missing_manifest_file_is_rejected_before_clearing(self):
        files = {MEDIA: b'new screenshot', MISSING: b'preview'}
        result = self.download(
            self.archive({MEDIA: files[MEDIA]}, self.manifest(files))
        )
        self.assert_rejected_without_changes(result)

    def test_manifest_only_archive_is_rejected_before_clearing(self):
        result = self.download(self.archive({}, self.manifest({MEDIA: b'missing'})))
        self.assert_rejected_without_changes(result)

    def test_manifest_file_count_mismatch_preserves_existing_media(self):
        files = {MEDIA: b'new screenshot'}
        for count in [0, 2]:
            with self.subTest(count=count):
                manifest = self.manifest(files)
                manifest['file_count'] = count
                self.assert_rejected_without_changes(
                    self.download(self.archive(files, manifest)))

    def test_manifest_file_count_requires_an_integer(self):
        files = {MEDIA: b'new screenshot'}
        for count in [True, False, 1.0, '1', None, [], {}]:
            with self.subTest(count=count):
                manifest = self.manifest(files)
                manifest['file_count'] = count
                self.assert_rejected_without_changes(
                    self.download(self.archive(files, manifest)))

    def test_missing_manifest_file_count_preserves_existing_media(self):
        files = {MEDIA: b'new screenshot'}
        manifest = self.manifest(files)
        del manifest['file_count']
        self.assert_rejected_without_changes(
            self.download(self.archive(files, manifest)))

    def test_duplicate_manifest_entries_are_rejected(self):
        files = {MEDIA: b'new screenshot'}
        manifest = self.manifest(files)
        manifest['files'].append(dict(manifest['files'][0]))
        manifest['file_count'] = 2
        self.assert_rejected_without_changes(
            self.download(self.archive(files, manifest))
        )

    def test_destination_ancestor_symlink_is_rejected_before_clearing_any_root(self):
        # Even a root absent from this archive is cleared by restore. Check all
        # managed roots before deleting the earlier iOS screenshots root.
        outside = self.root / 'outside'
        victim = (
            outside / 'fastlane/metadata-production/android/en-US/images'
            / 'phoneScreenshots/old.png'
        )
        victim.parent.mkdir(parents=True)
        victim.write_bytes(b'outside media must survive')
        (self.dest / 'android').symlink_to(outside, target_is_directory=True)
        files = {MEDIA: b'new screenshot'}
        result = self.download(self.archive(files, self.manifest(files)))
        self.assertEqual(victim.read_bytes() if victim.exists() else None,
                         b'outside media must survive')
        self.assert_rejected_without_changes(result)

    def test_destination_non_directory_ancestor_is_rejected_before_clearing(self):
        (self.dest / 'store').write_text('not a directory')
        files = {MEDIA: b'new screenshot', 'store/demo-videos/ads/demo.mp4': b'video'}
        self.assert_rejected_without_changes(
            self.download(self.archive(files, self.manifest(files))))

    def test_destination_manifest_directory_is_rejected_before_clearing(self):
        (self.dest / MANIFEST).mkdir()
        (self.dest / MANIFEST / 'keep.txt').write_text('keep')
        files = {MEDIA: b'new screenshot'}
        self.assert_rejected_without_changes(
            self.download(self.archive(files, self.manifest(files))))

    def test_dangling_destination_ancestor_symlink_is_rejected(self):
        (self.dest / 'android').symlink_to(
            self.root / 'missing', target_is_directory=True
        )
        files = {MEDIA: b'new screenshot'}
        self.assert_rejected_without_changes(
            self.download(self.archive(files, self.manifest(files))))

    def test_managed_root_symlink_is_unlinked_without_following_it(self):
        outside = self.root / 'outside-previews'
        outside.mkdir()
        (outside / 'keep.mov').write_bytes(b'outside')
        previews = self.dest / 'ios/fastlane/app-previews'
        previews.symlink_to(outside, target_is_directory=True)
        files = {MEDIA: b'new screenshot', MISSING: b'preview'}
        result = self.download(self.archive(files, self.manifest(files)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(previews.is_symlink())
        self.assertEqual((outside / 'keep.mov').read_bytes(), b'outside')
        self.assertEqual((self.dest / MISSING).read_bytes(), b'preview')

    def test_valid_manifest_replaces_stale_media_and_preserves_metadata(self):
        files = {MEDIA: b'new screenshot', MISSING: b'preview'}
        result = self.download(self.archive(files, self.manifest(files)))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.stale.exists())
        for name, data in files.items():
            self.assertEqual((self.dest / name).read_bytes(), data)
        self.assertEqual(self.metadata.read_text(), 'MonkeySSH')

    def test_legacy_archive_without_manifest_remains_supported(self):
        result = self.download(self.archive({MEDIA: b'legacy'}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.dest / MEDIA).read_bytes(), b'legacy')
        self.assertFalse(self.stale.exists())

    def test_hash_and_size_mismatch_preserve_existing_media(self):
        files = {MEDIA: b'new screenshot'}
        for field, value in [('sha256', '0' * 64), ('size', 999)]:
            with self.subTest(field=field):
                manifest = self.manifest(files)
                manifest['files'][0][field] = value
                self.assert_rejected_without_changes(
                    self.download(self.archive(files, manifest)))

    def test_unlisted_file_preserves_existing_media(self):
        self.assert_rejected_without_changes(self.download(self.archive(
            {MEDIA: b'new', MISSING: b'extra'}, self.manifest({MEDIA: b'new'}))))

    def test_unsafe_archive_paths_preserve_existing_media(self):
        for name in ['../escape', '/ios/fastlane/screenshots/absolute.png',
                     'ios/fastlane/screenshots/../../escape',
                     'ios/fastlane/metadata-production/name.txt']:
            with self.subTest(name=name):
                self.assert_rejected_without_changes(
                    self.download(self.archive({name: b'bad'}))
                )

    def test_archive_links_preserve_existing_media(self):
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE]:
            with self.subTest(kind=kind):
                self.assert_rejected_without_changes(self.download(self.archive(
                    {MEDIA: b'new'}, links=[(MISSING, MEDIA, kind)])))


if __name__ == '__main__':
    unittest.main()
