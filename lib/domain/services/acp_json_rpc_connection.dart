import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../models/acp_json.dart';
import 'acp_transport.dart';

/// JSON-RPC request identifier accepted by ACP.
typedef AcpRequestId = Object;

/// Generates request identifiers for an [AcpJsonRpcConnection].
typedef AcpRequestIdFactory = AcpRequestId Function();

/// JSON-RPC error code for a cancelled request (ACP `$/cancel_request`).
const acpRequestCancelledErrorCode = -32800;

/// Protocol-level notification that cancels one outstanding request.
const acpCancelRequestMethod = r'$/cancel_request';

/// Base class for ACP JSON-RPC failures.
sealed class AcpJsonRpcException implements Exception {
  const AcpJsonRpcException(this.message);

  /// Human-readable failure description.
  final String message;

  @override
  String toString() => 'ACP JSON-RPC error: $message';
}

/// The peer sent invalid JSON-RPC or invalid NDJSON framing.
final class AcpProtocolException extends AcpJsonRpcException {
  /// Creates a protocol error.
  const AcpProtocolException(super.message);
}

/// A JSON-RPC response contained an error object.
final class AcpRemoteException extends AcpJsonRpcException {
  /// Creates a remote JSON-RPC error.
  const AcpRemoteException({
    required this.code,
    required String message,
    this.data,
  }) : super(message);

  /// JSON-RPC error code.
  final int code;

  /// Optional error data.
  final Object? data;
}

/// A request ended as cancelled (JSON-RPC `-32800`).
///
/// Raised when the peer answers with `-32800`, and when this side cancels its
/// own in-flight request through [AcpJsonRpcConnection.cancelRequest]. It is an
/// [AcpRemoteException] so existing remote-error handling keeps working, while
/// callers that surface errors can match it and show a plain "cancelled"
/// outcome instead of a protocol failure.
final class AcpRequestCancelledException extends AcpRemoteException {
  /// Creates a cancellation error.
  const AcpRequestCancelledException({
    super.message = 'Request cancelled',
    super.data,
    this.cancelledLocally = false,
  }) : super(code: acpRequestCancelledErrorCode);

  /// Whether this side cancelled the request before any peer response.
  final bool cancelledLocally;
}

/// Lets a caller cancel one request issued with [AcpJsonRpcConnection.request].
///
/// Pass a fresh instance per request. Cancelling fails the request's future
/// with a locally cancelled [AcpRequestCancelledException] and sends a
/// best-effort `$/cancel_request` so the peer can stop its work.
final class AcpRequestCancellation {
  /// Creates an unbound cancellation handle.
  AcpRequestCancellation();

  Object? _owner;
  void Function()? _onCancel;
  var _cancelled = false;

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Cancels the bound request, if it is still pending. Idempotent.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final onCancel = _onCancel;
    _owner = null;
    _onCancel = null;
    onCancel?.call();
  }

  void _bind(Object owner, void Function() onCancel) {
    _owner = owner;
    _onCancel = onCancel;
  }

  void _unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _onCancel = null;
  }
}

/// A request did not receive a response before its deadline.
final class AcpRequestTimeoutException extends AcpJsonRpcException {
  /// Creates a timeout error.
  const AcpRequestTimeoutException(this.id, this.method, Duration timeout)
    : super('Request $method ($id) timed out after $timeout');

  /// Timed-out request identifier.
  final AcpRequestId id;

  /// Timed-out method.
  final String method;
}

/// The connection closed while work was pending.
final class AcpConnectionClosedException extends AcpJsonRpcException {
  /// Creates a connection-closed error.
  const AcpConnectionClosedException([super.message = 'Connection closed']);
}

/// A received JSON-RPC notification.
final class AcpJsonRpcNotification {
  /// Creates a JSON-RPC notification.
  const AcpJsonRpcNotification({
    required this.method,
    required this.params,
    required this.raw,
  });

  /// Notification method.
  final String method;

  /// Optional notification parameters.
  final Object? params;

  /// Complete notification object.
  final AcpJsonMap raw;
}

