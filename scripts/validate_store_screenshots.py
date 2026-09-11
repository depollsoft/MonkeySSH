#!/usr/bin/env python3

from __future__ import annotations

import argparse
import platform
import re
import shutil
from pathlib import Path

import store_media

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
SCREENSHOT_COUNT = 8
IOS_SCREENSHOTS = {
    ROOT / 'ios/fastlane/screenshots/en-US': {
        'iphone_6_9': (1320, 2868),
        'ipad_13': (2064, 2752),
    },
}
ANDROID_SCREENSHOTS = {
    'phoneScreenshots': (1440, 2560),
    'sevenInchScreenshots': (1200, 1920),
    'tenInchScreenshots': (1600, 2560),
}
BAD_OCR_PATTERNS = {
    'splash screen': re.compile(r'MonkeySSH\s*[βB]\s+SSH Terminal', re.IGNORECASE),
    'old prompt transcript': re.compile(
        r'Next two checks|release[- ]readiness|64 concise|sign[- ]off',
        re.IGNORECASE,
    ),
    'old AGENTS text scene': re.compile(
        r'Do not show emails|store-demo agents %|shared agent instructions',
        re.IGNORECASE,
    ),
    'notification prompt': re.compile(
        r'Would Like to Send You Notifications|Notifications may include',
        re.IGNORECASE,
    ),
    'private local path': re.compile(r'/Users/depoll|/private/var/folders', re.IGNORECASE),
    'disabled streamer mode': re.compile(r'Streamer mode disabled', re.IGNORECASE),
    'enabled streamer mode': re.compile(r'Streamer mode enabled', re.IGNORECASE),
    'visible API key': re.compile(r'ANTHROPIC_API_KEY|sk-ant-', re.IGNORECASE),
    'Claude account banner': re.compile(
        r'Account\s+(?:settings|details|email|plan|billing)',
        re.IGNORECASE,
    ),
    'Claude plan-mode footer': re.compile(r'plan mode on', re.IGNORECASE),
    'Claude unavailable model notice': re.compile(
        r'Fable\s+\d+|currently unavailable|fable-mythos-access',
        re.IGNORECASE,
    ),
    'Claude setup warning': re.compile(
        r'setup issue|run claude install|claude command at',
        re.IGNORECASE,
    ),
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate generated store screenshot counts and dimensions.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which store screenshot set to validate.',
    )
    return parser.parse_args()


def _image_size(path: Path) -> tuple[int, int]:
    if not path.exists():
        raise FileNotFoundError(f'Missing screenshot: {path}')

    with Image.open(path) as image:
        return image.size


def _validate_file(path: Path, expected_size: tuple[int, int]) -> None:
    actual_size = _image_size(path)
    if actual_size != expected_size:
        raise ValueError(
            f'{path.relative_to(ROOT)} is {actual_size[0]}x{actual_size[1]}; '
            f'expected {expected_size[0]}x{expected_size[1]}',
        )
    if path.stat().st_size < 10_000:
        raise ValueError(
            f'{path.relative_to(ROOT)} is unexpectedly small; '
            'regenerate real app screenshots before syncing metadata',
        )

    print(
        f'Validated {path.relative_to(ROOT)} '
        f'({actual_size[0]}x{actual_size[1]})',
    )


def _validate_copilot_image_frame(path: Path) -> None:
    """Reject accidental slivers while allowing one intentionally cropped edge."""
    with Image.open(path) as image:
        rgb = image.convert('RGB')
        width, height = rgb.size
        channels = [
            channel.point([
                255 if abs(value - target) <= tolerance else 0
                for value in range(256)
            ])
            for channel, target, tolerance in zip(
                rgb.split(), (64, 196, 255), (18, 18, 12),
            )
        ]
        mask = ImageChops.multiply(
            ImageChops.multiply(channels[0], channels[1]), channels[2],
        )

        horizontal_rows = [
            y
            for y in range(height)
            if mask.crop((0, y, width, y + 1)).histogram()[255] >= width * 0.2
        ]
        vertical_columns = [
            x
            for x in range(width)
            if mask.crop((x, 0, x + 1, height)).histogram()[255] >= height * 0.1
        ]

    def group_count(values: list[int]) -> int:
        if not values:
            return 0
        return 1 + sum(
            values[index] != values[index - 1] + 1
            for index in range(1, len(values))
        )

    horizontal_edges = group_count(horizontal_rows)
    vertical_edges = group_count(vertical_columns)
    visible_edges = horizontal_edges + vertical_edges
    if horizontal_edges == 0 or vertical_edges == 0 or visible_edges < 3:
        raise ValueError(
            f'{path.relative_to(ROOT)} shows only a sliver of the inline '
            f'Copilot image (horizontal edges: {horizontal_edges}, vertical '
            f'edges: {vertical_edges}); regenerate with enough app content '
            'visible to look intentional',
        )


def _ocr_texts(paths: list[Path]) -> dict[Path, str]:
    if platform.system() != 'Darwin' or shutil.which('swift') is None:
        raise RuntimeError(
            'OCR screenshot validation requires macOS with Swift/Vision. '
            'Run this validator on a macOS runner before syncing metadata.',
        )

    return store_media._ocr_texts(paths)


