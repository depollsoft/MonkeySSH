import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'diagnostics_log_service.dart';
import 'kitty_clipboard_protocol.dart';

/// Reads and writes the device clipboard by MIME type for the kitty clipboard
/// protocol.
abstract interface class KittyClipboardPlatform {
  /// The types on the clipboard that can be found without reading content
  /// that would make the system ask the user for permission.
  Future<List<String>> availableTypes();

  /// The clipboard's data for [mime], or null when it holds none.
  Future<Uint8List?> read(String mime);

  /// Replaces the clipboard with [entries], keeping what this platform can
  /// hold. Returns the types stored (empty when [entries] cleared the
  /// clipboard), or null when none of them could be stored.
  Future<List<String>?> write(List<KittyClipboardEntry> entries);

  /// Reads what a user's paste would send, for a paste event.
  Future<KittyClipboardPasteRead> readPasteSnapshot();
}

/// [KittyClipboardPlatform] on top of Flutter's text clipboard and the
/// `pasteboard` plugin the app already uses for image paste.
///
/// Neither holds more than one representation: a write keeps its text when
/// it has any, otherwise its image (iOS, macOS, Android and Windows; the
/// plugin cannot write images on Linux). HTML is readable on Android and
/// Windows only, and cannot be written.
class SystemKittyClipboardPlatform implements KittyClipboardPlatform {
  /// Creates the system clipboard adapter.
  const SystemKittyClipboardPlatform();

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _canReadHtml =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  bool get _canWriteImage =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Future<List<String>> availableTypes() async {
    final types = <String>[];
    // Probing an image reads it, which on iOS shows the paste permission
    // prompt, so iOS lists text only; a program can still ask for an image
    // type by name. hasStrings never prompts.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      final image = await _readImage();
      final imageMime = image == null ? null : kittyClipboardImageMime(image);
      if (imageMime != null) {
        types.add(imageMime);
      }
    }
    if (_canReadHtml && (await _readHtml())?.isNotEmpty == true) {
      types.add('text/html');
    }
    if (await Clipboard.hasStrings()) {
      types.add('text/plain');
    }
    return types;
  }

  @override
  Future<Uint8List?> read(String mime) async {
    if (isKittyClipboardTextMime(mime)) {
      final text = await readKittyClipboardSystemText();
      return text == null ? null : utf8.encode(text);
    }
    if (mime == 'text/html') {
      if (!_canReadHtml) {
        return null;
      }
      final html = await _readHtml();
      return html == null ? null : utf8.encode(html);
    }
    if (mime.startsWith('image/')) {
      final image = await _readImage();
      if (image == null || kittyClipboardImageMime(image) != mime) {
        return null;
      }
      return image;
    }
    return null;
  }

  @override
  Future<List<String>?> write(List<KittyClipboardEntry> entries) async {
    if (entries.isEmpty) {
      await Clipboard.setData(const ClipboardData(text: ''));
      return const [];
    }
    for (final entry in entries) {
      if (isKittyClipboardTextMime(entry.mime)) {
        await Clipboard.setData(
          ClipboardData(text: utf8.decode(entry.data, allowMalformed: true)),
        );
        return [entry.mime];
      }
    }
    if (_canWriteImage) {
      for (final entry in entries) {
        if (entry.mime.startsWith('image/') &&
            kittyClipboardImageMime(entry.data) != null) {
          await Pasteboard.writeImage(entry.data);
          return [entry.mime];
        }
      }
    }
    return null;
  }

  Future<Uint8List?> _readImage() async {
    final image = await Pasteboard.image;
    return image == null || image.isEmpty ? null : image;
  }

  Future<String?> _readHtml() => Pasteboard.html;

  /// Reads clipboard text, falling back to the plugin on Android where
  /// Flutter's reader can throw for some clip types.
  static Future<String?> readKittyClipboardSystemText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        return data!.text;
      }
    } on PlatformException {
      if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
        return null;
      }
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        return await Pasteboard.text;
      } on PlatformException {
        return null;
      }
    }
    return null;
  }

  /// Reads the clipboard in the order the attachment paste flow checks it:
  /// an image first on Android, files, an image elsewhere, then HTML and
  /// text.
  ///
  /// [KittyClipboardPasteRead.useAttachmentFlow] is set when the clipboard
  /// holds files, or an image in an unknown format or over
  /// [kittyClipboardMaxReadBytes]: those keep the upload flow, which gives
  /// the program a remote path it can open. Text that would push the total
  /// past that limit is left out.
  @override
  Future<KittyClipboardPasteRead> readPasteSnapshot() async {
    Uint8List? image;
    if (_isAndroid) {
      image = await _readImage();
    }
    if (image == null) {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        return const KittyClipboardPasteRead.attachment();
      }
      if (!_isAndroid) {
        image = await _readImage();
      }
    }
    final representations = <String, Uint8List>{};
    if (image != null) {
      final imageMime = kittyClipboardImageMime(image);
      if (imageMime == null || image.length > kittyClipboardMaxReadBytes) {
        return const KittyClipboardPasteRead.attachment();
      }
      representations[imageMime] = image;
    }
    var total = image?.length ?? 0;
    void addText(String mime, String? text) {
      if (text == null || text.isEmpty) {
        return;
      }
      final bytes = utf8.encode(text);
      if (total + bytes.length <= kittyClipboardMaxReadBytes) {
        representations[mime] = bytes;
        total += bytes.length;
      }
    }

    if (_canReadHtml) {
      addText('text/html', await _readHtml());
    }
    addText('text/plain', await readKittyClipboardSystemText());
    return KittyClipboardPasteRead.snapshot(
      KittyClipboardSnapshot(representations),
    );
  }
}

