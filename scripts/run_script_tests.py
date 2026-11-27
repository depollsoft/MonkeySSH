#!/usr/bin/env python3
"""Run Python script unittest suites in parallel across worker processes.

Discovers every matching test file under ``test/scripts`` and executes each file
in its own ``python -m unittest`` subprocess so slow suites run concurrently
without sharing process-global state, CWD, or environment mutations.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import os
from pathlib import Path
import subprocess
import sys
import time


def discover_test_modules(test_dir: Path, pattern: str = '*_test.py') -> list[Path]:
    """Return sorted test files matching ``pattern`` under ``test_dir``."""
    if not test_dir.is_dir():
        return []
    return sorted(
        (path for path in test_dir.glob(pattern) if path.is_file()),
        key=lambda p: p.as_posix(),
    )


def _run_one(args: tuple[str, str, str, str]) -> tuple[str, int, float, str, str]:
    python_exe, repo_root, start_dir, filename = args
    rel_path = f'{start_dir}/{filename}'
    start = time.monotonic()
    proc = subprocess.run(
        [python_exe, '-m', 'unittest', 'discover', '-s', start_dir, '-p', filename],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.monotonic() - start
    return rel_path, proc.returncode, elapsed, proc.stdout, proc.stderr


def run_suites(
    test_dir: Path,
    *,
    pattern: str = '*_test.py',
    jobs: int | None = None,
    python_exe: str | None = None,
    repo_root: Path | None = None,
) -> tuple[int, list[tuple[str, int, float, str, str]]]:
    """Run all discovered test modules in parallel and return ``(exit_code, results)``."""
    root = (repo_root or Path.cwd()).resolve()
    resolved_dir = (root / test_dir).resolve() if not test_dir.is_absolute() else test_dir.resolve()
    modules = discover_test_modules(resolved_dir, pattern)
    if not modules:
        return 1, []

    exe = python_exe or sys.executable
    workers = max(1, min(jobs or (os.cpu_count() or 4), len(modules)))
    start_dir = resolved_dir.relative_to(root).as_posix()
    tasks = [(exe, str(root), start_dir, mod.name) for mod in modules]

    results: list[tuple[str, int, float, str, str]] = []
    if workers == 1:
        results = [_run_one(task) for task in tasks]
    else:
        with ProcessPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(_run_one, task) for task in tasks]
            for future in as_completed(futures):
                results.append(future.result())

    results.sort(key=lambda item: item[0])
    exit_code = 0 if all(code == 0 for _, code, _, _, _ in results) else 1
    return exit_code, results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('-s', '--start-directory', default='test/scripts')
    parser.add_argument('-p', '--pattern', default='*_test.py')
    parser.add_argument('-j', '--jobs', type=int, default=None)
    args = parser.parse_args(argv)

    start = time.monotonic()
    exit_code, results = run_suites(
        Path(args.start_directory),
        pattern=args.pattern,
        jobs=args.jobs,
    )
    total_elapsed = time.monotonic() - start

    if not results:
        print(
            f'No test files matched {args.pattern!r} in {args.start_directory}',
            file=sys.stderr,
        )
        return 1

    failures = 0
    for rel_path, code, elapsed, stdout, stderr in results:
        status = 'PASS' if code == 0 else 'FAIL'
        print(f'[{status}] {rel_path} ({elapsed:.2f}s)')
        if code != 0:
            failures += 1
            if stdout:
                print(stdout, end='' if stdout.endswith('\n') else '\n')
            if stderr:
                print(stderr, end='' if stderr.endswith('\n') else '\n', file=sys.stderr)

    print(
        f'Ran {len(results)} Python test suites in {total_elapsed:.2f}s '
        f'({len(results) - failures} passed, {failures} failed).'
    )
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
