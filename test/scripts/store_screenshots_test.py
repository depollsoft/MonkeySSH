"""Store caption and scene-contract checks. Run on macOS with Pillow."""

import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import generate_store_screenshots as capture
import validate_store_screenshots as validate


class ProCaptionTest(unittest.TestCase):
    def test_every_target_preserves_complete_app_and_dimensions(self):
        for target in capture.TARGETS.values():
            for scene in capture.PRO_SCENE_CAPTIONS:
                with self.subTest(target=target.name, scene=scene):
                    source = Image.new('RGB', target.size, '#123456')
                    before = source.copy()
                    result = capture._add_pro_caption(source, scene)
                    self.assertEqual(result.size, target.size)
                    self.assertIsNone(ImageChops.difference(source, before).getbbox())
                    width, height = source.size
                    band_height = round(width * 0.16)
                    app = ImageOps.contain(
                        source, (width, height - band_height),
                        Image.Resampling.LANCZOS,
                    )
                    x = (width - app.width) // 2
                    actual = result.crop((x, 0, x + app.width, app.height))
                    self.assertIsNone(ImageChops.difference(actual, app).getbbox())
                    badge = (round(width * 0.88), height - band_height + round(width * 0.04))
                    self.assertEqual(result.getpixel(badge), (88, 163, 140))

    def test_android_capture_rejects_another_foreground_app(self):
        states = [
            ('topResumedActivity=ActivityRecord{ xyz.depollsoft.monkeyssh/.MainActivity }', True),
            ('mResumedActivity: ActivityRecord{ xyz.depollsoft.monkeyssh/.MainActivity }', True),
            ('topResumedActivity=ActivityRecord{ another.app/.MainActivity }', False),
            ('mResumedActivity: ActivityRecord{ xyz.depollsoft.monkeyssh/.MainActivity }\n'
             'topResumedActivity=ActivityRecord{ another.app/.MainActivity }', False),
            ('', False),
        ]
        for activity, valid in states:
            with self.subTest(activity=activity):
                with patch.object(capture, '_adb_path', return_value=Path('/test/adb')):
                    with patch.object(capture.subprocess, 'check_output', return_value=activity):
                        if valid:
                            capture._assert_android_capture_foreground('emulator-5580')
                        else:
                            with self.assertRaisesRegex(RuntimeError, 'dedicated emulator'):
                                capture._assert_android_capture_foreground('emulator-5580')

    def test_gallery_uses_current_capture_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'ios/fastlane/screenshots/en-US'
            folder.mkdir(parents=True)
            for index, color in ((7, '#123456'), (8, '#654321')):
                Image.new('RGB', (1320, 2868), color).save(folder / f'{index:02d}_iphone_6_9.png')
            with patch.object(capture, 'ROOT', root):
                output = capture._write_iphone_gallery()
                with Image.open(output) as image:
                    self.assertEqual(image.size, (1356, 1458))
                    self.assertEqual(image.getpixel((100, 100)), (18, 52, 86))
                    self.assertEqual(image.getpixel((800, 100)), (101, 67, 33))
                (folder / '08_iphone_6_9.png').unlink()
                with self.assertRaises(FileNotFoundError):
                    capture._write_iphone_gallery()

    def test_scene_option_matches_registered_app_scenes(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        block = source.split('const _sceneNames = <String>[', 1)[1].split('];', 1)[0]
        scenes = re.findall(r"'([^']+)'", block)
        for scene in scenes:
            with patch.object(sys, 'argv', ['capture', 'ios', '--scene', scene]):
                self.assertEqual(capture._parse_args().scene, scene)
        self.assertIn('_sceneNames[index] != _selectedScene', source)
        script = (ROOT / 'scripts/generate_store_screenshots.py').read_text()
        self.assertIn('STORE_SCREENSHOT_SCENE={scene}', script)

    def test_gallery_only_never_launches_a_demo_workspace(self):
        with patch.object(sys, 'argv', ['capture', '--gallery-only']):
            with patch.object(capture, '_write_iphone_gallery') as gallery:
                with patch.object(capture, 'StoreDemoEnvironment') as environment:
                    capture.main()
                    gallery.assert_called_once_with()
                    environment.assert_not_called()

    def test_caption_text_fits_every_target(self):
        for target in capture.TARGETS.values():
            width = target.size[0]
            title_font = ImageFont.load_default(size=round(width * 0.035))
            subtitle_font = ImageFont.load_default(size=round(width * 0.023))
            for title, subtitle in capture.PRO_SCENE_CAPTIONS.values():
                self.assertLess(title_font.getlength(title), width * 0.8)
                self.assertLess(subtitle_font.getlength(subtitle), width * 0.93)

    def test_eight_scenes_registered_in_capture_and_validator(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        scene_block = source.split('const _sceneNames = <String>[', 1)[1].split('];', 1)[0]
        scenes = re.findall(r"'([^']+)'", scene_block)
        self.assertEqual(len(scenes), validate.SCREENSHOT_COUNT)
        self.assertEqual(scenes[-2:], ['native_copilot', 'agent_management'])
        announced = re.findall(r'await _announceScene\((\d+)\)', source)
        self.assertEqual([int(index) for index in announced], list(range(8)))

    def test_agent_scenes_resolve_live_names_not_stale_numeric_indices(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        self.assertNotRegex(source, r'_selectMonkeyMuxWindow\(\d+')
        for agent in ('copilot', 'claude', 'opencode'):
            self.assertIn(f"_selectMonkeyMuxWindow('{agent}')", source)
        self.assertIn('window.name == windowName', source)
        self.assertIn('selectWindow(session, _muxSessionName, window.index)', source)
        self.assertNotIn('onTimeout: () {}', source)

    def test_claude_trust_prompt_handles_old_and_new_defaults(self):
        for prompt, keys in (
            ('❯ No, exit\n  Yes, I trust this folder', ['Down', 'Enter']),
            ('❯ Yes, I trust this folder\n  No, exit', ['Enter']),
        ):
            with self.subTest(prompt=prompt):
                demo = object.__new__(capture.StoreDemoEnvironment)
                with patch.object(demo, '_capture_visible_pane', side_effect=[prompt, 'Claude Code shortcuts']):
                    with patch.object(demo, '_monkeymux_send_keys') as send:
                        with patch.object(capture.time, 'sleep'):
                            demo._drive_claude_to_ready_prompt()
                        self.assertEqual(
                            [call.args for call in send.call_args_list],
                            [('claude', key) for key in keys],
                        )

    def test_claude_ready_with_legacy_and_current_footers(self):
        for text in (
            'Claude Code v2.1.0\n❯\n? for shortcuts',
            'ClaudeCodev2.1.270\nSonnet5\nClaudeCodeWorkspace─\n❯ Try"fixlint"\n←foragents',
        ):
            with self.subTest(text=text):
                self.assertTrue(capture._claude_prompt_ready(text))
                demo = object.__new__(capture.StoreDemoEnvironment)
                with patch.object(demo, '_capture_visible_pane', return_value=text):
                    demo._drive_claude_to_ready_prompt()

    def test_claude_setup_is_not_a_ready_prompt(self):
        self.assertFalse(capture._claude_prompt_ready(
            "Claude Code'll be able to read files\n❯ No, exit\nYes, I trust this folder",
        ))
        self.assertFalse(capture._claude_prompt_ready('Claude Code v2.1.270'))

    def test_claude_capture_requires_a_finished_response(self):
        prompt = 'ClaudeCodeWorkspace\n❯\n←foragents'
        self.assertFalse(capture._claude_response_ready(prompt))
        response = '⏺ Sessions keep running.\n✻Bakedfor2s·done1:34PM\n' + prompt
        self.assertTrue(capture._claude_response_ready(response))
        self.assertFalse(capture._claude_response_ready(response + '\nesctointerrupt'))

    def test_claude_auth_failure_is_actionable_without_exposing_pane(self):
        demo = object.__new__(capture.StoreDemoEnvironment)
        text = 'ClaudeCodeWorkspace\n❯\nauthenticationrejected(401)\nprivate content'
        with patch.object(demo, '_capture_visible_pane', return_value=text):
            with self.assertRaisesRegex(RuntimeError, 'capture authentication failed') as error:
                demo._drive_claude_to_ready_prompt()
        self.assertNotIn('private content', str(error.exception))

    def test_native_scene_has_no_badge_when_available_free(self):
        self.assertNotIn('native_copilot', capture.PRO_SCENE_CAPTIONS)
        self.assertEqual(set(capture.PRO_SCENE_CAPTIONS), {'agent_management'})
        path = ROOT / 'ios/fastlane/screenshots/en-US/07_iphone_6_9.png'
        valid = 'Message the agent reconnect'
        with patch.object(validate, '_ocr_texts', return_value={path: valid}):
            validate._validate_ocr_content([path])
        for missing in ('Message the agent', 'reconnect'):
            with self.subTest(missing=missing):
                with patch.object(validate, '_ocr_texts', return_value={path: valid.replace(missing, '')}):
                    with self.assertRaisesRegex(ValueError, 'missing expected'):
                        validate._validate_ocr_content([path])

    def test_screenshot_ocr_uses_shared_completeness_check(self):
        path = ROOT / 'ios/fastlane/screenshots/en-US/08_iphone_6_9.png'
        with patch.object(validate.platform, 'system', return_value='Darwin'), \
             patch.object(validate.shutil, 'which', return_value='swift'), \
             patch.object(validate.store_media.subprocess, 'run', return_value=Mock(stdout='')):
            with self.assertRaisesRegex(ValueError, 'OCR did not return text for .*08_iphone_6_9.png'):
                validate._validate_ocr_content([path])

    def test_manager_scene_requires_real_app_labels_and_badge(self):
        path = ROOT / 'ios/fastlane/screenshots/en-US/08_iphone_6_9.png'
        valid = 'Agent Management PRO Copilot CLI Claude Code'
        with patch.object(validate, '_ocr_texts', return_value={path: valid}):
            validate._validate_ocr_content([path])
        for missing in ('PRO', 'Copilot CLI', 'Claude Code'):
            with self.subTest(missing=missing):
                with patch.object(validate, '_ocr_texts', return_value={path: valid.replace(missing, '') + ' prompt progress provider'}):
                    with self.assertRaisesRegex(ValueError, 'missing expected'):
                        validate._validate_ocr_content([path])


class CopilotFrameTest(unittest.TestCase):
    def check_frame(self, *, color=(64, 196, 255), mode='RGB',
                    edges=('left', 'right', 'bottom'), width=20, height=10,
                    thickness=1, valid=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'frame.png'
            image = Image.new('RGB', (100, 100))
            draw = ImageDraw.Draw(image)
            x, y = 10 + width - 1, 10 + height - 1
            lines = {
                'left': (10, 10, 10, y), 'right': (x, 10, x, y),
                'top': (10, 10, x, 10), 'bottom': (10, y, x, y),
            }
            for edge in edges:
                draw.line(lines[edge], fill=color, width=thickness)
            image.convert(mode, palette=Image.Palette.ADAPTIVE).save(path)
            with patch.object(validate, 'ROOT', root):
                if valid:
                    validate._validate_copilot_image_frame(path)
                else:
                    with self.assertRaisesRegex(ValueError, 'only a sliver'):
                        validate._validate_copilot_image_frame(path)

    def test_three_edges_and_grouped_thick_edges(self):
        self.check_frame()
        self.check_frame(edges=('left', 'top', 'bottom'))
        self.check_frame(thickness=3)

    def test_slivers_and_pixel_count_boundaries(self):
        for edges in (('left', 'bottom'), ('left', 'right'), ('top', 'bottom'), ()):
            with self.subTest(edges=edges):
                self.check_frame(edges=edges, valid=False)
        self.check_frame(width=19, valid=False)
        self.check_frame(height=9, valid=False)

    def test_color_tolerance_boundaries(self):
        for color in ((46, 178, 243), (82, 214, 255)):
            with self.subTest(color=color):
                self.check_frame(color=color)
        for color in ((45, 196, 255), (83, 196, 255), (64, 177, 255),
                      (64, 215, 255), (64, 196, 242)):
            with self.subTest(color=color):
                self.check_frame(color=color, valid=False)

    def test_frame_converts_image_to_rgb(self):
        for mode in ('RGBA', 'P', 'L'):
            with self.subTest(mode=mode):
                self.check_frame(mode=mode, valid=mode != 'L')


class CaptureLaunchTest(unittest.TestCase):
    def test_android_capture_failures_restore_both_settings_once(self):
        target = capture.TARGETS['android_phone']
        for seed in (False, True):
            for stage in ('density', 'build', 'launch', 'capture'):
                for restore_failure in (None, 'size', 'density'):
                    with self.subTest(seed=seed, stage=stage, restore_failure=restore_failure):
                        failure = RuntimeError(f'{stage} failed')
                        cleanup_error = RuntimeError('restore failed')
                        demo = object.__new__(capture.StoreDemoEnvironment)
                        demo._seed_platform = 'android'
                        demo.demo_dir = Path('/demo')
                        demo.demo_image_b64 = 'image'
                        process = Mock(stdout=iter([
                            capture.READY_MARKER + '{"paths":["capture.png"]}\n',
                            capture.DONE_MARKER + '\n',
                        ]))

                        def run(command, **kwargs):
                            if command[-2:] == ['density', target.android_density] and stage == 'density':
                                raise failure
                            if command[-2:] == [restore_failure, 'reset']:
                                raise cleanup_error

                        with patch.object(demo, 'reset_monkeymux'), \
                             patch.object(capture, '_android_device_id', return_value='device'), \
                             patch.object(capture, '_adb_path', return_value=Path('/adb')), \
                             patch.object(capture.subprocess, 'check_output', return_value='Physical: 100'), \
                             patch.object(capture.subprocess, 'run', side_effect=run) as adb, \
                             patch.object(capture, '_capture_defines', return_value=[]), \
                             patch.object(capture, '_flutter_environment', return_value={}), \
                             patch.object(capture, '_build_android_screenshot_apk',
                                          side_effect=failure if stage == 'build' else None,
                                          return_value=Path('/app.apk')) as build, \
                             patch.object(capture.subprocess, 'Popen',
                                          side_effect=failure if stage == 'launch' else None,
                                          return_value=process) as launch, \
                             patch.object(capture, '_capture_native_screenshot', side_effect=failure), \
                             patch.object(capture, '_terminate_process') as terminate, \
                             patch.object(capture.time, 'sleep') as sleep:
                            with self.assertRaises(RuntimeError) as raised:
                                if seed:
                                    demo._capture_light_mode_demo_image()
                                else:
                                    capture._run_target(target, demo)
                        self.assertIs(raised.exception, failure)
                        self.assertEqual(
                            [call.args[0][-2:] for call in adb.call_args_list],
                            [['size', target.android_size], ['density', target.android_density],
                             ['size', 'reset'], ['density', 'reset']],
                        )
                        self.assertEqual(build.call_count, int(stage != 'density'))
                        self.assertEqual(launch.call_count, int(stage in ('launch', 'capture')))
                        if stage == 'capture':
                            terminate.assert_called_once_with(process, timeout=20)
                            sleep.assert_called_once_with(0.5 if seed else 0.4)
                            defines = build.call_args.args[1]
                            if seed:
                                self.assertIn('--dart-define=STORE_SCREENSHOT_THEME_MODE=light', defines)
                                self.assertIn('--dart-define=STORE_SCREENSHOT_SCENE_HOLD_MS=1800', defines)
                            else:
                                self.assertIn('--dart-define=STORE_SCREENSHOT_DEMO_IMAGE_B64=image', defines)
                        else:
                            terminate.assert_not_called()

    def test_android_display_restores_existing_overrides_and_reports_cleanup_failure(self):
        failure = RuntimeError('size restore failed')
        for restore_failure in (None, failure):
            with self.subTest(restore_failure=restore_failure), \
                 patch.object(capture, '_adb_path', return_value=Path('/adb')), \
                 patch.object(capture.subprocess, 'check_output', side_effect=[
                     'Physical size: 100x200\nOverride size: 80x160\n',
                     'Physical density: 100\nOverride density: 90\n',
                 ]), \
                 patch.object(capture.subprocess, 'run', side_effect=[
                     None, None, restore_failure, None,
                 ]) as adb:
                def configure():
                    with capture._android_display_override(capture.TARGETS['android_phone'], 'device'):
                        self.assertEqual(adb.call_count, 2)

                if restore_failure:
                    with self.assertRaises(RuntimeError) as raised:
                        configure()
                    self.assertIs(raised.exception, failure)
                else:
                    configure()
                self.assertEqual(
                    [call.args[0][-2:] for call in adb.call_args_list[2:]],
                    [['size', '80x160'], ['density', '90']],
                )

    def test_capture_marker_failures_terminate_flutter(self):
        for lines, returncode, error in (
            ([capture.ERROR_MARKER + 'scene failed'], 0, RuntimeError),
            ([], 0, RuntimeError),
            ([], 3, capture.subprocess.CalledProcessError),
            ([capture.READY_MARKER + 'invalid json'], 0, ValueError),
        ):
            with self.subTest(lines=lines, returncode=returncode):
                process = Mock(stdout=iter(lines), returncode=returncode)
                with patch.object(capture, '_flutter_environment', return_value={}), \
                     patch.object(capture, '_flutter_command', return_value=['flutter']), \
                     patch.object(capture.subprocess, 'Popen', return_value=process), \
                     patch.object(capture, '_terminate_process') as terminate:
                    with self.assertRaises(error):
                        capture._run_flutter_capture(capture.TARGETS['ios_phone'], 'device', [])
                terminate.assert_called_once_with(process, timeout=20)

    def test_ansi_strips_complete_osc_sequences(self):
        for sequence in ('\x1b]0;hidden title\x07', '\x1b]7;file:///hidden/path\x1b\\'):
            with self.subTest(sequence=sequence):
                self.assertEqual(capture._strip_terminal_output(sequence + '\x1b[32mvisible\x1b[0m'), 'visible')

    def test_control_hello_timeout_closes_process_and_reader(self):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        with patch.object(capture.subprocess, 'Popen', return_value=process), \
             patch.object(capture.threading, 'Thread') as thread, \
             patch.object(capture._MonkeyMuxControl, '_wait_for_hello', side_effect=RuntimeError('hello timeout')):
            with self.assertRaisesRegex(RuntimeError, 'hello timeout'):
                capture._MonkeyMuxControl(Path('/test/monkeymux'), 'demo', {})
        process.stdin.close.assert_called_once()
        process.send_signal.assert_called_once_with(capture.signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=2)
        thread.return_value.join.assert_called_once_with(timeout=1)

    def test_shared_flutter_launch_configuration(self):
        from types import SimpleNamespace
        demo = SimpleNamespace(port=2223, username='demo', private_key_b64='key',
                               host_key_b64='host', host_key_fingerprint='fingerprint',
                               mux_session='demo', demo_dir=Path('/demo'))
        with patch.object(capture, '_java_home_17', return_value='/jdk17'):
            env = capture._flutter_environment()
        self.assertEqual(env['JAVA_HOME'], '/jdk17')
        for target in capture.TARGETS.values():
            with self.subTest(target=target.name), \
                 patch.object(capture, '_build_android_screenshot_apk', return_value=Path('/app.apk')) as build:
                defines = capture._capture_defines(target, demo)
                self.assertEqual(len(defines), 10)
                self.assertIn(f'--dart-define=STORE_SCREENSHOT_TARGET={target.name}', defines)
                self.assertIn('--dart-define=STORE_SCREENSHOT_SSH_PORT=2223', defines)
                self.assertIn('--dart-define=STORE_SCREENSHOT_WORKSPACE_PATH=/demo', defines)
                command = capture._flutter_command(target, 'device', env, defines)
                if target.platform == 'android':
                    self.assertEqual(command, ['flutter', 'run', '-d', 'device', '--use-application-binary', '/app.apk', '--no-pub'])
                    build.assert_called_once_with(env, defines)
                else:
                    self.assertEqual(command, ['flutter', 'run', '--debug', '-d', 'device', '-t', 'tool/store_screenshot_app.dart', *defines, '--flavor', 'production'])
                    build.assert_not_called()

    def test_capture_consumes_markers_and_terminates_flutter(self):
        from unittest.mock import Mock
        demo = Mock(demo_image_b64='image')
        process = Mock(stdout=iter([
            capture.READY_MARKER + '{"paths":["capture.png"],"scene":"hosts"}\n',
            capture.DONE_MARKER + '\n',
        ]))
        with patch.object(capture, '_boot_ios_simulator', return_value='device'), \
             patch.object(capture, '_reset_ios_app_state'), \
             patch.object(capture, '_flutter_environment', return_value={}), \
             patch.object(capture, '_capture_defines', return_value=[]), \
             patch.object(capture, '_flutter_command', return_value=['flutter']) as command, \
             patch.object(capture.subprocess, 'Popen', return_value=process), \
             patch.object(capture, '_capture_native_screenshot') as screenshot, \
             patch.object(capture, '_terminate_process') as terminate, \
             patch.object(capture.time, 'sleep'):
            target = capture.TARGETS['ios_phone']
            capture._run_target(target, demo, scene='hosts')
        screenshot.assert_called_once_with(target=target, device_id='device', paths=[ROOT / 'capture.png'], scene='hosts')
        self.assertIn('--dart-define=STORE_SCREENSHOT_SCENE=hosts', command.call_args.args[3])
        terminate.assert_called_once_with(process, timeout=20)


if __name__ == '__main__':
    unittest.main()