/// The clipboard as it was when the user pasted: what a paste event lists and
/// what the program's follow-up read is served from.
@immutable
class KittyClipboardSnapshot {
  /// Creates a snapshot of [representations], in preferred order.
  KittyClipboardSnapshot(Map<String, Uint8List> representations)
    : representations = Map.unmodifiable(representations);

  /// Each MIME type and its data.
  final Map<String, Uint8List> representations;

  /// The MIME types, in preferred order.
  List<String> get mimeTypes => representations.keys.toList(growable: false);

  /// Whether the clipboard held nothing a paste could send.
  bool get isEmpty => representations.isEmpty;

  /// Total bytes over every type.
  int get byteCount =>
      representations.values.fold(0, (total, data) => total + data.length);
}

/// What a paste found on the clipboard.
@immutable
class KittyClipboardPasteRead {
  /// The clipboard can be offered as a paste event.
  const KittyClipboardPasteRead.snapshot(KittyClipboardSnapshot this.snapshot)
    : useAttachmentFlow = false;

  /// The clipboard belongs to the attachment upload flow.
  const KittyClipboardPasteRead.attachment()
    : snapshot = null,
      useAttachmentFlow = true;

  /// The representations to announce, when [useAttachmentFlow] is false.
  final KittyClipboardSnapshot? snapshot;

  /// Whether the clipboard holds files, or an image the protocol cannot
  /// carry, which the upload flow handles instead.
  final bool useAttachmentFlow;
}

/// What became of a paste event.
enum KittyClipboardPasteEventResult {
  /// The event was written to the program.
  sent,

  /// The paste no longer targeted the same window or input when its turn
  /// came, so nothing was written.
  skipped,

  /// The event could not be written, for example because the shell is gone.
  failed,

  /// The program turned paste events (mode 5522) off before the event's turn
  /// came, so nothing was written and the paste should take the usual path.
  disabled,
}

/// How long the one-time password of a paste event stays valid. The spec
/// asks for a short timeout; the program's read normally follows within one
/// round trip.
const kittyClipboardPasteGrantLifetime = Duration(seconds: 30);

/// How long an unfinished write may sit idle before it is dropped. A
/// multiplexer that moved away from the writing window mid-transaction never
/// sends its end, and the transaction would otherwise hold its data.
const kittyClipboardWriteIdleTimeout = Duration(seconds: 60);

/// Most requests that may wait for their turn, the one being answered
/// included. Past it, a program that keeps sending while a request waits on
/// the platform is answered at once and nothing is queued for it.
const kittyClipboardMaxPendingRequests = 64;

