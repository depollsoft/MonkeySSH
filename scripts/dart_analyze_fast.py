#!/usr/bin/env python3
"""Fast local Dart analyzer backed by a per-worktree Dart Analysis Server.

Uses Dart's own `dart language-server --protocol=analyzer` (the same analysis
engine invoked by `flutter analyze` and `dart analyze`) and keeps it warm in
the background per worktree so repeated inner-loop checks (`pre-commit`,
`pre-push`, `dev_check.sh`) complete in milliseconds instead of 10-23 seconds.

Guarantees parity with `dart analyze --fatal-warnings --fatal-infos`:
  * Restarts automatically when analysis_options.yaml, pubspec.yaml,
    pubspec.lock, .dart_tool/package_config.json, the Dart binary, or this
    script changes.
  * Synchronizes modified/added/deleted Dart files on disk before querying
    errors so filesystem-watcher lag can never serve stale results.
  * Filters out TODO diagnostics (matching `dart analyze` defaults) and
    enforces --fatal-warnings and --fatal-infos identically.
  * Falls back transparently to `dart analyze` on CI, when
    DART_ANALYZE_DAEMON=0, or if the daemon encounters any unexpected error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

SCRIPT_PATH = Path(__file__).resolve()
DEFAULT_IDLE_TIMEOUT = 1200  # 20 minutes
CONNECT_TIMEOUT = 1.5
STARTUP_TIMEOUT = 45.0
REQUEST_TIMEOUT = 120.0
IGNORED_TOP_DIRS = frozenset({
    '.dart_tool',
    '.git',
    'android',
    'assets',
    'build',
    'docs',
    'functions',
    'ios',
    'linux',
    'macos',
    'remote',
    'scripts',
    'store',
    'third_party',
    'windows',
})


def find_repo_root(start: Path) -> Path:
    cur = start.resolve()
    for candidate in (cur, *cur.parents):
        if (candidate / 'pubspec.yaml').is_file():
            return candidate
    return cur


def resolve_dart_bin() -> str:
    dart = shutil.which('dart')
    if dart:
        return os.path.realpath(dart)
    flutter = shutil.which('flutter')
    if flutter:
        candidate = Path(os.path.realpath(flutter)).parent / 'dart'
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError('Could not locate `dart` on PATH')


def compute_config_fingerprint(root: Path, dart_bin: str) -> str:
    h = hashlib.sha256()
    h.update(f'dart={dart_bin}\n'.encode())
    h.update(f'root={root}\n'.encode())
    for rel in (
        'analysis_options.yaml',
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
    ):
        p = root / rel
        h.update(f'file={rel}\n'.encode())
        if p.is_file():
            h.update(p.read_bytes())
        else:
            h.update(b'<missing>')
    h.update(b'script=')
    h.update(SCRIPT_PATH.read_bytes())
    return h.hexdigest()


def socket_path_for(root: Path) -> Path:
    # Keep Unix domain socket paths well below macOS's 104-byte sun_path limit
    # even when worktree paths are deeply nested.
    digest = hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:16]
    uid = os.getuid() if hasattr(os, 'getuid') else 0
    return Path(tempfile.gettempdir()) / f'monkeyssh-dart-an-{uid}-{digest}.sock'


def meta_path_for(root: Path) -> Path:
    return root / '.dart_tool' / 'dart_analyze_daemon.json'


def scan_dart_files(root: Path) -> dict[str, tuple[int, int]]:
    """Return {abs_path: (mtime_ns, size)} for non-excluded Dart files."""
    snapshot: dict[str, tuple[int, int]] = {}
    root_str = str(root)
    for dirpath, dirnames, filenames in os.walk(root_str):
        if dirpath == root_str:
            dirnames[:] = [
                d for d in dirnames
                if d not in IGNORED_TOP_DIRS and not d.startswith('.')
            ]
        else:
            dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        for name in filenames:
            if not name.endswith('.dart'):
                continue
            full = os.path.join(dirpath, name)
            try:
                st = os.stat(full)
            except OSError:
                continue
            snapshot[full] = (st.st_mtime_ns, st.st_size)
    return snapshot


def is_excluded_by_default(rel_posix: str) -> bool:
    if rel_posix.endswith(('.g.dart', '.freezed.dart', '.mocks.dart')):
        return True
    first = rel_posix.split('/', 1)[0]
    return first in IGNORED_TOP_DIRS


def normalize_targets(root: Path, raw_targets: list[str]) -> tuple[bool, list[str]]:
    """Return (whole_repo, abs_dart_files)."""
    if not raw_targets:
        return True, []
    root_resolved = root.resolve()
    files: list[str] = []
    seen: set[str] = set()
    for raw in raw_targets:
        p = Path(raw)
        if not p.is_absolute():
            p = (Path.cwd() / p).resolve()
        else:
            p = p.resolve()
        if p == root_resolved:
            return True, []
        if p.is_dir():
            for child in sorted(p.rglob('*.dart')):
                child_res = child.resolve()
                try:
                    rel = child_res.relative_to(root_resolved).as_posix()
                except ValueError:
                    continue
                if is_excluded_by_default(rel):
                    continue
                s = str(child_res)
                if s not in seen:
                    seen.add(s)
                    files.append(s)
        elif p.is_file():
            s = str(p)
            if s not in seen:
                seen.add(s)
                files.append(s)
        else:
            raise FileNotFoundError(f'Target path does not exist: {raw}')
    return False, files


class AnalysisServerBridge:
    """Manages a single `dart language-server --protocol=analyzer` child."""

    def __init__(self, root: Path, dart_bin: str) -> None:
        self.root = root.resolve()
        self.dart_bin = dart_bin
        self._req_id = 0
        self._lock = threading.Lock()
        self._pending: dict[str, tuple[threading.Event, dict]] = {}
        self._errors_by_file: dict[str, list[dict]] = {}
        self._is_analyzing = False
        self._seen_analyzing = False
        self._idle_cond = threading.Condition()
        self._closed = False
        self._stderr_lines: list[str] = []
        self._file_snapshot: dict[str, tuple[int, int]] = {}
        self._content_hashes: dict[str, bytes] = {}
        self.proc = subprocess.Popen(
            [dart_bin, 'language-server', '--protocol=analyzer'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=str(self.root),
        )
        self._stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            if len(self._stderr_lines) < 50:
                self._stderr_lines.append(line.rstrip())

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        try:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if 'id' in msg:
                    rid = str(msg['id'])
                    with self._lock:
                        entry = self._pending.pop(rid, None)
                    if entry is not None:
                        ev, box = entry
                        box['msg'] = msg
                        ev.set()
                    continue
                event = msg.get('event')
                if event == 'analysis.errors':
                    params = msg.get('params', {})
                    file_path = params.get('file')
                    if file_path:
                        self._errors_by_file[file_path] = params.get('errors', [])
                elif event == 'server.status':
                    analysis = msg.get('params', {}).get('analysis')
                    if analysis is not None:
                        is_an = bool(analysis.get('isAnalyzing', False))
                        with self._idle_cond:
                            self._is_analyzing = is_an
                            if is_an:
                                self._seen_analyzing = True
                            if not is_an:
                                self._idle_cond.notify_all()
        finally:
            with self._idle_cond:
                self._closed = True
                self._idle_cond.notify_all()
            with self._lock:
                for ev, box in self._pending.values():
                    box['error'] = 'analysis server exited unexpectedly'
                    ev.set()
                self._pending.clear()

    def _request(self, method: str, params: dict | None = None, timeout: float = 60.0) -> dict:
        if self._closed:
            raise RuntimeError('analysis server is closed')
        ev = threading.Event()
        box: dict = {}
        with self._lock:
            self._req_id += 1
            rid = str(self._req_id)
            self._pending[rid] = (ev, box)
            payload: dict = {'id': rid, 'method': method}
            if params is not None:
                payload['params'] = params
            assert self.proc.stdin is not None
            self.proc.stdin.write(json.dumps(payload) + '\n')
            self.proc.stdin.flush()
        if not ev.wait(timeout=timeout):
            with self._lock:
                self._pending.pop(rid, None)
            raise TimeoutError(f'analysis server timed out on {method}')
        if 'error' in box:
            raise RuntimeError(box['error'])
        return box['msg']

    def _wait_for_idle(self, require_analyzing_edge: bool = False, timeout: float = 90.0) -> None:
        deadline = time.monotonic() + timeout
        with self._idle_cond:
            while not self._closed:
                if not self._is_analyzing and (not require_analyzing_edge or self._seen_analyzing):
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('analysis server timed out waiting for idle')
                self._idle_cond.wait(timeout=remaining)
        if self._closed:
            raise RuntimeError('analysis server exited while analyzing')

    def initialize(self) -> None:
        self._file_snapshot = scan_dart_files(self.root)
        self._request('server.setSubscriptions', {'subscriptions': ['STATUS']})
        self._request(
            'analysis.setAnalysisRoots',
            {'included': [str(self.root)], 'excluded': []},
        )
        self._wait_for_idle(require_analyzing_edge=True, timeout=STARTUP_TIMEOUT)

    def _wait_for_analysis_settlement(
        self,
        *,
        edge_wait: float = 0.5,
        timeout: float = REQUEST_TIMEOUT,
    ) -> None:
        """Wait for a triggered analysis pass to start (bounded) and finish."""
        edge_deadline = time.monotonic() + edge_wait
        with self._idle_cond:
            while not self._closed and not self._seen_analyzing:
                remaining = edge_deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._idle_cond.wait(timeout=remaining)
            idle_deadline = time.monotonic() + timeout
            while not self._closed and self._is_analyzing:
                remaining = idle_deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('analysis server timed out waiting for idle')
                self._idle_cond.wait(timeout=remaining)
        if self._closed:
            raise RuntimeError('analysis server exited while analyzing')

    def sync_filesystem(self, requested_files: list[str] | None = None) -> None:
        """Synchronize disk edits/additions/deletions with the analysis server."""
        current = scan_dart_files(self.root)
        prev = self._file_snapshot

        added = set(current) - set(prev)
        removed = set(prev) - set(current)
        modified = {
            path for path, sig in current.items()
            if path in prev and prev[path] != sig
        }
        # Also check content hashes of explicitly requested files so edits
        # within the same filesystem mtime tick are never missed, without
        # triggering redundant re-analysis when bytes are unchanged.
        if requested_files:
            for path in requested_files:
                if path not in current or path in added or path in modified:
                    continue
                try:
                    digest = hashlib.sha256(Path(path).read_bytes()).digest()
                except OSError:
                    continue
                prev_digest = self._content_hashes.get(path)
                self._content_hashes[path] = digest
                if prev_digest is not None and prev_digest != digest:
                    modified.add(path)

        changed = sorted(added | modified)
        if added or removed:
            for path in removed:
                self._errors_by_file.pop(path, None)
                self._content_hashes.pop(path, None)
            with self._idle_cond:
                self._seen_analyzing = False
            self._request(
                'analysis.setAnalysisRoots',
                {'included': [str(self.root)], 'excluded': []},
            )
            if changed:
                self._refresh_files(changed)
                self._request('analysis.getErrors', {'file': changed[0]}, timeout=REQUEST_TIMEOUT)
            self._wait_for_analysis_settlement(timeout=REQUEST_TIMEOUT)
            self._request('server.getVersion', timeout=10.0)
        elif modified:
            with self._idle_cond:
                self._seen_analyzing = False
            self._refresh_files(changed)
            self._request('analysis.getErrors', {'file': changed[0]}, timeout=REQUEST_TIMEOUT)
            self._wait_for_analysis_settlement(timeout=REQUEST_TIMEOUT)
            self._request('server.getVersion', timeout=10.0)

        self._file_snapshot = current

    def _refresh_files(self, paths: list[str]) -> None:
        adds: dict[str, dict] = {}
        removes: dict[str, dict] = {}
        for path in paths:
            try:
                raw = Path(path).read_bytes()
            except OSError:
                continue
            self._content_hashes[path] = hashlib.sha256(raw).digest()
            content = raw.decode('utf-8', errors='replace')
            adds[path] = {'type': 'add', 'content': content}
            removes[path] = {'type': 'remove'}
        if not adds:
            return
        self._request('analysis.updateContent', {'files': adds})
        self._request('analysis.updateContent', {'files': removes})

    def get_errors(self, whole_repo: bool, files: list[str]) -> list[dict]:
        self.sync_filesystem(None if whole_repo else files)
        results: list[dict] = []
        if whole_repo:
            # Ensure all pending analysis notifications have been flushed.
            self._wait_for_idle(require_analyzing_edge=False, timeout=REQUEST_TIMEOUT)
            root_prefix = str(self.root) + os.sep
            for file_path in sorted(self._errors_by_file):
                if not file_path.startswith(root_prefix):
                    continue
                if not os.path.isfile(file_path):
                    continue
                results.extend(self._errors_by_file[file_path])
            return results

        for file_path in files:
            resp = self._request('analysis.getErrors', {'file': file_path}, timeout=REQUEST_TIMEOUT)
            if 'error' in resp:
                code = resp['error'].get('code', '')
                # Excluded or non-analyzed files (e.g. third_party/, *.g.dart).
                if code == 'GET_ERRORS_INVALID_FILE':
                    continue
                raise RuntimeError(f"analysis.getErrors failed: {resp['error']}")
            results.extend(resp.get('result', {}).get('errors', []))
        return results

    def shutdown(self) -> None:
        try:
            if not self._closed:
                self._request('server.shutdown', timeout=2.0)
        except Exception:
            pass
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def filter_errors(
    errors: list[dict],
    *,
    fatal_warnings: bool,
    fatal_infos: bool,
) -> tuple[list[dict], bool]:
    """Filter raw analysis_server errors to match `dart analyze`."""
    visible: list[dict] = []
    has_fatal = False
    for err in errors:
        # `dart analyze` omits TODO comments unless explicitly enabled in
        # analysis_options.yaml; analysis_server emits them with type == 'TODO'.
        if err.get('type') == 'TODO':
            continue
        severity = str(err.get('severity', 'INFO')).upper()
        visible.append(err)
        if severity == 'ERROR':
            has_fatal = True
        elif severity == 'WARNING' and fatal_warnings:
            has_fatal = True
        elif severity == 'INFO' and fatal_infos:
            has_fatal = True
    visible.sort(
        key=lambda e: (
            e.get('location', {}).get('file', ''),
            int(e.get('location', {}).get('startLine', 0)),
            int(e.get('location', {}).get('startColumn', 0)),
            str(e.get('code', '')),
        )
    )
    return visible, has_fatal


def format_errors(root: Path, errors: list[dict]) -> str:
    lines: list[str] = []
    root_resolved = root.resolve()
    for err in errors:
        severity = str(err.get('severity', 'INFO')).lower()
        message = str(err.get('message', '')).rstrip('.')
        code = str(err.get('code', '')).lower()
        loc = err.get('location', {})
        raw_file = loc.get('file', '')
        try:
            rel_file = str(Path(raw_file).resolve().relative_to(root_resolved))
        except Exception:
            rel_file = raw_file
        line = loc.get('startLine', 1)
        col = loc.get('startColumn', 1)
        lines.append(f'  {severity} • {message} • {rel_file}:{line}:{col} • {code}')
    return '\n'.join(lines)


def run_daemon(root: Path, dart_bin: str, fingerprint: str, idle_timeout: int) -> int:
    sock_path = socket_path_for(root)
    meta_path = meta_path_for(root)
    meta_path.parent.mkdir(parents=True, exist_ok=True)

    # Remove stale socket if present.
    try:
        sock_path.unlink()
    except FileNotFoundError:
        pass

    bridge = AnalysisServerBridge(root, dart_bin)
    try:
        bridge.initialize()
    except Exception:
        bridge.shutdown()
        raise

    server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old_umask = os.umask(0o177)
    try:
        server_sock.bind(str(sock_path))
    finally:
        os.umask(old_umask)
    server_sock.listen(16)
    server_sock.setblocking(False)

    meta = {
        'pid': os.getpid(),
        'root': str(root.resolve()),
        'socket': str(sock_path),
        'fingerprint': fingerprint,
        'started_at': time.time(),
    }
    meta_tmp = meta_path.with_suffix('.tmp')
    meta_tmp.write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    meta_tmp.replace(meta_path)

    stop_requested = False

    def _handle_sig(_signum: int, _frame: object) -> None:
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGTERM, _handle_sig)
    signal.signal(signal.SIGINT, _handle_sig)

    sel = selectors.DefaultSelector()
    sel.register(server_sock, selectors.EVENT_READ)
    last_activity = time.monotonic()

    try:
        while not stop_requested and not bridge._closed:
            remaining = idle_timeout - (time.monotonic() - last_activity)
            if remaining <= 0:
                break
            events = sel.select(timeout=min(remaining, 1.0))
            if not events:
                continue
            try:
                conn, _ = server_sock.accept()
            except OSError:
                continue
            last_activity = time.monotonic()
            with conn:
                conn.settimeout(REQUEST_TIMEOUT)
                try:
                    req_raw = _recv_line(conn)
                    if not req_raw:
                        continue
                    req = json.loads(req_raw)
                except Exception as exc:
                    _send_json(conn, {'ok': False, 'error': f'bad request: {exc}'})
                    continue

                action = req.get('action')
                if action == 'ping':
                    _send_json(conn, {'ok': True, 'pid': os.getpid(), 'fingerprint': fingerprint})
                elif action == 'shutdown':
                    _send_json(conn, {'ok': True})
                    stop_requested = True
                elif action == 'analyze':
                    if req.get('fingerprint') != fingerprint:
                        _send_json(conn, {'ok': False, 'stale': True})
                        stop_requested = True
                        continue
                    try:
                        raw_errors = bridge.get_errors(
                            bool(req.get('whole_repo', False)),
                            list(req.get('files', [])),
                        )
                        _send_json(conn, {'ok': True, 'errors': raw_errors})
                    except Exception as exc:
                        _send_json(conn, {'ok': False, 'error': str(exc)})
                        stop_requested = True
                else:
                    _send_json(conn, {'ok': False, 'error': f'unknown action: {action}'})
    finally:
        sel.close()
        server_sock.close()
        bridge.shutdown()
        try:
            sock_path.unlink()
        except FileNotFoundError:
            pass
        try:
            if meta_path.is_file():
                existing = json.loads(meta_path.read_text(encoding='utf-8'))
                if existing.get('pid') == os.getpid():
                    meta_path.unlink()
        except Exception:
            pass
    return 0


def _recv_line(sock: socket.socket) -> str:
    chunks: list[bytes] = []
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        nl = chunk.find(b'\n')
        if nl != -1:
            chunks.append(chunk[:nl])
            break
        chunks.append(chunk)
    return b''.join(chunks).decode('utf-8', errors='replace')


def _send_json(sock: socket.socket, obj: dict) -> None:
    data = (json.dumps(obj) + '\n').encode('utf-8')
    sock.sendall(data)


def request_daemon(sock_path: Path, payload: dict, timeout: float = REQUEST_TIMEOUT) -> dict | None:
    if not sock_path.exists():
        return None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(str(sock_path))
        sock.settimeout(timeout)
        _send_json(sock, payload)
        raw = _recv_line(sock)
        if not raw:
            return None
        return json.loads(raw)
    except OSError:
        return None
    finally:
        sock.close()


def spawn_daemon(root: Path, idle_timeout: int) -> bool:
    sock_path = socket_path_for(root)
    log_path = root / '.dart_tool' / 'dart_analyze_daemon.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, 'ab') as log_file:
        subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT_PATH),
                '--_daemon',
                '--root',
                str(root),
                '--idle-timeout',
                str(idle_timeout),
            ],
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=log_file,
            start_new_session=True,
            close_fds=True,
        )
    deadline = time.monotonic() + STARTUP_TIMEOUT
    while time.monotonic() < deadline:
        resp = request_daemon(sock_path, {'action': 'ping'}, timeout=2.0)
        if resp and resp.get('ok'):
            return True
        time.sleep(0.05)
    return False


def run_fallback_dart_analyze(
    root: Path,
    dart_bin: str,
    raw_targets: list[str],
    *,
    fatal_warnings: bool,
    fatal_infos: bool,
) -> int:
    cmd = [dart_bin, 'analyze']
    cmd.append('--fatal-warnings' if fatal_warnings else '--no-fatal-warnings')
    if fatal_infos:
        cmd.append('--fatal-infos')
    if raw_targets:
        cmd.append('--')
        cmd.extend(raw_targets)
    proc = subprocess.run(cmd, cwd=str(root))
    return proc.returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Fast Dart analyzer using a per-worktree Analysis Server daemon.'
    )
    parser.add_argument(
        '--fatal-warnings',
        dest='fatal_warnings',
        action='store_true',
        default=True,
        help='Treat warning-level issues as fatal (default: on).',
    )
    parser.add_argument(
        '--no-fatal-warnings',
        dest='fatal_warnings',
        action='store_false',
        help='Do not treat warning-level issues as fatal.',
    )
    parser.add_argument(
        '--fatal-infos',
        dest='fatal_infos',
        action='store_true',
        default=False,
        help='Treat info-level issues as fatal.',
    )
    parser.add_argument(
        '--no-daemon',
        action='store_true',
        help='Bypass the daemon and invoke `dart analyze` directly.',
    )
    parser.add_argument(
        '--stop',
        action='store_true',
        help='Stop the running daemon for this worktree and exit.',
    )
    parser.add_argument(
        '--status',
        action='store_true',
        help='Print daemon status for this worktree and exit.',
    )
    parser.add_argument(
        '--root',
        type=Path,
        default=None,
        help='Explicit package root directory.',
    )
    parser.add_argument(
        '--idle-timeout',
        type=int,
        default=int(os.environ.get('DART_ANALYZE_DAEMON_IDLE', DEFAULT_IDLE_TIMEOUT)),
        help='Daemon idle shutdown timeout in seconds.',
    )
    parser.add_argument('--_daemon', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('targets', nargs='*')
    args = parser.parse_args(argv)

    root = (args.root or find_repo_root(Path.cwd())).resolve()
    dart_bin = resolve_dart_bin()
    fingerprint = compute_config_fingerprint(root, dart_bin)
    sock_path = socket_path_for(root)

    if args._daemon:
        return run_daemon(root, dart_bin, fingerprint, args.idle_timeout)

    if args.stop:
        resp = request_daemon(sock_path, {'action': 'shutdown'}, timeout=3.0)
        if resp and resp.get('ok'):
            print('Stopped Dart analysis daemon.')
        else:
            print('Dart analysis daemon is not running.')
        return 0

    if args.status:
        resp = request_daemon(sock_path, {'action': 'ping'}, timeout=2.0)
        if resp and resp.get('ok'):
            stale = resp.get('fingerprint') != fingerprint
            state = 'running (stale config)' if stale else 'running'
            print(f"Dart analysis daemon {state} (pid={resp.get('pid')}, socket={sock_path})")
            return 0
        print('Dart analysis daemon is not running.')
        return 1

    ci_active = os.environ.get('CI', '').lower() in {'1', 'true', 'yes'}
    daemon_disabled = os.environ.get('DART_ANALYZE_DAEMON', '1') == '0'
    if args.no_daemon or ci_active or daemon_disabled or not hasattr(socket, 'AF_UNIX'):
        return run_fallback_dart_analyze(
            root,
            dart_bin,
            args.targets,
            fatal_warnings=args.fatal_warnings,
            fatal_infos=args.fatal_infos,
        )

    try:
        whole_repo, files = normalize_targets(root, args.targets)
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if not whole_repo and not files:
        print('No issues found!')
        return 0

    t0 = time.perf_counter()
    payload = {
        'action': 'analyze',
        'fingerprint': fingerprint,
        'whole_repo': whole_repo,
        'files': files,
    }
    resp = request_daemon(sock_path, payload)
    if resp is None or resp.get('stale'):
        # Start (or restart after stale config) the daemon, then retry once.
        if resp and resp.get('stale'):
            time.sleep(0.1)
        if spawn_daemon(root, args.idle_timeout):
            resp = request_daemon(sock_path, payload)

    if not resp or not resp.get('ok'):
        return run_fallback_dart_analyze(
            root,
            dart_bin,
            args.targets,
            fatal_warnings=args.fatal_warnings,
            fatal_infos=args.fatal_infos,
        )

    visible, has_fatal = filter_errors(
        resp.get('errors', []),
        fatal_warnings=args.fatal_warnings,
        fatal_infos=args.fatal_infos,
    )
    elapsed = time.perf_counter() - t0
    if visible:
        print(format_errors(root, visible))
        count = len(visible)
        noun = 'issue' if count == 1 else 'issues'
        print(f'\n{count} {noun} found. (ran in {elapsed:.2f}s)')
        return 1 if has_fatal else 0

    print(f'No issues found! (ran in {elapsed:.2f}s)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
