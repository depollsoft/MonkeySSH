#!/usr/bin/env python3
"""The pty side of the esctest conformance harness (esctest_test.dart).

esctest needs a real tty, and the terminal under test is a Dart object, so
this runs esctest on the slave side of a new pty and relays its master side
over pipes to esctest_test.dart:

* Everything esctest writes to the terminal is copied to stdout as it is.
* The terminal's replies arrive on stdin in frames, so that a resize can
  travel on the same pipe:

      b'D' <length: 4 bytes, big-endian> <bytes>   bytes esctest reads
      b'R' <rows: 2 bytes> <cols: 2 bytes>          the terminal resized

Usage:
    esctest_bridge.py list ESCTEST_DIR
        Print the name of every esctest test, one per line.
    esctest_bridge.py run ESCTEST_DIR ROWS COLS [esctest arguments...]
        Run esctest with these arguments on a ROWS x COLS pty, relaying until
        it exits, and exit with its status.

ESCTEST_DIR is a checkout of https://github.com/ThomasDickey/esctest2. It is
GPL-2.0, so it is fetched at test time (fetch_esctest.sh) and never vendored.
"""

import errno
import fcntl
import inspect
import os
import pty
import select
import signal
import struct
import sys
import termios


def list_tests(esctest_dir):
    sys.path.insert(0, os.path.join(esctest_dir, 'esctest'))
    # esctest's modules import each other in a cycle that only resolves in
    # the order esctest.py imports them, and its decorators read the parsed
    # arguments.
    import escargs
    import esccmd  # noqa: F401
    escargs.args = escargs.parser.parse_args([])
    import tests

    for test_class in tests.tests:
        methods = inspect.getmembers(test_class(), predicate=inspect.ismethod)
        for name, _ in methods:
            if name.startswith('test_'):
                print(test_class.__name__ + '.' + name)
    return 0


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


class Frames:
    """Splits the framed stream from esctest_test.dart into messages."""

    def __init__(self):
        self.buffer = b''

    def feed(self, data):
        self.buffer += data
        while self.buffer:
            kind = self.buffer[:1]
            if kind == b'D':
                if len(self.buffer) < 5:
                    return
                (length,) = struct.unpack('>I', self.buffer[1:5])
                if len(self.buffer) < 5 + length:
                    return
                yield kind, self.buffer[5:5 + length]
                self.buffer = self.buffer[5 + length:]
            elif kind == b'R':
                if len(self.buffer) < 5:
                    return
                yield kind, struct.unpack('>HH', self.buffer[1:5])
                self.buffer = self.buffer[5:]
            else:
                raise ValueError('bad frame type %r' % kind)


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def run(esctest_dir, rows, cols, args):
    pid, master = pty.fork()
    if pid == 0:
        try:
            set_size(0, rows, cols)
            os.chdir(os.path.join(esctest_dir, 'esctest'))
            os.execv(sys.executable,
                     [sys.executable, '-B', 'esctest.py'] + args)
        finally:
            os._exit(127)

    def stop(signum, frame):
        os.kill(pid, signal.SIGKILL)
        os._exit(128 + signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)

    # Replies queue here rather than block: esctest may be busy writing, and
    # it only reads once it has asked for something.
    os.set_blocking(master, False)
    pending = b''
    # esctest reports its own crashes on the pty, so keep the last of what
    # it wrote to show if it exits with an error.
    tail = b''
    frames = Frames()
    stdin_open = True
    while True:
        readers = [master] + ([0] if stdin_open else [])
        writers = [master] if pending else []
        readable, writable, _ = select.select(readers, writers, [])
        if master in readable:
            try:
                data = os.read(master, 65536)
            except BlockingIOError:
                data = None
            except OSError as e:
                # Linux reports the slave side closing as EIO.
                if e.errno != errno.EIO:
                    raise
                data = b''
            if data == b'':
                break
            if data:
                write_all(1, data)
                tail = (tail + data)[-4096:]
        if master in writable:
            try:
                pending = pending[os.write(master, pending):]
            except BlockingIOError:
                pass
        if 0 in readable:
            data = os.read(0, 65536)
            if not data:
                # The harness gave up on this test.
                stdin_open = False
                os.kill(pid, signal.SIGKILL)
                continue
            for kind, payload in frames.feed(data):
                if kind == b'D':
                    pending += payload
                else:
                    set_size(master, *payload)

    _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
    if code != 0:
        sys.stderr.write('esctest exited with %d. It last wrote:\n%s\n' %
                         (code, tail.decode('latin-1')))
    return code


def main(argv):
    if len(argv) >= 3 and argv[1] == 'list':
        return list_tests(argv[2])
    if len(argv) >= 5 and argv[1] == 'run':
        return run(argv[2], int(argv[3]), int(argv[4]), argv[5:])
    sys.stderr.write(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