/// A received JSON-RPC request that must be answered by the client.
final class AcpJsonRpcServerRequest {
  AcpJsonRpcServerRequest._({
    required this.id,
    required this.method,
    required this.params,
    required this.raw,
    required Future<void> Function(Object? result) respond,
    required Future<void> Function(int code, String message, Object? data)
    respondError,
    void Function(AcpJsonRpcServerRequest request)? onAnswered,
  }) : _respond = respond,
       _respondError = respondError,
       _onAnswered = onAnswered;

  /// Request identifier.
  final AcpRequestId id;

  /// Request method.
  final String method;

  /// Optional request parameters.
  final Object? params;

  /// Complete request object.
  final AcpJsonMap raw;

  final Future<void> Function(Object? result) _respond;
  final Future<void> Function(int code, String message, Object? data)
  _respondError;
  final void Function(AcpJsonRpcServerRequest request)? _onAnswered;
  final _cancellation = Completer<void>();
  var _answered = false;
  var _cancelledByPeer = false;

  /// Whether a response (including a cancellation error) has been sent.
  bool get isAnswered => _answered;

  /// Whether the peer withdrew this request with `$/cancel_request`.
  ///
  /// The connection has already answered it with `-32800`; later [respond]
  /// and [respondError] calls are silently ignored so slow work that finishes
  /// afterward never double-answers.
  bool get isCancelled => _cancelledByPeer;

  /// Completes when the peer cancels this request. Never errors.
  Future<void> get cancelled => _cancellation.future;

  /// Responds successfully exactly once.
  Future<void> respond([Object? result]) {
    if (_cancelledByPeer) return Future<void>.value();
    _markAnswered();
    return _respond(result);
  }

  /// Responds with a JSON-RPC error exactly once.
  Future<void> respondError(int code, String message, {Object? data}) {
    if (_cancelledByPeer) return Future<void>.value();
    _markAnswered();
    return _respondError(code, message, data);
  }

  /// Answers with `-32800` because this side abandoned the request.
  Future<void> respondCancelled() =>
      respondError(acpRequestCancelledErrorCode, 'Request cancelled');

  Future<void> _cancelFromPeer() {
    if (_answered) return Future<void>.value();
    _markAnswered();
    _cancelledByPeer = true;
    _cancellation.complete();
    return _respondError(
      acpRequestCancelledErrorCode,
      'Request cancelled',
      null,
    );
  }

  void _markAnswered() {
    if (_answered) throw StateError('JSON-RPC request was already answered');
    _answered = true;
    _onAnswered?.call(this);
  }
}

final class _PendingResponse {
  _PendingResponse({
    required this.id,
    required this.completer,
    required this.timer,
    this.cancellation,
    this.onWriteStarted,
  });

  final AcpRequestId id;
  final Completer<Object?> completer;
  final Timer? timer;
  final AcpRequestCancellation? cancellation;
  final void Function()? onWriteStarted;

  /// Whether the request's frame started reaching the peer. A request that
  /// expires while still queued is never written, so the peer needs no
  /// `$/cancel_request` for it.
  bool writeStarted = false;
}

/// Default bounded ACP JSON-RPC frame size, large enough for a 10 MiB image
/// after base64 expansion and JSON envelope overhead.
const acpJsonRpcDefaultMaxFrameBytes = 20 * 1024 * 1024;

/// Reusable NDJSON JSON-RPC 2.0 connection for ACP.
final class AcpJsonRpcConnection {
  /// Starts a connection over [transport].
  AcpJsonRpcConnection({
    required AcpTransport transport,
    this.defaultRequestTimeout = const Duration(seconds: 30),
    this.maxFrameSize = acpJsonRpcDefaultMaxFrameBytes,
    AcpRequestIdFactory? requestIdFactory,
  }) : _transport = transport,
       _requestIdFactory = requestIdFactory ?? const Uuid().v4 {
    if (maxFrameSize <= 0) {
      throw ArgumentError.value(maxFrameSize, 'maxFrameSize');
    }
    _incomingSubscription = transport is AcpDecodedTransport
        ? transport.incomingFrames.listen(
            _handleDecodedFrame,
            onError: _handleTransportError,
            onDone: _handleTransportDone,
            cancelOnError: false,
          )
        : transport.incoming.listen(
            _handleBytes,
            onError: _handleTransportError,
            onDone: _handleTransportDone,
            cancelOnError: false,
          );
  }

  /// Default deadline applied to requests.
  final Duration defaultRequestTimeout;

