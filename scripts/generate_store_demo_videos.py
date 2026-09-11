#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import generate_store_screenshots as store_screenshots
from store_media import _video_duration

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCENE_HOLD_MS = 1600
ANDROID_RECORDING_BIT_RATE = 8_000_000
# Store-slot output locations (all relative to the repo root).
APP_PREVIEW_DIR = 'ios/fastlane/app-previews/en-US'
ADS_DIR = 'store/demo-videos/ads'
GOOGLE_PLAY_DIR = 'store/demo-videos/google-play'
MAX_COMPOSE_DURATION = 28.0
# Captions are nudged slightly earlier than their measured beat so they arrive
# with — never after — the scene they describe (covers recorder start latency).
CAPTION_LEAD_S = 0.45
PIXEL_LAUNCHER_PACKAGE = 'com.google.android.apps.nexuslauncher'
OVERLAY_FPS = 30
COPILOT_PROMPT = (
    'Visually describe only what is shown in the attached light-mode '
    'MonkeySSH screenshot and call out the strongest store-listing details. '
    'Do not run tools, read other files, or load skills.'
)
CLAUDE_PROMPT = 'Summarize the riskiest release checks'


@dataclass(frozen=True)
class VideoOutput:
    """One composed deliverable derived from a device's raw recording."""

    kind: str  # 'app_preview' | 'landscape_promo' | 'portrait_ads'
    rel_path: str  # output path relative to the repo root
    width: int = 0  # target resolution for app previews
    height: int = 0


@dataclass(frozen=True)
class DemoVideoTarget:
    name: str
    screenshot_target: store_screenshots.ScreenshotTarget
    outputs: tuple[VideoOutput, ...]


@dataclass(frozen=True)
class PromoSegment:
    eyebrow: str
    headline: str
    body: str
    label: str
    accent: tuple[int, int, int]


TARGETS = {
    'iphone': DemoVideoTarget(
        name='iphone',
        screenshot_target=store_screenshots.TARGETS['ios_phone'],
        outputs=(
            # App Store iPhone slot: full-screen native app at 886x1920.
            VideoOutput('app_preview', f'{APP_PREVIEW_DIR}/iphone_67_1.mov', 886, 1920),
            # Branded portrait canvas, kept for ads/marketing use.
            VideoOutput('portrait_ads', f'{ADS_DIR}/monkeyssh-ios-ads.mp4'),
        ),
    ),
    'ipad': DemoVideoTarget(
        name='ipad',
        screenshot_target=store_screenshots.TARGETS['ios_ipad'],
        outputs=(
            # App Store iPad 13" slot: full-screen native app at 1200x1600.
            VideoOutput('app_preview', f'{APP_PREVIEW_DIR}/ipad_13_1.mov', 1200, 1600),
        ),
    ),
    'android': DemoVideoTarget(
        name='android',
        screenshot_target=store_screenshots.TARGETS['android_phone'],
        outputs=(
            # Google Play preview (uploaded to YouTube): 16:9 landscape promo.
            VideoOutput(
                'landscape_promo',
                f'{GOOGLE_PLAY_DIR}/monkeyssh-google-play-promo.mp4',
            ),
            # Branded portrait canvas, kept for ads/marketing use.
            VideoOutput('portrait_ads', f'{ADS_DIR}/monkeyssh-android-ads.mp4'),
        ),
    ),
}


def main() -> None:
    store_screenshots._prefer_stable_xcode()
    args = _parse_args()
    targets = _targets_for_platform(args.platform)

    with store_screenshots.StoreDemoEnvironment(
        seed_platform=args.platform,
    ) as demo:
        for target in targets:
            _run_target(
                target=target,
                demo=demo,
                scene_hold_ms=args.scene_hold_ms,
            )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Record store-compliant MonkeySSH product demo videos.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which platform to record (ios = iPhone + iPad app previews).',
    )
    parser.add_argument(
        '--scene-hold-ms',
        type=int,
        default=DEFAULT_SCENE_HOLD_MS,
        help='Milliseconds to hold each settled scene while recording.',
    )
    return parser.parse_args()


def _targets_for_platform(platform: str) -> list[DemoVideoTarget]:
    if platform == 'ios':
        return [TARGETS['iphone'], TARGETS['ipad']]
    if platform == 'android':
        return [TARGETS['android']]
    return [TARGETS['iphone'], TARGETS['ipad'], TARGETS['android']]


def _run_target(
    *,
    target: DemoVideoTarget,
    demo: store_screenshots.StoreDemoEnvironment,
    scene_hold_ms: int,
) -> None:
    print(f'Recording {target.name} demo video...')
    demo.reset_monkeymux()
    screenshot_target = target.screenshot_target
    if screenshot_target.platform == 'ios':
        device_id = store_screenshots._boot_ios_simulator(
            store_screenshots._ios_simulator_name(screenshot_target),
        )
        store_screenshots._reset_ios_app_state(device_id)
    else:
        device_id = store_screenshots._android_device_id()

    with store_screenshots._android_display_override(screenshot_target, device_id):
        with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-video-') as tmpdir:
            suffix = '.mov' if screenshot_target.platform == 'ios' else '.mp4'
            raw_path = Path(tmpdir) / f'raw{suffix}'
            beat_offsets = _run_flutter_recording(
                target=screenshot_target,
                device_id=device_id,
                demo=demo,
                output_path=raw_path,
                scene_hold_ms=scene_hold_ms,
            )
            for output in target.outputs:
                _compose_output(
                    output=output,
                    screenshot_target=screenshot_target,
                    raw_path=raw_path,
                    beat_offsets=beat_offsets,
                )


def _compose_output(
    *,
    output: VideoOutput,
    screenshot_target: store_screenshots.ScreenshotTarget,
    raw_path: Path,
    beat_offsets: list[float],
) -> None:
    output_path = ROOT / output.rel_path
    if output.kind == 'app_preview':
        _compose_app_preview(
            raw_path=raw_path,
            output_path=output_path,
            width=output.width,
            height=output.height,
            beat_offsets=beat_offsets,
        )
    elif output.kind == 'landscape_promo':
        _compose_landscape_promo(
            raw_path=raw_path,
            output_path=output_path,
            beat_offsets=beat_offsets,
        )
    elif output.kind == 'portrait_ads':
        _compose_promotional_video(
            target=screenshot_target,
            raw_path=raw_path,
            output_path=output_path,
            beat_offsets=beat_offsets,
        )
    else:
        raise ValueError(f'Unknown video output kind: {output.kind}')


