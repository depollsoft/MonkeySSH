import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _regularFileType = 0x8000;
const _directoryType = 0x4000;
const _symlinkType = 0xA000;

/// In-memory SFTP server with POSIX-rename semantics, per-file permission
/// bits and whole-second modified times.
///
/// Writes stamp files with [now]; tests move [now] forward or call
/// [writeFile] to play another program editing the host.
class InMemorySftpClient extends Fake implements SftpClient {
  /// Creates a server whose home directory is [home].
  InMemorySftpClient({this.home = '/home/demo'}) {
    directories.add(home);
  }

  /// Directory `absolute('.')` resolves to.
  final String home;

  /// File contents by absolute path.
  final files = <String, Uint8List>{};

  /// Permission bits by file path.
  final modes = <String, int>{};

  /// Modified times by file path, in seconds since the epoch.
  final modifyTimes = <String, int>{};

  /// Directories that exist.
  final directories = <String>{'/'};

  /// Symbolic links and their targets.
  final links = <String, String>{};

  /// Every path passed to [setStat], in order.
  final setStats = <String>[];

  /// Whether stat replies leave out size and modified time.
  bool omitMetadata = false;

  /// Whether stat replies leave out permissions, as some servers do.
  bool omitMode = false;

  /// Thrown by [mkdir] when set, as by servers that refuse new folders.
  Object? mkdirFailure;

  /// Runs after an open handle is closed.
  void Function(String path)? afterClose;

  /// Permission bits each file had when content was first written to it.
  final modeAtFirstWrite = <String, int>{};

  /// Whether open file handles reject fstat.
  bool rejectFstat = false;

  /// Thrown by [setStat] when set.
  Object? setStatFailure;

  /// Thrown by file writes when set.
  Object? writeFailure;

  /// Runs after an open handle's fstat replies, before its content is read,
  /// so a test can change the file in between.
  void Function(String path)? afterFstat;

  /// Runs after each write through an open handle.
  void Function(String path)? afterWrite;

  /// Number of fstat requests answered.
  int fstatCount = 0;

  /// Every path written through an open handle, in order.
  final writes = <String>[];

  /// Current server time in seconds since the epoch.
  int now = 1700000000;

  /// Writes [bytes] to [path] as another program on the host would.
  void writeFile(String path, List<int> bytes, {int? modifyTime, int? mode}) {
    files[path] = Uint8List.fromList(bytes);
    modifyTimes[path] = modifyTime ?? now;
    modes[path] = mode ?? modes[path] ?? 0x1A4;
  }

  /// Removes [path] as another program on the host would.
  void deleteFile(String path) {
    files.remove(path);
    modes.remove(path);
    modifyTimes.remove(path);
  }

  String _resolve(String path) => links[path] ?? path;

  Never _missing(String path) =>
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');

  SftpFileAttrs _attrsFor(String path) {
    if (files[path] case final bytes?) {
      return SftpFileAttrs(
        size: omitMetadata ? null : bytes.length,
        mode: omitMode
            ? null
            : SftpFileMode.value(_regularFileType | (modes[path] ?? 0x1A4)),
        accessTime: omitMetadata ? null : modifyTimes[path],
        modifyTime: omitMetadata ? null : modifyTimes[path],
        userID: 1000,
        groupID: 1000,
      );
    }
    if (directories.contains(path)) {
      return SftpFileAttrs(
        mode: const SftpFileMode.value(_directoryType | 0x1ED),
      );
    }
    _missing(path);
  }

