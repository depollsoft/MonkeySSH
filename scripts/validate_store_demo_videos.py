#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from store_media import _ocr_texts

ROOT = Path(__file__).resolve().parents[1]
BAD_VIDEO_OCR_PATTERNS = {
    'Android system error dialog': re.compile(
        r"Pixel Launcher|isn[’']t responding|not responding|Close app",
        re.IGNORECASE,
    ),
    'private local path': re.compile(r'/Users/depoll|/private/var/folders', re.IGNORECASE),
    'visible API key': re.compile(r'ANTHROPIC_API_KEY|sk-ant-', re.IGNORECASE),
}


@dataclass(frozen=True)
class VideoTarget:
    name: str
    platform: str
    rel_path: str
    size: tuple[int, int]
    live_crop: str
    slot: str
    requires_audio: bool = False
    animated_bg: bool = True


# Crop expressions isolating the live app region for motion/progression checks.
_APP_PREVIEW_CROP = 'crop=iw*0.62:ih*0.40:iw*0.19:ih*0.30'
_PORTRAIT_ADS_CROP = 'crop=iw*0.58:ih*0.46:iw*0.21:ih*0.31'
_LANDSCAPE_CROP = 'crop=iw*0.20:ih*0.62:iw*0.066:ih*0.19'

TARGETS = [
    VideoTarget(
        name='iphone_app_preview',
        platform='ios',
        rel_path='ios/fastlane/app-previews/en-US/iphone_67_1.mov',
        size=(886, 1920),
        live_crop=_APP_PREVIEW_CROP,
        slot='App Store iPhone 6.9" app preview',
        requires_audio=True,
        animated_bg=False,
    ),
    VideoTarget(
        name='ipad_app_preview',
        platform='ios',
        rel_path='ios/fastlane/app-previews/en-US/ipad_13_1.mov',
        size=(1200, 1600),
        live_crop=_APP_PREVIEW_CROP,
        slot='App Store iPad 13" app preview',
        requires_audio=True,
        animated_bg=False,
    ),
    VideoTarget(
        name='google_play_promo',
        platform='android',
        rel_path='store/demo-videos/google-play/monkeyssh-google-play-promo.mp4',
        size=(1920, 1080),
        live_crop=_LANDSCAPE_CROP,
        slot='Google Play landscape promo (YouTube)',
    ),
    VideoTarget(
        name='ios_ads',
        platform='ios',
        rel_path='store/demo-videos/ads/monkeyssh-ios-ads.mp4',
        size=(1320, 2868),
        live_crop=_PORTRAIT_ADS_CROP,
        slot='iOS portrait ad/marketing',
    ),
    VideoTarget(
        name='android_ads',
        platform='android',
        rel_path='store/demo-videos/ads/monkeyssh-android-ads.mp4',
        size=(1440, 2560),
        live_crop=_PORTRAIT_ADS_CROP,
        slot='Android portrait ad/marketing',
    ),
]


@dataclass(frozen=True)
class VideoInfo:
    width: int
    height: int
    duration: float
    has_audio: bool


def main() -> None:
    args = _parse_args()
    ffmpeg = shutil.which('ffmpeg')
    ffprobe = shutil.which('ffprobe')
    if ffmpeg is None or ffprobe is None:
        raise RuntimeError('Video validation requires ffmpeg and ffprobe.')
    targets = _filter_targets(args.platform)
    paths = [ROOT / target.rel_path for target in targets]
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f'Missing demo video: {path}')
    infos = _probe_videos(ffprobe, paths)
    for index, target in enumerate(targets):
        path = paths[index]
        _validate_video(
            path=path,
            expected_size=target.size,
            min_duration=args.min_duration,
            max_duration=args.max_duration,
            info=infos[path],
        )
        if target.requires_audio and not infos[path].has_audio:
            raise ValueError(
                f'{_display_path(path)} ({target.slot}) has no audio track; '
                'App Store app previews require an audio track',
            )
        _validate_dynamics(ffmpeg, path, target=target, info=infos[path])
    _validate_sampled_ocr_content(ffmpeg, infos)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate generated MonkeySSH store demo videos.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'all'],
        nargs='?',
        default='all',
        help='Which slots to validate (default: all store + ads outputs).',
    )
    parser.add_argument(
        '--min-duration',
        type=float,
        default=15,
        help='Minimum acceptable duration in seconds.',
    )
    parser.add_argument(
        '--max-duration',
        type=float,
        default=30,
        help='Maximum acceptable duration in seconds.',
    )
    return parser.parse_args()


def _filter_targets(platform: str) -> list[VideoTarget]:
    if platform == 'all':
        return TARGETS
    return [target for target in TARGETS if target.platform == platform]


def _validate_video(
    *,
    path: Path,
    expected_size: tuple[int, int],
    min_duration: float,
    max_duration: float,
    info: VideoInfo,
) -> None:
    if not path.exists():
        raise FileNotFoundError(f'Missing demo video: {path}')
    if path.stat().st_size < 500_000:
        raise ValueError(f'{_display_path(path)} is too small for a real recording')
    actual_size = (info.width, info.height)
    if actual_size != expected_size:
        raise ValueError(
            f'{_display_path(path)} is {info.width}x{info.height}; '
            f'expected {expected_size[0]}x{expected_size[1]}',
        )
    if info.duration < min_duration or info.duration > max_duration:
        raise ValueError(
            f'{_display_path(path)} is {info.duration:.1f}s; '
            f'expected {min_duration:.1f}-{max_duration:.1f}s',
        )
    print(
        f'Validated {_display_path(path)} '
        f'({info.width}x{info.height}, {info.duration:.1f}s)',
    )