const _maxReadMimes = 8;
const _maxPasteGrants = 4;
const _passwordLength = 22;
// kitty's one-time password alphabet: alphanumerics without look-alikes.
const _passwordAlphabet =
    '23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
const _replyBatchChars = 64 * 1024;

class _PasteGrant {
  _PasteGrant(this.password, this.snapshot, this.expiresAt);

  final String password;
  final KittyClipboardSnapshot snapshot;
  final DateTime expiresAt;
}

/// Answers the kitty clipboard protocol (OSC 5522) for one terminal session
/// and sends its paste events (mode 5522).
///
/// Writes follow the OSC 52 write setting ([canWrite]); reads follow the OSC
/// 52 read setting ([canRead]) and are answered EPERM when it is off. A
/// program's read carrying the one-time password of a paste event is served
/// from what the user pasted regardless of those settings, as the user
/// pasted it. The primary selection does not exist on the app's platforms,
/// so `loc=primary` is answered ENOSYS.
///
/// Requests are answered one at a time in arrival order, so a read that
/// follows a write sees the written data and replies never interleave. A
/// request that would queue past [kittyClipboardMaxPendingRequests] is
/// answered at once instead: EBUSY, or the error it already has.
/// Replies go only to the shell channel that asked ([abandonChannel]), and
/// nothing queued touches the clipboard after [dispose].
class KittyClipboardHandler {
  /// Creates a handler that answers through [sendReply].
  KittyClipboardHandler({
    required this.canWrite,
    required this.canRead,
    required this.sendReply,
    this.connectionId,
    KittyClipboardPlatform platform = const SystemKittyClipboardPlatform(),
    this.maxWriteBytes = kittyClipboardMaxBytes,
    DiagnosticsLogger? logger,
    DateTime Function()? clock,
    Random? random,
  }) : _platform = platform,
       _logger = logger ?? DiagnosticsLogService.instance,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// Whether the remote may write the local clipboard.
  final bool Function() canWrite;

  /// Whether the remote may read the local clipboard.
  final bool Function() canRead;

  /// Writes reply bytes to the program. Returns false when nothing could be
  /// written, for example because the shell is gone.
  final bool Function(String data) sendReply;

  /// The session's connection id, for diagnostics.
  final int? Function()? connectionId;

  /// Most decoded bytes one write may carry before it is refused with EFBIG.
  final int maxWriteBytes;

  KittyClipboardPlatform _platform;
  final DiagnosticsLogger _logger;
  final DateTime Function() _clock;
  final Random _random;

  KittyClipboardWriteTransaction? _write;
  Timer? _writeIdleTimer;
  final _grants = <_PasteGrant>[];
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;
  // Decoded bytes of committed writes still waiting for their turn.
  int _queuedWriteBytes = 0;
  // Queued tasks not finished yet, the one running included.
  int _pendingTasks = 0;
  // The shell channel requests arrive on, and the one the queued task being
  // answered arrived on; see [abandonChannel].
  int _channel = 0;
  int _taskChannel = 0;

  /// The clipboard adapter. Tests replace it.
  KittyClipboardPlatform get platform => _platform;

  @visibleForTesting
  set platform(KittyClipboardPlatform value) => _platform = value;

  /// Completes once every queued request has been answered.
  @visibleForTesting
  Future<void> get idle => _queue;

  /// Handles one OSC 5522 sequence; [args] is what the terminal's OSC parser
  /// produced after the code, split on `;`.
  void handleOsc(List<String> args) {
    if (_disposed) {
      return;
    }
    final joined = args.join(';');
    final separator = joined.indexOf(';');
    final rawMetadata = separator < 0 ? joined : joined.substring(0, separator);
    final payload = separator < 0 ? '' : joined.substring(separator + 1);
    final parsed = parseKittyClipboardMetadata(rawMetadata);
    if (parsed == null) {
      return;
    }
    final metadata = parsed.metadata;
    if (metadata == null) {
      if (parsed.operation == KittyClipboardOperation.writeData ||
          parsed.operation == KittyClipboardOperation.writeAlias) {
        _abortWrite(KittyClipboardStatus.invalid);
      }
      return;
    }
    switch (metadata.operation) {
      case KittyClipboardOperation.read:
        _read(metadata, payload);
      case KittyClipboardOperation.write:
        _beginWrite(metadata);
      case KittyClipboardOperation.writeData:
        _writeData(metadata, payload);
      case KittyClipboardOperation.writeAlias:
        _writeAlias(metadata, payload);
    }
  }

