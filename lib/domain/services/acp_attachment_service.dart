import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/acp_attachment.dart';
import '../models/acp_content.dart';
import '../models/acp_protocol.dart';
import 'diagnostics_log_service.dart';
import 'remote_file_service.dart';

const _diagnosticsCategory = 'acp_attachment';
const _defaultMimeType = 'application/octet-stream';

/// Mutable cancellation signal shared with attachment preparation.
final class AcpAttachmentCancellationToken {
  bool _isCancelled = false;

  /// Whether cancellation was requested.
  bool get isCancelled => _isCancelled;

  /// Requests cancellation.
  void cancel() => _isCancelled = true;

  void _throwIfCancelled() {
    if (_isCancelled) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.cancelled,
        'Attachment preparation was cancelled.',
      );
    }
  }
}

/// Safe progress metadata for one remote upload.
final class AcpAttachmentUploadProgress {
  /// Creates upload progress.
  const AcpAttachmentUploadProgress({
    required this.attachmentIndex,
    required this.attachmentCount,
    required this.bytesTransferred,
    required this.totalBytes,
  });

  /// Zero-based attachment index.
  final int attachmentIndex;

  /// Number of attachments in the prompt.
  final int attachmentCount;

  /// Bytes uploaded so far.
  final int bytesTransferred;

  /// Total bytes when known.
  final int? totalBytes;
}

/// Remote upload result used to build an ACP resource link.
final class AcpUploadedAttachment {
  /// Creates an uploaded attachment.
  const AcpUploadedAttachment({
    required this.remotePath,
    required this.displayName,
    required this.sizeBytes,
    required this.mimeType,
  });

  /// Absolute uploaded path.
  final String remotePath;

  /// Sanitized remote file name.
  final String displayName;

  /// Uploaded byte count.
  final int sizeBytes;

  /// Detected MIME type.
  final String mimeType;
}

/// Remote-upload seam used by attachment preparation.
abstract interface class AcpAttachmentUploader {
  /// Uploads [stream] into the app-owned private remote upload directory.
  Future<AcpUploadedAttachment> upload({
    required String originalName,
    required String mimeType,
    required Stream<List<int>> stream,
    required int? totalBytes,
    required int maxBytes,
    required int attachmentIndex,
    required int attachmentCount,
    required AcpAttachmentCancellationToken cancellationToken,
    void Function(AcpAttachmentUploadProgress progress)? onProgress,
  });
}

/// Builds a sanitized, collision-safe ACP upload file name.
String buildAcpAttachmentUploadFileName({
  required String originalName,
  required DateTime timestamp,
  required String uniqueId,
}) {
  final safeName = sanitizeRemoteUploadFileName(originalName);
  final safeId = uniqueId.replaceAll(RegExp('[^A-Za-z0-9]'), '');
  final prefix =
      'acp-${timestamp.toUtc().millisecondsSinceEpoch}-'
      '${safeId.isEmpty ? 'upload' : safeId}-';
  const maxNameLength = 240;
  if (prefix.length + safeName.length <= maxNameLength) {
    return '$prefix$safeName';
  }

  final extension = path.extension(safeName);
  final baseName = path.basenameWithoutExtension(safeName);
  final available = math.max(
    1,
    maxNameLength - prefix.length - extension.length,
  );
  return '$prefix${baseName.substring(0, math.min(baseName.length, available))}'
      '$extension';
}

/// SFTP uploader for ACP attachment fallbacks.
final class SftpAcpAttachmentUploader implements AcpAttachmentUploader {
  /// Creates an SFTP attachment uploader.
  SftpAcpAttachmentUploader({
    required this.sftp,
    this.remoteFileService = const RemoteFileService(),
    DiagnosticsLogger? diagnostics,
    DateTime Function()? now,
    String Function()? uniqueId,
  }) : _diagnostics = diagnostics ?? const NoopDiagnosticsLogger(),
       _now = now ?? DateTime.now,
       _uniqueId = uniqueId ?? const Uuid().v4;

  /// Connected SFTP client.
  final SftpClient sftp;

  /// Shared remote-file operations.
  final RemoteFileService remoteFileService;

  final DiagnosticsLogger _diagnostics;
  final DateTime Function() _now;
  final String Function() _uniqueId;