def _validate_dynamics(
    ffmpeg: str, path: Path, *, target: VideoTarget, info: VideoInfo,
) -> None:
    result = subprocess.run(
        [
            ffmpeg, '-hide_banner', '-nostats', '-i', str(path),
            '-filter_complex',
            '[0:v:0]split[full][live];'
            '[full]blackdetect@full=d=0.4:pic_th=0.98,'
            'freezedetect@full=n=0.003:d=2.0[full_out];'
            f'[live]{target.live_crop},freezedetect@live=n=0.003:d=1.0,'
            "select='gt(scene,0.10)',"
            'metadata@scenes=print:key=lavfi.scene_score,nullsink',
            '-map', '[full_out]', '-an', '-f', 'null', '-',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    full = '\n'.join(line for line in result.stderr.splitlines() if '@full ' in line)
    live = '\n'.join(line for line in result.stderr.splitlines() if 'freezedetect@live ' in line)
    black_total = sum(
        float(value)
        for value in re.findall(r'black_duration:(\d+(?:\.\d+)?)', full)
    )
    if black_total > 1.0:
        raise ValueError(
            f'{_display_path(path)} contains {black_total:.1f}s of near-black '
            'frames; the screen capture likely failed — regenerate the demo video',
        )
    # Native previews hold still during scene reads; branded backdrops animate.
    if target.animated_bg and 'freeze_start' in full:
        raise ValueError(
            f'{_display_path(path)} contains a frozen/static segment of 2s or '
            'more; the promotional animation is missing — regenerate the demo video',
        )
    frozen = sum(
        float(value)
        for value in re.findall(
            r'freeze_duration:\s*(\d+(?:\.\d+)?)',
            live,
        )
    )
    starts = re.findall(r'freeze_start:\s*(\d+(?:\.\d+)?)', live)
    ends = re.findall(r'freeze_end:\s*(\d+(?:\.\d+)?)', live)
    if len(starts) > len(ends):
        frozen += info.duration - float(starts[-1])
    fraction = frozen / info.duration
    if fraction > 0.97:
        raise ValueError(
            f'{_display_path(path)} live app region is frozen '
            f'{fraction * 100:.0f}% of the time; the device capture likely '
            'failed or stalled — regenerate the demo video',
        )
    scene_changes = sum(
        'metadata@scenes ' in line and 'lavfi.scene_score=' in line
        for line in result.stderr.splitlines()
    )
    if scene_changes < 4:
        raise ValueError(
            f'{_display_path(path)} live app region only changes '
            f'{scene_changes} time(s); the device capture likely stalled on '
            'a single screen — regenerate the demo video',
        )
    print(
        f'Validated live app progression for {_display_path(path)} '
        f'({scene_changes} scene changes)',
    )


def _validate_sampled_ocr_content(ffmpeg: str, infos: dict[Path, VideoInfo]) -> None:
    if platform.system() != 'Darwin' or shutil.which('swift') is None:
        print('Skipping video OCR validation; requires macOS, Swift, and ffmpeg.')
        return

    with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-video-ocr-') as tmpdir:
        frame_paths: list[Path] = []
        tmpdir_path = Path(tmpdir)
        for video_path, info in infos.items():
            for index, timestamp in enumerate(_sample_times(info.duration)):
                frame_path = tmpdir_path / f'{video_path.stem}-{index}.png'
                subprocess.run(
                    [
                        ffmpeg,
                        '-y',
                        '-loglevel',
                        'error',
                        '-ss',
                        f'{timestamp:.3f}',
                        '-i',
                        str(video_path),
                        '-frames:v',
                        '1',
                        str(frame_path),
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=True,
                )
                frame_paths.append(frame_path)

        texts = _ocr_texts(frame_paths)
        for frame_path, text in texts.items():
            for label, pattern in BAD_VIDEO_OCR_PATTERNS.items():
                if pattern.search(text):
                    raise ValueError(
                        f'{frame_path.name} appears to contain {label}; '
                        'regenerate store-quality demo videos before syncing assets',
                    )


def _sample_times(duration: float) -> list[float]:
    if duration <= 4:
        return [max(duration / 2, 0)]
    return [
        min(max(1.0, duration * ratio), max(duration - 0.5, 0))
        for ratio in (0.1, 0.25, 0.42, 0.58, 0.75, 0.9)
    ]


def _probe_videos(
    ffprobe: str,
    paths: list[Path],
) -> dict[Path, VideoInfo]:
    infos: dict[Path, VideoInfo] = {}
    for path in paths:
        result = subprocess.run(
            [
                ffprobe,
                '-v',
                'error',
                '-show_entries',
                'stream=codec_type,width,height,duration:format=duration',
                '-of',
                'json',
                str(path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
        payload = json.loads(result.stdout)
        streams = payload.get('streams', [])
        stream = next((s for s in streams if s.get('codec_type') == 'video'), None)
        if stream is None:
            raise ValueError(f'{_display_path(path)} does not contain a video stream')
        duration = _float_or_none(stream.get('duration'))
        if duration is None:
            duration = _float_or_none(payload.get('format', {}).get('duration'))
        if duration is None:
            raise ValueError(f'Could not read duration for {_display_path(path)}')
        infos[path] = VideoInfo(
            width=int(stream['width']),
            height=int(stream['height']),
            duration=duration,
            has_audio=any(s.get('codec_type') == 'audio' for s in streams),
        )
    return infos


def _float_or_none(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (float, int)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


if __name__ == '__main__':
    main()
