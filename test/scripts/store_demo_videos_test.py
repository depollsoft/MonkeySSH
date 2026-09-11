"""Failure-path checks for store video recording."""

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import generate_store_demo_videos as video


class RecordingCleanupTest(unittest.TestCase):
    def test_recording_failures_release_acquired_resources(self):
        for failure in ('build', 'popen', 'start', 'stop'):
            with self.subTest(failure=failure):
                restore = Mock()
                process = Mock(stdout=iter([
                    video.store_screenshots.READY_MARKER + '{"beat":0}\n',
                    video.store_screenshots.DONE_MARKER + '\n',
                ]))
                watchdog, recorder = Mock(), Mock()
                if failure in ('start', 'stop'):
                    getattr(recorder, failure).side_effect = RuntimeError(failure)
                with patch.object(video.store_screenshots, '_flutter_environment', return_value={}), \
                     patch.object(video.store_screenshots, '_capture_defines', return_value=[]), \
                     patch.object(video.store_screenshots, '_flutter_command', side_effect=RuntimeError('build') if failure == 'build' else None, return_value=['flutter']), \
                     patch.object(video, '_suppress_android_error_dialogs', return_value=restore), \
                     patch.object(video, '_dismiss_android_system_dialogs'), \
                     patch.object(video, '_AndroidSystemDialogWatchdog', return_value=watchdog), \
                     patch.object(video.subprocess, 'Popen', side_effect=RuntimeError('popen') if failure == 'popen' else None, return_value=process), \
                     patch.object(video, '_recorder_for_target', return_value=recorder), \
                     patch.object(video.store_screenshots, '_terminate_process') as terminate:
                    with self.assertRaisesRegex(RuntimeError, failure):
                        video._run_flutter_recording(
                            target=video.store_screenshots.TARGETS['android_phone'],
                            device_id='device', demo=Mock(demo_image_b64=''),
                            output_path=Path('/unused.mp4'), scene_hold_ms=1600,
                        )
                restore.assert_called_once_with()
                if failure != 'build':
                    watchdog.stop.assert_called_once_with()
                if failure in ('start', 'stop'):
                    terminate.assert_called_once_with(process, timeout=20)
                    recorder.stop.assert_called_once_with()
                else:
                    terminate.assert_not_called()
