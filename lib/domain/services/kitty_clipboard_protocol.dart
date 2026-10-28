import 'dart:convert';
import 'dart:typed_data';

/// The OSC code of the kitty clipboard protocol.
///
/// `ESC ] 5522 ; metadata ; payload ST`, where metadata is a colon separated
/// list of `key=value` records and the payload is base64.
/// https://sw.kovidgoyal.net/kitty/clipboard/
const kittyClipboardOscCode = '5522';

/// The DEC private mode a program sets to receive paste events.
const kittyPasteEventsPrivateMode = 5522;

/// The MIME type a read request uses to ask for the available types.
const kittyClipboardTargetsMime = '.';

/// Most bytes of one data packet before base64 encoding, fixed by the spec.
const kittyClipboardChunkBytes = 4096;

/// Most decoded bytes one clipboard write may carry.
///
/// The spec asks terminals to accept at least 64 MB, which is what kitty and
/// Ghostty default to. MonkeySSH runs on phones: a write is held in memory as
/// its packets arrive, copied again across the platform channel, and an image
/// is then decoded into a bitmap by UIKit or Android's BitmapFactory, which for
/// a large PNG is many times its file size. 16 MiB still covers a
/// full-resolution screenshot from any current phone or Retina display. A
/// larger write is refused with EFBIG, so the program learns why instead of the
/// app being killed for memory.
const kittyClipboardMaxBytes = 16 * 1024 * 1024;

/// Most bytes one read answer, or one paste event's snapshot, serves over all
/// its types. Larger types are left out, as unavailable.
///
/// Half the write limit, because an answer travels as base64 (4/3 larger)
/// and, under MonkeyMux, through the server's per-client input queue, which
/// drops a client that queues more than 16 MiB for a program reading slowly.
const kittyClipboardMaxReadBytes = 8 * 1024 * 1024;

/// The human name the paste event spec asks programs to send with a paste
/// event's one-time password.
const kittyClipboardPasteEventName = 'Paste event';

const _maxIdLength = 512;
const _maxMimeLength = 256;
const _maxNameLength = 256;
const _maxPasswordLength = 128;
const _maxWriteMimes = 64;
const _maxWriteAliases = 64;

/// The operation a kitty clipboard packet performs.
enum KittyClipboardOperation {
  /// Read types, or list them, from the clipboard.
  read('read'),

  /// Start a write transaction.
  write('write'),

  /// One chunk of a write, or the end of the write when it has no MIME type.
  writeData('wdata'),

  /// Make more MIME types share the data of a written type.
  writeAlias('walias');

  const KittyClipboardOperation(this.wireName);

  /// The `type=` value on the wire.
  final String wireName;
}

/// The status a terminal reports in a kitty clipboard response.
enum KittyClipboardStatus {
  /// A read is starting.
  ok('OK'),

  /// A read data packet.
  data('DATA'),

  /// A read or write finished.
  done('DONE'),

  /// Clipboard access was denied by the user or a setting.
  permissionDenied('EPERM'),

  /// The requested clipboard (the primary selection) does not exist here.
  unavailable('ENOSYS'),

  /// A temporary conflict, such as another multiplexer window's request.
  busy('EBUSY'),

  /// The clipboard could not be written.
  ioError('EIO'),

  /// A write packet was malformed.
  invalid('EINVAL'),

  /// A write was larger than [kittyClipboardMaxBytes].
  tooLarge('EFBIG');

  const KittyClipboardStatus(this.wireName);

  /// The `status=` value on the wire.
  final String wireName;
}

/// One MIME type and its data.
typedef KittyClipboardEntry = ({String mime, Uint8List data});

/// The decoded metadata of one kitty clipboard packet.
class KittyClipboardMetadata {
  /// Creates metadata for [operation].
  const KittyClipboardMetadata({
    required this.operation,
    this.primary = false,
    this.id = '',
    this.mime = '',
    this.password = '',
    this.name = '',
  });

  /// The packet's operation.
  final KittyClipboardOperation operation;

  /// Whether the packet targets the primary selection (`loc=primary`).
  final bool primary;

  /// The sanitized request id, echoed in every response.
  final String id;

  /// The decoded MIME type, empty when absent.
  final String mime;

  /// The decoded password, empty when absent or too long.
  final String password;

  /// The decoded human-readable program name, empty when absent.
  final String name;
}

