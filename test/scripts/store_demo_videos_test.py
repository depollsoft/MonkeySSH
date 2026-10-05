"""Failure-path checks for store video recording."""

import re
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import generate_store_demo_videos as video
import validate_store_demo_videos as validator


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
                else:
                    terminate.assert_not_called()
                # stop() collects the recording, so it must not run after a
                # failed start() and replace that error with its own.
                if failure == 'stop':
                    recorder.stop.assert_called_once_with()
                else:
                    recorder.stop.assert_not_called()

    def test_android_recorder_start_failure_reaps_and_stop_is_a_no_op(self):
        with patch.object(video.store_screenshots, '_adb_path', return_value=Path('/adb')):
            recorder = video._AndroidScreenRecorder(
                device_id='device', output_path=Path('/unused.mp4'), size=(720, 1280))
        process = Mock()
        with patch.object(video.subprocess, 'Popen', return_value=process), \
             patch.object(recorder, '_wait_for_remote_pid', side_effect=RuntimeError('timed out')), \
             patch.object(video.store_screenshots, '_terminate_process') as terminate, \
             patch.object(video.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                recorder.start()
            terminate.assert_called_once_with(process, timeout=5)
            recorder.stop()
            run.assert_not_called()


class BeatTimingTest(unittest.TestCase):
    def test_incomplete_or_extra_beats_fail_instead_of_even_slicing(self):
        count = len(video._promo_segments())
        complete = {beat: float(beat) for beat in range(1, count + 1)}
        self.assertEqual(video._compute_beat_offsets(complete, count),
                         [float(beat) for beat in range(count)])
        for beats in ({k: v for k, v in complete.items() if k != 3},
                      {**complete, count + 1: 99.0}, {}):
            with self.subTest(beats=sorted(beats)):
                with self.assertRaisesRegex(RuntimeError, 'expected'):
                    video._compute_beat_offsets(beats, count)

    def test_validator_slots_match_generated_outputs(self):
        generated = {}
        for target in video.TARGETS.values():
            for output in target.outputs:
                size = {
                    'app_preview': (output.width, output.height),
                    'portrait_ads': target.screenshot_target.size,
                    'landscape_promo': (1920, 1080),
                }[output.kind]
                generated[output.rel_path] = size
        layout = video._landscape_layout()
        self.assertEqual((layout['canvas_width'], layout['canvas_height']), (1920, 1080))
        self.assertEqual(generated, {t.rel_path: t.size for t in validator.TARGETS})

    def test_app_emits_one_beat_per_caption_segment(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        beats = sorted(int(beat) for beat in re.findall(r'_emitBeat\((\d+)\)', source))
        self.assertEqual(beats, list(range(1, len(video._promo_segments()) + 1)))
