import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

/// A [PlatformFile] backed by an [XFile] or in-memory bytes.
///
/// The federated file picker returns platform-specific implementations, while
/// app-created files and tests need a platform-neutral implementation.
final class AppPlatformFile extends PlatformFile {
  /// Creates a file with optional local, URI, byte, and known-length backing.
  AppPlatformFile({
    required this.name,
    String? path,
    Uri? uri,
    Uint8List? bytes,
    int? size,
    XFile? xFile,
  }) : _bytes = bytes,
       _knownLength = size,
       _path = path,
       uri =
           uri ??
           (path == null
               ? Uri(scheme: 'memory', path: Uri.encodeComponent(name))
               : Uri.file(path)),
       _xFile =
           xFile ??
           (path == null
               ? XFile.fromData(bytes ?? Uint8List(0), name: name)
               : XFile(path, name: name));

  /// Wraps a file returned by image picker.
  factory AppPlatformFile.fromXFile(XFile file, {required String name}) =>
      AppPlatformFile(name: name, path: file.path, xFile: file);

  @override
  final String name;

  @override
  final Uri uri;

  final Uint8List? _bytes;
  final int? _knownLength;
  final String? _path;
  final XFile _xFile;

  @override
  String? get path => _path ?? super.path;

  @override
  XFile get xFile => _xFile;

  @override
  int? lengthSync() => _knownLength ?? _bytes?.lengthInBytes;

  @override
  Future<int?> length() async => lengthSync() ?? _xFile.length();

  @override
  Future<Uint8List> readAsBytes() async =>
      _bytes == null ? _xFile.readAsBytes() : Uint8List.fromList(_bytes);

  @override
  Stream<Uint8List> readAsByteStream() =>
      _bytes == null ? _xFile.openRead() : Stream.value(_bytes);
}