/// Parses the metadata section of an OSC 5522 packet.
///
/// Returns null when the packet must be dropped without a reply: a record
/// without `=`, or a missing or unknown `type`. Returns a null `metadata` when
/// the operation is known but a base64 value is invalid, which aborts an open
/// write for data and alias packets. Unknown keys are ignored and a repeated
/// key keeps its last value, as in kitty.
({KittyClipboardOperation operation, KittyClipboardMetadata? metadata})?
parseKittyClipboardMetadata(String raw) {
  final fields = <String, String>{};
  for (final record in raw.split(':')) {
    final separator = record.indexOf('=');
    if (separator < 0) {
      return null;
    }
    fields[record.substring(0, separator)] = record.substring(separator + 1);
  }
  final type = fields['type'];
  KittyClipboardOperation? operation;
  for (final candidate in KittyClipboardOperation.values) {
    if (candidate.wireName == type) {
      operation = candidate;
    }
  }
  if (operation == null) {
    return null;
  }

  final mime = _decodeMetadataText(fields['mime'], _maxMimeLength);
  final name = _decodeMetadataText(fields['name'], _maxNameLength);
  final password = _decodeMetadataText(fields['pw'], _maxPasswordLength);
  if (mime.invalid || mime.overflow || name.invalid || name.overflow) {
    return (operation: operation, metadata: null);
  }
  if (password.invalid) {
    return (operation: operation, metadata: null);
  }
  return (
    operation: operation,
    metadata: KittyClipboardMetadata(
      operation: operation,
      primary: fields['loc'] == 'primary',
      id: sanitizeKittyClipboardId(fields['id'] ?? ''),
      mime: mime.value,
      // An over-long password is treated as no password, as in Ghostty.
      password: password.overflow ? '' : password.value,
      name: name.value,
    ),
  );
}

({String value, bool invalid, bool overflow}) _decodeMetadataText(
  String? value,
  int maxLength,
) {
  if (value == null || value.isEmpty) {
    return (value: '', invalid: false, overflow: false);
  }
  if (value.length > (maxLength + 2) ~/ 3 * 4) {
    return (value: '', invalid: false, overflow: true);
  }
  final bytes = decodeKittyClipboardBase64(value);
  if (bytes == null) {
    return (value: '', invalid: true, overflow: false);
  }
  if (bytes.length > maxLength) {
    return (value: '', invalid: false, overflow: true);
  }
  try {
    return (value: utf8.decode(bytes), invalid: false, overflow: false);
  } on FormatException {
    return (value: '', invalid: true, overflow: false);
  }
}