  /// Announces a paste to a program that set mode 5522: the types in
  /// [snapshot] and a one-time password its read can use to fetch them
  /// without a prompt.
  ///
  /// The event waits behind any request still being answered, so
  /// [stillTargeted] is asked again right before it is written: when the
  /// user has moved to another window or typed meanwhile, the event (and
  /// with it the password) is not sent at all. Nor is it when [stillEnabled]
  /// says the program has turned paste events off since.
  Future<KittyClipboardPasteEventResult> sendPasteEvent(
    KittyClipboardSnapshot snapshot, {
    bool Function()? stillTargeted,
    bool Function()? stillEnabled,
  }) {
    final completer = Completer<KittyClipboardPasteEventResult>();
    _enqueue(() async {
      try {
        completer.complete(
          _sendPasteEventNow(snapshot, stillTargeted, stillEnabled),
        );
      } on Object {
        completer.complete(KittyClipboardPasteEventResult.failed);
        rethrow;
      }
    });
    return completer.future;
  }

  KittyClipboardPasteEventResult _sendPasteEventNow(
    KittyClipboardSnapshot snapshot,
    bool Function()? stillTargeted,
    bool Function()? stillEnabled,
  ) {
    if (_disposed) {
      return KittyClipboardPasteEventResult.failed;
    }
    // The paste was for the program on a shell channel that has since gone.
    if (_taskChannelAbandoned || (stillTargeted != null && !stillTargeted())) {
      _logger.info(
        'terminal.clipboard',
        'kitty_paste_event_skipped',
        fields: {'connectionId': connectionId?.call()},
      );
      return KittyClipboardPasteEventResult.skipped;
    }
    if (stillEnabled != null && !stillEnabled()) {
      _logger.info(
        'terminal.clipboard',
        'kitty_paste_event_disabled',
        fields: {'connectionId': connectionId?.call()},
      );
      return KittyClipboardPasteEventResult.disabled;
    }
    final password = _newPassword();
    _pruneGrants();
    _grants.add(
      _PasteGrant(
        password,
        snapshot,
        _clock().add(kittyClipboardPasteGrantLifetime),
      ),
    );
    while (_grants.length > _maxPasteGrants) {
      _grants.removeAt(0);
    }
    final sent = _send(
      encodeKittyClipboardReadSuccess(
        password: password,
        listing: snapshot.mimeTypes,
      ),
    );
    _logger.info(
      'terminal.clipboard',
      'kitty_paste_event',
      fields: {
        'connectionId': connectionId?.call(),
        'typeCount': snapshot.representations.length,
        'hasText': snapshot.representations.keys.any(isKittyClipboardTextMime),
        'hasImage': snapshot.representations.keys.any(
          (mime) => mime.startsWith('image/'),
        ),
        'sizeBucket': kittyClipboardSizeBucket(snapshot.byteCount),
        'sent': sent,
      },
    );
    return sent
        ? KittyClipboardPasteEventResult.sent
        : KittyClipboardPasteEventResult.failed;
  }

  /// Drops any open write and every paste grant. Requests still queued are
  /// neither answered nor carried out.
  void dispose() {
    _disposed = true;
    _dropWrite();
    _grants.clear();
  }

  /// Forgets the shell channel that requests have arrived on, as when it
  /// closed or another shell took its place: what is still owed to it is not
  /// sent to the next one, which would read the replies as input. Its open
  /// write and paste grants end with it; a write it already finished still
  /// reaches the clipboard.
  void abandonChannel() {
    _channel++;
    _dropWrite();
    _grants.clear();
  }

  bool get _taskChannelAbandoned => _taskChannel != _channel;

