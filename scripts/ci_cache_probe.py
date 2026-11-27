#!/usr/bin/env python3
"""Check whether GitHub Actions main-branch build caches need warming on push.

Queries the GitHub Actions Caches API for ``refs/heads/main`` so push-to-main
CI can warm Apple compilation/SPM caches and Windows pub caches when they are
missing (e.g. after a Flutter/lockfile bump or 10 GB LRU eviction; Xcode-only
image bumps are not detected because prefixes stop before the Xcode key)
without allocating macOS or Windows runners when caches are already warm.

Fails open (outputs ``false`` with a warning) on transient API errors so a
GitHub API hiccup never fails a push-to-main run.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


def github_hash_files(root: Path, paths: list[str]) -> str:
    """Match GitHub Actions ``hashFiles(...)`` SHA-256 algorithm."""
    outer = hashlib.sha256()
    matched = 0
    for rel in paths:
        target = root / rel
        if not target.is_file():
            continue
        matched += 1
        outer.update(hashlib.sha256(target.read_bytes()).digest())
    return outer.hexdigest() if matched else ''


def required_cache_prefixes(root: Path, flutter_version: str) -> dict[str, list[str]]:
    """Return ``main``-branch cache key prefixes required for each warm target."""
    ios_fp = github_hash_files(
        root, ['pubspec.lock', 'ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved']
    )
    macos_fp = github_hash_files(
        root, ['pubspec.lock', 'macos/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved']
    )
    pub_fp = github_hash_files(root, ['pubspec.lock'])
    return {
        'warm_ios': [
            f'ios-compile-v1-macOS-ARM64-{flutter_version}-production-{ios_fp}-',
            f'spm-workspace-v1-macOS-ARM64-{flutter_version}-ios-{ios_fp}-',
        ],
        'warm_macos': [
            f'macos-compile-v1-macOS-ARM64-{flutter_version}-release-{macos_fp}-',
            f'spm-workspace-v1-macOS-ARM64-{flutter_version}-macos-{macos_fp}-',
        ],
        'warm_windows_pub': [
            f'windows-pub-v1-{flutter_version}-{pub_fp}',
        ],
    }


def cache_prefix_exists(
    repo: str,
    prefix: str,
    token: str,
    *,
    ref: str = 'refs/heads/main',
    api_url: str = 'https://api.github.com',
    urlopen=urllib.request.urlopen,
) -> bool:
    """Return True if at least one cache matching ``prefix`` exists on ``ref``."""
    query = urllib.parse.urlencode({'ref': ref, 'key': prefix, 'per_page': 1})
    url = f'{api_url.rstrip("/")}/repos/{repo}/actions/caches?{query}'
    request = urllib.request.Request(
        url,
        headers={
            'Accept': 'application/vnd.github+json',
            'Authorization': f'Bearer {token}',
            'X-GitHub-Api-Version': '2022-11-28',
        },
    )
    with urlopen(request, timeout=15) as response:
        payload = json.loads(response.read().decode('utf-8'))
    return int(payload.get('total_count', 0)) > 0


def probe(
    root: Path,
    flutter_version: str,
    repo: str,
    token: str,
    *,
    api_url: str = 'https://api.github.com',
    urlopen=urllib.request.urlopen,
) -> dict[str, bool]:
    """Return whether each warm target is missing one or more required caches."""
    prefixes = required_cache_prefixes(root, flutter_version)
    results: dict[str, bool] = {}
    for target, keys in prefixes.items():
        missing = False
        for prefix in keys:
            if not cache_prefix_exists(
                repo, prefix, token, api_url=api_url, urlopen=urlopen
            ):
                missing = True
                break
        results[target] = missing
    return results


def main() -> int:
    root = Path.cwd()
    flutter_version = os.environ.get('FLUTTER_VERSION', '').strip()
    repo = os.environ.get('GITHUB_REPOSITORY', '').strip()
    token = os.environ.get('GH_TOKEN', '').strip()
    api_url = os.environ.get('GITHUB_API_URL', 'https://api.github.com')

    results = {'warm_ios': False, 'warm_macos': False, 'warm_windows_pub': False}
    if not flutter_version or not repo or not token:
        print(
            '::warning::Cache probe skipped (missing FLUTTER_VERSION, GITHUB_REPOSITORY, or GH_TOKEN).'
        )
    else:
        try:
            results = probe(root, flutter_version, repo, token, api_url=api_url)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
            print(f'::warning::Cache probe failed ({exc}); skipping extra cache warming.')

    output = ''.join(f'{name}={str(val).lower()}\n' for name, val in results.items())
    github_output = os.environ.get('GITHUB_OUTPUT')
    if github_output:
        with Path(github_output).open('a', encoding='utf-8') as dest:
            dest.write(output)
    print(output, end='')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