  /// Maximum UTF-8 size of one JSON frame, excluding its LF or CRLF delimiter.
  final int maxFrameSize;

  final AcpTransport _transport;
  final AcpRequestIdFactory _requestIdFactory;
  final _frameBytes = BytesBuilder(copy: false);
  final _pending = <AcpRequestId, _PendingResponse>{};
  // Unanswered peer requests by their exact JSON-RPC id. Dart map keys keep
  // numeric `1` and string `"1"` distinct, matching JSON-RPC identity.
  final _inboundRequests = <AcpRequestId, AcpJsonRpcServerRequest>{};
  final _notifications = StreamController<AcpJsonRpcNotification>.broadcast(
    sync: true,
  );
  final _serverRequests = StreamController<AcpJsonRpcServerRequest>.broadcast(
    sync: true,
  );
  final _errors = StreamController<AcpJsonRpcException>.broadcast(sync: true);
  late final StreamSubscription<Object?> _incomingSubscription;
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _closeFuture;
  var _closed = false;

  /// Received JSON-RPC notifications.
  Stream<AcpJsonRpcNotification> get notifications => _notifications.stream;

  /// Received server-to-client JSON-RPC requests.
  Stream<AcpJsonRpcServerRequest> get serverRequests => _serverRequests.stream;

  /// Protocol and transport failures observed by the connection.
  Stream<AcpJsonRpcException> get errors => _errors.stream;

  /// Whether the connection has closed.
  bool get isClosed => _closed;

  /// Sends a request and awaits its result.
  ///
  /// When the deadline passes, the request fails with
  /// [AcpRequestTimeoutException] and a best-effort `$/cancel_request` asks the
  /// peer to stop working on it. [cancellation] lets the caller cancel it
  /// explicitly; see [cancelRequest]. Requests that expire or are cancelled
  /// before their queued write begins are not sent, and need no cancel.
  ///
  /// [onWriteStarted] runs once the frame starts reaching the peer. A request
  /// that fails without it never left this side: the connection was already
  /// closed, the frame was too large, or it closed while the write was queued.
  Future<Object?> request(
    String method, {
    Object? params,
    Duration? timeout,
    AcpRequestId? id,
    bool noTimeout = false,
    AcpRequestCancellation? cancellation,
    void Function()? onWriteStarted,
  }) {
    _ensureOpen();
    final requestId = id ?? _requestIdFactory();
    if (requestId is! String && requestId is! int) {
      throw ArgumentError.value(
        requestId,
        'id',
        'JSON-RPC IDs must be strings or integers',
      );
    }
    if (_pending.containsKey(requestId)) {
      throw StateError('Duplicate JSON-RPC request ID: $requestId');
    }
    if (cancellation?.isCancelled ?? false) {
      return Future<Object?>.error(
        const AcpRequestCancelledException(cancelledLocally: true),
      );
    }
    final completer = Completer<Object?>();
    final effectiveTimeout = noTimeout
        ? null
        : timeout ?? defaultRequestTimeout;
    late final _PendingResponse pending;
    final timer = effectiveTimeout == null
        ? null
        : Timer(effectiveTimeout, () {
            if (!_removePending(pending)) return;
            pending.completer.completeError(
              AcpRequestTimeoutException(requestId, method, effectiveTimeout),
            );
            if (pending.writeStarted) _sendCancelRequest(requestId);
          });
    pending = _PendingResponse(
      id: requestId,
      completer: completer,
      timer: timer,
      cancellation: cancellation,
      onWriteStarted: onWriteStarted,
    );
    _pending[requestId] = pending;
    cancellation?._bind(pending, () => cancelRequest(requestId));
    unawaited(
      _writeMessage(<String, Object?>{
        'jsonrpc': '2.0',
        'id': requestId,
        'method': method,
        'params': ?params,
      }, pending: pending).catchError((Object error, StackTrace stackTrace) {
        if (_removePending(pending)) {
          pending.completer.completeError(error, stackTrace);
        }
      }),
    );
    return completer.future;
  }

