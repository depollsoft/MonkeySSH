part of 'ssh_service.dart';

class _AppReviewDemoSshClient implements SSHClient {
  _AppReviewDemoSshClient(this.host);

  final Host host;
  final _done = Completer<void>();
  bool _isClosed = false;
  _AppReviewDemoSftpClient? _sftp;

  @override
  String? get remoteVersion => 'SSH-2.0-MonkeySSH_App_Review_Demo';

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> get authenticated => Future<void>.value();

  @override
  String get username => host.username;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => _AppReviewDemoSshSession.interactive(host);

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    if (pty != null && _looksLikeLoginShellCommand(command)) {
      return _AppReviewDemoSshSession.interactive(host);
    }
    return _AppReviewDemoSshSession.completed(_demoExecOutput(command));
  }

  @override
  Future<SftpClient> sftp() async => _sftp ??= _AppReviewDemoSftpClient();

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async => _AppReviewDemoForwardChannel(
    remoteHost: remoteHost,
    remotePort: remotePort,
  );

  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async => null;

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async => Uint8List.fromList(utf8.encode(_demoExecOutput(command)));

  @override
  Future<SSHRunResult> runWithResult(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final output = Uint8List.fromList(utf8.encode(_demoExecOutput(command)));
    return SSHRunResult(
      output: output,
      stdout: stdout ? output : Uint8List(0),
      stderr: Uint8List(0),
      exitCode: 0,
      exitSignal: null,
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    await _sftp?.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  static bool _looksLikeLoginShellCommand(String command) =>
      command.contains('COLORTERM=truecolor') ||
      command.contains('TERM_PROGRAM=kitty') ||
      command.contains('/bin/sh -lc');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSshSession implements SSHSession {
  _AppReviewDemoSshSession._({required this.exitCode})
    : _stdinController = StreamController<Uint8List>(),
      _stdoutController = StreamController<Uint8List>(),
      _stderrController = StreamController<Uint8List>() {
    _stdinSubscription = _stdinController.stream.listen(_handleInput);
  }

  factory _AppReviewDemoSshSession.interactive(Host host) {
    final session = _AppReviewDemoSshSession._(exitCode: null);
    scheduleMicrotask(() {
      session
        .._writeText(_demoInteractiveBanner(host))
        .._writePrompt();
    });
    return session;
  }

  factory _AppReviewDemoSshSession.completed(String stdout) {
    final session = _AppReviewDemoSshSession._(exitCode: 0);
    scheduleMicrotask(() async {
      if (stdout.isNotEmpty) {
        session._writeText(stdout);
      }
      await session._finish(exitCode: 0);
    });
    return session;
  }

  @override
  final int? exitCode;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  late final StreamSubscription<Uint8List> _stdinSubscription;
  final StreamController<Uint8List> _stdinController;
  final StreamController<Uint8List> _stdoutController;
  final StreamController<Uint8List> _stderrController;
  final _done = Completer<void>();
  final _exitCompleter = Completer<int?>();
  final _input = StringBuffer();
  bool _closed = false;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> get done => _done.future;

  // Callers destroy abandoned exec and shell channels through this.
  @override
  late final SSHChannel channel = _AppReviewDemoSshChannel(this);

  @override
  void write(Uint8List data) {
    if (!_closed) {
      _handleInput(data);
    }
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  void close() {
    unawaited(_finish(exitCode: exitCode));
  }

  @override
  Future<int?> waitForExit({Duration? timeout}) {
    final future = _exitCompleter.future;
    return timeout == null
        ? future
        : future.timeout(timeout, onTimeout: () => null);
  }

  @override
  void kill(SSHSignal signal) {
    _writeText('^C\r\n');
    close();
  }

  void _handleInput(Uint8List data) {
    if (_closed) {
      return;
    }
    final text = utf8.decode(data, allowMalformed: true);
    for (var i = 0; i < text.length; i += 1) {
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit == 0x03) {
        _input.clear();
        _writeText('^C\r\n');
        _writePrompt();
        continue;
      }
      if (codeUnit == 0x04) {
        close();
        continue;
      }
      if (codeUnit == 0x7F || codeUnit == 0x08) {
        final current = _input.toString();
        if (current.isNotEmpty) {
          _input
            ..clear()
            ..write(current.substring(0, current.length - 1));
          _writeText('\b \b');
        }
        continue;
      }
      if (codeUnit == 0x0D || codeUnit == 0x0A) {
        final command = _input.toString().trim();
        _input.clear();
        _writeText('\r\n');
        _runInteractiveCommand(command);
        if (!_closed) {
          _writePrompt();
        }
        continue;
      }
      if (codeUnit == 0x1B) {
        continue;
      }
      final char = String.fromCharCode(codeUnit);
      _input.write(char);
      _writeText(char);
    }
  }

  void _runInteractiveCommand(String command) {
    if (command.isEmpty) {
      return;
    }
    final normalized = command.toLowerCase();
    if (normalized == 'clear') {
      _writeText('\x1b[2J\x1b[H');
      return;
    }
    if (normalized == 'exit' || normalized == 'logout') {
      _writeText('logout\r\n');
      close();
      return;
    }
    _writeText(_demoInteractiveCommandOutput(command));
  }

  void _writePrompt() {
    _writeText(r'reviewer@demo:~/demo$ ');
  }

  void _writeText(String text) {
    if (_closed || _stdoutController.isClosed) {
      return;
    }
    _stdoutController.add(
      Uint8List.fromList(utf8.encode(_normalizeDemoTerminalOutput(text))),
    );
  }

  void writeDemoOutput(
    String text, {
    bool replaceScreen = false,
    bool showPrompt = true,
  }) {
    if (_closed) {
      return;
    }
    if (replaceScreen) {
      _writeText('\x1b[2J\x1b[H$text');
    } else {
      _writeText('\r\n$text');
    }
    if (showPrompt && !text.endsWith('\n') && !text.endsWith('\r')) {
      _writeText('\r\n');
    }
    if (showPrompt) {
      _writePrompt();
    }
  }

  Future<void> _finish({int? exitCode}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _stdinSubscription.cancel();
    // Closing a stream nobody listened to never completes, and callers often
    // ignore exec output, so done must not wait for these.
    unawaited(_stdinController.close());
    unawaited(_stdoutController.close());
    unawaited(_stderrController.close());
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(exitCode);
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSshChannel implements SSHChannel {
  _AppReviewDemoSshChannel(this._session);

  final _AppReviewDemoSshSession _session;

  @override
  Future<void> get done => _session.done;

  @override
  void destroy() => _session.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSftpClient implements SftpClient {
  _AppReviewDemoSftpClient();

  static const _home = '/home/reviewer';
  static const _workspace = '/home/reviewer/work/monkeyssh-demo';
  final _files = <String, Uint8List>{
    for (final entry in _demoSftpFiles.entries)
      entry.key: Uint8List.fromList(utf8.encode(entry.value)),
  };
  bool _closed = false;

  @override
  Future<SftpHandsake> get handshake =>
      Future<SftpHandsake>.value(SftpHandsake(3, const {}));

  @override
  Future<String> absolute(String path) async => _normalizeDemoSftpPath(path);

  @override
  Future<List<SftpName>> listdir(String path) async {
    final directory = _normalizeDemoSftpPath(path);
    final entries = <SftpName>[];
    for (final child in _demoSftpDirectoryChildren(directory, _files.keys)) {
      final childPath = _joinDemoSftpPath(directory, child);
      final isDirectory = _demoSftpDirectories.contains(childPath);
      entries.add(
        SftpName(
          filename: child,
          longname: child,
          attr: isDirectory
              ? _demoDirectoryAttrs()
              : _demoFileAttrs(_files[childPath]?.length ?? 0),
        ),
      );
    }
    return entries;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final normalized = _normalizeDemoSftpPath(path);
    if (_demoSftpDirectories.contains(normalized)) {
      return _demoDirectoryAttrs();
    }
    final content = _files[normalized];
    if (content != null) {
      return _demoFileAttrs(content.length);
    }
    throw StateError('No such file: $path');
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    final normalized = _normalizeDemoSftpPath(path);
    if ((mode.flag & SftpFileOpenMode.truncate.flag) != 0) {
      _files[normalized] = Uint8List(0);
    } else {
      _files.putIfAbsent(normalized, () => Uint8List(0));
    }
    return _AppReviewDemoSftpFile(
      attrs: _demoFileAttrs(_files[normalized]!.length),
      readContent: () => _files[normalized] ?? Uint8List(0),
      writeContent: (value) => _files[normalized] = Uint8List.fromList(value),
    );
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {}

  @override
  Future<void> rmdir(String dirname) async {}

  @override
  Future<void> remove(String filename) async {
    _files.remove(_normalizeDemoSftpPath(filename));
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final oldNormalized = _normalizeDemoSftpPath(oldPath);
    final content = _files.remove(oldNormalized);
    if (content != null) {
      _files[_normalizeDemoSftpPath(newPath)] = content;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (_closed) {
      throw StateError('Connection closed');
    }
    return super.noSuchMethod(invocation);
  }
}

class _AppReviewDemoSftpFile implements SftpFile {
  _AppReviewDemoSftpFile({
    required SftpFileAttrs attrs,
    required Uint8List Function() readContent,
    required void Function(Uint8List value) writeContent,
  }) : _attrs = attrs,
       _readContent = readContent,
       _writeContent = writeContent;

  final Uint8List Function() _readContent;
  final void Function(Uint8List value) _writeContent;
  SftpFileAttrs _attrs;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<SftpFileAttrs> stat() async {
    _ensureOpen();
    return _attrs;
  }

  void _ensureOpen() {
    if (_isClosed) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpError('File is closed');
    }
  }

  @override
  Future<void> setStat(SftpFileAttrs attrs) async {
    _ensureOpen();
    final size = attrs.size;
    if (size != null) {
      if (size < 0) {
        // ignore: only_throw_errors
        throw SftpError('File size must not be negative');
      }
      final previous = _readContent();
      _writeContent(
        Uint8List(size)..setRange(0, math.min(size, previous.length), previous),
      );
    }
    _attrs = SftpFileAttrs(
      size: size ?? _readContent().length,
      mode: attrs.mode ?? _attrs.mode,
      userID: attrs.userID ?? _attrs.userID,
      groupID: attrs.groupID ?? _attrs.groupID,
      accessTime: attrs.accessTime ?? _attrs.accessTime,
      modifyTime: attrs.modifyTime ?? _attrs.modifyTime,
    );
  }

  @override
  Future<Never> statvfs() async {
    _ensureOpen();
    // ignore: only_throw_errors
    throw SftpExtensionUnsupportedError('fstatvfs@openssh.com');
  }

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
  }) async* {
    _ensureOpen();
    if (offset < 0 || (length != null && length < 0)) {
      // ignore: only_throw_errors
      throw SftpError('Read offset and length must not be negative');
    }
    if (chunkSize <= 0 || maxPendingRequests <= 0) {
      // ignore: only_throw_errors
      throw SftpError('Read chunk size and request count must be positive');
    }
    final bytes = Uint8List.fromList(_readContent());
    final start = offset.clamp(0, bytes.length);
    final requestedLength = length ?? bytes.length - start;
    final end = (start + requestedLength).clamp(start, bytes.length);
    for (var position = start; position < end; position += chunkSize) {
      _ensureOpen();
      final chunkEnd = math.min(position + chunkSize, end);
      onProgress?.call(chunkEnd - start);
      yield Uint8List.sublistView(bytes, position, chunkEnd);
    }
  }

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in read(length: length, offset: offset)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  SftpFileWriter write(
    Stream<Uint8List> stream, {
    int offset = 0,
    void Function(int total)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
  }) {
    _ensureOpen();
    if (offset < 0) {
      // ignore: only_throw_errors
      throw SftpError('Write offset must not be negative');
    }
    if (chunkSize <= 0 || maxPendingRequests <= 0) {
      // ignore: only_throw_errors
      throw SftpError('Write chunk size and request count must be positive');
    }
    return _AppReviewDemoSftpFileWriter(this, stream, offset, onProgress);
  }

  @override
  Future<void> writeBytes(
    Uint8List data, {
    int offset = 0,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
  }) async {
    _ensureOpen();
    if (offset < 0) {
      // ignore: only_throw_errors
      throw SftpError('Write offset must not be negative');
    }
    if (chunkSize <= 0 || maxPendingRequests <= 0) {
      // ignore: only_throw_errors
      throw SftpError('Write chunk size and request count must be positive');
    }
    final previousBytes = _readContent();
    final requiredLength = offset + data.length;
    final bytes = Uint8List(math.max(previousBytes.length, requiredLength))
      ..setRange(0, previousBytes.length, previousBytes)
      ..setRange(offset, requiredLength, data);
    _writeContent(bytes);
    await setStat(SftpFileAttrs(size: bytes.length));
  }

  @override
  Future<void> close() async {
    _isClosed = true;
  }

  @override
  Future<int> downloadTo(
    StreamSink<List<int>> destination, {
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
    bool closeDestination = false,
  }) async {
    var total = 0;
    try {
      await destination.addStream(
        read(
          length: length,
          offset: offset,
          chunkSize: chunkSize,
          maxPendingRequests: maxPendingRequests,
          onProgress: (count) {
            total = count;
            onProgress?.call(count);
          },
        ),
      );
      return total;
    } finally {
      if (closeDestination) await destination.close();
    }
  }

  @override
  Future<Uint8List?> readChunk(int length, [int offset = 0]) async {
    _ensureOpen();
    if (offset < 0 || length < 0) {
      // ignore: only_throw_errors
      throw SftpError('Read offset and length must not be negative');
    }
    final bytes = _readContent();
    if (offset >= bytes.length) {
      return null;
    }
    final end = math.min(offset + length, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }
}

// dartssh2's writer does not route source/write errors to done. Keep the demo
// writer's asynchronous work owned by the upload caller, including cancellation.
class _AppReviewDemoSftpFileWriter implements SftpFileWriter {
  _AppReviewDemoSftpFileWriter(
    this.file,
    this.stream,
    this.offset,
    this.onProgress,
  ) {
    _source = StreamIterator(stream);
    done = _write();
  }

  @override
  final SftpFile file;
  @override
  final Stream<Uint8List> stream;
  @override
  final int offset;
  @override
  final void Function(int)? onProgress;
  late final StreamIterator<Uint8List> _source;
  Completer<void>? _resume;
  var _progress = 0;
  var _aborted = false;

  Future<void> _write() async {
    try {
      while (!_aborted && await _source.moveNext()) {
        await _resume?.future;
        if (_aborted) break;
        final chunk = _source.current;
        await file.writeBytes(chunk, offset: offset + _progress);
        _progress += chunk.length;
        onProgress?.call(_progress);
      }
    } finally {
      await _source.cancel();
    }
  }

  @override
  late final Future<void> done;
  @override
  int get progress => _progress;
  @override
  void pause() {
    _resume ??= Completer<void>();
  }

  @override
  void resume() {
    _resume?.complete();
    _resume = null;
  }

  @override
  Future<void> abort() async {
    _aborted = true;
    resume();
    await _source.cancel();
    await done;
  }

  @override
  Stream<void> asStream() => done.asStream();
  @override
  Future<void> catchError(Function onError, {bool Function(Object)? test}) =>
      done.catchError(onError, test: test);
  @override
  Future<T> then<T>(
    FutureOr<T> Function(dynamic) onValue, {
    Function? onError,
  }) => done.then(onValue, onError: onError);
  @override
  Future<void> whenComplete(FutureOr<void> Function() action) =>
      done.whenComplete(action);
  @override
  Future<void> timeout(
    Duration timeLimit, {
    FutureOr<void> Function()? onTimeout,
  }) => done.timeout(timeLimit, onTimeout: onTimeout);
}

class _AppReviewDemoForwardChannel implements SSHForwardChannel {
  _AppReviewDemoForwardChannel({
    required String remoteHost,
    required int remotePort,
  }) : _response = _demoForwardHttpResponse(remoteHost, remotePort) {
    _sinkController.stream.drain<void>().ignore();
    scheduleMicrotask(() async {
      _streamController.add(Uint8List.fromList(utf8.encode(_response)));
      await close();
    });
  }

  final String _response;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();
  final _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    // Keep accepting request bytes while the response drains to the socket.
    await _streamController.close();
    await _sinkController.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void destroy() {
    unawaited(close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _demoSftpDirectories = <String>{
  '/',
  '/home',
  '/home/reviewer',
  '/home/reviewer/work',
  '/home/reviewer/work/monkeyssh-demo',
  '/home/reviewer/work/monkeyssh-demo/logs',
  '/home/reviewer/work/monkeyssh-demo/src',
  '/home/reviewer/work/monkeyssh-demo/screenshots',
};

const _demoSftpFiles = <String, String>{
  '/home/reviewer/work/monkeyssh-demo/README.md': '''
# MonkeySSH App Review Demo

This is an in-app local demo workspace. It does not require a private SSH
server, but it behaves like a connected terminal for review.
''',
  '/home/reviewer/work/monkeyssh-demo/package.json': '''
{"scripts":{"dev":"vite --host 127.0.0.1","test":"flutter test"}}
''',
  '/home/reviewer/work/monkeyssh-demo/deploy-demo.sh': '''
#!/bin/sh
echo "dry-run deploy complete"
''',
  '/home/reviewer/work/monkeyssh-demo/logs/app.log': '''
01:08:22 connected local review shell
01:08:23 loaded MonkeyMux workspace metadata
01:08:24 opened sample SFTP tree
''',
  '/home/reviewer/work/monkeyssh-demo/src/main.dart': '''
void main() {
  print('MonkeySSH App Review Demo');
}
''',
};

String _demoInteractiveBanner(Host host) =>
    '''
\x1b]0;${host.label}\x07\x1b]7;file://localhost/home/reviewer/work/monkeyssh-demo\x07MonkeySSH App Review Demo

Connected locally for:
  ${_shortDemoHostLabel(host.label)}

No external SSH server or credentials are required.

Sample workspace: ~/work/monkeyssh-demo

Try:
  ls
  pwd
  cat README.md
  monkeymux windows
  copilot

''';

String _shortDemoHostLabel(String label) =>
    label.replaceFirst('${AppReviewDemoService.demoHostLabelPrefix} ', '');

String _normalizeDemoTerminalOutput(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

String _demoInteractiveCommandOutput(String command) {
  final normalized = command.toLowerCase();
  if (normalized == 'pwd') {
    return '/home/reviewer/work/monkeyssh-demo\r\n';
  }
  if (normalized == 'whoami') {
    return 'reviewer\r\n';
  }
  if (normalized == 'ls' || normalized == 'ls -la') {
    return 'README.md  deploy-demo.sh  logs  package.json  screenshots  src\r\n';
  }
  if (normalized == 'cat readme.md' ||
      normalized == 'cat README.md'.toLowerCase()) {
    return '${_demoSftpFiles['/home/reviewer/work/monkeyssh-demo/README.md']}\r\n';
  }
  if (normalized.contains('monkeymux') || normalized.contains('tmux')) {
    return '''
review-workspace
  0  Copilot CLI     planning App Review notes
  1  Claude Code    running focused tests
  2  OpenCode       editing README.md
  3  SFTP           browsing /home/reviewer/work/monkeyssh-demo
''';
  }
  if (normalized.contains('copilot')) {
    return '''
Copilot CLI demo
  ✓ inspected staged changes
  ✓ prepared review notes
  → ready for /deploy
''';
  }
  if (normalized.contains('deploy-demo')) {
    return 'dry-run deploy complete\r\n';
  }
  return 'demo shell: command "$command" completed locally\r\n';
}

String _demoExecOutput(String command) {
  final normalized = command.toLowerCase();
  if (normalized.contains('pwd')) {
    return '/home/reviewer/work/monkeyssh-demo\n';
  }
  if (normalized.contains('tmux') && normalized.contains('list')) {
    return 'review-workspace: 4 windows\n';
  }
  if (normalized.contains('command -v') ||
      normalized.contains('which ') ||
      normalized.contains('uname')) {
    return '';
  }
  return '';
}

String _demoForwardHttpResponse(String remoteHost, int remotePort) {
  const body = '''
<!doctype html>
<title>MonkeySSH App Review Demo</title>
<h1>MonkeySSH forwarded preview</h1>
<p>This page was served by the in-app demo tunnel.</p>
''';
  return 'HTTP/1.1 200 OK\r\n'
      'content-type: text/html; charset=utf-8\r\n'
      'content-length: ${utf8.encode(body).length}\r\n'
      'connection: close\r\n'
      '\r\n'
      '$body';
}

List<String> _demoSftpDirectoryChildren(
  String directory,
  Iterable<String> filePaths,
) {
  final children = <String>{};
  for (final path in [..._demoSftpDirectories, ...filePaths]) {
    if (path == directory || !path.startsWith('$directory/')) {
      continue;
    }
    final remainder = path.substring(
      directory == '/' ? 1 : directory.length + 1,
    );
    if (remainder.isEmpty || remainder.contains('/')) {
      continue;
    }
    children.add(remainder);
  }
  return children.toList()..sort();
}

String _normalizeDemoSftpPath(String input) {
  var path = input.trim();
  if (path.isEmpty || path == '.') {
    return _AppReviewDemoSftpClient._workspace;
  }
  if (path == '~') {
    return _AppReviewDemoSftpClient._home;
  }
  if (path.startsWith('~/')) {
    path = '${_AppReviewDemoSftpClient._home}/${path.substring(2)}';
  }
  if (!path.startsWith('/')) {
    path = '${_AppReviewDemoSftpClient._workspace}/$path';
  }
  while (path.contains('//')) {
    path = path.replaceAll('//', '/');
  }
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

String _joinDemoSftpPath(String directory, String child) =>
    directory == '/' ? '/$child' : '$directory/$child';

SftpFileAttrs _demoDirectoryAttrs() => SftpFileAttrs(
  size: 0,
  mode: const SftpFileMode.value(0x4000 | 0x01ED),
  modifyTime: 1783325486,
);

SftpFileAttrs _demoFileAttrs(int size) => SftpFileAttrs(
  size: size,
  mode: const SftpFileMode.value(0x8000 | 0x01A4),
  modifyTime: 1783325486,
);