def _run_flutter_recording(
    *,
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    demo: store_screenshots.StoreDemoEnvironment,
    output_path: Path,
    scene_hold_ms: int,
) -> list[float]:
    env = store_screenshots._flutter_environment()
    dart_defines = store_screenshots._capture_defines(target, demo) + [
        '--dart-define=STORE_SCREENSHOT_VIDEO_DEMO=true',
        f'--dart-define=STORE_SCREENSHOT_COPILOT_PROMPT={COPILOT_PROMPT}',
        f'--dart-define=STORE_SCREENSHOT_CLAUDE_PROMPT={CLAUDE_PROMPT}',
        f'--dart-define=STORE_SCREENSHOT_SCENE_HOLD_MS={scene_hold_ms}',
    ]
    if demo.demo_image_b64:
        dart_defines.append(
            f'--dart-define=STORE_SCREENSHOT_DEMO_IMAGE_B64={demo.demo_image_b64}',
        )
    with ExitStack() as cleanup:
        if target.platform == 'android':
            cleanup.callback(_suppress_android_error_dialogs(device_id))
            _dismiss_android_system_dialogs(device_id, force=True)
        command = store_screenshots._flutter_command(target, device_id, env, dart_defines)
        watchdog = (
            _AndroidSystemDialogWatchdog(device_id)
            if target.platform == 'android'
            else None
        )
        if watchdog is not None:
            watchdog.start()
            cleanup.callback(watchdog.stop)
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        cleanup.callback(store_screenshots._terminate_process, process, timeout=20)
        assert process.stdout is not None

        recorder: _NativeScreenRecorder | None = None
        saw_done = False
        failure: str | None = None
        beat_times: dict[int, float] = {}
        for raw_line in process.stdout:
            print(raw_line, end='')
            line = raw_line.strip()
            if store_screenshots.READY_MARKER in line:
                if recorder is None:
                    if target.platform == 'android':
                        _dismiss_android_system_dialogs(device_id, force=True)
                    pending_recorder = _recorder_for_target(
                        target, device_id, output_path,
                    )
                    cleanup.callback(pending_recorder.stop)
                    pending_recorder.start()
                    recorder = pending_recorder
                beat = _parse_beat(line)
                if beat is not None and beat not in beat_times:
                    beat_times[beat] = time.monotonic()
            if store_screenshots.ERROR_MARKER in line:
                failure = line.split(store_screenshots.ERROR_MARKER, 1)[1].strip()
                break
            if store_screenshots.DONE_MARKER in line:
                saw_done = True
                break
    if failure is not None:
        raise RuntimeError(f'{target.name} run failed in the app: {failure}')

    if not saw_done:
        if process.returncode not in (0, None):
            raise subprocess.CalledProcessError(process.returncode, command)
        raise RuntimeError(f'{target.name} run ended before the video was complete')
    if recorder is None:
        raise RuntimeError(f'{target.name} run ended before recording started')
    if not output_path.exists():
        raise RuntimeError(f'{target.name} screen recording was not produced: {output_path}')
    if output_path.stat().st_size < 500_000:
        raise RuntimeError(f'{output_path} is too small to be a real screen recording')

    print(f'Wrote {_display_path(output_path)}')
    return _compute_beat_offsets(beat_times, len(_promo_segments()))


def _parse_beat(line: str) -> int | None:
    """Extracts the promo beat index from a READY marker line, if present."""
    marker_at = line.find(store_screenshots.READY_MARKER)
    if marker_at < 0:
        return None
    payload = line[marker_at + len(store_screenshots.READY_MARKER):].strip()
    if not payload:
        return None
    try:
        data = json.loads(payload)
    except (ValueError, TypeError):
        return None
    beat = data.get('beat') if isinstance(data, dict) else None
    return beat if isinstance(beat, int) else None


def _compute_beat_offsets(
    beat_times: dict[int, float],
    seg_count: int,
) -> list[float]:
    """Returns per-beat offsets (seconds) relative to beat 1.

    Returns an empty list when the beats are incomplete so callers fall back to
    even time-slicing.
    """
    if 1 not in beat_times:
        return []
    origin = beat_times[1]
    offsets: list[float] = []
    for beat in range(1, seg_count + 1):
        if beat not in beat_times:
            return []
        offsets.append(max(0.0, beat_times[beat] - origin))
    return offsets


def _compose_promotional_video(
    *,
    target: store_screenshots.ScreenshotTarget,
    raw_path: Path,
    output_path: Path,
    beat_offsets: list[float] | None = None,
) -> None:
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        raise RuntimeError('ffmpeg is required to compose store demo videos.')

    duration = _video_duration(raw_path)
    duration = min(duration, MAX_COMPOSE_DURATION)
    seg_starts = _segment_starts(beat_offsets or [], len(_promo_segments()), duration)
    with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-compose-') as tmpdir:
        tmpdir_path = Path(tmpdir)
        layout = _promo_layout(target)

        base_path = tmpdir_path / 'base.png'
        _create_promo_base(target, layout).save(base_path)

        frames_dir = tmpdir_path / 'overlay-frames'
        frames_dir.mkdir(parents=True, exist_ok=True)
        _render_overlay_frames(
            target=target,
            layout=layout,
            duration=duration,
            fps=OVERLAY_FPS,
            directory=frames_dir,
            seg_starts=seg_starts,
        )

        screen_w = layout['screen_width']
        screen_h = layout['screen_height']
        screen_x = layout['screen_x']
        screen_y = layout['screen_y']

        command = [
            ffmpeg,
            '-y',
            '-loglevel',
            'error',
            '-i',
            str(raw_path),
            '-loop',
            '1',
            '-t',
            f'{duration:.3f}',
            '-i',
            str(base_path),
            '-framerate',
            str(OVERLAY_FPS),
            '-i',
            str(frames_dir / 'frame-%05d.png'),
        ]

        filter_parts = [
            (
                f'[0:v]scale={screen_w}:{screen_h}:'
                'force_original_aspect_ratio=decrease,setsar=1[app]'
            ),
            # Gentle living color drift plus imperceptible temporal grain keeps
            # the gradient backdrop measurably in motion every frame, even during
            # long static app holds, so freeze validation stays meaningful.
            "[1:v]format=rgba,hue=h='14*sin(2*PI*t/16)':s=1.06,"
            "noise=alls=8:allf=t[bg]",
            (
                f'[bg][app]overlay=x={screen_x}+({screen_w}-w)/2:'
                f'y={screen_y}+({screen_h}-h)/2:shortest=1[comp]'
            ),
            '[comp][2:v]overlay=0:0:shortest=1[ov]',
            '[ov]format=yuv420p[out]',
        ]

        output_path.parent.mkdir(parents=True, exist_ok=True)
        command.extend(
            [
                '-filter_complex',
                ';'.join(filter_parts),
                '-map',
                '[out]',
                '-an',
                '-r',
                '30',
                '-t',
                f'{duration:.3f}',
                '-c:v',
                'libx264',
                '-profile:v',
                'high',
                '-pix_fmt',
                'yuv420p',
                '-movflags',
                '+faststart',
                str(output_path),
            ]
        )
        subprocess.run(command, cwd=ROOT, check=True)

    if output_path.stat().st_size < 500_000:
        raise RuntimeError(f'{output_path} is too small to be a composed demo video')
    print(f'Wrote {_display_path(output_path)}')


