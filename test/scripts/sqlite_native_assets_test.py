"""Offline SQLite prefetch tests, with no Flutter or network access."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/cache_sqlite3_native_assets.sh'
PAYLOAD = b'verified sqlite fixture'
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


class SqliteNativeAssetsTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        script = self.root / 'scripts' / SCRIPT.name
        script.parent.mkdir()
        shutil.copyfile(SCRIPT, script)
        self.script = script
        package = self.root / 'sqlite3'
        hashes = package / 'lib/src/hook/asset_hashes.dart'
        hashes.parent.mkdir(parents=True)
        hashes.write_text(
            "const releaseTag = 'fixture';\n"
            f"const hashes = {{'libsqlite3.x64.linux.so': '{DIGEST}'}};\n"
        )
        config = self.root / '.dart_tool/package_config.json'
        config.parent.mkdir()
        config.write_text(json.dumps({'packages': [
            {'name': 'sqlite3', 'rootUri': package.as_uri()},
        ]}))
        self.dest = self.root / (
            f'.dart_tool/hooks_runner/shared/sqlite3/build/download-{DIGEST[:8]}'
            '/libsqlite3.so'
        )
        self.payload = self.root / 'payload'
        self.payload.write_bytes(PAYLOAD)
        bindir = self.root / 'bin'
        bindir.mkdir()
        curl = bindir / 'curl'
        curl.write_text('''#!/bin/bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then shift; output="$1"; fi
  shift
done
printf '%s\n' "$output" >> "$TEST_ROOT/downloads"
if [ "${TEST_CONCURRENT:-0}" = 1 ]; then
  # Both clients must select their temporary file before either writes it.
  for i in {1..500}; do
    [ "$(wc -l < "$TEST_ROOT/downloads")" -ge 2 ] && break
    /bin/sleep 0.01
  done
  [ "$(wc -l < "$TEST_ROOT/downloads")" -ge 2 ] || exit 99
fi
cp "$TEST_PAYLOAD" "$output"
''')
        curl.chmod(0o755)
        # Keep failure-path retries fast and offline.
        sleep = bindir / 'sleep'
        sleep.write_text('#!/bin/bash\nexit 0\n')
        sleep.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                        TEST_ROOT=str(self.root), TEST_PAYLOAD=str(self.payload))
        self.env.pop('SQLITE3_NATIVE_ASSETS_VERIFY_ONLY', None)

    def run_script(self):
        return subprocess.run(['bash', str(self.script), 'linux-x64'],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def test_download_and_reuse_verified_cache(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.dest.read_bytes(), PAYLOAD)
        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn('Reusing cached', second.stdout)
        self.assertEqual(len((self.root / 'downloads').read_text().splitlines()), 1)
        self.assertEqual(list(self.dest.parent.glob('*.tmp*')), [])

    def test_replaces_corrupt_cache_only_after_verification(self):
        self.dest.parent.mkdir(parents=True)
        self.dest.write_bytes(b'old corrupt cache')
        self.payload.write_bytes(b'bad download')
        failed = self.run_script()
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.dest.read_bytes(), b'old corrupt cache')
        self.payload.write_bytes(PAYLOAD)
        recovered = self.run_script()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(self.dest.read_bytes(), PAYLOAD)
        self.assertEqual(list(self.dest.parent.glob('*.tmp*')), [])

    def test_verify_only_does_not_download_or_write_cache(self):
        self.env['SQLITE3_NATIVE_ASSETS_VERIFY_ONLY'] = '1'
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.dest.parent.exists())
        self.assertFalse((self.root / 'downloads').exists())

    def test_rejects_bad_hash_and_removes_temporary_downloads(self):
        self.payload.write_bytes(b'corrupt fixture')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.dest.exists())
        self.assertEqual(list(self.dest.parent.glob('*.tmp*')), [])

    def test_concurrent_downloads_use_distinct_temporary_files(self):
        self.env['TEST_CONCURRENT'] = '1'
        processes = [subprocess.Popen(
            ['bash', str(self.script), 'linux-x64'], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) for _ in range(2)]
        try:
            results = [process.communicate(timeout=20) for process in processes]
            for process, result in zip(processes, results):
                self.assertEqual(process.returncode, 0, result)
            paths = (self.root / 'downloads').read_text().splitlines()
            self.assertEqual(len(paths), 2, paths)
            self.assertEqual(len(set(paths)), 2, paths)
            self.assertEqual(self.dest.read_bytes(), PAYLOAD)
            self.assertEqual(list(self.dest.parent.glob('*.tmp*')), [])
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == '__main__':
    unittest.main()