  @override
  Future<AcpUploadedAttachment> upload({
    required String originalName,
    required String mimeType,
    required Stream<List<int>> stream,
    required int? totalBytes,
    required int maxBytes,
    required int attachmentIndex,
    required int attachmentCount,
    required AcpAttachmentCancellationToken cancellationToken,
    void Function(AcpAttachmentUploadProgress progress)? onProgress,
  }) async {
    cancellationToken._throwIfCancelled();
    final stopwatch = Stopwatch()..start();
    String? remotePath;
    var transferred = 0;
    try {
      final homeDirectory = await remoteFileService.resolveInitialDirectory(
        sftp,
      );
      cancellationToken._throwIfCancelled();
      final parentDirectory = buildRemoteClipboardUploadParentDirectory(
        homeDirectory,
      );
      final uploadDirectory = buildRemoteClipboardUploadDirectory(
        homeDirectory,
      );
      await remoteFileService.ensureDirectoryExists(
        sftp,
        parentDirectory,
        mode: remoteUploadDirectoryMode,
      );
      await remoteFileService.ensureDirectoryExists(
        sftp,
        uploadDirectory,
        mode: remoteUploadDirectoryMode,
      );

      final displayName = buildAcpAttachmentUploadFileName(
        originalName: originalName,
        timestamp: _now(),
        uniqueId: _uniqueId(),
      );
      remotePath = joinRemotePath(uploadDirectory, displayName);
      onProgress?.call(
        AcpAttachmentUploadProgress(
          attachmentIndex: attachmentIndex,
          attachmentCount: attachmentCount,
          bytesTransferred: 0,
          totalBytes: totalBytes,
        ),
      );
      final progressStream = stream.map((chunk) {
        cancellationToken._throwIfCancelled();
        transferred += chunk.length;
        if (transferred > maxBytes) {
          throw const AcpAttachmentException(
            AcpAttachmentFailure.fileSizeLimit,
            'An attachment exceeds the per-file byte limit.',
          );
        }
        onProgress?.call(
          AcpAttachmentUploadProgress(
            attachmentIndex: attachmentIndex,
            attachmentCount: attachmentCount,
            bytesTransferred: transferred,
            totalBytes: totalBytes,
          ),
        );
        return chunk;
      });
      await remoteFileService.uploadStream(
        sftp: sftp,
        remotePath: remotePath,
        stream: progressStream,
      );
      cancellationToken._throwIfCancelled();
      _diagnostics.info(
        _diagnosticsCategory,
        'upload_completed',
        fields: <String, Object?>{
          'attachmentCount': attachmentCount,
          'attachmentIndex': attachmentIndex,
          'bytes': transferred,
          'durationMs': stopwatch.elapsedMilliseconds,
          'category': _mimeCategory(mimeType),
        },
      );
      return AcpUploadedAttachment(
        remotePath: remotePath,
        displayName: displayName,
        sizeBytes: transferred,
        mimeType: mimeType,
      );
    } on Object catch (error) {
      if (remotePath != null) {
        try {
          await sftp.remove(remotePath);
        } on Object catch (cleanupError) {
          _diagnostics.warning(
            _diagnosticsCategory,
            'upload_cleanup_failed',
            fields: <String, Object?>{
              'errorType': cleanupError.runtimeType.toString(),
            },
          );
        }
      }
      _diagnostics.warning(
        _diagnosticsCategory,
        'upload_failed',
        fields: <String, Object?>{
          'bytes': transferred,
          'durationMs': stopwatch.elapsedMilliseconds,
          'errorType': error.runtimeType.toString(),
        },
      );
      if (error is AcpAttachmentException) {
        rethrow;
      }
      throw const AcpAttachmentException(
        AcpAttachmentFailure.uploadFailed,
        'The attachment upload failed.',
      );
    }
  }
}

/// Converts ordered text and attachment drafts into ACP content blocks.
final class AcpAttachmentPreparationService {
  /// Creates an attachment preparation service.
  const AcpAttachmentPreparationService({
    this.limits = const AcpAttachmentLimits(),
    this.diagnostics = const NoopDiagnosticsLogger(),
  });