def _compose_app_preview(
    *,
    raw_path: Path,
    output_path: Path,
    width: int,
    height: int,
    beat_offsets: list[float] | None = None,
) -> None:
    """Composes an App Store-compliant preview: the full-screen native app at the
    exact device slot resolution, with fading lower-third caption overlays and a
    silent stereo AAC track (Apple validates resolution and prefers an audio
    track). The app fills the frame at native resolution; copy is overlaid for
    muted-autoplay context, per Apple's app preview guidelines."""
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        raise RuntimeError('ffmpeg is required to compose app previews.')
    duration = min(_video_duration(raw_path), MAX_COMPOSE_DURATION)
    seg_starts = _segment_starts(beat_offsets or [], len(_promo_segments()), duration)
    with tempfile.TemporaryDirectory(prefix='monkeyssh-app-preview-') as tmpdir:
        frames_dir = Path(tmpdir) / 'overlay-frames'
        frames_dir.mkdir(parents=True, exist_ok=True)
        _render_app_preview_overlays(
            width=width,
            height=height,
            duration=duration,
            fps=OVERLAY_FPS,
            directory=frames_dir,
            seg_starts=seg_starts,
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        filter_parts = [
            (
                f'[0:v]scale={width}:{height}:force_original_aspect_ratio=increase,'
                f'crop={width}:{height},setsar=1[app]'
            ),
            '[app][1:v]overlay=0:0:shortest=1[ov]',
            '[ov]format=yuv420p[out]',
        ]
        command = [
            ffmpeg,
            '-y',
            '-loglevel',
            'error',
            '-i',
            str(raw_path),
            '-framerate',
            str(OVERLAY_FPS),
            '-i',
            str(frames_dir / 'frame-%05d.png'),
            '-f',
            'lavfi',
            '-i',
            'anullsrc=channel_layout=stereo:sample_rate=48000',
            '-filter_complex',
            ';'.join(filter_parts),
            '-map',
            '[out]',
            '-map',
            '2:a',
            '-r',
            '30',
            '-t',
            f'{duration:.3f}',
            '-c:v',
            'libx264',
            '-profile:v',
            'high',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'aac',
            '-b:a',
            '256k',
            '-ac',
            '2',
            '-movflags',
            '+faststart',
            '-shortest',
            str(output_path),
        ]
        subprocess.run(command, cwd=ROOT, check=True)

    if output_path.stat().st_size < 300_000:
        raise RuntimeError(f'{output_path} is too small to be an app preview')
    print(f'Wrote {_display_path(output_path)}')


def _render_app_preview_overlays(
    *,
    width: int,
    height: int,
    duration: float,
    fps: int,
    directory: Path,
    seg_starts: list[float],
) -> None:
    segments = _promo_segments()
    fonts = {
        'eyebrow': _load_font(max(20, int(width * 0.040)), bold=True, mono=True),
        'headline': _load_font(max(34, int(width * 0.076)), bold=True),
    }
    margin = int(width * 0.062)
    region_w = width - 2 * margin
    layers = [
        _build_app_preview_caption_layer(
            seg, width, height, margin, region_w, fonts,
        )
        for seg in segments
    ]
    frame_count = int(math.ceil(duration * fps)) + 1
    for index in range(frame_count):
        t = min(index / fps, duration)
        frame = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        seg_index = _segment_at(t, seg_starts)
        alpha = _app_preview_caption_alpha(t, seg_index, seg_starts, duration)
        if alpha > 0.01:
            layer = layers[seg_index].copy()
            _scale_alpha(layer, alpha)
            frame.alpha_composite(layer)
        _draw_app_preview_progress(
            frame, t, duration, segments, seg_starts, width, height,
        )
        frame.save(directory / f'frame-{index:05d}.png')


def _build_app_preview_caption_layer(
    segment: PromoSegment,
    width: int,
    height: int,
    margin: int,
    region_w: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> Image.Image:
    layer = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    band_top = int(height * 0.58)
    span = max(height - band_top, 1)
    scrim = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    scrim_draw = ImageDraw.Draw(scrim)
    for y in range(band_top, height):
        ratio = (y - band_top) / span
        alpha = int(200 * (ratio ** 1.5))
        scrim_draw.line([(0, y), (width, y)], fill=(4, 6, 16, alpha))
    layer.alpha_composite(scrim)

    draw = ImageDraw.Draw(layer)
    accent = segment.accent
    eyebrow_font = fonts['eyebrow']
    headline_font = fonts['headline']
    line_spacing = max(4, int(height * 0.006))
    eyebrow = segment.eyebrow.upper()
    eyebrow_h = _text_h(draw, 'Ag', eyebrow_font)
    head_h = _wrapped_text_height(draw, segment.headline, headline_font, region_w, line_spacing)
    gap = int(height * 0.015)
    bottom_pad = int(height * 0.078)
    total = eyebrow_h + gap + head_h
    y0 = height - bottom_pad - total
    rule_w = int(width * 0.10)
    draw.rounded_rectangle(
        [margin, y0 - int(height * 0.018), margin + rule_w, y0 - int(height * 0.014)],
        radius=3,
        fill=(*_lighten(accent), 255),
    )
    draw.text((margin, y0), eyebrow, font=eyebrow_font, fill=(*_lighten(accent), 255))
    _draw_wrapped_text(
        draw,
        segment.headline,
        font=headline_font,
        xy=(margin, y0 + eyebrow_h + gap),
        max_width=region_w,
        fill=(255, 255, 255, 255),
        line_spacing=line_spacing,
    )
    return layer


def _app_preview_caption_alpha(
    t: float,
    seg_index: int,
    seg_starts: list[float],
    duration: float,
) -> float:
    start, seg_len = _segment_span(seg_index, seg_starts, duration)
    local = t - start
    visible = min(seg_len - 0.15, 3.6)
    if visible <= 0 or local < 0 or local > visible:
        return 0.0
    fade_in = 0.4
    fade_out = 0.55
    return min(_clamp01(local / fade_in), _clamp01((visible - local) / fade_out))


def _draw_app_preview_progress(
    frame: Image.Image,
    t: float,
    duration: float,
    segments: list[PromoSegment],
    seg_starts: list[float],
    width: int,
    height: int,
) -> None:
    draw = ImageDraw.Draw(frame)
    accent = segments[_segment_at(t, seg_starts)].accent
    y = height - int(height * 0.024)
    x0 = int(width * 0.062)
    x1 = width - int(width * 0.062)
    thickness = max(3, int(height * 0.0035))
    draw.rounded_rectangle(
        [x0, y - thickness, x1, y + thickness], radius=thickness, fill=(255, 255, 255, 46),
    )
    progress = _clamp01(t / duration) if duration > 0 else 0.0
    fill_x = int(x0 + (x1 - x0) * progress)
    draw.rounded_rectangle(
        [x0, y - thickness, fill_x, y + thickness], radius=thickness, fill=(*accent, 235),
    )


def _compose_landscape_promo(
    *,
    raw_path: Path,
    output_path: Path,
    beat_offsets: list[float] | None = None,
) -> None:
    """Composes a 16:9 landscape branded promo for the Google Play preview slot
    (uploaded to YouTube): the portrait app capture sits in a device frame on the
    left with branded copy on the right. No black bars; the live app is visible
    from the first frame."""
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        raise RuntimeError('ffmpeg is required to compose the landscape promo.')
    duration = min(_video_duration(raw_path), MAX_COMPOSE_DURATION)
    seg_starts = _segment_starts(beat_offsets or [], len(_promo_segments()), duration)
    layout = _landscape_layout()
    with tempfile.TemporaryDirectory(prefix='monkeyssh-landscape-') as tmpdir:
        tmpdir_path = Path(tmpdir)
        base_path = tmpdir_path / 'base.png'
        _create_landscape_base(layout).save(base_path)
        frames_dir = tmpdir_path / 'overlay-frames'
        frames_dir.mkdir(parents=True, exist_ok=True)
        _render_landscape_overlays(
            layout=layout,
            duration=duration,
            fps=OVERLAY_FPS,
            directory=frames_dir,
            seg_starts=seg_starts,
        )
        screen_w = layout['screen_width']
        screen_h = layout['screen_height']
        screen_x = layout['screen_x']
        screen_y = layout['screen_y']
        filter_parts = [
            (
                f'[0:v]scale={screen_w}:{screen_h}:'
                'force_original_aspect_ratio=decrease,setsar=1[app]'
            ),
            "[1:v]format=rgba,hue=h='12*sin(2*PI*t/16)':s=1.05,"
            "noise=alls=6:allf=t[bg]",
            (
                f'[bg][app]overlay=x={screen_x}+({screen_w}-w)/2:'
                f'y={screen_y}+({screen_h}-h)/2:shortest=1[comp]'
            ),
            '[comp][2:v]overlay=0:0:shortest=1[ov]',
            '[ov]format=yuv420p[out]',
        ]
        output_path.parent.mkdir(parents=True, exist_ok=True)
        command = [
            ffmpeg,
            '-y',
            '-loglevel',
            'error',
            '-i',
            str(raw_path),
            '-loop',
            '1',
            '-t',
            f'{duration:.3f}',
            '-i',
            str(base_path),
            '-framerate',
            str(OVERLAY_FPS),
            '-i',
            str(frames_dir / 'frame-%05d.png'),
            '-f',
            'lavfi',
            '-i',
            'anullsrc=channel_layout=stereo:sample_rate=48000',
            '-filter_complex',
            ';'.join(filter_parts),
            '-map',
            '[out]',
            '-map',
            '3:a',
            '-r',
            '30',
            '-t',
            f'{duration:.3f}',
            '-c:v',
            'libx264',
            '-profile:v',
            'high',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'aac',
            '-b:a',
            '256k',
            '-ac',
            '2',
            '-movflags',
            '+faststart',
            '-shortest',
            str(output_path),
        ]
        subprocess.run(command, cwd=ROOT, check=True)

    if output_path.stat().st_size < 300_000:
        raise RuntimeError(f'{output_path} is too small to be a landscape promo')
    print(f'Wrote {_display_path(output_path)}')


def _landscape_layout() -> dict[str, int]:
    width, height = 1920, 1080
    screen_h = int(height * 0.84)
    screen_w = int(screen_h * 1440 / 2560)
    screen_x = int(width * 0.058)
    screen_y = (height - screen_h) // 2
    return {
        'canvas_width': width,
        'canvas_height': height,
        'screen_width': screen_w,
        'screen_height': screen_h,
        'screen_x': screen_x,
        'screen_y': screen_y,
    }


def _create_landscape_base(layout: dict[str, int]) -> Image.Image:
    width = layout['canvas_width']
    height = layout['canvas_height']
    image = Image.new('RGB', (width, height), (8, 10, 24))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        ratio = y / max(height - 1, 1)
        draw.line(
            [(0, y), (width, y)],
            fill=(int(9 + ratio * 14), int(12 + ratio * 8), int(31 + ratio * 22)),
        )
    glows = Image.new('RGBA', image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glows)
    glow_draw.ellipse(
        (-width // 5, -height // 3, width // 2, height // 2), fill=(0, 201, 255, 60),
    )
    glow_draw.ellipse(
        (width // 2, height // 3, width + width // 5, height + height // 4),
        fill=(167, 139, 250, 52),
    )
    image = Image.alpha_composite(
        image.convert('RGBA'), glows.filter(ImageFilter.GaussianBlur(radius=120)),
    )
    draw = ImageDraw.Draw(image)

    brand_font = _load_font(38, bold=True, mono=True)
    tagline_font = _load_font(22)
    panel_x = layout['screen_x'] + layout['screen_width'] + int(width * 0.045)
    draw.text((panel_x, int(height * 0.11)), 'MonkeySSH', font=brand_font, fill=(255, 255, 255))
    draw.text(
        (panel_x, int(height * 0.165)),
        'Run coding agents over SSH, from anywhere',
        font=tagline_font,
        fill=(206, 214, 229),
    )

    screen_x = layout['screen_x']
    screen_y = layout['screen_y']
    screen_width = layout['screen_width']
    screen_height = layout['screen_height']
    halo = Image.new('RGBA', image.size, (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo)
    halo_draw.rounded_rectangle(
        [
            screen_x - 56,
            screen_y - 56,
            screen_x + screen_width + 56,
            screen_y + screen_height + 56,
        ],
        radius=96,
        outline=(0, 201, 255, 90),
        width=20,
    )
    image = Image.alpha_composite(image, halo.filter(ImageFilter.GaussianBlur(radius=48)))
    shadow = Image.new('RGBA', image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    frame_rect = [
        screen_x - 16,
        screen_y - 16,
        screen_x + screen_width + 16,
        screen_y + screen_height + 16,
    ]
    shadow_draw.rounded_rectangle(frame_rect, radius=44, fill=(0, 0, 0, 170))
    image = Image.alpha_composite(image, shadow.filter(ImageFilter.GaussianBlur(radius=24)))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        frame_rect, radius=44, outline=(255, 255, 255, 80), width=4, fill=(5, 8, 22, 255),
    )
    return image


def _render_landscape_overlays(
    *,
    layout: dict[str, int],
    duration: float,
    fps: int,
    directory: Path,
    seg_starts: list[float],
) -> None:
    width = layout['canvas_width']
    height = layout['canvas_height']
    segments = _promo_segments()
    panel_x = layout['screen_x'] + layout['screen_width'] + int(width * 0.045)
    panel_w = width - panel_x - int(width * 0.05)
    fonts = {
        'eyebrow': _load_font(int(height * 0.026), bold=True, mono=True),
        'headline': _load_font(int(height * 0.066), bold=True),
        'body': _load_font(int(height * 0.030)),
        'label': _load_font(int(height * 0.030), bold=True, mono=True),
    }
    text_top = int(height * 0.30)
    frame_count = int(math.ceil(duration * fps)) + 1
    for index in range(frame_count):
        t = min(index / fps, duration)
        frame = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        _draw_landscape_drift_glow(frame, t, segments, seg_starts, layout)
        for seg_index, segment in enumerate(segments):
            start, seg_len = _segment_span(seg_index, seg_starts, duration)
            local = t - start
            fade = 0.5
            if local < -fade or local > seg_len + fade:
                continue
            alpha_in = _clamp01(local / fade)
            alpha_out = (
                1.0
                if seg_index == len(segments) - 1
                else _clamp01((seg_len - local) / fade)
            )
            env = min(alpha_in, alpha_out)
            if env <= 0.01:
                continue
            layer = _render_segment_text(
                segment, seg_index + 1, len(segments), panel_w, fonts,
            )
            _scale_alpha(layer, env)
            slide = int((1 - _ease_in_out(alpha_in)) * 40)
            frame.alpha_composite(layer, (panel_x, text_top + slide))
        _draw_landscape_timeline(
            frame, t, segments, seg_starts, duration, panel_x, panel_w, height, fonts,
        )
        frame.save(directory / f'frame-{index:05d}.png')


def _draw_landscape_drift_glow(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_starts: list[float],
    layout: dict[str, int],
) -> None:
    width = layout['canvas_width']
    height = layout['canvas_height']
    accent = segments[_segment_at(t, seg_starts)].accent
    size = int(width * 0.42)
    sprite = _glow_sprite(accent, size, alpha=44)
    phase = 2 * math.pi * t
    top_x = int(width * 0.72 + math.sin(phase / 9) * width * 0.07) - size // 2
    top_y = int(height * 0.26 + math.cos(phase / 11) * height * 0.06) - size // 2
    frame.alpha_composite(sprite, (top_x, top_y))
    bottom_x = int(width * 0.83 + math.sin(phase / 8 + 1.7) * width * 0.06) - size // 2
    bottom_y = int(height * 0.80 + math.cos(phase / 10) * height * 0.06) - size // 2
    frame.alpha_composite(sprite, (bottom_x, bottom_y))


def _draw_landscape_timeline(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_starts: list[float],
    duration: float,
    panel_x: int,
    panel_w: int,
    height: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> None:
    draw = ImageDraw.Draw(frame)
    count = len(segments)
    seg_index = _segment_at(t, seg_starts)
    accent = segments[seg_index].accent
    track_y = int(height * 0.88)
    x0 = panel_x
    x1 = panel_x + panel_w
    draw.rounded_rectangle([x0, track_y - 4, x1, track_y + 4], radius=4, fill=(255, 255, 255, 46))
    progress = _clamp01(t / duration) if duration > 0 else 0.0
    fill_x = int(x0 + (x1 - x0) * progress)
    draw.rounded_rectangle([x0, track_y - 4, fill_x, track_y + 4], radius=4, fill=(*accent, 235))
    for index, segment in enumerate(segments):
        cx = int(x0 + (x1 - x0) * (index + 0.5) / count)
        if index < seg_index:
            node_r = 10
            color = (*segment.accent, 235)
        elif index == seg_index:
            pulse = 0.5 + 0.5 * math.sin(2 * math.pi * t / 1.3)
            node_r = int(13 + 3 * pulse)
            draw.ellipse(
                [cx - node_r - 8, track_y - node_r - 8, cx + node_r + 8, track_y + node_r + 8],
                outline=(*segment.accent, 180),
                width=3,
            )
            color = (*_lighten(segment.accent), 255)
        else:
            node_r = 8
            color = (255, 255, 255, 70)
        draw.ellipse(
            [cx - node_r, track_y - node_r, cx + node_r, track_y + node_r], fill=color,
        )
    label = segments[seg_index].label
    label_font = fonts['label']
    label_h = _text_h(draw, label, label_font)
    draw.text(
        (x0, track_y - int(height * 0.05) - label_h),
        label,
        font=label_font,
        fill=(*_lighten(accent), 255),
    )



def _promo_layout(target: store_screenshots.ScreenshotTarget) -> dict[str, int]:
    canvas_width, canvas_height = target.size
    if target.platform == 'ios':
        screen_height = int(canvas_height * 0.625)
        top = int(canvas_height * 0.285)
    else:
        screen_height = int(canvas_height * 0.615)
        top = int(canvas_height * 0.292)
    screen_width = int(screen_height * canvas_width / canvas_height)
    screen_width = min(screen_width, int(canvas_width * 0.72))
    left = (canvas_width - screen_width) // 2
    return {
        'canvas_width': canvas_width,
        'canvas_height': canvas_height,
        'screen_width': screen_width,
        'screen_height': screen_height,
        'screen_x': left,
        'screen_y': top,
    }


def _clamp01(value: float) -> float:
    return 0.0 if value < 0 else 1.0 if value > 1 else value


def _ease_in_out(value: float) -> float:
    value = _clamp01(value)
    return value * value * (3 - 2 * value)


def _scale_alpha(image: Image.Image, factor: float) -> None:
    if factor >= 1.0:
        return
    alpha = image.getchannel('A').point(lambda v: int(v * factor))
    image.putalpha(alpha)


def _text_w(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0]


def _text_h(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[3] - bbox[1]


def _glow_sprite(accent: tuple[int, int, int], size: int, alpha: int) -> Image.Image:
    sprite = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(sprite)
    pad = int(size * 0.18)
    draw.ellipse([pad, pad, size - pad, size - pad], fill=(*accent, alpha))
    return sprite.filter(ImageFilter.GaussianBlur(radius=size * 0.16))


def _render_overlay_frames(
    *,
    target: store_screenshots.ScreenshotTarget,
    layout: dict[str, int],
    duration: float,
    fps: int,
    directory: Path,
    seg_starts: list[float],
) -> int:
    width = layout['canvas_width']
    height = layout['canvas_height']
    big = height > 2600
    segments = _promo_segments()
    seg_count = len(segments)
    if len(seg_starts) != seg_count:
        seg_starts = [i * duration / seg_count for i in range(seg_count)]
    margin = int(width * 0.072)
    fonts = {
        'eyebrow': _load_font(28 if big else 23, bold=True, mono=True),
        'headline': _load_font(62 if big else 50, bold=True),
        'body': _load_font(30 if big else 25),
        'label': _load_font(34 if big else 28, bold=True, mono=True),
    }

    glow_size = int(width * 0.5)
    glow_sprites = [
        _glow_sprite(segment.accent, glow_size, alpha=80) for segment in segments
    ]

    text_top = int(height * 0.103)

    frame_count = int(math.ceil(duration * fps)) + 1
    for index in range(frame_count):
        t = min(index / fps, duration)
        frame = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        _draw_drift_glow(frame, t, seg_starts, glow_sprites, layout)
        _draw_top_text(frame, t, segments, seg_starts, duration, margin, text_top, width, fonts)
        _draw_timeline(frame, t, segments, seg_starts, duration, margin, width, height, fonts)
        frame.save(directory / f'frame-{index:05d}.png')
    return frame_count


def _segment_starts(
    beat_offsets: list[float],
    seg_count: int,
    duration: float,
) -> list[float]:
    """Builds caption start times from measured beat offsets.

    Falls back to even slicing when beats are missing. Applies a small lead so
    captions land with their scene, and keeps the starts strictly increasing.
    """
    if len(beat_offsets) != seg_count:
        return [i * duration / seg_count for i in range(seg_count)]
    starts: list[float] = []
    prev = -1.0
    for index, offset in enumerate(beat_offsets):
        start = 0.0 if index == 0 else max(0.0, offset - CAPTION_LEAD_S)
        start = max(start, prev + 0.3)
        start = min(start, max(0.0, duration - 0.3))
        starts.append(start)
        prev = start
    starts[0] = 0.0
    return starts


def _segment_at(t: float, seg_starts: list[float]) -> int:
    index = 0
    for candidate, start in enumerate(seg_starts):
        if t >= start:
            index = candidate
        else:
            break
    return index


def _segment_span(
    index: int,
    seg_starts: list[float],
    duration: float,
) -> tuple[float, float]:
    start = seg_starts[index]
    end = seg_starts[index + 1] if index + 1 < len(seg_starts) else duration
    return start, max(end - start, 0.1)


def _draw_drift_glow(
    frame: Image.Image,
    t: float,
    seg_starts: list[float],
    glow_sprites: list[Image.Image],
    layout: dict[str, int],
) -> None:
    width = layout['canvas_width']
    height = layout['canvas_height']
    index = _segment_at(t, seg_starts)
    sprite = glow_sprites[index]
    size = sprite.width
    phase = 2 * math.pi * t
    top_x = int(width * 0.20 + math.sin(phase / 9) * width * 0.10) - size // 2
    top_y = int(height * 0.06 + math.cos(phase / 11) * height * 0.012) - size // 2
    frame.alpha_composite(sprite, (top_x, top_y))
    bottom_x = int(width * 0.80 + math.sin(phase / 8 + 1.7) * width * 0.10) - size // 2
    bottom_y = int(height * 0.94 + math.cos(phase / 10) * height * 0.012) - size // 2
    frame.alpha_composite(sprite, (bottom_x, bottom_y))


def _draw_top_text(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_starts: list[float],
    duration: float,
    margin: int,
    text_top: int,
    width: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> None:
    region_w = width - 2 * margin
    fade = 0.5
    for index, segment in enumerate(segments):
        start, seg_len = _segment_span(index, seg_starts, duration)
        local = t - start
        if local < -fade or local > seg_len + fade:
            continue
        alpha_in = _clamp01(local / fade)
        alpha_out = (
            1.0
            if index == len(segments) - 1
            else _clamp01((seg_len - local) / fade)
        )
        env = min(alpha_in, alpha_out)
        if env <= 0.01:
            continue
        slide = int((1 - _ease_in_out(alpha_in)) * 48) - int(
            (1 - _ease_in_out(alpha_out)) * 48,
        )
        layer = _render_segment_text(
            segment, index + 1, len(segments), region_w, fonts,
        )
        _scale_alpha(layer, env)
        frame.alpha_composite(layer, (margin, text_top + slide))


def _render_segment_text(
    segment: PromoSegment,
    number: int,
    count: int,
    region_w: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> Image.Image:
    measure = ImageDraw.Draw(Image.new('RGBA', (region_w, 8)))
    eyebrow_font = fonts['eyebrow']
    headline_font = fonts['headline']
    body_font = fonts['body']

    pill_text = f'{number:02d} · {segment.eyebrow.upper()}'
    pill_h = _text_h(measure, 'Ag', eyebrow_font) + 26
    head_h = _wrapped_text_height(measure, segment.headline, headline_font, region_w, 10)
    body_h = _wrapped_text_height(measure, segment.body, body_font, region_w, 8)
    gap1 = 26
    gap2 = 22
    total = pill_h + gap1 + head_h + gap2 + body_h + 8

    layer = Image.new('RGBA', (region_w, total), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    accent = segment.accent

    pill_w = _text_w(draw, pill_text, eyebrow_font) + 40
    draw.rounded_rectangle(
        [0, 0, pill_w, pill_h],
        radius=pill_h // 2,
        fill=(*accent, 46),
        outline=(*accent, 210),
        width=2,
    )
    draw.text((20, (pill_h - _text_h(draw, 'Ag', eyebrow_font)) // 2 - 2),
              pill_text, font=eyebrow_font, fill=(*_lighten(accent), 255))

    headline_y = pill_h + gap1
    _draw_wrapped_text(
        draw,
        segment.headline,
        font=headline_font,
        xy=(0, headline_y),
        max_width=region_w,
        fill=(255, 255, 255, 255),
        line_spacing=10,
    )
    body_y = headline_y + head_h + gap2
    _draw_wrapped_text(
        draw,
        segment.body,
        font=body_font,
        xy=(0, body_y),
        max_width=region_w,
        fill=(206, 214, 229, 255),
        line_spacing=8,
    )
    return layer


def _lighten(accent: tuple[int, int, int]) -> tuple[int, int, int]:
    return tuple(min(255, int(c + (255 - c) * 0.45)) for c in accent)


def _promo_segments() -> list[PromoSegment]:
    return [
        PromoSegment(
            eyebrow='From anywhere',
            headline='Run coding agents from your phone.',
            body='Open a session on your own server and prompt it straight '
            'from the keyboard.',
            label='Anywhere',
            accent=(0, 201, 255),
        ),
        PromoSegment(
            eyebrow='Always on',
            headline='Sessions stay live when you disconnect.',
            body='Reconnect to running agents from any device or network, '
            'right where you left off.',
            label='Always on',
            accent=(244, 114, 182),
        ),
        PromoSegment(
            eyebrow='Touch native',
            headline='Tap, scroll and select in the terminal.',
            body='Full mouse and touch, no laptop required.',
            label='Touch',
            accent=(129, 140, 248),
        ),
        PromoSegment(
            eyebrow='Real context',
            headline='Paste a screenshot for instant context.',
            body='Upload an image from your phone and the agent reads it '
            'in seconds.',
            label='Context',
            accent=(45, 212, 191),
        ),
        PromoSegment(
            eyebrow='Any agent',
            headline='Switch agents, keep your workspace.',
            body='Move between agents in one session. Your files and context '
            'stay put.',
            label='Any agent',
            accent=(34, 211, 238),
        ),
    ]


def _create_promo_base(
    target: store_screenshots.ScreenshotTarget,
    layout: dict[str, int],
) -> Image.Image:
    width = layout['canvas_width']
    height = layout['canvas_height']
    image = Image.new('RGB', (width, height), (8, 10, 24))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        ratio = y / max(height - 1, 1)
        red = int(9 + ratio * 15)
        green = int(12 + ratio * 8)
        blue = int(31 + ratio * 24)
        draw.line([(0, y), (width, y)], fill=(red, green, blue))

    glows = Image.new('RGBA', image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glows)
    glow_draw.ellipse(
        (-width // 3, -height // 8, width // 2, height // 3),
        fill=(0, 201, 255, 72),
    )
    glow_draw.ellipse(
        (width // 2, height // 5, width + width // 4, height),
        fill=(167, 139, 250, 56),
    )
    glow_draw.ellipse(
        (-width // 4, height // 2, width // 3, height + height // 5),
        fill=(244, 114, 182, 36),
    )
    image = Image.alpha_composite(
        image.convert('RGBA'),
        glows.filter(ImageFilter.GaussianBlur(radius=90)),
    )
    draw = ImageDraw.Draw(image)

    brand_font = _load_font(40 if target.platform == 'ios' else 36, bold=True, mono=True)
    tagline_font = _load_font(22 if target.platform == 'ios' else 20)
    margin = int(width * 0.08)
    draw.text((margin, int(height * 0.045)), 'MonkeySSH', font=brand_font, fill=(255, 255, 255))
    draw.text(
        (margin, int(height * 0.073)),
        'Run coding agents over SSH, from anywhere',
        font=tagline_font,
        fill=(208, 213, 221),
    )

    screen_x = layout['screen_x']
    screen_y = layout['screen_y']
    screen_width = layout['screen_width']
    screen_height = layout['screen_height']

    halo = Image.new('RGBA', image.size, (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo)
    halo_draw.rounded_rectangle(
        [
            screen_x - 70,
            screen_y - 70,
            screen_x + screen_width + 70,
            screen_y + screen_height + 70,
        ],
        radius=120,
        outline=(0, 201, 255, 90),
        width=26,
    )
    image = Image.alpha_composite(
        image,
        halo.filter(ImageFilter.GaussianBlur(radius=60)),
    )

    shadow = Image.new('RGBA', image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    frame_rect = [
        screen_x - 18,
        screen_y - 18,
        screen_x + screen_width + 18,
        screen_y + screen_height + 18,
    ]
    shadow_draw.rounded_rectangle(frame_rect, radius=48, fill=(0, 0, 0, 170))
    image = Image.alpha_composite(
        image,
        shadow.filter(ImageFilter.GaussianBlur(radius=26)),
    )
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        frame_rect,
        radius=48,
        outline=(255, 255, 255, 80),
        width=4,
        fill=(5, 8, 22, 255),
    )

    return image


def _draw_timeline(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_starts: list[float],
    duration: float,
    margin: int,
    width: int,
    height: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> None:
    draw = ImageDraw.Draw(frame)
    count = len(segments)
    seg_index = _segment_at(t, seg_starts)
    accent = segments[seg_index].accent

    track_y = int(height * 0.955)
    x0 = margin
    x1 = width - margin
    draw.rounded_rectangle(
        [x0, track_y - 4, x1, track_y + 4],
        radius=4,
        fill=(255, 255, 255, 46),
    )
    progress = _clamp01(t / duration) if duration > 0 else 0.0
    fill_x = int(x0 + (x1 - x0) * progress)
    draw.rounded_rectangle(
        [x0, track_y - 4, fill_x, track_y + 4],
        radius=4,
        fill=(*accent, 235),
    )

    for index, segment in enumerate(segments):
        cx = int(x0 + (x1 - x0) * (index + 0.5) / count)
        if index < seg_index:
            node_r = 11
            color = (*segment.accent, 235)
        elif index == seg_index:
            pulse = 0.5 + 0.5 * math.sin(2 * math.pi * t / 1.3)
            node_r = int(15 + 3 * pulse)
            ring_r = node_r + 9
            draw.ellipse(
                [cx - ring_r, track_y - ring_r, cx + ring_r, track_y + ring_r],
                outline=(*segment.accent, 180),
                width=3,
            )
            color = (*_lighten(segment.accent), 255)
        else:
            node_r = 9
            color = (255, 255, 255, 70)
        draw.ellipse(
            [cx - node_r, track_y - node_r, cx + node_r, track_y + node_r],
            fill=color,
        )

    label = segments[seg_index].label
    label_font = fonts['label']
    label_w = _text_w(draw, label, label_font)
    label_h = _text_h(draw, label, label_font)
    # Seat the now-playing label in the clear band between the phone frame and
    # the progress track so it never collides with either.
    label_y = int(height * 0.933) - label_h // 2
    draw.text(
        ((width - label_w) // 2, label_y),
        label,
        font=label_font,
        fill=(*_lighten(accent), 255),
    )


def _draw_wrapped_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    *,
    font: ImageFont.ImageFont,
    xy: tuple[int, int],
    max_width: int,
    fill: tuple[int, int, int, int],
    line_spacing: int,
) -> None:
    x, y = xy
    for line in _wrap_text(draw, text, font, max_width):
        draw.text((x, y), line, font=font, fill=fill)
        bbox = draw.textbbox((0, 0), line, font=font)
        y += bbox[3] - bbox[1] + line_spacing


def _wrapped_text_height(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
    line_spacing: int,
) -> int:
    height = 0
    lines = _wrap_text(draw, text, font, max_width)
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font)
        height += bbox[3] - bbox[1] + line_spacing
    return max(height - line_spacing, 0)


def _wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
) -> list[str]:
    lines: list[str] = []
    current = ''
    for word in text.split():
        candidate = word if not current else f'{current} {word}'
        bbox = draw.textbbox((0, 0), candidate, font=font)
        if bbox[2] - bbox[0] <= max_width:
            current = candidate
            continue
        if current:
            lines.append(current)
        current = word
    if current:
        lines.append(current)
    return lines


def _load_font(
    size: int,
    *,
    bold: bool = False,
    mono: bool = False,
) -> ImageFont.ImageFont:
    if mono:
        candidates = [
            Path('/System/Library/Fonts/SFNSMono.ttf'),
            Path('/System/Library/Fonts/Menlo.ttc'),
            Path('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf')
            if bold
            else Path('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'),
        ]
    else:
        candidates = [
            Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')
            if bold
            else Path('/System/Library/Fonts/Supplemental/Arial.ttf'),
            Path('/System/Library/Fonts/Helvetica.ttc'),
            Path('/Library/Fonts/Arial.ttf'),
            Path('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf')
            if bold
            else Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
        ]
    for path in candidates:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)



def _recorder_for_target(
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    output_path: Path,
) -> _NativeScreenRecorder:
    if target.platform == 'ios':
        return _IosSimulatorRecorder(device_id=device_id, output_path=output_path)
    return _AndroidScreenRecorder(
        device_id=device_id,
        output_path=output_path,
        size=target.size,
    )


class _NativeScreenRecorder:
    def start(self) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


class _IosSimulatorRecorder(_NativeScreenRecorder):
    def __init__(self, *, device_id: str, output_path: Path) -> None:
        self._device_id = device_id
        self._output_path = output_path
        self._process: subprocess.Popen[str] | None = None
        self._stderr = ''

    def start(self) -> None:
        if self._output_path.exists():
            self._output_path.unlink()
        self._process = subprocess.Popen(
            [
                'xcrun',
                'simctl',
                'io',
                self._device_id,
                'recordVideo',
                '--codec=h264',
                '--force',
                str(self._output_path),
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        time.sleep(0.5)
        if self._process.poll() is not None:
            stderr = self._process.stderr.read() if self._process.stderr else ''
            raise RuntimeError(f'iOS screen recording failed to start: {stderr}')

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if process.stderr is not None:
            self._stderr = process.stderr.read()
            process.stderr.close()
        if not self._output_path.exists():
            raise RuntimeError(
                'iOS screen recording did not produce a file. '
                f'simctl output: {self._stderr.strip()}'
            )


class _AndroidScreenRecorder(_NativeScreenRecorder):
    def __init__(
        self,
        *,
        device_id: str,
        output_path: Path,
        size: tuple[int, int],
    ) -> None:
        self._adb = store_screenshots._adb_path()
        self._device_id = device_id
        self._output_path = output_path
        self._size = size
        self._process: subprocess.Popen[str] | None = None
        suffix = f'{os.getpid()}-{int(time.time())}'
        self._remote_path = f'/sdcard/monkeyssh-store-demo-{suffix}.mp4'
        self._pid_path = f'/data/local/tmp/monkeyssh-store-demo-{suffix}.pid'
        self._remote_pid: int | None = None

    def start(self) -> None:
        if self._output_path.exists():
            self._output_path.unlink()
        width, height = self._size
        remote_command = (
            f'echo $$ > {self._pid_path}; '
            'exec screenrecord '
            f'--bit-rate {ANDROID_RECORDING_BIT_RATE} '
            f'--size {width}x{height} '
            f'{self._remote_path}'
        )
        self._process = subprocess.Popen(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'shell',
                remote_command,
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self._remote_pid = self._wait_for_remote_pid()

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is not None and process.poll() is None:
            if self._remote_pid is not None:
                subprocess.run(
                    [
                        str(self._adb),
                        '-s',
                        self._device_id,
                        'shell',
                        'kill',
                        '-2',
                        str(self._remote_pid),
                    ],
                    cwd=ROOT,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        subprocess.run(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'pull',
                self._remote_path,
                str(self._output_path),
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'shell',
                'rm',
                '-f',
                self._remote_path,
                self._pid_path,
            ],
            cwd=ROOT,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _wait_for_remote_pid(self) -> int:
        deadline = time.time() + 10
        while time.time() < deadline:
            process = self._process
            if process is not None and process.poll() is not None:
                raise RuntimeError('Android screenrecord exited before recording started')
            result = subprocess.run(
                [
                    str(self._adb),
                    '-s',
                    self._device_id,
                    'shell',
                    'cat',
                    self._pid_path,
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                value = result.stdout.strip()
                if value.isdigit():
                    return int(value)
            time.sleep(0.2)
        raise RuntimeError('Timed out waiting for Android screenrecord to start')


class _AndroidSystemDialogWatchdog:
    def __init__(self, device_id: str) -> None:
        self._device_id = device_id
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=3)

    def _run(self) -> None:
        while not self._stop.wait(0.75):
            _dismiss_android_system_dialogs(self._device_id)


def _suppress_android_error_dialogs(device_id: str):
    """Disable system ANR/crash dialogs for the duration of a recording.

    Returns a callable that restores the previous values. Pixel Launcher ANR
    popups are the main offender on a busy headless emulator; hiding error
    dialogs system-wide is far more reliable than racing to dismiss them.
    """
    adb = store_screenshots._adb_path()
    previous = _android_global_setting(adb, device_id, 'hide_error_dialogs')
    _put_android_global_setting(adb, device_id, 'hide_error_dialogs', '1')

    def restore() -> None:
        target = previous if previous in ('0', '1') else '0'
        _put_android_global_setting(adb, device_id, 'hide_error_dialogs', target)

    return restore


def _android_global_setting(adb: Path, device_id: str, key: str) -> str | None:
    try:
        result = subprocess.run(
            [str(adb), '-s', device_id, 'shell', 'settings', 'get', 'global', key],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value if value and value != 'null' else None


def _put_android_global_setting(
    adb: Path,
    device_id: str,
    key: str,
    value: str,
) -> None:
    subprocess.run(
        [str(adb), '-s', device_id, 'shell', 'settings', 'put', 'global', key, value],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def _dismiss_android_system_dialogs(device_id: str, *, force: bool = False) -> None:
    adb = store_screenshots._adb_path()
    if force:
        _force_stop_android_launcher(adb, device_id)
    if not _android_has_system_error_dialog(adb, device_id):
        return
    _force_stop_android_launcher(adb, device_id)
    _press_android_back(adb, device_id)


def _android_has_system_error_dialog(adb: Path, device_id: str) -> bool:
    try:
        result = subprocess.run(
            [str(adb), '-s', device_id, 'shell', 'dumpsys', 'window', 'windows'],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    text = result.stdout.casefold()
    return (
        'application error' in text
        or 'apperrordialog' in text
        or "isn't responding" in text
        or 'not responding' in text
    )


def _force_stop_android_launcher(adb: Path, device_id: str) -> None:
    subprocess.run(
        [
            str(adb),
            '-s',
            device_id,
            'shell',
            'am',
            'force-stop',
            PIXEL_LAUNCHER_PACKAGE,
        ],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def _press_android_back(adb: Path, device_id: str) -> None:
    subprocess.run(
        [str(adb), '-s', device_id, 'shell', 'input', 'keyevent', 'BACK'],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'error: {error}', file=sys.stderr)
        raise
