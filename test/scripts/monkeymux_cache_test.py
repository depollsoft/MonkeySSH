"""Exercise the real asset builder's fingerprint and cache reuse decisions."""

import gzip
import hashlib
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
from verify_monkeymux_assets import PLATFORMS, verify


class MonkeyMuxCacheTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'scripts').mkdir()
        for name in ['build_monkeymux_assets.sh', 'ensure_monkeymux_assets.sh',
                     'verify_monkeymux_assets.py', 'deterministic_gzip.go']:
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.remote = self.root / 'remote/monkeymux'
        (self.remote / 'conpty').mkdir(parents=True)
        (self.remote / 'go.mod').write_text('module fixture\n\ngo 1.26.0\ntoolchain go1.26.5\n')
        (self.remote / 'go.sum').write_text('fixture dependency')
        (self.remote / 'main.go').write_text('package main\n')
        (self.remote / 'monkeymux-version.sh').write_text('echo 1.2.3\n')
        (self.remote / 'conpty/payload.dll').write_bytes(b'fixture DLL')
        self.assets = self.root / 'assets/monkeymux'
        entries = []
        for platform in sorted(PLATFORMS):
            payload = f'payload for {platform}'.encode()
            dest = self.assets / f'bin/{platform}/monkeymux.gz'
            dest.parent.mkdir(parents=True)
            dest.write_bytes(gzip.compress(payload))
            entries.append({'platform': platform, 'asset': f'assets/monkeymux/bin/{platform}/monkeymux.gz',
                            'encoding': 'gzip', 'size': len(payload),
                            'sha256': hashlib.sha256(payload).hexdigest()})
        self.manifest = {'version': '1.2.3', 'entries': entries}
        self.write_manifest()
        self.payloads = {path.relative_to(self.assets): path.read_bytes()
                         for path in self.assets.glob('bin/*/monkeymux.gz')}
        self.stamp = self.assets / '.build-inputs.sha256'
        self.stamp.write_text(self.fingerprint() + '\n')
        # Any attempt to compile is observable, without requiring a Go install
        # or cross-compiling six binaries for every cache regression case.
        bindir = self.root / 'bin'
        bindir.mkdir()
        go = bindir / 'go'
        go.write_text('#!/bin/sh\necho "compile requested" >&2\nexit 42\n')
        go.chmod(0o755)
        self.env = {**os.environ, 'PATH': f'{bindir}{os.pathsep}{os.environ.get("PATH", os.defpath)}'}

    def builder(self, *args):
        return subprocess.run(['bash', str(self.root / 'scripts/build_monkeymux_assets.sh'), *args],
                              capture_output=True, text=True, env=getattr(self, 'env', None))

    def fingerprint(self):
        result = self.builder('--print-fingerprint')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r'^[0-9a-f]{64}$')
        return result.stdout.strip()

    def write_manifest(self):
        (self.assets / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_valid_cache_skips_go_entirely(self):
        result = self.builder()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('assets are current', result.stdout)

    def test_all_build_inputs_invalidate_the_fingerprint(self):
        paths = ['remote/monkeymux/main.go', 'remote/monkeymux/go.sum',
                 'remote/monkeymux/go.mod', 'remote/monkeymux/conpty/payload.dll',
                 'remote/monkeymux/monkeymux-version.sh',
                 'scripts/build_monkeymux_assets.sh', 'scripts/ensure_monkeymux_assets.sh',
                 'scripts/deterministic_gzip.go', 'scripts/verify_monkeymux_assets.py']
        for path in paths:
            with self.subTest(path=path):
                before = self.fingerprint()
                target = self.root / path
                original = target.read_bytes()
                target.write_bytes(original + b'\n# modified input\n')
                self.assertNotEqual(before, self.fingerprint())
                target.write_bytes(original)

    def test_go_test_edits_do_not_invalidate_the_fingerprint(self):
        before = self.fingerprint()
        test = self.remote / 'main_test.go'
        for content in ['package main\n', 'package main\n// changed test\n']:
            test.write_text(content)
            self.assertEqual(before, self.fingerprint())
        self.assertEqual(self.builder().returncode, 0)

    def test_conpty_files_remain_packaged_even_with_test_or_documentation_names(self):
        for name in ['payload_test.go', 'README.md']:
            with self.subTest(name=name):
                before = self.fingerprint()
                (self.remote / 'conpty' / name).write_text('packaged input')
                self.assertNotEqual(before, self.fingerprint())

    def test_app_only_edits_and_checkout_location_do_not_invalidate(self):
        before = self.fingerprint()
        (self.root / 'lib').mkdir()
        (self.root / 'lib/main.dart').write_text('changed app')
        (self.remote / 'README.md').write_text('changed documentation')
        self.assertEqual(before, self.fingerprint())
        clone = self.root / 'another-checkout'
        shutil.copytree(self.root / 'scripts', clone / 'scripts')
        shutil.copytree(self.root / 'remote', clone / 'remote')
        result = subprocess.check_output(['bash', str(clone / 'scripts/build_monkeymux_assets.sh'),
                                          '--print-fingerprint'], text=True)
        self.assertEqual(before, result.strip())

    def test_missing_stamp_missing_payload_and_corruption_request_a_rebuild(self):
        payload = self.assets / 'bin/linux-amd64/monkeymux.gz'
        for scenario in ['stamp', 'missing', 'corrupt']:
            with self.subTest(scenario=scenario):
                self.stamp.write_text(self.fingerprint() + '\n')
                for relative, data in self.payloads.items():
                    dest = self.assets / relative
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(data)
                if scenario == 'stamp':
                    self.stamp.unlink()
                elif scenario == 'missing':
                    payload.unlink()
                else:
                    payload.write_bytes(b'corrupt compressed file')
                result = self.builder()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('compile requested', result.stderr)
                self.assertFalse(self.stamp.exists())

    def test_stale_input_stamp_requests_a_rebuild(self):
        (self.remote / 'main.go').write_text('package main\n// changed\n')
        result = self.builder()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compile requested', result.stderr)
        self.assertFalse(self.stamp.exists())

    def test_manifest_version_hash_size_and_target_set_are_checked(self):
        for scenario in ['version', 'hash', 'size', 'duplicate', 'path']:
            with self.subTest(scenario=scenario):
                original = json.loads(json.dumps(self.manifest))
                if scenario == 'version':
                    self.manifest['version'] = '0.0.0'
                elif scenario == 'hash':
                    self.manifest['entries'][0]['sha256'] = '0' * 64
                elif scenario == 'size':
                    self.manifest['entries'][0]['size'] += 1
                elif scenario == 'duplicate':
                    self.manifest['entries'][0] = self.manifest['entries'][1]
                else:
                    self.manifest['entries'][0]['asset'] = '../../outside'
                self.write_manifest()
                with self.assertRaises(ValueError):
                    verify(self.assets, '1.2.3')
                self.manifest = original
                self.write_manifest()


if __name__ == '__main__':
    unittest.main()