/// Removes characters the spec does not allow in an id
/// (`[a-zA-Z0-9-_+.]`) and truncates it to 512 characters.
String sanitizeKittyClipboardId(String id) {
  final buffer = StringBuffer();
  for (final codeUnit in id.codeUnits) {
    if (buffer.length >= _maxIdLength) {
      break;
    }
    if (_isIdCodeUnit(codeUnit)) {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}

bool _isIdCodeUnit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
    codeUnit == 0x2D ||
    codeUnit == 0x5F ||
    codeUnit == 0x2B ||
    codeUnit == 0x2E;

final _strictBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);
final _base64Characters = RegExp(r'^[A-Za-z0-9+/=]*$');
final _paddedQuantum = RegExp(r'^[A-Za-z0-9+/]{2}(?:==|[A-Za-z0-9+/]=)$');

/// Decodes [value] as strict RFC 4648 base64, as the spec requires: only the
/// standard alphabet, no whitespace, and correct padding. Returns null for
/// anything else. Dart's own decoder also accepts the URL-safe alphabet and
/// percent-encoded padding, which the spec forbids.
Uint8List? decodeKittyClipboardBase64(String value) {
  if (!_strictBase64.hasMatch(value)) {
    return null;
  }
  return base64.decode(value);
}

/// Decodes the base64 stream of one MIME type split over many `wdata`
/// packets. Only the concatenation has to be padded correctly, so a packet
/// may end mid-quantum. A padded quantum ends a stream and the next one
/// starts afresh, which lets independently encoded chunks through too, as in
/// kitty.
class KittyClipboardBase64Stream {
  String _carry = '';

  /// Whether every character fed so far has been decoded.
  bool get isComplete => _carry.isEmpty;

  /// Decodes the complete quanta of [payload] after any carried characters.
  /// Returns null when the data is not valid base64.
  Uint8List? feed(String payload) {
    if (!_base64Characters.hasMatch(payload)) {
      return null;
    }
    final combined = _carry + payload;
    final completeLength = combined.length - combined.length % 4;
    final carry = combined.substring(completeLength);
    final carryPadding = carry.indexOf('=');
    if (carryPadding >= 0 && carryPadding < 2) {
      return null;
    }
    final decoded = BytesBuilder(copy: false);
    var segmentStart = 0;
    var searchFrom = 0;
    while (true) {
      final padding = combined.indexOf('=', searchFrom);
      if (padding < 0 || padding >= completeLength) {
        break;
      }
      final quantumStart = padding - padding % 4;
      final quantumEnd = quantumStart + 4;
      if (!_paddedQuantum.hasMatch(
        combined.substring(quantumStart, quantumEnd),
      )) {
        return null;
      }
      decoded.add(base64.decode(combined.substring(segmentStart, quantumEnd)));
      segmentStart = quantumEnd;
      searchFrom = quantumEnd;
    }
    if (segmentStart < completeLength) {
      decoded.add(
        base64.decode(combined.substring(segmentStart, completeLength)),
      );
    }
    _carry = carry;
    return decoded.takeBytes();
  }
}

/// One write transaction: a `type=write` packet followed by `wdata` and
/// `walias` packets until the `wdata` packet without a MIME type commits it.
///
/// Follows kitty and Ghostty: data for a MIME type sent again later replaces
/// the earlier data, types past the 64th are ignored, and aliases resolve in
/// the order they arrived against the types written so far.
class KittyClipboardWriteTransaction {
  /// Starts a transaction answered with [id].
  KittyClipboardWriteTransaction({
    required this.id,
    this.maxBytes = kittyClipboardMaxBytes,
  });

  /// The id of the opening `type=write` packet, echoed in the final reply.
  final String id;

  /// The most decoded bytes the transaction accepts.
  final int maxBytes;

  final _entries = <String, BytesBuilder>{};
  final _aliases = <String, String>{};
  String? _current;
  KittyClipboardBase64Stream _stream = KittyClipboardBase64Stream();
  int _bytes = 0;

  /// Decoded bytes held so far.
  int get byteCount => _bytes;

  /// Adds one chunk of [mime] data. Returns the status that aborts the
  /// transaction, or null when the chunk was accepted (or ignored).
  KittyClipboardStatus? addData(String mime, String payload) {
    if (_current != mime) {
      if (_current != null && !_stream.isComplete) {
        return KittyClipboardStatus.invalid;
      }
      _stream = KittyClipboardBase64Stream();
      final existing = _entries[mime];
      if (existing != null) {
        _bytes -= existing.length;
        _entries[mime] = BytesBuilder(copy: false);
      } else if (_entries.length >= _maxWriteMimes) {
        _current = null;
        return null;
      } else {
        _entries[mime] = BytesBuilder(copy: false);
      }
      _current = mime;
    }
    final decoded = _stream.feed(payload);
    if (decoded == null) {
      return KittyClipboardStatus.invalid;
    }
    if (decoded.length > maxBytes - _bytes) {
      return KittyClipboardStatus.tooLarge;
    }
    _entries[mime]!.add(decoded);
    _bytes += decoded.length;
    return null;
  }

  /// Makes the types listed in the base64 [payload] share [target]'s data.
  /// Returns false when the payload is not base64 encoded UTF-8.
  bool addAliases(String target, String payload) {
    final bytes = decodeKittyClipboardBase64(payload);
    if (bytes == null) {
      return false;
    }
    final String names;
    try {
      names = utf8.decode(bytes);
    } on FormatException {
      return false;
    }
    for (final alias in names.split(RegExp(r'\s+'))) {
      if (alias.isEmpty || alias.length > _maxMimeLength) {
        continue;
      }
      if (!_aliases.containsKey(alias) && _aliases.length >= _maxWriteAliases) {
        return true;
      }
      _aliases[alias] = target;
    }
    return true;
  }

  /// Ends the transaction. Returns the written types in arrival order, or
  /// null when the last type's data was not padded correctly.
  List<KittyClipboardEntry>? commit() {
    if (_current != null && !_stream.isComplete) {
      return null;
    }
    final contents = <String, Uint8List>{
      for (final entry in _entries.entries) entry.key: entry.value.takeBytes(),
    };
    for (final alias in _aliases.entries) {
      final data = contents[alias.value];
      if (data != null) {
        contents[alias.key] = data;
      }
    }
    return [
      for (final entry in contents.entries)
        (mime: entry.key, data: entry.value),
    ];
  }
}

/// Encodes one response packet, terminated with ST.
///
/// Fields follow kitty's order. An empty payload adds no payload section.
String encodeKittyClipboardResponse({
  required KittyClipboardOperation operation,
  required KittyClipboardStatus status,
  bool primary = false,
  String id = '',
  String? mime,
  String? password,
  List<int>? payload,
}) {
  final buffer = StringBuffer(
    '\x1b]$kittyClipboardOscCode;type=${operation.wireName}'
    ':status=${status.wireName}',
  );
  if (primary) {
    buffer.write(':loc=primary');
  }
  if (id.isNotEmpty) {
    buffer.write(':id=$id');
  }
  if (mime != null) {
    buffer.write(':mime=${base64Encode(utf8.encode(mime))}');
  }
  if (password != null) {
    buffer.write(':pw=${base64Encode(utf8.encode(password))}');
  }
  if (payload != null && payload.isNotEmpty) {
    buffer
      ..write(';')
      ..write(base64Encode(payload));
  }
  buffer.write('\x1b\\');
  return buffer.toString();
}

/// Encodes a successful read: `OK`, the type listing when [listing] is
/// given, `DATA` packets of at most [kittyClipboardChunkBytes] for each of
/// [contents] in order, then `DONE`. A paste event has the same shape, with a
/// listing, no contents and a one-time [password] in every packet.
Iterable<String> encodeKittyClipboardReadSuccess({
  String id = '',
  String? password,
  List<String>? listing,
  List<KittyClipboardEntry> contents = const [],
}) sync* {
  yield encodeKittyClipboardResponse(
    operation: KittyClipboardOperation.read,
    status: KittyClipboardStatus.ok,
    id: id,
    password: password,
  );
  if (listing != null) {
    yield encodeKittyClipboardResponse(
      operation: KittyClipboardOperation.read,
      status: KittyClipboardStatus.data,
      id: id,
      mime: kittyClipboardTargetsMime,
      password: password,
      payload: _encodeListing(listing),
    );
  }
  for (final content in contents) {
    final data = content.data;
    for (
      var offset = 0;
      offset < data.length;
      offset += kittyClipboardChunkBytes
    ) {
      final end = offset + kittyClipboardChunkBytes < data.length
          ? offset + kittyClipboardChunkBytes
          : data.length;
      yield encodeKittyClipboardResponse(
        operation: KittyClipboardOperation.read,
        status: KittyClipboardStatus.data,
        id: id,
        mime: content.mime,
        password: password,
        payload: Uint8List.sublistView(data, offset, end),
      );
    }
  }
  yield encodeKittyClipboardResponse(
    operation: KittyClipboardOperation.read,
    status: KittyClipboardStatus.done,
    id: id,
    password: password,
  );
}

/// The listing is the space separated types with a trailing newline, as
/// kitty sends it. It is one data packet, so types that would push it past
/// the chunk size are left out.
List<int> _encodeListing(List<String> types) {
  final listing = <int>[];
  for (final type in types) {
    final encoded = utf8.encode(type);
    final separator = listing.isEmpty ? 0 : 1;
    if (listing.length + separator + encoded.length + 1 >
        kittyClipboardChunkBytes) {
      break;
    }
    if (separator > 0) {
      listing.add(0x20);
    }
    listing.addAll(encoded);
  }
  if (listing.isNotEmpty) {
    listing.add(0x0A);
  }
  return listing;
}

/// Whether [mime] names plain text, the way the X11 and Wayland clipboards
/// and kitty spell it.
bool isKittyClipboardTextMime(String mime) {
  final lower = mime.toLowerCase().replaceAll(' ', '');
  return lower == 'text/plain' ||
      lower == 'text/plain;charset=utf-8' ||
      mime == 'UTF8_STRING' ||
      mime == 'TEXT' ||
      mime == 'STRING';
}

/// The image MIME type of [bytes] from its signature, or null when it is not
/// a format a clipboard commonly holds.
String? kittyClipboardImageMime(Uint8List bytes) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) {
      return false;
    }
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg';
  }
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) {
    return 'image/gif';
  }
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  if (startsWith(const [0x49, 0x49, 0x2A, 0x00]) ||
      startsWith(const [0x4D, 0x4D, 0x00, 0x2A])) {
    return 'image/tiff';
  }
  if (startsWith(const [0x42, 0x4D])) {
    return 'image/bmp';
  }
  return null;
}