  void _beginWrite(KittyClipboardMetadata metadata) {
    // A new write silently replaces an open one, as in kitty.
    _dropWrite();
    if (!canWrite()) {
      _replyStatus(
        KittyClipboardOperation.write,
        KittyClipboardStatus.permissionDenied,
        metadata.id,
      );
      _logWrite(KittyClipboardStatus.permissionDenied, typeCount: 0, bytes: 0);
      return;
    }
    if (metadata.primary) {
      _replyStatus(
        KittyClipboardOperation.write,
        KittyClipboardStatus.unavailable,
        metadata.id,
      );
      _logWrite(KittyClipboardStatus.unavailable, typeCount: 0, bytes: 0);
      return;
    }
    _write = KittyClipboardWriteTransaction(
      id: metadata.id,
      maxBytes: maxWriteBytes,
    );
    _touchWrite();
  }

  void _writeData(KittyClipboardMetadata metadata, String payload) {
    final write = _write;
    if (write == null) {
      return;
    }
    if (metadata.mime.isEmpty) {
      _commitWrite(write);
      return;
    }
    final status = write.addData(metadata.mime, payload);
    if (status != null) {
      _abortWrite(status);
      return;
    }
    _touchWrite();
  }

  void _writeAlias(KittyClipboardMetadata metadata, String payload) {
    final write = _write;
    if (write == null) {
      return;
    }
    if (metadata.mime.isEmpty || !write.addAliases(metadata.mime, payload)) {
      _abortWrite(KittyClipboardStatus.invalid);
      return;
    }
    _touchWrite();
  }

  void _commitWrite(KittyClipboardWriteTransaction write) {
    _dropWrite();
    final bytes = write.byteCount;
    final entries = write.commit();
    if (entries == null) {
      _replyStatus(
        KittyClipboardOperation.write,
        KittyClipboardStatus.invalid,
        write.id,
      );
      _logWrite(KittyClipboardStatus.invalid, typeCount: 0, bytes: bytes);
      return;
    }
    // Writes waiting behind a slow request hold their data until their turn,
    // so together they get the budget of one write.
    if (bytes > maxWriteBytes - _queuedWriteBytes) {
      _replyStatus(
        KittyClipboardOperation.write,
        KittyClipboardStatus.tooLarge,
        write.id,
      );
      _logWrite(KittyClipboardStatus.tooLarge, typeCount: 0, bytes: bytes);
      return;
    }
    if (_queueFull) {
      _sendStatusNow(
        KittyClipboardOperation.write,
        KittyClipboardStatus.busy,
        write.id,
      );
      _logWrite(KittyClipboardStatus.busy, typeCount: 0, bytes: bytes);
      return;
    }
    _queuedWriteBytes += bytes;
    _enqueue(() async {
      _queuedWriteBytes -= bytes;
      if (_disposed) {
        return;
      }
      var status = KittyClipboardStatus.done;
      if (!canWrite()) {
        status = KittyClipboardStatus.permissionDenied;
      } else {
        try {
          final stored = await _platform.write(entries);
          if (stored == null) {
            status = KittyClipboardStatus.ioError;
          }
        } on PlatformException {
          status = KittyClipboardStatus.ioError;
        } on MissingPluginException {
          status = KittyClipboardStatus.ioError;
        }
      }
      _sendStatus(KittyClipboardOperation.write, status, write.id);
      _logWrite(status, typeCount: entries.length, bytes: bytes);
    });
  }

  void _abortWrite(KittyClipboardStatus status) {
    final write = _write;
    if (write == null) {
      return;
    }
    _dropWrite();
    _replyStatus(KittyClipboardOperation.write, status, write.id);
    _logWrite(status, typeCount: 0, bytes: write.byteCount);
  }

  void _dropWrite() {
    _write = null;
    _writeIdleTimer?.cancel();
    _writeIdleTimer = null;
  }

  void _touchWrite() {
    _writeIdleTimer?.cancel();
    _writeIdleTimer = Timer(kittyClipboardWriteIdleTimeout, _dropWrite);
  }

