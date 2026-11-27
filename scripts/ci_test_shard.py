#!/usr/bin/env python3
"""Deterministically partition Flutter test files into balanced shards.

Discovers every ``*_test.dart`` file under ``test/`` (matching ``flutter test``
default discovery) and assigns each file to exactly one shard using greedy
Longest Processing Time (LPT) bin-packing over a static structural weight.

The weight accounts for per-file isolate compile/load overhead, relative
``*_cases.dart`` imports (bundled suites), widget tests, and subprocess-heavy
shell/git tests so shards stay balanced as tests are added, bundled, or split.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

BASE_FILE_WEIGHT = 15
UNIT_TEST_WEIGHT = 2
WIDGET_TEST_WEIGHT = 12
PROCESS_CALL_WEIGHT = 25
BYTES_PER_WEIGHT = 2000

_TEST_RE = re.compile(r'\btest\s*\(')
_TEST_WIDGETS_RE = re.compile(r'\btestWidgets\s*\(')
_PROCESS_RE = re.compile(r'\bProcess\.(?:run|runSync|start)\s*\(')
_IMPORT_RE = re.compile(r"""^\s*(?:import|part)\s+['"]([^'"]+)['"]""", re.MULTILINE)


def discover_test_files(root: Path) -> list[Path]:
    """Return all ``*_test.dart`` files under ``root``, sorted by POSIX path."""
    if not root.is_dir():
        return []
    return sorted(
        (path for path in root.rglob('*_test.dart') if path.is_file()),
        key=lambda p: p.as_posix(),
    )


def _collect_local_sources(entry: Path, test_root: Path) -> list[Path]:
    """Return ``entry`` plus transitive local ``*_cases.dart`` / part files."""
    seen: set[Path] = set()
    stack = [entry.resolve()]
    resolved_root = test_root.resolve()
    sources: list[Path] = []

    while stack:
        current = stack.pop()
        if current in seen or not current.is_file():
            continue
        seen.add(current)
        sources.append(current)
        try:
            text = current.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        for match in _IMPORT_RE.finditer(text):
            target = match.group(1)
            if target.startswith(('dart:', 'package:')):
                continue
            candidate = (current.parent / target).resolve()
            if not candidate.is_file():
                continue
            try:
                candidate.relative_to(resolved_root)
            except ValueError:
                continue
            # Follow bundled case/part libraries, not shared test helpers.
            if (
                candidate.name.endswith('_cases.dart')
                or candidate.parent == current.parent
                and not candidate.name.endswith('_test.dart')
                and 'helper' not in candidate.name
                and 'fixture' not in candidate.name
            ):
                stack.append(candidate)
    return sources


def estimate_weight(entry: Path, test_root: Path) -> int:
    """Estimate relative runtime weight for a single ``*_test.dart`` file."""
    weight = BASE_FILE_WEIGHT
    for source in _collect_local_sources(entry, test_root):
        try:
            text = source.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        unit_count = len(_TEST_RE.findall(text))
        widget_count = len(_TEST_WIDGETS_RE.findall(text))
        process_count = len(_PROCESS_RE.findall(text))
        weight += (
            unit_count * UNIT_TEST_WEIGHT
            + widget_count * WIDGET_TEST_WEIGHT
            + process_count * PROCESS_CALL_WEIGHT
            + len(text) // BYTES_PER_WEIGHT
        )
    return max(weight, 1)


def partition_shards(
    files: list[Path],
    total_shards: int,
    test_root: Path,
    base_dir: Path | None = None,
) -> list[tuple[int, list[str]]]:
    """Partition ``files`` into ``total_shards`` balanced buckets.

    Returns a list of ``(total_weight, [relative_posix_paths])`` indexed by
    shard index. Every input file appears in exactly one shard.
    """
    if total_shards < 1:
        raise ValueError(f'total_shards must be >= 1, got {total_shards}')

    weighted: list[tuple[int, str]] = []
    for path in files:
        rel = path.relative_to(base_dir).as_posix() if base_dir else path.as_posix()
        weighted.append((estimate_weight(path, test_root), rel))

    # Deterministic LPT order: heaviest first, alphabetical tie-break.
    weighted.sort(key=lambda item: (-item[0], item[1]))

    buckets: list[list[str]] = [[] for _ in range(total_shards)]
    loads = [0] * total_shards
    for weight, rel in weighted:
        target = min(range(total_shards), key=lambda i: (loads[i], len(buckets[i]), i))
        buckets[target].append(rel)
        loads[target] += weight

    return [(loads[i], sorted(buckets[i])) for i in range(total_shards)]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test-dir', default='test', help='Root test directory (default: test)')
    parser.add_argument('--total-shards', type=int, required=True, help='Total number of shards')
    parser.add_argument('--shard-index', type=int, help='0-based shard index to select')
    parser.add_argument(
        '--summary',
        action='store_true',
        help='Print load summary across all shards and exit',
    )
    parser.add_argument(
        '--run',
        action='store_true',
        help='Execute the command after `--` with the selected shard files appended',
    )
    parser.add_argument('command', nargs=argparse.REMAINDER, help='Command to run after `--`')
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    base_dir = Path.cwd().resolve()
    test_root = (base_dir / args.test_dir).resolve()
    files = discover_test_files(test_root)
    shards = partition_shards(files, args.total_shards, test_root, base_dir=base_dir)

    if args.summary:
        total_weight = sum(load for load, _ in shards)
        for index, (load, items) in enumerate(shards):
            print(f'shard {index}/{args.total_shards}: files={len(items):3d} weight={load:5d}')
        print(f'total: files={len(files)} weight={total_weight}')
        return 0

    if args.shard_index is None:
        raise SystemExit('--shard-index is required unless --summary is set')
    if not (0 <= args.shard_index < args.total_shards):
        raise SystemExit(
            f'--shard-index must be in [0, {args.total_shards - 1}], got {args.shard_index}'
        )

    load, selected = shards[args.shard_index]
    total_weight = sum(w for w, _ in shards)
    print(
        f'Shard {args.shard_index}/{args.total_shards}: '
        f'{len(selected)}/{len(files)} files, weight {load}/{total_weight}',
        file=sys.stderr,
    )

    if args.run:
        cmd = list(args.command)
        if cmd and cmd[0] == '--':
            cmd = cmd[1:]
        if not cmd:
            raise SystemExit('--run requires a command after `--`')
        if not files:
            print(f'No *_test.dart files discovered under {test_root}.', file=sys.stderr)
            return 1
        if not selected:
            print('No test files assigned to this shard; skipping.', file=sys.stderr)
            return 0
        completed = subprocess.run([*cmd, *selected], check=False)
        return completed.returncode

    for rel in selected:
        print(rel)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
