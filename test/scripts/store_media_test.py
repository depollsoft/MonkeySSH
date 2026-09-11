"""Shared store-media subprocess contracts."""

import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import store_media
import validate_store_screenshots as screenshots


class MediaProbeTest(unittest.TestCase):
    def test_ocr_parses_multiple_files(self):
        output = 'FILE\t/one.png\nHello World\nEND_FILE\nFILE\t/two.png\nMore text\nEND_FILE\n'
        with patch.object(store_media.subprocess, 'run', return_value=Mock(stdout=output)) as run:
            self.assertEqual(store_media._ocr_texts([Path('/one.png'), Path('/two.png')]),
                             {Path('/one.png'): 'Hello World', Path('/two.png'): 'More text'})
        self.assertTrue(run.call_args.kwargs['check'])
        self.assertNotIn('stderr', run.call_args.kwargs)  # Swift diagnostics remain visible.

    def test_screenshot_ocr_requires_macos_and_swift(self):
        with patch.object(screenshots.platform, 'system', return_value='Linux'):
            with self.assertRaisesRegex(RuntimeError, 'macOS with Swift/Vision'):
                screenshots._ocr_texts([])

    def test_duration_and_probe_errors(self):
        with patch.object(store_media.shutil, 'which', return_value='/bin/ffprobe'), \
             patch.object(store_media.subprocess, 'run', return_value=Mock(stdout='12.5\n')) as run:
            self.assertEqual(store_media._video_duration(Path('/video.mp4')), 12.5)
            run.side_effect = subprocess.CalledProcessError(1, 'ffprobe', stderr='invalid media')
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                store_media._video_duration(Path('/video.mp4'))
            self.assertEqual(raised.exception.stderr, 'invalid media')

    def test_ocr_rejects_errors_missing_and_unfinished_results(self):
        for output, error in (
            ('FILE\t/bad.png\tERROR\tCould not load image\n', 'OCR failed for /bad.png: Could not load image'),
            ('FILE\t/other.png\nHello\nEND_FILE\n', 'OCR did not return text for /bad.png'),
            ('FILE\t/bad.png\nHello\n', 'OCR did not return text for /bad.png'),
            ('', 'OCR did not return text for /bad.png'),
        ):
            with self.subTest(output=output), patch.object(store_media.subprocess, 'run', return_value=Mock(stdout=output)):
                with self.assertRaisesRegex(ValueError, error):
                    store_media._ocr_texts([Path('/bad.png')])

    def test_ocr_accepts_completed_empty_text(self):
        with patch.object(store_media.subprocess, 'run', return_value=Mock(stdout='FILE\t/blank.png\n\nEND_FILE\n')):
            self.assertEqual(store_media._ocr_texts([Path('/blank.png')]), {Path('/blank.png'): ''})