def _validate_ocr_content(paths: list[Path]) -> None:
    texts = _ocr_texts(paths)
    for path, text in texts.items():
        for label, pattern in BAD_OCR_PATTERNS.items():
            if pattern.search(text):
                raise ValueError(
                    f'{path.relative_to(ROOT)} appears to contain {label}; '
                    'regenerate store-quality screenshots before syncing metadata',
                )

    monkeymux_texts: dict[str, list[tuple[Path, str]]] = {}
    for path, text in texts.items():
        filename = path.name
        if filename in {'01_iphone_6_9.png', '01_ipad_13.png', '1.png'}:
            _validate_copilot_image_frame(path)
            _require_ocr_markers(path, text, ['Copilot'])
            # Require labels unique to the embedded light-mode hosts screenshot
            # (not words that also appear in the submitted Copilot prompt).
            _require_ocr_markers(
                path,
                text,
                ['Add Host', 'Build runner'],
                require_any=True,
            )
        elif filename in {'02_iphone_6_9.png', '02_ipad_13.png', '2.png'}:
            _require_ocr_markers(path, text, ['Hosts', 'Add Host'])
        elif filename in {'03_iphone_6_9.png', '03_ipad_13.png', '3.png'}:
            _require_ocr_markers(path, text, ['Snippets'])
        elif filename in {'04_iphone_6_9.png', '04_ipad_13.png', '4.png'}:
            _require_ocr_markers(path, text, ['New Window'])
            monkeymux_texts.setdefault(_monkeymux_scene_group(path), []).append(
                (path, text),
            )
        elif filename in {'05_iphone_6_9.png', '05_ipad_13.png', '5.png'}:
            _require_ocr_markers(path, text, ['AGENTS.md'])
        elif filename in {'06_iphone_6_9.png', '06_ipad_13.png', '6.png'}:
            _require_ocr_markers(path, text, ['Claude Code'])
        elif filename in {'07_iphone_6_9.png', '07_ipad_13.png', '7.png'}:
            _require_ocr_markers(
                path, text,
                ['Message the agent', 'reconnect'],
            )
        elif filename in {'08_iphone_6_9.png', '08_ipad_13.png', '8.png'}:
            _require_ocr_markers(
                path, text,
                ['Agent Management', 'PRO', 'Copilot CLI', 'Claude Code'],
            )

    for grouped_texts in monkeymux_texts.values():
        paths_description = ', '.join(
            str(path.relative_to(ROOT)) for path, _ in grouped_texts
        )
        _require_ocr_markers(
            paths_description,
            ' '.join(text for _, text in grouped_texts),
            ['copilot', 'claude', 'codex', 'opencode', 'antigravity'],
        )


def _monkeymux_scene_group(path: Path) -> str:
    relative_parts = path.relative_to(ROOT).parts
    if relative_parts[:3] == ('ios', 'fastlane', 'screenshots'):
        return '/'.join(relative_parts[:4])
    if relative_parts[:2] == ('android', 'fastlane'):
        return '/'.join(relative_parts[:5])
    return str(path.parent.relative_to(ROOT))


def _require_ocr_markers(
    path: Path | str,
    text: str,
    markers: list[str],
    *,
    require_any: bool = False,
) -> None:
    normalized_text = text.casefold()
    compacted_text = _compact_ocr_text(text)
    matched = [
        marker
        for marker in markers
        if _text_contains_marker(marker, normalized_text, compacted_text)
    ]
    if require_any:
        if matched:
            return
        raise ValueError(
            f'{_display_path(path)} is missing expected store screenshot '
            f'content (any of: {", ".join(markers)})',
        )
    missing = [marker for marker in markers if marker not in matched]
    if missing:
        raise ValueError(
            f'{_display_path(path)} is missing expected store screenshot '
            f'content: {", ".join(missing)}',
        )


def _text_contains_marker(
    marker: str,
    normalized_text: str,
    compacted_text: str,
) -> bool:
    if marker == 'PRO':
        # A substring match would accept "prompt", "progress" or "provider"
        # even when the store-only badge was accidentally omitted.
        return re.search(r'\bpro\b', normalized_text) is not None
    return (
        marker.casefold() in normalized_text
        or _compact_ocr_text(marker) in compacted_text
    )


def _compact_ocr_text(text: str) -> str:
    return re.sub(r'[^a-z0-9]+', '', text.casefold())


def _display_path(path: Path | str) -> str:
    if isinstance(path, str):
        return path
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def _validate_ios() -> None:
    paths = []
    for locale_dir, devices in IOS_SCREENSHOTS.items():
        for index in range(1, SCREENSHOT_COUNT + 1):
            for device_name, expected_size in devices.items():
                path = locale_dir / f'{index:02d}_{device_name}.png'
                _validate_file(path, expected_size)
                paths.append(path)
    _validate_ocr_content(paths)


def _validate_android() -> None:
    paths = []
    for variant in ('production', 'private'):
        images_dir = ROOT / f'android/fastlane/metadata-{variant}/android/en-US/images'
        for screenshot_dir, expected_size in ANDROID_SCREENSHOTS.items():
            for index in range(1, SCREENSHOT_COUNT + 1):
                path = images_dir / screenshot_dir / f'{index}.png'
                _validate_file(path, expected_size)
                paths.append(path)
    _validate_ocr_content(paths)


def main() -> None:
    args = _parse_args()
    if args.platform in ('ios', 'both'):
        _validate_ios()
    if args.platform in ('android', 'both'):
        _validate_android()


if __name__ == '__main__':
    main()
