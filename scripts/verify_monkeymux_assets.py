#!/usr/bin/env python3
"""Verify every generated payload against its manifest before reusing it."""

import gzip
import hashlib
import json
from pathlib import Path
import sys


PLATFORMS = {
    f'{system}-{arch}'
    for system in ('darwin', 'linux', 'windows')
    for arch in ('amd64', 'arm64')
}


def verify(asset_dir, version):
    manifest = json.loads((asset_dir / 'manifest.json').read_text())
    if manifest['version'] != version:
        raise ValueError('manifest version does not match source')
    entries = manifest['entries']
    if len(entries) != len(PLATFORMS) or {e['platform'] for e in entries} != PLATFORMS:
        raise ValueError('manifest must contain exactly the six supported platforms')
    for entry in entries:
        relative = f"bin/{entry['platform']}/monkeymux.gz"
        if entry['asset'] != f'assets/monkeymux/{relative}' or entry['encoding'] != 'gzip':
            raise ValueError('invalid payload path or encoding')
        digest = hashlib.sha256()
        size = 0
        with gzip.open(asset_dir / relative, 'rb') as payload:
            while chunk := payload.read(1024 * 1024):
                size += len(chunk)
                if size > entry['size']:
                    raise ValueError('payload exceeds manifest size')
                digest.update(chunk)
        if size != entry['size'] or digest.hexdigest() != entry['sha256']:
            raise ValueError('payload does not match manifest')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]), sys.argv[2])
    except (OSError, EOFError, ValueError, KeyError, TypeError) as error:
        print(f'MonkeyMux assets need rebuilding: {error}', file=sys.stderr)
        sys.exit(1)
