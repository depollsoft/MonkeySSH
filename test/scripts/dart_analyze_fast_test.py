"""Tests for scripts/dart_analyze_fast.py parity, invalidation, and daemon lifecycle."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts' / 'dart_analyze_fast.py'
sys.path.insert(0, str(ROOT / 'scripts'))
import dart_analyze_fast  # noqa: E402


class DartAnalyzeFastUnitTest(unittest.TestCase):
    def test_filter_errors_excludes_todos_and_enforces_fatal_flags(self):
        raw = [
            {
                'severity': 'INFO',
                'type': 'TODO',
                'code': 'todo',
                'message': 'TODO: revisit',
                'location': {'file': '/tmp/a.dart', 'startLine': 1, 'startColumn': 1},
            },
            {
                'severity': 'INFO',
                'type': 'LINT',
                'code': 'prefer_const_constructors',
                'message': 'Use const',
                'location': {'file': '/tmp/a.dart', 'startLine': 2, 'startColumn': 3},
            },
        ]
        visible, fatal = dart_analyze_fast.filter_errors(
            raw, fatal_warnings=True, fatal_infos=False
        )
        self.assertEqual([e['code'] for e in visible], ['prefer_const_constructors'])
        self.assertFalse(fatal)

        visible2, fatal2 = dart_analyze_fast.filter_errors(
            raw, fatal_warnings=True, fatal_infos=True
        )
        self.assertEqual([e['code'] for e in visible2], ['prefer_const_constructors'])
        self.assertTrue(fatal2)

    def test_socket_path_stays_under_macos_sun_path_limit(self):
        deep = Path('/' + '/'.join(['very-long-worktree-segment'] * 8))
        sock = dart_analyze_fast.socket_path_for(deep)
        self.assertLess(len(str(sock)), 96)


@unittest.skipUnless(shutil.which('dart'), 'dart SDK is required')
class DartAnalyzeFastIntegrationTest(unittest.TestCase):
    """Runs the real Dart analysis server daemon against a tiny temp Dart package."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.pkg = Path(self._tmp.name).resolve()
        (self.pkg / 'lib').mkdir()
        (self.pkg / '.dart_tool').mkdir()
        (self.pkg / 'pubspec.yaml').write_text(
            'name: fixture_pkg\n'
            'environment:\n'
            '  sdk: ^3.0.0\n',
            encoding='utf-8',
        )
        (self.pkg / 'pubspec.lock').write_text('# fixture\n', encoding='utf-8')
        (self.pkg / '.dart_tool' / 'package_config.json').write_text(
            '{"configVersion": 2, "packages": ['
            '{"name": "fixture_pkg", "rootUri": "../", "packageUri": "lib/", '
            '"languageVersion": "3.0"}'
            ']}\n',
            encoding='utf-8',
        )
        (self.pkg / 'analysis_options.yaml').write_text(
            'linter:\n'
            '  rules:\n'
            '    - avoid_print\n'
            '    - prefer_final_locals\n',
            encoding='utf-8',
        )
        self.clean_file = self.pkg / 'lib' / 'clean.dart'
        self.clean_file.write_text(
            '// TODO: ignored by dart analyze\n'
            'int add(int a, int b) => a + b;\n',
            encoding='utf-8',
        )
        self.env = {
            **os.environ,
            'CI': '',
            'DART_ANALYZE_DAEMON': '1',
            'DART_ANALYZE_DAEMON_IDLE': '60',
        }
        self.addCleanup(self._stop_daemon)

    def _stop_daemon(self):
        subprocess.run(
            [sys.executable, str(SCRIPT), '--root', str(self.pkg), '--stop'],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def _run_fast(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), '--root', str(self.pkg), *args],
            cwd=self.pkg,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def _run_dart_analyze(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ['dart', 'analyze', *args],
            cwd=self.pkg,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_matches_dart_analyze_for_clean_info_warning_error_and_config_reload(self):
        # 1. Clean file with TODO comment: both pass with exit 0.
        fast_clean = self._run_fast('--fatal-warnings', '--fatal-infos', 'lib/clean.dart')
        self.assertEqual(fast_clean.returncode, 0, fast_clean.stdout + fast_clean.stderr)
        dart_clean = self._run_dart_analyze('--fatal-warnings', '--fatal-infos', 'lib/clean.dart')
        self.assertEqual(dart_clean.returncode, 0, dart_clean.stdout + dart_clean.stderr)

        # Verify daemon is running and metadata was written in .dart_tool/.
        status = self._run_fast('--status')
        self.assertEqual(status.returncode, 0, status.stdout)
        self.assertTrue((self.pkg / '.dart_tool' / 'dart_analyze_daemon.json').is_file())

        # 2. Inject INFO lint (avoid_print), WARNING (unused_local_variable),
        #    and ERROR (undefined_identifier) on disk and verify warm daemon
        #    synchronizes disk state immediately without watcher flake.
        self.clean_file.write_text(
            'void f() {\n'
            '  var unusedVal = 1;\n'
            '  print(missingSymbol);\n'
            '}\n',
            encoding='utf-8',
        )
        fast_bad = self._run_fast('--fatal-warnings', '--fatal-infos', 'lib/clean.dart')
        dart_bad = self._run_dart_analyze('--fatal-warnings', '--fatal-infos', 'lib/clean.dart')
        self.assertNotEqual(fast_bad.returncode, 0)
        self.assertNotEqual(dart_bad.returncode, 0)
        for code in ('avoid_print', 'unused_local_variable', 'undefined_identifier'):
            self.assertIn(code, fast_bad.stdout)
            self.assertIn(code, dart_bad.stdout)

        # 3. INFO-only file: fatal when --fatal-infos is set, non-fatal without it.
        self.clean_file.write_text(
            'void logMsg(String s) {\n'
            '  print(s);\n'
            '}\n',
            encoding='utf-8',
        )
        fast_info_fatal = self._run_fast('--fatal-warnings', '--fatal-infos', 'lib/clean.dart')
        self.assertEqual(fast_info_fatal.returncode, 1, fast_info_fatal.stdout)
        self.assertIn('avoid_print', fast_info_fatal.stdout)

        fast_info_ok = self._run_fast('--fatal-warnings', 'lib/clean.dart')
        self.assertEqual(fast_info_ok.returncode, 0, fast_info_ok.stdout)

        # 4. Updating analysis_options.yaml automatically restarts the daemon
        #    and reflects the changed lint rule set.
        (self.pkg / 'analysis_options.yaml').write_text(
            'linter:\n'
            '  rules:\n'
            '    - prefer_final_locals\n',
            encoding='utf-8',
        )
        fast_reloaded = self._run_fast('--fatal-warnings', '--fatal-infos', 'lib/clean.dart')
        self.assertEqual(fast_reloaded.returncode, 0, fast_reloaded.stdout + fast_reloaded.stderr)

    def test_whole_repo_catches_transitive_dependent_error_after_signature_change(self):
        lib_a = self.pkg / 'lib' / 'a.dart'
        lib_b = self.pkg / 'lib' / 'b.dart'
        lib_a.write_text('int compute(int x) => x + 1;\n', encoding='utf-8')
        lib_b.write_text(
            "import 'a.dart';\nint useCompute() => compute(1);\n",
            encoding='utf-8',
        )

        # Warm whole-repo analysis passes initially.
        clean = self._run_fast('--fatal-warnings', '--fatal-infos')
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)

        # Change signature in lib/a.dart (valid by itself) so dependent lib/b.dart breaks.
        lib_a.write_text('int compute(int x, int y) => x + y;\n', encoding='utf-8')
        broken = self._run_fast('--fatal-warnings', '--fatal-infos')
        dart_broken = self._run_dart_analyze('--fatal-warnings', '--fatal-infos')
        self.assertEqual(broken.returncode, 1, broken.stdout + broken.stderr)
        self.assertNotEqual(dart_broken.returncode, 0, dart_broken.stdout + dart_broken.stderr)
        self.assertIn('lib/b.dart', broken.stdout)
        self.assertIn('not_enough_positional_arguments', broken.stdout)
        self.assertIn('not_enough_positional_arguments', dart_broken.stdout)

        # Fixing lib/b.dart makes whole-repo analysis pass again immediately.
        lib_b.write_text(
            "import 'a.dart';\nint useCompute() => compute(1, 2);\n",
            encoding='utf-8',
        )
        fixed = self._run_fast('--fatal-warnings', '--fatal-infos')
        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)


if __name__ == '__main__':
    unittest.main()
