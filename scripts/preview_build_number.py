#!/usr/bin/env python3
"""Give independently scheduled platform builds the same PR-event version."""

from datetime import datetime
import json
import os
from pathlib import Path


def build_number(event):
    updated = datetime.fromisoformat(event['pull_request']['updated_at'].replace('Z', '+00:00'))
    if updated.tzinfo is None:
        raise ValueError('PR update timestamp must include a timezone')
    number = int(updated.timestamp()) // 10
    if not 0 < number <= 2147483647:
        raise ValueError('PR update timestamp is outside the Android version-code range')
    return number


if __name__ == '__main__':
    print(build_number(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())))
