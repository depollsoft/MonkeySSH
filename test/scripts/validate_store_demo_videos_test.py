"""Store video validation subprocess and threshold contracts."""

import json
import sys
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import validate_store_demo_videos as videos

SCENES = '[metadata@scenes @ 0x1] lavfi.scene_score=0.2\n'


class VideoValidationTest(unittest.TestCase):
    def test_missing_tools_fail_before_probing(self):
        for missing in ('ffmpeg', 'ffprobe'):
            with self.subTest(missing=missing), \
                 patch.object(sys, 'argv', ['validate']), \
                 patch.object(videos.shutil, 'which', side_effect=lambda tool: None if tool == missing else tool), \
                 patch.object(videos, '_probe_videos') as probe:
                with self.assertRaisesRegex(RuntimeError, 'requires ffmpeg and ffprobe'):
                    videos.main()
                probe.assert_not_called()

    def test_one_probe_and_scan_per_target_and_required_audio(self):
        for platform, has_audio, probes, scans in (('all', True, 5, 5), ('all', False, 5, 0), ('android', False, 2, 2)):
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == 'ffmpeg':
                    return Mock(stderr=SCENES * 4)
                target = next(t for t in videos.TARGETS if str(command[-1]).endswith(t.rel_path))
                streams = [{'codec_type': 'audio'}] if has_audio else []
                streams.append(dict(codec_type='video', width=target.size[0], height=target.size[1], duration='N/A'))
                return Mock(stdout=json.dumps(dict(streams=streams, format={'duration': '20'})))
            with self.subTest(platform=platform, has_audio=has_audio), \
                 patch.object(sys, 'argv', ['validate', platform]), \
                 patch.object(videos.shutil, 'which', side_effect=lambda tool: tool), \
                 patch.object(Path, 'exists', return_value=True), \
                 patch.object(Path, 'stat', return_value=Mock(st_size=500_000)), \
                 patch.object(videos.subprocess, 'run', side_effect=run), \
                 patch.object(videos, '_validate_sampled_ocr_content') as ocr:
                with nullcontext() if scans else self.assertRaisesRegex(ValueError, 'has no audio track'):
                    videos.main()
                self.assertEqual(sum(c[0] == 'ffprobe' for c in calls), probes)
                self.assertEqual(sum(c[0] == 'ffmpeg' for c in calls), scans)
                if scans:
                    self.assertEqual({i.duration for i in ocr.call_args.args[1].values()}, {20})
                else:
                    ocr.assert_not_called()

    def test_motion_thresholds_and_branch_isolation(self):
        cases = [
            ('[blackdetect@full @ 0x1] black_duration:1.0', 4, 0, None),
            ('[blackdetect@full @ 0x1] black_duration:0.6\n[blackdetect@full @ 0x1] black_duration:0.5', 4, 0, 'near-black'),
            ('[freezedetect@full @ 0x1] freeze_start: 0', 4, 0, None),
            ('[freezedetect@full @ 0x1] freeze_start: 0', 4, 2, 'frozen/static'),
            ('[freezedetect@live @ 0x1] freeze_duration: 2', 4, 2, None),
            ('[freezedetect@live @ 0x1] freeze_duration: 19.4', 4, 0, None),
            ('[freezedetect@live @ 0x1] freeze_duration: 19.41', 4, 0, 'live app region is frozen'),
            ('[freezedetect@full @ 0x1] freeze_duration: 20', 4, 0, None),
            ('[freezedetect@live @ 0x1] freeze_start: 0', 4, 0, 'live app region is frozen'),
            ('[freezedetect@live @ 0x1] freeze_start: 0\n[freezedetect@live @ 0x1] freeze_end: 2\n[freezedetect@live @ 0x1] freeze_duration: 2', 4, 0, None),
            ('[metadata@other @ 0x1] lavfi.scene_score=0.9', 3, 0, 'only changes 3'),
            ('', 0, 0, 'only changes 0'),
            ('', 4, 0, None),
        ]
        for log, scenes, target, error in cases:
            with self.subTest(log=log, scenes=scenes, target=target), \
                 patch.object(videos.subprocess, 'run', return_value=Mock(stderr=log + '\n' + SCENES * scenes)) as run:
                with self.assertRaisesRegex(ValueError, error) if error else nullcontext():
                    videos._validate_dynamics('ffmpeg', Path('/video.mov'), target=videos.TARGETS[target],
                                              info=videos.VideoInfo(886, 1920, 20, True))
                run.assert_called_once()
                graph = run.call_args.args[0][6]
                for threshold in ('blackdetect@full=d=0.4:pic_th=0.98', 'freezedetect@full=n=0.003:d=2.0',
                                  'freezedetect@live=n=0.003:d=1.0', "select='gt(scene,0.10)'"):
                    self.assertIn(threshold, graph)

    def test_video_ocr_requires_every_sample_and_rejects_bad_content(self):
        info = videos.VideoInfo(886, 1920, 20, True)
        for content, error in ((None, 'OCR did not return text'), ('Close app', 'Android system error dialog'),
                               ('/Users/depoll', 'private local path'), ('sk-ant-', 'visible API key')):
            with self.subTest(content=content), \
                 patch.object(videos.platform, 'system', return_value='Darwin'), \
                 patch.object(videos.shutil, 'which', return_value='swift'), \
                 patch.object(videos.subprocess, 'run', return_value=Mock(stdout='')) as run:
                ocr = (patch.object(videos, '_ocr_texts', side_effect=lambda paths: dict.fromkeys(paths, content))
                       if content is not None else nullcontext())
                with ocr, self.assertRaisesRegex(ValueError, error):
                    videos._validate_sampled_ocr_content('ffmpeg', {Path('/video.mov'): info})
                captures = [c.args[0] for c in run.call_args_list if c.args[0][0] == 'ffmpeg']
                self.assertEqual([c[5] for c in captures], ['2.000', '5.000', '8.400', '11.600', '15.000', '18.000'])