  void _read(KittyClipboardMetadata metadata, String payload) {
    // A read with an undecodable payload is ignored, as reads have no error
    // status for it.
    final decoded = decodeKittyClipboardBase64(payload);
    if (decoded == null) {
      return;
    }
    final String requested;
    try {
      requested = utf8.decode(decoded);
    } on FormatException {
      return;
    }
    var listing = false;
    final mimes = <String>[];
    for (final mime in requested.split(RegExp(r'\s+'))) {
      if (mime.isEmpty) {
        continue;
      }
      if (mime == kittyClipboardTargetsMime) {
        listing = true;
      } else if (mimes.length < _maxReadMimes && !mimes.contains(mime)) {
        mimes.add(mime);
      }
    }
    if (_queueFull) {
      // Refused before its password is checked, so the paste grant it may
      // carry is still there for a retry.
      _sendStatusNow(
        KittyClipboardOperation.read,
        KittyClipboardStatus.busy,
        metadata.id,
      );
      _logRead(KittyClipboardStatus.busy, mimes.length, 0);
      return;
    }
    // A password without a name is no password, per the spec.
    final grant = metadata.name.isEmpty
        ? null
        : _takeGrant(metadata.password, consume: mimes.isNotEmpty);
    _enqueue(() async {
      if (_disposed || _taskChannelAbandoned) {
        return;
      }
      if (grant == null && !canRead()) {
        _sendStatus(
          KittyClipboardOperation.read,
          KittyClipboardStatus.permissionDenied,
          metadata.id,
        );
        _logRead(KittyClipboardStatus.permissionDenied, mimes.length, 0);
        return;
      }
      if (metadata.primary) {
        _sendStatus(
          KittyClipboardOperation.read,
          KittyClipboardStatus.unavailable,
          metadata.id,
        );
        _logRead(KittyClipboardStatus.unavailable, mimes.length, 0);
        return;
      }
      final contents = <KittyClipboardEntry>[];
      // The budget covers the whole answer, so a type requested under
      // several names (text/plain and UTF8_STRING) counts each time.
      var total = 0;
      void serve(String mime, Uint8List? data) {
        if (data != null && total + data.length <= kittyClipboardMaxReadBytes) {
          contents.add((mime: mime, data: data));
          total += data.length;
        }
      }

      List<String>? types;
      if (grant != null) {
        if (listing) {
          types = grant.snapshot.mimeTypes;
        }
        for (final mime in mimes) {
          serve(mime, _snapshotData(grant.snapshot, mime));
        }
      } else {
        try {
          if (listing) {
            types = await _platform.availableTypes();
          }
          for (final mime in mimes) {
            // Nobody is left to answer: stop reading the clipboard.
            if (_disposed || _taskChannelAbandoned) {
              return;
            }
            serve(mime, await _platform.read(mime));
          }
        } on PlatformException {
          // What was read so far is still served; a type the platform failed
          // to read is reported the way the spec reports any unavailable
          // type, by sending no data for it.
        } on MissingPluginException {
          // As above.
        }
      }
      if (_disposed || _taskChannelAbandoned) {
        return;
      }
      _send(
        encodeKittyClipboardReadSuccess(
          id: metadata.id,
          listing: types,
          contents: contents,
        ),
      );
      _logRead(
        KittyClipboardStatus.done,
        mimes.length,
        contents.fold(0, (total, entry) => total + entry.data.length),
        servedCount: contents.length,
        listing: listing,
        pasteGrant: grant != null,
      );
    });
  }