  @override
  Future<String> absolute(String path) async =>
      path == '.' ? home : _resolve(path);

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (!followLink && links.containsKey(path)) {
      return SftpFileAttrs(
        mode: const SftpFileMode.value(_symlinkType | 0x1FF),
      );
    }
    return _attrsFor(_resolve(path));
  }

  @override
  Future<List<SftpName>> listdir(String path) async {
    if (!directories.contains(path)) _missing(path);
    final prefix = path.endsWith('/') ? path : '$path/';
    final names = <SftpName>[];
    for (final child in {...files.keys, ...directories, ...links.keys}) {
      if (!child.startsWith(prefix)) continue;
      final name = child.substring(prefix.length);
      if (name.isEmpty || name.contains('/')) continue;
      names.add(
        SftpName(
          filename: name,
          longname: name,
          attr: await stat(child, followLink: false),
        ),
      );
    }
    return names;
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    bool has(SftpFileOpenMode flag) => mode.flag & flag.flag != 0;
    // O_EXCL fails on any existing name, a dangling symlink included.
    if (has(SftpFileOpenMode.exclusive) &&
        (files.containsKey(path) ||
            links.containsKey(path) ||
            directories.contains(path))) {
      // SFTP v3 has no "already exists" status code.
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Failure');
    }
    final target = _resolve(path);
    if (directories.contains(target)) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Is a directory');
    }
    final exists = files.containsKey(target);
    if (!exists) {
      if (!has(SftpFileOpenMode.create)) _missing(target);
      if (!directories.contains(target.substring(0, target.lastIndexOf('/')))) {
        _missing(target);
      }
      writeFile(target, const [], mode: 0x1A4);
    } else if (has(SftpFileOpenMode.truncate)) {
      writeFile(target, const []);
    }
    return InMemorySftpFile._(this, target);
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (setStatFailure case final failure?) throw failure;
    setStats.add(path);
    final target = _resolve(path);
    if (attrs.mode case final mode? when files.containsKey(target)) {
      modes[target] = mode.value & 0xFFF;
    }
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (mkdirFailure case final failure?) throw failure;
    if (directories.contains(path) || files.containsKey(path)) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Failure');
    }
    directories.add(path);
  }

  @override
  Future<void> rmdir(String dirname) async {
    final prefix = '$dirname/';
    if ([...files.keys, ...directories].any((p) => p.startsWith(prefix))) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Failure');
    }
    directories.remove(dirname);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (directories.contains(newPath)) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.failure, 'Is a directory');
    }
    if (directories.contains(oldPath)) {
      // A folder moves with everything inside it.
      String moved(String path) => newPath + path.substring(oldPath.length);
      bool inside(String path) =>
          path == oldPath || path.startsWith('$oldPath/');
      for (final path in directories.where(inside).toList()) {
        directories
          ..remove(path)
          ..add(moved(path));
      }
      for (final path in files.keys.where(inside).toList()) {
        files[moved(path)] = files.remove(path)!;
        modes[moved(path)] = modes.remove(path) ?? 0x1A4;
        modifyTimes[moved(path)] = modifyTimes.remove(path) ?? now;
      }
      return;
    }
    final bytes = files.remove(oldPath) ?? _missing(oldPath);
    files[newPath] = bytes;
    modes[newPath] = modes.remove(oldPath) ?? 0x1A4;
    modifyTimes[newPath] = modifyTimes.remove(oldPath) ?? now;
  }

  @override
  Future<void> remove(String filename) async {
    if (!files.containsKey(filename)) _missing(filename);
    deleteFile(filename);
  }

  @override
  Future<void> close() async {}
}

/// Open handle on an [InMemorySftpClient] file.
class InMemorySftpFile extends Fake implements SftpFile {
  InMemorySftpFile._(this._server, this._path);

  final InMemorySftpClient _server;
  final String _path;

  @override
  Future<SftpFileAttrs> stat() async {
    if (_server.rejectFstat) {
      // ignore: only_throw_errors, dartssh2 models protocol errors this way.
      throw SftpStatusError(SftpStatusCode.opUnsupported, 'Unsupported');
    }
    _server.fstatCount++;
    final attrs = _server._attrsFor(_path);
    _server.afterFstat?.call(_path);
    return attrs;
  }

  @override
  Future<void> setStat(SftpFileAttrs attrs) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (_server.setStatFailure case final failure?) throw failure;
    _server.setStats.add(_path);
    if (attrs.mode case final mode?) _server.modes[_path] = mode.value & 0xFFF;
  }

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    final bytes = _server.files[_path] ?? _server._missing(_path);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset.clamp(0, end), end));
  }

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 0,
    int maxPendingRequests = 0,
  }) async* {
    yield await readBytes(length: length, offset: offset);
  }

  @override
  Future<void> writeBytes(
    Uint8List data, {
    int offset = 0,
    int chunkSize = 0,
    int maxPendingRequests = 0,
  }) async {
    // ignore: only_throw_errors, dartssh2 models protocol errors this way.
    if (_server.writeFailure case final failure?) throw failure;
    final current = _server.files[_path] ?? _server._missing(_path);
    final next =
        Uint8List(
            offset + data.length > current.length
                ? offset + data.length
                : current.length,
          )
          ..setAll(0, current)
          ..setAll(offset, data);
    if (data.isNotEmpty) {
      _server.modeAtFirstWrite.putIfAbsent(
        _path,
        () => _server.modes[_path] ?? 0x1A4,
      );
    }
    _server
      ..files[_path] = next
      ..modifyTimes[_path] = _server.now
      ..writes.add(_path)
      ..afterWrite?.call(_path);
  }

  @override
  Future<void> close() async => _server.afterClose?.call(_path);
}
