#!/usr/bin/env python3
"""Separate store copy updates from published screenshot/video updates."""

import json
import os
from pathlib import Path

from ci_changes import changed_paths


def classify(paths, platform='', app='both'):
    if app not in {'both', 'private', 'production'}:
        raise ValueError('unsupported app listing')
    result = dict.fromkeys(('ios', 'android', 'ios_screenshots', 'ios_app_previews',
                            'android_screenshots'), False)
    if platform:
        if platform not in {'both', 'ios', 'android'}:
            raise ValueError('unsupported store platform')
        for name in result:
            result[name] = platform == 'both' or name.startswith(platform)
    elif paths is None:
        result = dict.fromkeys(result, True)
    else:
        for path in paths:
            if path.startswith('ios/fastlane/metadata-') or path in {'scripts/validate_app_store_metadata.py', 'scripts/store_metadata.rb'}:
                result['ios'] = True
            if path.startswith('android/fastlane/metadata-') or path == 'scripts/validate_play_store_metadata.py':
                result['android'] = True
            if path.startswith('assets/icons/') or (
                path.startswith('android/fastlane/metadata-') and '/images/' in path
            ) or path == 'scripts/sync_play_store_icons.py':
                result['android'] = result['android_screenshots'] = True
            if path in {
                'scripts/store_assets.sh', 'scripts/validate_store_screenshots.py',
                'scripts/validate_store_demo_videos.py', 'scripts/store_media.py',
                '.github/workflows/sync-metadata.yml', 'scripts/metadata_changes.py',
            }:
                result = dict.fromkeys(result, True)
    return {**result, 'app': app, 'apps': json.dumps(
        ['private', 'production'] if app == 'both' else [app])}


if __name__ == '__main__':
    platform = os.environ.get('INPUT_PLATFORM', '')
    result = classify(None if platform else changed_paths(os.environ),
                      platform, os.environ.get('INPUT_APP') or 'both')
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
        for name, value in result.items():
            output.write(f'{name}={str(value).lower() if isinstance(value, bool) else value}\n')