  /// Safety and resource limits.
  final AcpAttachmentLimits limits;

  /// Safe diagnostics sink.
  final DiagnosticsLogger diagnostics;

  /// Prepares an ordered ACP prompt.
  Future<List<AcpContentBlock>> prepare({
    required AcpPromptDraft draft,
    required AcpPromptCapabilities capabilities,
    AcpAttachmentUploader? uploader,
    AcpAttachmentCancellationToken? cancellationToken,
    void Function(AcpAttachmentUploadProgress progress)? onUploadProgress,
  }) async {
    final cancellation = cancellationToken ?? AcpAttachmentCancellationToken();
    final attachmentCount = draft.items.whereType<AcpAttachmentDraft>().length;
    if (attachmentCount > limits.maxCount) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.countLimit,
        'Too many attachments were selected.',
      );
    }

    final stopwatch = Stopwatch()..start();
    diagnostics.info(
      _diagnosticsCategory,
      'prepare_started',
      fields: <String, Object?>{
        'attachmentCount': attachmentCount,
        'itemCount': draft.items.length,
        'imageSupported': capabilities.image,
        'embeddedContextSupported': capabilities.embeddedContext,
      },
    );
    var totalBytes = 0;
    var attachmentIndex = 0;
    final blocks = <AcpContentBlock>[];
    try {
      for (final item in draft.items) {
        cancellation._throwIfCancelled();
        switch (item) {
          case AcpPromptTextDraft(:final text):
            blocks.add(AcpTextContent(text));
          case AcpAttachmentDraft():
            final remainingTotal = limits.maxTotalBytes - totalBytes;
            if (remainingTotal <= 0) {
              throw const AcpAttachmentException(
                AcpAttachmentFailure.totalSizeLimit,
                'Attachments exceed the total byte limit.',
              );
            }
            final prepared = await _prepareAttachment(
              draft: item,
              capabilities: capabilities,
              uploader: uploader,
              cancellation: cancellation,
              attachmentIndex: attachmentIndex,
              attachmentCount: attachmentCount,
              remainingTotalBytes: remainingTotal,
              onUploadProgress: onUploadProgress,
            );
            cancellation._throwIfCancelled();
            totalBytes += prepared.bytes;
            blocks.add(prepared.block);
            attachmentIndex++;
        }
      }
      diagnostics.info(
        _diagnosticsCategory,
        'prepare_completed',
        fields: <String, Object?>{
          'attachmentCount': attachmentCount,
          'blockCount': blocks.length,
          'bytes': totalBytes,
          'durationMs': stopwatch.elapsedMilliseconds,
        },
      );
      return List<AcpContentBlock>.unmodifiable(blocks);
    } catch (error) {
      diagnostics.warning(
        _diagnosticsCategory,
        'prepare_failed',
        fields: <String, Object?>{
          'attachmentCount': attachmentCount,
          'bytes': totalBytes,
          'durationMs': stopwatch.elapsedMilliseconds,
          'errorType': error.runtimeType.toString(),
          if (error is AcpAttachmentException) 'reason': error.failure.name,
        },
      );
      rethrow;
    }
  }

  Future<({AcpContentBlock block, int bytes})> _prepareAttachment({
    required AcpAttachmentDraft draft,
    required AcpPromptCapabilities capabilities,
    required AcpAttachmentUploader? uploader,
    required AcpAttachmentCancellationToken cancellation,
    required int attachmentIndex,
    required int attachmentCount,
    required int remainingTotalBytes,
    required void Function(AcpAttachmentUploadProgress progress)?
    onUploadProgress,
  }) async {
    final candidate = draft.candidate;
    _validateFileName(candidate.name);
    _validateMimeType(candidate.mimeType);
    final knownSize = candidate.sizeBytes;
    if (knownSize != null) {
      _validateSize(knownSize, remainingTotalBytes);
    }

    return switch (candidate) {
      AcpRemoteFileAttachmentCandidate() => _prepareRemote(candidate),
      AcpMemoryAttachmentCandidate() when candidate.isPastedText =>
        _preparePastedText(candidate),
      AcpMemoryAttachmentCandidate() => _prepareBytes(
        draft: draft,
        bytes: candidate.bytes,
        capabilities: capabilities,
        uploader: uploader,
        cancellation: cancellation,
        attachmentIndex: attachmentIndex,
        attachmentCount: attachmentCount,
        remainingTotalBytes: remainingTotalBytes,
        onUploadProgress: onUploadProgress,
      ),
      AcpLocalFileAttachmentCandidate() => _prepareLocalFile(
        draft: draft,
        candidate: candidate,
        capabilities: capabilities,
        uploader: uploader,
        cancellation: cancellation,
        attachmentIndex: attachmentIndex,
        attachmentCount: attachmentCount,
        remainingTotalBytes: remainingTotalBytes,
        onUploadProgress: onUploadProgress,
      ),
    };
  }

  ({AcpContentBlock block, int bytes}) _preparePastedText(
    AcpMemoryAttachmentCandidate candidate,
  ) {
    if (candidate.bytes.length > limits.maxEmbeddedBytes) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.inlineSizeLimit,
        'Pasted text exceeds the inline byte limit.',
      );
    }
    try {
      return (
        block: AcpTextContent(utf8.decode(candidate.bytes)),
        bytes: candidate.bytes.length,
      );
    } on FormatException {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.invalidUtf8,
        'Pasted text is not valid UTF-8.',
      );
    }
  }

  ({AcpContentBlock block, int bytes}) _prepareRemote(
    AcpRemoteFileAttachmentCandidate candidate,
  ) {
    final mimeType = _resolveMimeType(
      name: candidate.name,
      supplied: candidate.mimeType,
    );
    return (
      block: _resourceLink(
        name: candidate.name,
        remotePath: candidate.remotePath,
        mimeType: mimeType,
        sizeBytes: candidate.sizeBytes,
      ),
      bytes: candidate.sizeBytes ?? 0,
    );
  }

  Future<({AcpContentBlock block, int bytes})> _prepareBytes({
    required AcpAttachmentDraft draft,
    required Uint8List bytes,
    required AcpPromptCapabilities capabilities,
    required AcpAttachmentUploader? uploader,
    required AcpAttachmentCancellationToken cancellation,
    required int attachmentIndex,
    required int attachmentCount,
    required int remainingTotalBytes,
    required void Function(AcpAttachmentUploadProgress progress)?
    onUploadProgress,
  }) async {
    _validateSize(bytes.length, remainingTotalBytes);
    final mimeType = _resolveMimeType(
      name: draft.candidate.name,
      supplied: draft.candidate.mimeType,
      headerBytes: bytes.take(limits.mimeSniffBytes).toList(),
    );
    final inline = _inlineKind(
      mimeType: mimeType,
      sizeBytes: bytes.length,
      capabilities: capabilities,
    );
    if (inline != null) {
      return (
        block: _inlineBlock(
          name: draft.candidate.name,
          bytes: bytes,
          mimeType: mimeType,
          kind: inline,
        ),
        bytes: bytes.length,
      );
    }
    return _uploadOrReject(
      draft: draft,
      stream: Stream<List<int>>.value(bytes),
      sizeBytes: bytes.length,
      mimeType: mimeType,
      capabilities: capabilities,
      uploader: uploader,
      cancellation: cancellation,
      attachmentIndex: attachmentIndex,
      attachmentCount: attachmentCount,
      remainingTotalBytes: remainingTotalBytes,
      onUploadProgress: onUploadProgress,
    );
  }

  Future<({AcpContentBlock block, int bytes})> _prepareLocalFile({
    required AcpAttachmentDraft draft,
    required AcpLocalFileAttachmentCandidate candidate,
    required AcpPromptCapabilities capabilities,
    required AcpAttachmentUploader? uploader,
    required AcpAttachmentCancellationToken cancellation,
    required int attachmentIndex,
    required int attachmentCount,
    required int remainingTotalBytes,
    required void Function(AcpAttachmentUploadProgress progress)?
    onUploadProgress,
  }) async {
    Stream<List<int>> source;
    try {
      source = candidate.openRead();
    } on Object {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.unreadable,
        'A selected local file could not be read.',
      );
    }
    final iterator = StreamIterator<List<int>>(source);
    final prefix = <Uint8List>[];
    var prefixBytes = 0;
    var reachedEnd = false;
    try {
      while (prefixBytes < limits.mimeSniffBytes) {
        cancellation._throwIfCancelled();
        bool hasNext;
        try {
          hasNext = await iterator.moveNext();
        } on Object {
          throw const AcpAttachmentException(
            AcpAttachmentFailure.unreadable,
            'A selected local file could not be read.',
          );
        }
        if (!hasNext) {
          reachedEnd = true;
          break;
        }
        final chunk = Uint8List.fromList(iterator.current);
        prefixBytes += chunk.length;
        _validateSize(prefixBytes, remainingTotalBytes);
        prefix.add(chunk);
      }

      final sniffBytes = BytesBuilder(copy: false);
      var remainingSniff = limits.mimeSniffBytes;
      for (final chunk in prefix) {
        if (remainingSniff <= 0) break;
        final take = math.min(chunk.length, remainingSniff);
        sniffBytes.add(chunk.sublist(0, take));
        remainingSniff -= take;
      }
      final mimeType = _resolveMimeType(
        name: candidate.name,
        supplied: candidate.mimeType,
        headerBytes: sniffBytes.takeBytes(),
      );
      final knownSize = candidate.sizeBytes;
      // Buffer only up to a format the agent can actually accept. Images
      // may also fit as embedded blobs when that capability is advertised.
      final inlineLimit = math.max(
        mimeType.startsWith('image/') && capabilities.image
            ? limits.maxImageBytes
            : 0,
        capabilities.embeddedContext ? limits.maxEmbeddedBytes : 0,
      );
      final canInlineByCapability =
          (mimeType.startsWith('image/') && capabilities.image) ||
          capabilities.embeddedContext;
      final shouldTryInline =
          canInlineByCapability &&
          (knownSize == null || knownSize <= inlineLimit) &&
          prefixBytes <= inlineLimit;

      if (shouldTryInline) {
        final bytes = BytesBuilder(copy: false);
        for (final chunk in prefix) {
          bytes.add(chunk);
        }
        var byteCount = prefixBytes;
        while (!reachedEnd) {
          cancellation._throwIfCancelled();
          bool hasNext;
          try {
            hasNext = await iterator.moveNext();
          } on Object {
            throw const AcpAttachmentException(
              AcpAttachmentFailure.unreadable,
              'A selected local file could not be read.',
            );
          }
          if (!hasNext) {
            reachedEnd = true;
            break;
          }
          final chunk = Uint8List.fromList(iterator.current);
          byteCount += chunk.length;
          _validateSize(byteCount, remainingTotalBytes);
          if (byteCount > inlineLimit) {
            final uploaded = await _uploadBufferedOrReject(
              draft: draft,
              buffered: bytes,
              overflowChunk: chunk,
              iterator: iterator,
              sizeBytes: knownSize,
              mimeType: mimeType,
              capabilities: capabilities,
              uploader: uploader,
              cancellation: cancellation,
              attachmentIndex: attachmentIndex,
              attachmentCount: attachmentCount,
              remainingTotalBytes: remainingTotalBytes,
              onUploadProgress: onUploadProgress,
            );
            return uploaded;
          }
          bytes.add(chunk);
        }
        final value = bytes.takeBytes();
        final kind = _inlineKind(
          mimeType: mimeType,
          sizeBytes: value.length,
          capabilities: capabilities,
        );
        if (kind != null) {
          return (
            block: _inlineBlock(
              name: candidate.name,
              bytes: value,
              mimeType: mimeType,
              kind: kind,
            ),
            bytes: value.length,
          );
        }
      }

      final buffered = BytesBuilder(copy: false);
      for (final chunk in prefix) {
        buffered.add(chunk);
      }
      final uploaded = await _uploadBufferedOrReject(
        draft: draft,
        buffered: buffered,
        iterator: iterator,
        sizeBytes: knownSize,
        mimeType: mimeType,
        capabilities: capabilities,
        uploader: uploader,
        cancellation: cancellation,
        attachmentIndex: attachmentIndex,
        attachmentCount: attachmentCount,
        remainingTotalBytes: remainingTotalBytes,
        onUploadProgress: onUploadProgress,
      );
      return uploaded;
    } finally {
      await iterator.cancel();
    }
  }

  Future<({AcpContentBlock block, int bytes})> _uploadBufferedOrReject({
    required AcpAttachmentDraft draft,
    required BytesBuilder buffered,
    required StreamIterator<List<int>> iterator,
    required int? sizeBytes,
    required String mimeType,
    required AcpPromptCapabilities capabilities,
    required AcpAttachmentUploader? uploader,
    required AcpAttachmentCancellationToken cancellation,
    required int attachmentIndex,
    required int attachmentCount,
    required int remainingTotalBytes,
    required void Function(AcpAttachmentUploadProgress progress)?
    onUploadProgress,
    Uint8List? overflowChunk,
  }) {
    final initial = buffered.takeBytes();
    final stream = () async* {
      var transferred = 0;
      for (final chunk in <Uint8List>[
        if (initial.isNotEmpty) initial,
        ?overflowChunk,
      ]) {
        transferred += chunk.length;
        _validateSize(transferred, remainingTotalBytes);
        yield chunk;
      }
      while (true) {
        cancellation._throwIfCancelled();
        bool hasNext;
        try {
          hasNext = await iterator.moveNext();
        } on Object {
          throw const AcpAttachmentException(
            AcpAttachmentFailure.unreadable,
            'A selected local file could not be read.',
          );
        }
        if (!hasNext) break;
        final chunk = Uint8List.fromList(iterator.current);
        transferred += chunk.length;
        _validateSize(transferred, remainingTotalBytes);
        yield chunk;
      }
    }();
    return _uploadOrReject(
      draft: draft,
      stream: stream,
      sizeBytes: sizeBytes,
      mimeType: mimeType,
      capabilities: capabilities,
      uploader: uploader,
      cancellation: cancellation,
      attachmentIndex: attachmentIndex,
      attachmentCount: attachmentCount,
      remainingTotalBytes: remainingTotalBytes,
      onUploadProgress: onUploadProgress,
    );
  }

  Future<({AcpContentBlock block, int bytes})> _uploadOrReject({
    required AcpAttachmentDraft draft,
    required Stream<List<int>> stream,
    required int? sizeBytes,
    required String mimeType,
    required AcpPromptCapabilities capabilities,
    required AcpAttachmentUploader? uploader,
    required AcpAttachmentCancellationToken cancellation,
    required int attachmentIndex,
    required int attachmentCount,
    required int remainingTotalBytes,
    required void Function(AcpAttachmentUploadProgress progress)?
    onUploadProgress,
  }) async {
    if (draft.fallback != AcpAttachmentFallback.remoteUpload) {
      final capabilitySupported =
          (mimeType.startsWith('image/') && capabilities.image) ||
          capabilities.embeddedContext;
      throw AcpAttachmentException(
        capabilitySupported
            ? mimeType.startsWith('image/')
                  ? AcpAttachmentFailure.imageSizeLimit
                  : AcpAttachmentFailure.inlineSizeLimit
            : AcpAttachmentFailure.unsupportedCapability,
        capabilitySupported
            ? 'The attachment is too large to embed.'
            : 'The agent cannot accept this attachment inline.',
      );
    }
    if (uploader == null) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.uploadUnavailable,
        'Remote upload is unavailable.',
      );
    }
    final uploaded = await uploader.upload(
      originalName: draft.candidate.name,
      mimeType: mimeType,
      stream: stream,
      totalBytes: sizeBytes,
      maxBytes: math.min(limits.maxFileBytes, remainingTotalBytes),
      attachmentIndex: attachmentIndex,
      attachmentCount: attachmentCount,
      cancellationToken: cancellation,
      onProgress: onUploadProgress,
    );
    _validateSize(uploaded.sizeBytes, remainingTotalBytes);
    return (
      block: _resourceLink(
        name: draft.candidate.name,
        remotePath: uploaded.remotePath,
        mimeType: uploaded.mimeType,
        sizeBytes: uploaded.sizeBytes,
      ),
      bytes: uploaded.sizeBytes,
    );
  }

  _AcpInlineKind? _inlineKind({
    required String mimeType,
    required int sizeBytes,
    required AcpPromptCapabilities capabilities,
  }) {
    if (mimeType.startsWith('image/') &&
        capabilities.image &&
        sizeBytes <= limits.maxImageBytes) {
      return _AcpInlineKind.image;
    }
    if (!capabilities.embeddedContext || sizeBytes > limits.maxEmbeddedBytes) {
      return null;
    }
    return _isTextMimeType(mimeType)
        ? _AcpInlineKind.textResource
        : _AcpInlineKind.blobResource;
  }

  AcpContentBlock _inlineBlock({
    required String name,
    required Uint8List bytes,
    required String mimeType,
    required _AcpInlineKind kind,
  }) {
    final uri = _localAttachmentUri(name);
    return switch (kind) {
      _AcpInlineKind.image => AcpImageContent(
        data: base64Encode(bytes),
        mimeType: mimeType,
        uri: uri,
      ),
      _AcpInlineKind.textResource => AcpResourceContent(
        resource: AcpTextResource(
          uri: uri,
          text: _decodeUtf8(bytes),
          mimeType: mimeType,
        ),
      ),
      _AcpInlineKind.blobResource => AcpResourceContent(
        resource: AcpBlobResource(
          uri: uri,
          blob: base64Encode(bytes),
          mimeType: mimeType,
        ),
      ),
    };
  }

  AcpResourceLinkContent _resourceLink({
    required String name,
    required String remotePath,
    required String mimeType,
    required int? sizeBytes,
  }) => AcpResourceLinkContent(
    name: name,
    uri: _remoteFileUri(remotePath),
    mimeType: mimeType,
    size: sizeBytes,
  );

  void _validateFileName(String name) {
    final trimmed = name.trim();
    final utf8Length = utf8.encode(trimmed).length;
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed.contains('\x00') ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(trimmed) ||
        utf8Length > limits.maxFileNameBytes) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.invalidFileName,
        'An attachment has an invalid file name.',
      );
    }
  }

  void _validateMimeType(String? mimeType) {
    if (mimeType == null) return;
    final normalized = mimeType.trim();
    if (utf8.encode(normalized).length > limits.maxMimeTypeBytes ||
        !RegExp(
          r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
        ).hasMatch(normalized)) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.invalidMimeType,
        'An attachment has an invalid MIME type.',
      );
    }
  }

  void _validateSize(int sizeBytes, int remainingTotalBytes) {
    if (sizeBytes < 0 || sizeBytes > limits.maxFileBytes) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.fileSizeLimit,
        'An attachment exceeds the per-file byte limit.',
      );
    }
    if (sizeBytes > remainingTotalBytes) {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.totalSizeLimit,
        'Attachments exceed the total byte limit.',
      );
    }
  }

  String _resolveMimeType({
    required String name,
    required String? supplied,
    List<int>? headerBytes,
  }) {
    final detected = lookupMimeType(name, headerBytes: headerBytes);
    final resolved = (supplied?.trim().toLowerCase().isNotEmpty ?? false)
        ? supplied!.trim().toLowerCase()
        : detected ?? _defaultMimeType;
    _validateMimeType(resolved);
    return resolved;
  }

  String _decodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const AcpAttachmentException(
        AcpAttachmentFailure.invalidUtf8,
        'A text attachment is not valid UTF-8.',
      );
    }
  }
}

enum _AcpInlineKind { image, textResource, blobResource }

bool _isTextMimeType(String mimeType) =>
    mimeType.startsWith('text/') ||
    mimeType == 'application/json' ||
    mimeType.endsWith('+json') ||
    mimeType == 'application/xml' ||
    mimeType.endsWith('+xml') ||
    mimeType == 'application/javascript' ||
    mimeType == 'application/x-yaml';

String _mimeCategory(String mimeType) {
  if (mimeType.startsWith('image/')) return 'image';
  if (_isTextMimeType(mimeType)) return 'text';
  return 'binary';
}

String _localAttachmentUri(String name) => Uri(
  scheme: 'attachment',
  host: 'local',
  pathSegments: <String>[name],
).toString();

String _remoteFileUri(String remotePath) {
  final normalized = remotePath.replaceAll(r'\', '/');
  final absolute = normalized.startsWith('/') ? normalized : '/$normalized';
  return Uri(scheme: 'file', path: absolute).toString();
}