  /// Sends a JSON-RPC notification.
  Future<void> notify(String method, {Object? params}) {
    _ensureOpen();
    return _writeMessage(<String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  /// Cancels an in-flight request this side issued.
  ///
  /// The request's future fails immediately with a locally cancelled
  /// [AcpRequestCancelledException], and a best-effort `$/cancel_request` asks
  /// the peer to stop. A request still queued behind other writes is dropped
  /// instead. Any late peer response for [id] is ignored. Returns whether a
  /// pending request with exactly [id] (type included) was found.
  bool cancelRequest(AcpRequestId id) {
    final pending = _pending[id];
    if (pending == null || !_removePending(pending)) return false;
    if (!pending.completer.isCompleted) {
      pending.completer.completeError(
        const AcpRequestCancelledException(cancelledLocally: true),
      );
    }
    if (pending.writeStarted) _sendCancelRequest(id);
    return true;
  }

  void _sendCancelRequest(AcpRequestId id) {
    if (_closed) return;
    unawaited(
      notify(
        acpCancelRequestMethod,
        params: <String, Object?>{'requestId': id},
      ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  /// Closes the connection and fails all pending requests.
  Future<void> close() => _terminate(const AcpConnectionClosedException());

  void _handleBytes(List<int> bytes) {
    if (_closed) return;
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var start = 0;
    while (start < chunk.length) {
      final end = chunk.indexOf(0x0a, start);
      final segmentEnd = end < 0 ? chunk.length : end;
      if (segmentEnd > start) {
        _frameBytes.add(Uint8List.sublistView(chunk, start, segmentEnd));
        // A trailing CR may be the first byte of a split CRLF delimiter.
        final trailingCr = chunk[segmentEnd - 1] == 0x0d ? 1 : 0;
        if (!_validateIncomingFrameSize(_frameBytes.length - trailingCr)) {
          return;
        }
      }
      if (end < 0) return;
      var frame = _frameBytes.takeBytes();
      if (frame.isNotEmpty && frame.last == 0x0d) {
        frame = Uint8List.sublistView(frame, 0, frame.length - 1);
      }
      if (frame.isNotEmpty) _handleFrame(frame);
      if (_closed) return;
      start = end + 1;
    }
  }

  void _handleFrame(List<int> bytes) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      _protocolFailure(const AcpProtocolException('Invalid ACP JSON frame'));
      return;
    }
    _handleMessage(AcpJson.object(decoded));
  }

  void _handleDecodedFrame(AcpDecodedFrame frame) {
    if (_closed) return;
    if (!_validateIncomingFrameSize(frame.byteLength)) return;
    _handleMessage(frame.message, immutable: true);
  }

  bool _validateIncomingFrameSize(int byteLength) {
    if (byteLength >= 0 && byteLength <= maxFrameSize) return true;
    _protocolFailure(
      AcpProtocolException(
        'ACP frame exceeds maximum size of $maxFrameSize bytes',
      ),
    );
    return false;
  }

  void _handleMessage(AcpJsonMap? message, {bool immutable = false}) {
    if (message == null || message['jsonrpc'] != '2.0') {
      _protocolFailure(
        const AcpProtocolException('Invalid JSON-RPC 2.0 message'),
      );
      return;
    }
    final method = AcpJson.string(message, 'method');
    final id = message['id'];
    if (method != null) {
      if (id == null) {
        if (method == acpCancelRequestMethod) {
          // Answer before listeners see the notification so they observe the
          // request as already cancelled.
          _handlePeerCancel(message['params']);
        }
        _notifications.add(
          AcpJsonRpcNotification(
            method: method,
            params: message['params'],
            raw: immutable ? message : AcpJson.immutableObject(message),
          ),
        );
        return;
      }
      if (id is! String && id is! int) {
        _protocolFailure(
          const AcpProtocolException('Invalid JSON-RPC request ID'),
        );
        return;
      }
      final request = AcpJsonRpcServerRequest._(
        id: id,
        method: method,
        params: message['params'],
        raw: immutable ? message : AcpJson.immutableObject(message),
        respond: (result) => _writeMessage(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }),
        respondError: (code, errorMessage, data) =>
            _writeMessage(<String, Object?>{
              'jsonrpc': '2.0',
              'id': id,
              'error': <String, Object?>{
                'code': code,
                'message': errorMessage,
                'data': ?data,
              },
            }),
        onAnswered: (answered) {
          if (identical(_inboundRequests[answered.id], answered)) {
            _inboundRequests.remove(answered.id);
          }
        },
      );
      _inboundRequests[id] = request;
      _serverRequests.add(request);
      return;
    }
    if (id is! String && id is! int) {
      _protocolFailure(
        const AcpProtocolException('Invalid JSON-RPC response ID'),
      );
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.cancellation?._unbind(pending);
    final error = AcpJson.objectField(message, 'error');
    if (error != null) {
      final code = AcpJson.integer(error, 'code');
      if (code == null) {
        const protocolError = AcpProtocolException(
          'JSON-RPC error response has an invalid code',
        );
        pending.completer.completeError(protocolError);
        _protocolFailure(protocolError);
        return;
      }
      final errorMessage = AcpJson.string(error, 'message') ?? 'Remote error';
      pending.completer.completeError(
        code == acpRequestCancelledErrorCode
            ? AcpRequestCancelledException(
                message: errorMessage,
                data: error['data'],
              )
            : AcpRemoteException(
                code: code,
                message: errorMessage,
                data: error['data'],
              ),
      );
      return;
    }
    if (!message.containsKey('result')) {
      pending.completer.completeError(
        const AcpProtocolException(
          'JSON-RPC response has neither result nor error',
        ),
      );
      return;
    }
    pending.completer.complete(message['result']);
  }

  bool _removePending(_PendingResponse pending) {
    // An ID may have been reused since this request's callback was scheduled.
    if (!identical(_pending[pending.id], pending)) return false;
    _pending.remove(pending.id);
    pending.timer?.cancel();
    pending.cancellation?._unbind(pending);
    return true;
  }

  void _handlePeerCancel(Object? params) {
    final requestId = AcpJson.object(params)?['requestId'];
    // Only exact JSON-RPC ids match: a numeric 1 never cancels request "1".
    if (requestId is! String && requestId is! int) return;
    final request = _inboundRequests.remove(requestId);
    if (request == null) return;
    unawaited(
      request._cancelFromPeer().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  Future<void> _writeMessage(
    AcpJsonMap message, {
    _PendingResponse? pending,
  }) async {
    _ensureOpen();
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length - 1 > maxFrameSize) {
      throw AcpProtocolException(
        'ACP frame exceeds maximum size of $maxFrameSize bytes',
      );
    }
    final operation = _writeTail.then<void>((_) async {
      _ensureOpen();
      // A request may expire while waiting for an earlier write. Check the
      // pending object as well as its ID because callers can reuse expired IDs.
      if (pending != null) {
        if (!identical(_pending[pending.id], pending)) return;
        pending.writeStarted = true;
        pending.onWriteStarted?.call();
      }
      await _transport.write(bytes);
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(operation.then<void>((_) {}, onError: _handleTransportError));
    return operation;
  }

  void _handleTransportError(Object error, StackTrace stackTrace) {
    if (_closed) return;
    final reason = AcpConnectionClosedException('ACP transport failed: $error');
    final termination = _terminate(reason, stackTrace);
    if (!_errors.isClosed) _errors.add(reason);
    unawaited(termination);
  }

  void _handleTransportDone() {
    if (_frameBytes.isNotEmpty) {
      _protocolFailure(
        const AcpProtocolException('ACP transport closed mid-frame'),
      );
      return;
    }
    unawaited(
      _terminate(const AcpConnectionClosedException('ACP transport closed')),
    );
  }

  void _protocolFailure(AcpProtocolException error) {
    final termination = _terminate(error);
    if (!_errors.isClosed) _errors.add(error);
    unawaited(termination);
  }

  Future<void> _terminate(
    AcpJsonRpcException reason, [
    StackTrace? stackTrace,
  ]) => _closeFuture ??= _performTermination(reason, stackTrace);

  Future<void> _performTermination(
    AcpJsonRpcException reason,
    StackTrace? stackTrace,
  ) async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      pending.cancellation?._unbind(pending);
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(reason, stackTrace);
      }
    }
    _pending.clear();
    _inboundRequests.clear();
    await _incomingSubscription.cancel();
    try {
      await _transport.close();
    } on Object {
      // The connection is already terminal; transport cleanup is best-effort.
    }
    await _notifications.close();
    await _serverRequests.close();
    await _errors.close();
  }

  void _ensureOpen() {
    if (_closed) throw const AcpConnectionClosedException();
  }
}