  /// Serves [mime] from a paste snapshot, matching any text spelling to the
  /// snapshot's plain text.
  Uint8List? _snapshotData(KittyClipboardSnapshot snapshot, String mime) {
    final exact = snapshot.representations[mime];
    if (exact != null || !isKittyClipboardTextMime(mime)) {
      return exact;
    }
    for (final entry in snapshot.representations.entries) {
      if (isKittyClipboardTextMime(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  _PasteGrant? _takeGrant(String password, {required bool consume}) {
    if (password.isEmpty) {
      return null;
    }
    _pruneGrants();
    for (var index = 0; index < _grants.length; index++) {
      final grant = _grants[index];
      if (grant.password != password) {
        continue;
      }
      // A listing discloses no data, so it leaves the grant for the read
      // that follows it, as in Ghostty.
      if (consume) {
        _grants.removeAt(index);
      }
      return grant;
    }
    return null;
  }

  void _pruneGrants() {
    final now = _clock();
    _grants.removeWhere((grant) => !grant.expiresAt.isAfter(now));
  }

  String _newPassword() => String.fromCharCodes(
    List.generate(
      _passwordLength,
      (_) => _passwordAlphabet.codeUnitAt(
        _random.nextInt(_passwordAlphabet.length),
      ),
    ),
  );

  bool get _queueFull => _pendingTasks >= kittyClipboardMaxPendingRequests;

  void _enqueue(Future<void> Function() task) {
    final channel = _channel;
    _pendingTasks++;
    _queue = _queue
        .then((_) {
          _taskChannel = channel;
          return task();
        })
        .catchError((Object error) {
          _logger.warning(
            'terminal.clipboard',
            'kitty_request_failed',
            fields: {
              'connectionId': connectionId?.call(),
              'errorType': error.runtimeType,
            },
          );
        })
        .whenComplete(() => _pendingTasks--);
  }

  /// Answers from outside the queue, behind every reply already queued, so
  /// replies keep the order of the requests. When the queue is full the
  /// reply goes out at once instead.
  void _replyStatus(
    KittyClipboardOperation operation,
    KittyClipboardStatus status,
    String id,
  ) {
    if (_queueFull) {
      _sendStatusNow(operation, status, id);
      return;
    }
    _enqueue(() async => _sendStatus(operation, status, id));
  }

  /// Answers a request that just arrived, ahead of the replies still
  /// queued. It goes to the current shell channel, which sent the request,
  /// whatever channel the task being answered came from.
  void _sendStatusNow(
    KittyClipboardOperation operation,
    KittyClipboardStatus status,
    String id,
  ) {
    if (_disposed) {
      return;
    }
    sendReply(
      encodeKittyClipboardResponse(
        operation: operation,
        status: status,
        id: id,
      ),
    );
  }

  void _sendStatus(
    KittyClipboardOperation operation,
    KittyClipboardStatus status,
    String id,
  ) => _send([
    encodeKittyClipboardResponse(operation: operation, status: status, id: id),
  ]);

  /// Writes [packets] in batches, so a large read is neither one huge string
  /// nor thousands of tiny writes.
  bool _send(Iterable<String> packets) {
    final batch = StringBuffer();
    var sent = true;
    for (final packet in packets) {
      batch.write(packet);
      if (batch.length >= _replyBatchChars) {
        sent = _sendBatch(batch.toString()) && sent;
        batch.clear();
      }
    }
    if (batch.isNotEmpty) {
      sent = _sendBatch(batch.toString()) && sent;
    }
    return sent;
  }

  bool _sendBatch(String data) {
    if (_disposed || _taskChannelAbandoned) {
      return false;
    }
    return sendReply(data);
  }

  void _logWrite(
    KittyClipboardStatus status, {
    required int typeCount,
    required int bytes,
  }) {
    _logger.info(
      'terminal.clipboard',
      'kitty_write',
      fields: {
        'connectionId': connectionId?.call(),
        'status': status.wireName,
        'typeCount': typeCount,
        'sizeBucket': kittyClipboardSizeBucket(bytes),
      },
    );
  }

  void _logRead(
    KittyClipboardStatus status,
    int requestedCount,
    int bytes, {
    int servedCount = 0,
    bool listing = false,
    bool pasteGrant = false,
  }) {
    _logger.info(
      'terminal.clipboard',
      'kitty_read',
      fields: {
        'connectionId': connectionId?.call(),
        'status': status.wireName,
        'requestedCount': requestedCount,
        'servedCount': servedCount,
        'listing': listing,
        'pasteGrant': pasteGrant,
        'sizeBucket': kittyClipboardSizeBucket(bytes),
      },
    );
  }
}

/// A coarse size bucket for diagnostics, never the exact size.
String kittyClipboardSizeBucket(int bytes) {
  if (bytes <= 0) {
    return '0';
  }
  if (bytes < 4 * 1024) {
    return 'lt_4kb';
  }
  if (bytes < 64 * 1024) {
    return 'lt_64kb';
  }
  if (bytes < 1024 * 1024) {
    return 'lt_1mb';
  }
  if (bytes <= kittyClipboardMaxBytes) {
    return 'le_16mb';
  }
  return 'gt_16mb';
}
