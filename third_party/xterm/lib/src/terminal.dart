import 'dart:async';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:xterm/src/base/observable.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/escape/emitter.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/core/graphics_manager.dart';
import 'package:xterm/src/core/escape/parser.dart';
import 'package:xterm/src/core/input/handler.dart';
import 'package:xterm/src/core/input/kitty_keyboard.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/handler.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/platform.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/core/tabs.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

typedef _GraphicsPreinflation = ({Uint8List? payload, int micros});
typedef _GraphicsImageNumberReservation = ({
  int number,
  int imageId,
  int? previousImageId,
});
typedef _GraphicsDeletePosition = ({
  Buffer buffer,
  int cursorCol,
  int cursorRow,
  int scrollBack,
});

// MonkeySSH-private DEC mode used to make MonkeyMux redraws paint atomically.
const _monkeyMuxSynchronizedOutputMode = 9002;

/// [Terminal] is an interface to interact with command line applications. It
/// translates escape sequences from the application into updates to the
/// [buffer] and events such as [onTitleChange] or [onBell], as well as
/// translating user input into escape sequences that the application can
/// understand.
class Terminal with Observable implements TerminalState, EscapeHandler {
  /// The number of lines that the scrollback buffer can hold. If the buffer
  /// exceeds this size, the lines at the top of the buffer will be removed.
  final int maxLines;

  /// Function that is called when the program requests the terminal to ring
  /// the bell. If not set, the terminal will do nothing.
  void Function()? onBell;

  /// Function that is called when the program requests the terminal to change
  /// the title of the window to [title].
  void Function(String title)? onTitleChange;

  /// Function that is called when the program requests the terminal to change
  /// the icon of the window. [icon] is the name of the icon.
  void Function(String icon)? onIconChange;

  /// Function that is called when the terminal emits data to the underlying
  /// program. This is typically caused by user inputs from [textInput],
  /// [keyInput], [mouseInput], or [paste].
  void Function(String data)? onOutput;

  /// Function that is called when the dimensions of the terminal change.
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
      onResize;

  /// Function called after a MonkeySSH-private host resize updates the grid.
  void Function(int width, int height)? onHostResize;

  /// Whether MonkeySSH-private host resize sequences may update this terminal.
  bool Function()? canResizeFromHost;

  int _hostResizeGeneration = 0;
  bool _monkeyMuxSynchronizedOutput = false;

  /// Number of MonkeySSH-private host resizes parsed by this terminal.
  int get hostResizeGeneration => _hostResizeGeneration;

  /// Resets private host-resize negotiation before opening a new transport.
  void resetHostResizeState() {
    _hostResizeGeneration = 0;
    final wasSynchronized = _monkeyMuxSynchronizedOutput;
    _monkeyMuxSynchronizedOutput = false;
    if (wasSynchronized) {
      // A synchronized redraw (DEC mode 9002) was interrupted mid-transaction
      // by a transport reset / reattach. The server always writes the begin and
      // end markers together, so this only happens when the parse was cut off,
      // e.g. a very large redraw split across parse turns. Flush the repaint we
      // were holding so the parsed-so-far content is not stranded off-screen.
      notifyListeners();
    }
  }

  /// The [TerminalInputHandler] used by this terminal. [defaultInputHandler] is
  /// used when not specified. User of this class can provide their own
  /// implementation of [TerminalInputHandler] or extend [defaultInputHandler]
  /// with [CascadeInputHandler].
  TerminalInputHandler? inputHandler;

  TerminalMouseHandler? mouseHandler;

  /// The callback that is called when the terminal receives a unrecognized
  /// escape sequence.
  void Function(String code, List<String> args)? onPrivateOSC;

  /// Flag to toggle os specific behaviors.
  final TerminalTargetPlatform platform;

  /// Characters that break selection when double clicking. If not set, the
  /// [Buffer.defaultWordSeparators] will be used.
  final Set<int>? wordSeparators;

  Terminal({
    this.maxLines = 1000,
    this.onBell,
    this.onTitleChange,
    this.onIconChange,
    this.onOutput,
    this.onResize,
    this.platform = TerminalTargetPlatform.unknown,
    this.inputHandler = defaultInputHandler,
    this.mouseHandler = defaultMouseHandler,
    this.onPrivateOSC,
    this.reflowEnabled = true,
    this.wordSeparators,
  });

  late final _parser = EscapeParser(this);

  final _emitter = const EscapeEmitter();

  /// Decoded Kitty-graphics-protocol images and their placements for the active
  /// buffer. Read by the painter to composite images over the cell grid. Each
  /// buffer keeps its own set, so images do not leak between the main and
  /// alternate screens.
  GraphicsManager get graphics => _buffer.graphics;

  /// Whether this terminal advertises and accepts Kitty graphics.
  ///
  /// Disable this when an intermediate terminal layer cannot carry Kitty APC
  /// sequences end-to-end. Native Windows OpenSSH PTY channels use the system
  /// ConPTY, which removes the image transmission while preserving Unicode
  /// placeholder cells; reporting support there would produce permanent holes.
  bool kittyGraphicsEnabled = true;

  /// The `{imageId: sourceSignature}` of every Kitty image currently held across
  /// both the main and alternate screens (decoded or still pending).
  ///
  /// Reported to the MonkeyMux server on a window switch so it can omit
  /// re-transmitting images the client already holds, avoiding a multi-megabyte
  /// re-parse of image data the client would immediately discard as a duplicate.
  Map<int, int> heldImageSignatures() {
    final result = <int, int>{}
      ..addAll(_mainBuffer.graphics.heldImageSignatures())
      ..addAll(_altBuffer.graphics.heldImageSignatures());
    return result;
  }

  /// Protocol image ids referenced by on-screen Kitty Unicode-placeholder cells
  /// on the active screen that resolve to no stored or pending image.
  ///
  /// Scoped to the active buffer on purpose: it is the visible screen, and it is
  /// the only buffer a replay repopulates — the bytes a server sends in response
  /// arrive as normal output and are parsed into whichever buffer is active when
  /// they land. Reporting an id that is only unresolved on the inactive buffer
  /// would request bytes that get parsed into the wrong buffer, leaving the
  /// inactive one blank while the caller records the id as already handled.
  /// Reported to the MonkeyMux server via `request_images` so it can replay
  /// exactly these ids from its retained cache, repopulating images a bounded
  /// switch/reconnect replay dropped.
  Set<int> unresolvedPlaceholderImageIds() =>
      _buffer.graphics.unresolvedPlaceholderImageIds();

  /// Cap on the size of a single buffered graphics transmission (16 MiB).
  static const _maxGraphicsBytes = 16 * 1024 * 1024;
  static const _graphicsBarrierOperationKey = 'barrier';
  static const _graphicsUnkeyedOperationKey = 'unkeyed';

  bool _graphicsActive = false;
  Map<String, String> _graphicsArgs = const {};
  final List<int> _graphicsData = [];
  final Map<GraphicsManager, Map<String, Future<void>>> _graphicsOperations =
      {};
  _PendingKittyPlaceholder? _pendingKittyPlaceholder;
  _PendingKittyPlaceholder? _lastKittyPlaceholder;

  late var _buffer = _mainBuffer;

  late final _mainBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: false,
    wordSeparators: wordSeparators,
  );

  late final _altBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: true,
    wordSeparators: wordSeparators,
  );

  final _tabStops = TabStops();

  /// The last character written to the buffer. Used to implement some escape
  /// sequences that repeat the last character.
  var _precedingCodepoint = 0;

  /* TerminalState */

  int _viewWidth = 80;

  int _viewHeight = 24;

  final _cursorStyle = CursorStyle();

  bool _insertMode = false;

  bool _lineFeedMode = false;

  bool _cursorKeysMode = false;

  bool _ansiMode = true;

  bool _reverseDisplayMode = false;

  bool _originMode = false;

  bool _autoWrapMode = true;

  MouseMode _mouseMode = MouseMode.none;

  MouseReportMode _mouseReportMode = MouseReportMode.normal;

  bool _cursorBlinkMode = false;

  bool _cursorVisibleMode = true;

  bool _appKeypadMode = false;

  bool _reportFocusMode = false;

  bool _altBufferMouseScrollMode = false;

  bool _bracketedPasteMode = false;

  final _mainKittyKeyboardState = KittyKeyboardState();

  final _altKittyKeyboardState = KittyKeyboardState();

  /* State getters */

  /// Number of cells in a terminal row.
  @override
  int get viewWidth => _viewWidth;

  /// Number of rows in this terminal.
  @override
  int get viewHeight => _viewHeight;

  @override
  CursorStyle get cursor => _cursorStyle;

  @override
  bool get insertMode => _insertMode;

  @override
  bool get lineFeedMode => _lineFeedMode;

  @override
  bool get cursorKeysMode => _cursorKeysMode;

  @override
  bool get ansiMode => _ansiMode;

  @override
  bool get reverseDisplayMode => _reverseDisplayMode;

  @override
  bool get originMode => _originMode;

  @override
  bool get autoWrapMode => _autoWrapMode;

  @override
  MouseMode get mouseMode => _mouseMode;

  @override
  MouseReportMode get mouseReportMode => _mouseReportMode;

  @override
  bool get cursorBlinkMode => _cursorBlinkMode;

  @override
  bool get cursorVisibleMode => _cursorVisibleMode;

  @override
  bool get appKeypadMode => _appKeypadMode;

  @override
  bool get reportFocusMode => _reportFocusMode;

  @override
  bool get altBufferMouseScrollMode => _altBufferMouseScrollMode;

  @override
  bool get bracketedPasteMode => _bracketedPasteMode;

  /// Whether Kitty keyboard progressive-enhancement flags are active.
  bool get kittyKeyboardMode => kittyKeyboardFlags != 0;

  /// Alias matching kterm's public API.
  bool get kittyMode => kittyKeyboardMode;

  /// Active Kitty keyboard progressive-enhancement flags for the current buffer.
  int get kittyKeyboardFlags => _kittyKeyboardState.flags;

  KittyKeyboardState get _kittyKeyboardState =>
      _buffer.isAltBuffer ? _altKittyKeyboardState : _mainKittyKeyboardState;

  /// Current active buffer of the terminal. This is initially [mainBuffer] and
  /// can be switched back and forth from [altBuffer] to [mainBuffer] when
  /// the underlying program requests it.
  Buffer get buffer => _buffer;

  Buffer get mainBuffer => _mainBuffer;

  Buffer get altBuffer => _altBuffer;

  bool get isUsingAltBuffer => _buffer == _altBuffer;

  /// Lines of the active buffer.
  IndexAwareCircularBuffer<BufferLine> get lines => _buffer.lines;

  /// Whether the terminal performs reflow when the viewport size changes or
  /// simply truncates lines. true by default.
  @override
  bool reflowEnabled;

  /// Writes the data from the underlying program to the terminal. Calling this
  /// updates the states of the terminal and emits events such as [onBell] or
  /// [onTitleChange] when the escape sequences in [data] request it.
  void write(String data) {
    _parser.write(data);
    notifyListeners();
  }

  /// Writes [data] to the terminal without notifying listeners of the resulting
  /// state change.
  ///
  /// Escape sequences that reply to the program (device attributes, cursor
  /// position, etc.) still fire their own notifications, but the routine buffer
  /// update does not, so the view is not repainted for this write.
  ///
  /// This lets the host app drain a large burst of output — e.g. the multi-MB
  /// redraw a multiplexer replays when switching to an image-heavy window —
  /// across several frames while coalescing repaints: advance the parser with
  /// this, then call [notifyListeners] at a throttled cadence and once more when
  /// the burst is fully drained. Scheduling one repaint per parsed slice instead
  /// floods the raster thread with image-heavy frames it cannot keep up with,
  /// so frames queue and the switch appears to hang. Interactive writes should
  /// use [write], which repaints immediately.
  ///
  /// While a MonkeyMux synchronized redraw (DEC private mode 9002) is open this
  /// method still advances the parser but the caller's [notifyListeners] is
  /// suppressed, so the intermediate synthetic-resize frame captured mid-redraw
  /// never paints. The single settled repaint is emitted by the caller's own
  /// progress notification once the closing marker has been parsed.
  void writeSilently(String data) {
    _parser.write(data);
  }

  @override
  void notifyListeners() {
    // Hold repaints while a synchronized redraw transaction is open so the
    // whole redraw (including the hidden synthetic-resize frame) is applied as
    // one atomic paint. The server always emits the 9002 begin and end markers
    // in the same write, so the transaction cannot be left open across writes.
    if (_monkeyMuxSynchronizedOutput) {
      return;
    }
    super.notifyListeners();
  }

  /// Sends a key event to the underlying program.
  ///
  /// See also:
  /// - [charInput]
  /// - [textInput]
  /// - [paste]
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool meta = false,
    TerminalKeyEventType type = TerminalKeyEventType.press,
  }) {
    final event = TerminalKeyboardEvent(
      key: key,
      shift: shift,
      alt: alt,
      ctrl: ctrl,
      meta: meta,
      type: type,
      state: this,
      altBuffer: isUsingAltBuffer,
      platform: platform,
    );

    final kittyOutput = encodeKittyKeyboardEvent(
      event,
      _kittyKeyboardState.flags,
    );
    if (kittyOutput != null) {
      onOutput?.call(kittyOutput);
      notifyListeners();
      return true;
    }

    if (type == TerminalKeyEventType.release) {
      return false;
    }

    final output = inputHandler?.call(event);

    if (output != null) {
      onOutput?.call(output);
      notifyListeners();
      return true;
    }

    return false;
  }

  /// Similary to [keyInput], but takes a character as input instead of a
  /// [TerminalKey].
  ///
  /// See also:
  /// - [keyInput]
  /// - [textInput]
  /// - [paste]
  bool charInput(int charCode, {bool alt = false, bool ctrl = false}) {
    if (ctrl) {
      // a(97) ~ z(122)
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final output = charCode - Ascii.a + 1;
        onOutput?.call(String.fromCharCode(output));
        notifyListeners();
        return true;
      }

      // [(91) ~ _(95)
      if (charCode >= Ascii.openBracket && charCode <= Ascii.underscore) {
        final output = charCode - Ascii.openBracket + 27;
        onOutput?.call(String.fromCharCode(output));
        notifyListeners();
        return true;
      }
    }

    if (alt && platform != TerminalTargetPlatform.macos) {
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final code = charCode - Ascii.a + 65;
        final input = [0x1b, code];
        onOutput?.call(String.fromCharCodes(input));
        notifyListeners();
        return true;
      }
    }

    return false;
  }

  /// Sends regular text input to the underlying program.
  ///
  /// See also:
  /// - [keyInput]
  /// - [charInput]
  /// - [paste]
  void textInput(String text) {
    final kittyOutput = encodeKittyTextInput(text, _kittyKeyboardState.flags);
    if (kittyOutput != null) {
      onOutput?.call(kittyOutput);
      notifyListeners();
      return;
    }
    onOutput?.call(text);
    notifyListeners();
  }

  /// Similar to [textInput], except that when the program tells the terminal
  /// that it supports [bracketedPasteMode], the text is wrapped in escape
  /// sequences to indicate that it is a paste operation. Prefer this method
  /// over [textInput] when pasting text.
  ///
  /// See also:
  /// - [textInput]
  void paste(String text) {
    // Strip terminal control sequences and unsafe controls before sending paste
    // payloads.
    text = text.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
    text = text.replaceAll(RegExp(r'\x1b\][\s\S]*?(?:\x07|\x1b\\)'), '');
    text = text.replaceAll(RegExp(r'\x1b[P\^_X][\s\S]*?\x1b\\'), '');
    text = text.replaceAll(RegExp(r'\x1b[ -/]*[@-~]'), '');
    text = text.replaceAll(
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'),
      '',
    );

    text = text.replaceAll('\r\n', '\n');
    text = text.replaceAll('\r', '\n');
    text = text.replaceAll('\n', _lineFeedMode ? '\r\n' : '\r');

    if (_bracketedPasteMode) {
      onOutput?.call(_emitter.bracketedPaste(text));
      notifyListeners();
    } else {
      textInput(text);
    }
  }

  // Handle a mouse event and return true if it was handled.
  bool mouseInput(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    CellOffset position,
  ) {
    final output = mouseHandler?.call(
      TerminalMouseEvent(
        button: button,
        buttonState: buttonState,
        position: position,
        state: this,
        platform: platform,
      ),
    );
    if (output != null) {
      onOutput?.call(output);
      return true;
    }
    return false;
  }

  /// Resize the terminal screen. [newWidth] and [newHeight] should be greater
  /// than 0. Text reflow is currently not implemented and will be avaliable in
  /// the future.
  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    _resize(
      newWidth,
      newHeight,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      notify: true,
    );
  }

  @override
  void resizeFromHost(int newWidth, int newHeight) {
    if (!(canResizeFromHost?.call() ?? false)) {
      return;
    }
    _resize(newWidth, newHeight, notify: false);
    _hostResizeGeneration++;
    onHostResize?.call(viewWidth, viewHeight);
    // Applying the host grid re-lays-out both buffers. Without a repaint the
    // reflowed content is never drawn, so a grid publish that arrives as the
    // last bytes of a burst would leave the view showing the pre-resize frame.
    notifyListeners();
  }

  void _resize(
    int newWidth,
    int newHeight, {
    int? pixelWidth,
    int? pixelHeight,
    required bool notify,
  }) {
    newWidth = max(newWidth, 1);
    newHeight = max(newHeight, 1);

    if (notify) {
      onResize?.call(newWidth, newHeight, pixelWidth ?? 0, pixelHeight ?? 0);
    }

    //we need to resize both buffers so that they are ready when we switch between them
    _altBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);
    _mainBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);

    _viewWidth = newWidth;
    _viewHeight = newHeight;
    _altBuffer.graphics.setViewportColumns(newWidth);
    _mainBuffer.graphics.setViewportColumns(newWidth);

    if (buffer == _altBuffer) {
      buffer.clearScrollback();
    }

    _altBuffer.resetVerticalMargins();
    _mainBuffer.resetVerticalMargins();
  }

  @override
  String toString() {
    return 'Terminal(#$hashCode, $_viewWidth x $_viewHeight, ${_buffer.height} lines)';
  }

  /* Handlers */

  @override
  void writeChar(int char) {
    if (_pendingKittyPlaceholder != null) {
      final diacriticValue = _kittyPlaceholderDiacriticValue(char);
      if (diacriticValue != null) {
        _pendingKittyPlaceholder!.addDiacritic(diacriticValue);
        _lastKittyPlaceholder = _pendingKittyPlaceholder;
        return;
      }
      _pendingKittyPlaceholder = null;
    }
    _PendingKittyPlaceholder? placeholderToBind;
    if (char == kittyGraphicsPlaceholderCodePoint) {
      final line = _buffer.currentLine;
      final pending = _PendingKittyPlaceholder(
        foreground: _buffer.terminal.cursor.foreground,
        underlineColor: _buffer.terminal.cursor.underlineColor,
        anchor: line.createAnchor(_buffer.cursorX),
        previous: _lastKittyPlaceholder,
      );
      placeholderToBind = pending;
      _pendingKittyPlaceholder = pending;
      _lastKittyPlaceholder = pending;
    }
    _precedingCodepoint = char;
    _buffer.writeChar(char);
    if (placeholderToBind != null) {
      placeholderToBind.bind(
        _buffer.graphics.addPlaceholder(
          imageId: placeholderToBind.imageId,
          imageIdBitWidth: placeholderToBind.imageIdBitWidth,
          anchor: placeholderToBind.anchor,
          row: placeholderToBind.row,
          col: placeholderToBind.col,
        ),
      );
    }
  }

  /* SBC */

  @override
  void bell() {
    onBell?.call();
  }

  @override
  void backspaceReturn() {
    _buffer.moveCursorX(-1);
  }

  @override
  void tab() {
    final nextStop = _tabStops.find(_buffer.cursorX + 1, _viewWidth);

    if (nextStop != null) {
      _buffer.setCursorX(nextStop);
    } else {
      _buffer.setCursorX(_viewWidth);
      _buffer.cursorGoForward(); // Enter pending-wrap state
    }
  }

  @override
  void lineFeed() {
    _buffer.lineFeed();
  }

  @override
  void carriageReturn() {
    _buffer.setCursorX(0);
  }

  @override
  void shiftOut() {
    _buffer.charset.use(1);
  }

  @override
  void shiftIn() {
    _buffer.charset.use(0);
  }

  @override
  void unknownSBC(int char) {
    // no-op
  }

  /* ANSI sequence */

  @override
  void saveCursor() {
    _buffer.saveCursor();
  }

  @override
  void restoreCursor() {
    _buffer.restoreCursor();
  }

  @override
  void index() {
    _buffer.index();
  }

  @override
  void nextLine() {
    _buffer.index();
    _buffer.setCursorX(0);
  }

  @override
  void setTapStop() {
    _tabStops.setAt(_buffer.cursorX);
  }

  @override
  void reverseIndex() {
    _buffer.reverseIndex();
  }

  @override
  void designateCharset(int charset, int name) {
    _buffer.charset.designate(charset, name);
  }

  @override
  void unkownEscape(int char) {
    // no-op
  }

  /* CSI */

  @override
  void repeatPreviousCharacter(int count) {
    if (_precedingCodepoint == 0) {
      return;
    }

    for (var i = 0; i < count; i++) {
      _buffer.writeChar(_precedingCodepoint);
    }
  }

  @override
  void setCursor(int x, int y) {
    _buffer.setCursor(x, y);
  }

  @override
  void setCursorX(int x) {
    _buffer.setCursorX(x);
  }

  @override
  void setCursorY(int y) {
    _buffer.setCursorY(y);
  }

  @override
  void moveCursorX(int offset) {
    _buffer.moveCursorX(offset);
  }

  @override
  void moveCursorY(int n) {
    _buffer.moveCursorY(n);
  }

  @override
  void clearTabStopUnderCursor() {
    _tabStops.clearAt(_buffer.cursorX);
  }

  @override
  void clearAllTabStops() {
    _tabStops.clearAll();
  }

  @override
  void sendPrimaryDeviceAttributes() {
    onOutput?.call(_emitter.primaryDeviceAttributes());
  }

  @override
  void sendSecondaryDeviceAttributes() {
    onOutput?.call(_emitter.secondaryDeviceAttributes());
  }

  @override
  void sendTertiaryDeviceAttributes() {
    onOutput?.call(_emitter.tertiaryDeviceAttributes());
  }

  @override
  void sendTerminalVersion() {
    onOutput?.call(_emitter.terminalVersion());
  }

  @override
  void sendModeReport(int mode) {
    onOutput?.call(_emitter.modeReport(mode, _ansiModeValue(mode)));
  }

  /// DECRQM state value for an ANSI mode: 1 set, 2 reset, 0 not recognized.
  ///
  /// Only the ANSI-mode form (`CSI Ps $ p`) is answered here. The DEC-private
  /// form (`CSI ? Ps $ p`) is answered by the MonkeySSH app layer, so the core
  /// must not reply to it (see [EscapeParser]).
  int _ansiModeValue(int mode) {
    switch (mode) {
      case 4: // IRM - Insert/Replace
        return _insertMode ? 1 : 2;
      case 20: // LNM - Line Feed/New Line
        return _lineFeedMode ? 1 : 2;
      default:
        return 0;
    }
  }

  @override
  void sendTermcapReport(List<String> capabilities) {
    final output = onOutput;
    if (output == null) return;
    for (final hexName in capabilities) {
      if (hexName.isEmpty) continue;
      final name = _decodeHex(hexName);
      final value = name == null ? null : _termcapValue(name);
      output(
        _emitter.termcapReport(
          hexName,
          value == null ? null : _encodeHex(value),
        ),
      );
    }
  }

  /// Resolves a terminfo/termcap capability value for XTGETTCAP, or null when
  /// the capability is unknown/unsupported.
  ///
  /// Only unambiguous, theme-independent capabilities are answered. The
  /// terminal name (`TN`) is intentionally not reported: TERM is host-defined
  /// (MonkeySSH leaves it unchanged, often `xterm-256color`), so answering a
  /// fixed name here would risk a mismatch with the negotiated TERM.
  String? _termcapValue(String name) {
    switch (name) {
      case 'Co': // termcap: maximum colors
      case 'colors': // terminfo: maximum colors
        return '256';
      case 'RGB': // direct-color support, bits per channel
        return '8/8/8';
      default:
        return null;
    }
  }

  String? _decodeHex(String hex) {
    if (hex.isEmpty || hex.length.isOdd) return null;
    final units = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      units.add(byte);
    }
    return String.fromCharCodes(units);
  }

  String _encodeHex(String value) {
    final buffer = StringBuffer();
    for (final unit in value.codeUnits) {
      buffer.write(unit.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  @override
  void sendStatusStringReport(String request) {
    onOutput?.call(_emitter.statusStringReport(_statusStringValue(request)));
  }

  /// Resolves the DECRQSS status string for [request] (the control function's
  /// intermediate/final), or null when the request is not recognized.
  ///
  /// Only control functions whose state the terminal actually tracks are
  /// answered; the cursor style (` q`), conformance level (`"p`) and similar
  /// are reported as not recognized rather than guessed.
  String? _statusStringValue(String request) {
    switch (request) {
      case 'r': // DECSTBM - scrolling region (top/bottom margins, 1-based)
        return '${_buffer.marginTop + 1};${_buffer.marginBottom + 1}r';
      case 'm': // SGR - current graphic rendition
        return '${_currentSgrParameters()}m';
      default:
        return null;
    }
  }

  /// Serializes the active pen as SGR parameters, beginning with `0` (reset) so
  /// the string reproduces the rendition on its own.
  String _currentSgrParameters() {
    final params = <int>[0];
    final style = _cursorStyle;
    final attrs = style.attrs;
    if (attrs & CellAttr.bold != 0) params.add(1);
    if (attrs & CellAttr.faint != 0) params.add(2);
    if (attrs & CellAttr.italic != 0) params.add(3);
    if (attrs & CellAttr.underline != 0) params.add(4);
    if (attrs & CellAttr.blink != 0) params.add(5);
    if (attrs & CellAttr.inverse != 0) params.add(7);
    if (attrs & CellAttr.invisible != 0) params.add(8);
    if (attrs & CellAttr.strikethrough != 0) params.add(9);
    if (attrs & CellAttr.overline != 0) params.add(53);
    _appendSgrColor(params, style.foreground, named: 30, bright: 90, ext: 38);
    _appendSgrColor(params, style.background, named: 40, bright: 100, ext: 48);
    _appendSgrUnderlineColor(params, style.underlineColor);
    return params.join(';');
  }

  void _appendSgrColor(
    List<int> params,
    int color, {
    required int named,
    required int bright,
    required int ext,
  }) {
    final type = (color & CellColor.typeMask);
    final value = color & CellColor.valueMask;
    switch (type) {
      case CellColor.named:
        params.add(value < 8 ? named + value : bright + (value - 8));
        break;
      case CellColor.palette:
        params.addAll([ext, 5, value]);
        break;
      case CellColor.rgb:
        params.addAll([
          ext,
          2,
          (value >> 16) & 0xFF,
          (value >> 8) & 0xFF,
          value & 0xFF,
        ]);
        break;
    }
  }

  void _appendSgrUnderlineColor(List<int> params, int color) {
    final value = color & CellColor.valueMask;
    switch (color & CellColor.typeMask) {
      case CellColor.palette:
        params.addAll([58, 5, value]);
        break;
      case CellColor.rgb:
        params.addAll([
          58,
          2,
          (value >> 16) & 0xFF,
          (value >> 8) & 0xFF,
          value & 0xFF,
        ]);
        break;
    }
  }

  @override
  void sendOperatingStatus() {
    onOutput?.call(_emitter.operatingStatus());
  }

  @override
  void sendCursorPosition() {
    onOutput?.call(_emitter.cursorPosition(_buffer.cursorX, _buffer.cursorY));
  }

  @override
  void setMargins(int top, [int? bottom]) {
    _buffer.setVerticalMargins(top, bottom ?? viewHeight - 1);
  }

  @override
  void cursorNextLine(int amount) {
    _buffer.moveCursorY(amount);
    _buffer.setCursorX(0);
  }

  @override
  void cursorPrecedingLine(int amount) {
    _buffer.moveCursorY(-amount);
    _buffer.setCursorX(0);
  }

  @override
  void eraseDisplayBelow() {
    _buffer.eraseDisplayFromCursor();
  }

  @override
  void eraseDisplayAbove() {
    _buffer.eraseDisplayToCursor();
  }

  @override
  void eraseDisplay() {
    _buffer.eraseDisplay();
  }

  @override
  void eraseScrollbackOnly() {
    _buffer.clearScrollback();
  }

  @override
  void eraseLineRight() {
    _buffer.eraseLineFromCursor();
  }

  @override
  void eraseLineLeft() {
    _buffer.eraseLineToCursor();
  }

  @override
  void eraseLine() {
    _buffer.eraseLine();
  }

  @override
  void insertLines(int amount) {
    _buffer.insertLines(amount);
  }

  @override
  void deleteLines(int amount) {
    _buffer.deleteLines(amount);
  }

  @override
  void deleteChars(int amount) {
    _buffer.deleteChars(amount);
  }

  @override
  void scrollUp(int amount) {
    _buffer.scrollUp(amount);
  }

  @override
  void scrollDown(int amount) {
    _buffer.scrollDown(amount);
  }

  @override
  void eraseChars(int amount) {
    _buffer.eraseChars(amount);
  }

  @override
  void insertBlankChars(int amount) {
    _buffer.insertBlankChars(amount);
  }

  @override
  void sendSize() {
    onOutput?.call(_emitter.size(viewHeight, viewWidth));
  }

  @override
  void unknownCSI(int finalByte) {
    // no-op
  }

  /* Modes */

  @override
  void setInsertMode(bool enabled) {
    _insertMode = enabled;
  }

  @override
  void setLineFeedMode(bool enabled) {
    _lineFeedMode = enabled;
  }

  @override
  void setUnknownMode(int mode, bool enabled) {
    // no-op
  }

  /* DEC Private modes */

  @override
  void setCursorKeysMode(bool enabled) {
    _cursorKeysMode = enabled;
  }

  @override
  void setAnsiMode(bool enabled) {
    _ansiMode = enabled;
  }

  @override
  void setReverseDisplayMode(bool enabled) {
    _reverseDisplayMode = enabled;
  }

  @override
  void setOriginMode(bool enabled) {
    _originMode = enabled;
  }

  @override
  void setColumnMode(bool enabled) {
    // no-op
  }

  @override
  void setAutoWrapMode(bool enabled) {
    _autoWrapMode = enabled;
  }

  @override
  void setMouseMode(MouseMode mode) {
    _mouseMode = mode;
  }

  @override
  void setCursorBlinkMode(bool enabled) {
    _cursorBlinkMode = enabled;
  }

  @override
  void setCursorVisibleMode(bool enabled) {
    _cursorVisibleMode = enabled;
  }

  @override
  void useAltBuffer() {
    _buffer = _altBuffer;
  }

  @override
  void useMainBuffer() {
    _buffer = _mainBuffer;
  }

  @override
  void clearAltBuffer() {
    _altBuffer.clear();
  }

  @override
  void setAppKeypadMode(bool enabled) {
    _appKeypadMode = enabled;
  }

  @override
  void setReportFocusMode(bool enabled) {
    _reportFocusMode = enabled;
  }

  @override
  void setMouseReportMode(MouseReportMode mode) {
    _mouseReportMode = mode;
  }

  @override
  void setAltBufferMouseScrollMode(bool enabled) {
    _altBufferMouseScrollMode = enabled;
  }

  @override
  void setBracketedPasteMode(bool enabled) {
    _bracketedPasteMode = enabled;
  }

  @override
  void setUnknownDecMode(int mode, bool enabled) {
    if (mode != _monkeyMuxSynchronizedOutputMode) {
      return;
    }
    _monkeyMuxSynchronizedOutput = enabled;
  }

  @override
  void setKittyKeyboardFlags(int flags, int mode) {
    _kittyKeyboardState.setFlags(flags, mode);
  }

  @override
  void pushKittyKeyboardFlags(int flags) {
    _kittyKeyboardState.pushFlags(flags);
  }

  @override
  void popKittyKeyboardFlags(int count) {
    _kittyKeyboardState.popFlags(count);
  }

  @override
  void sendKittyKeyboardFlags() {
    onOutput?.call('\x1b[?${_kittyKeyboardState.flags}u');
  }

  /* Select Graphic Rendition (SGR) */

  @override
  void resetCursorStyle() {
    _cursorStyle.reset();
  }

  @override
  void setCursorBold() {
    _cursorStyle.setBold();
  }

  @override
  void setCursorFaint() {
    _cursorStyle.setFaint();
  }

  @override
  void setCursorItalic() {
    _cursorStyle.setItalic();
  }

  @override
  void setCursorUnderline() {
    _cursorStyle.setUnderline();
  }

  @override
  void setCursorUnderlineStyle(UnderlineStyle style) {
    _cursorStyle.setUnderlineStyle(style);
  }

  @override
  void setCursorOverline() {
    _cursorStyle.setOverline();
  }

  @override
  void setCursorBlink() {
    _cursorStyle.setBlink();
  }

  @override
  void setCursorInverse() {
    _cursorStyle.setInverse();
  }

  @override
  void setCursorInvisible() {
    _cursorStyle.setInvisible();
  }

  @override
  void setCursorStrikethrough() {
    _cursorStyle.setStrikethrough();
  }

  @override
  void unsetCursorBold() {
    _cursorStyle.unsetBold();
  }

  @override
  void unsetCursorFaint() {
    _cursorStyle.unsetFaint();
  }

  @override
  void unsetCursorItalic() {
    _cursorStyle.unsetItalic();
  }

  @override
  void unsetCursorUnderline() {
    _cursorStyle.unsetUnderline();
  }

  @override
  void unsetCursorOverline() {
    _cursorStyle.unsetOverline();
  }

  @override
  void unsetCursorBlink() {
    _cursorStyle.unsetBlink();
  }

  @override
  void unsetCursorInverse() {
    _cursorStyle.unsetInverse();
  }

  @override
  void unsetCursorInvisible() {
    _cursorStyle.unsetInvisible();
  }

  @override
  void unsetCursorStrikethrough() {
    _cursorStyle.unsetStrikethrough();
  }

  @override
  void setForegroundColor16(int color) {
    _cursorStyle.setForegroundColor16(color);
  }

  @override
  void setForegroundColor256(int index) {
    _cursorStyle.setForegroundColor256(index);
  }

  @override
  void setForegroundColorRgb(int r, int g, int b) {
    _cursorStyle.setForegroundColorRgb(r, g, b);
  }

  @override
  void resetForeground() {
    _cursorStyle.resetForegroundColor();
  }

  @override
  void setBackgroundColor16(int color) {
    _cursorStyle.setBackgroundColor16(color);
  }

  @override
  void setBackgroundColor256(int index) {
    _cursorStyle.setBackgroundColor256(index);
  }

  @override
  void setBackgroundColorRgb(int r, int g, int b) {
    _cursorStyle.setBackgroundColorRgb(r, g, b);
  }

  @override
  void resetBackground() {
    _cursorStyle.resetBackgroundColor();
  }

  @override
  void setUnderlineColor256(int index) {
    _cursorStyle.setUnderlineColor256(index);
  }

  @override
  void setUnderlineColorRgb(int r, int g, int b) {
    _cursorStyle.setUnderlineColorRgb(r, g, b);
  }

  @override
  void resetUnderlineColor() {
    _cursorStyle.resetUnderlineColor();
  }

  @override
  void unsupportedStyle(int param) {
    // no-op
  }

  /* OSC */

  @override
  void setTitle(String name) {
    onTitleChange?.call(name);
  }

  @override
  void setIconName(String name) {
    onIconChange?.call(name);
  }

  @override
  void unknownOSC(String ps, List<String> pt) {
    onPrivateOSC?.call(ps, pt);
  }

  @override
  void graphicsCommandStart(Map<String, String> args) {
    if (_graphicsActive) return; // continuation chunk; keep the first args
    if (_isBareContinuationArgs(args)) {
      // An orphaned continuation chunk: it carries only the `m` more-data flag,
      // so its first chunk (with the action/format/id) was never seen — e.g. a
      // transmission truncated by a racing window-switch replay. Starting a
      // command from it would decode a headless image (no id/format, which then
      // fails to decode) and, worse, leave the transmission "active" so the next
      // real image's first chunk is swallowed as a no-op start and finalized
      // under these empty args, dropping that image. Ignore it instead.
      return;
    }
    _graphicsActive = true;
    _graphicsArgs = args;
    _graphicsData.clear();
  }

  /// Whether [args] is a bare Kitty continuation chunk — one that carries only
  /// the `m` more-data flag (optionally `q` quiet) and none of the keys a first
  /// chunk sets (action, format, id, dimensions, ...). Such a chunk is only
  /// valid while a transmission is already active.
  static bool _isBareContinuationArgs(Map<String, String> args) {
    if (!args.containsKey('m')) return false;
    for (final key in args.keys) {
      if (key != 'm' && key != 'q') return false;
    }
    return true;
  }

  /// Atomically submits a complete graphics command when no multipart Kitty
  /// transmission is active.
  ///
  /// Returns false instead of corrupting the pending command when another
  /// protocol attempts to interleave a complete image.
  bool submitGraphicsCommand(Map<String, String> args, List<int> data) {
    if (_graphicsActive) return false;
    graphicsCommandStart(args);
    graphicsDataChunk(data);
    graphicsCommandEnd();
    return true;
  }

  /// Fits an encoded image inside a terminal-cell bounding box while
  /// preserving its decoded pixel aspect ratio as closely as cell rounding
  /// permits.
  ({int columns, int rows})? fitGraphicsInCellBounds(
    Uint8List data, {
    required int maxColumns,
    required int maxRows,
  }) {
    if (maxColumns <= 0 || maxRows <= 0) return null;
    final dimensions = _graphicsPayloadDimensions(const {'f': '98'}, data);
    if (dimensions == null || dimensions.width <= 0 || dimensions.height <= 0) {
      return null;
    }
    final rowsPerColumn = dimensions.height /
        dimensions.width *
        _buffer.graphics.cellPixelAspectRatio;
    if (!rowsPerColumn.isFinite || rowsPerColumn <= 0) return null;

    var columns = maxColumns;
    var rows = (columns * rowsPerColumn).ceil();
    if (rows > maxRows) {
      rows = maxRows;
      columns = (rows / rowsPerColumn).floor().clamp(1, maxColumns);
      rows = (columns * rowsPerColumn).ceil().clamp(1, maxRows);
    }
    return (columns: columns.clamp(1, maxColumns), rows: rows);
  }

  @override
  void graphicsDataChunk(List<int> data) {
    if (!_graphicsActive) return;
    if (_graphicsData.length + data.length > _maxGraphicsBytes) {
      // Discard oversized transmissions instead of growing without bound.
      _graphicsActive = false;
      _graphicsData.clear();
      return;
    }
    _graphicsData.addAll(data);
  }

  @override
  void graphicsCommandAbort() {
    // An ESC ended the command before its terminator, so whatever an earlier
    // `m=1` chunk opened can never be completed. Dropping it keeps the next
    // real image from being swallowed as a continuation of this one.
    if (!_graphicsActive) return;
    _graphicsActive = false;
    _graphicsData.clear();
  }

  @override
  void graphicsCommandEnd() {
    if (!_graphicsActive) return;
    _graphicsActive = false;

    final args = _graphicsArgs;
    final data = Uint8List.fromList(_graphicsData);
    _graphicsData.clear();

    if (!kittyGraphicsEnabled) {
      _respondToGraphicsFailure(args, 'ENOTSUP: graphics disabled');
      return;
    }

    if (args['a'] == 'q') {
      _respondToGraphicsQuery(args, data);
      return;
    }

    final action = args['a'] ?? 't';
    final virtualPlacement = args['U'] == '1';
    final manager = _buffer.graphics;
    final explicitImageId = int.tryParse(args['i'] ?? '');
    final imageNumber = int.tryParse(args['I'] ?? '');
    _GraphicsImageNumberReservation? imageNumberReservation;
    if (explicitImageId != null &&
        explicitImageId > 0 &&
        imageNumber != null &&
        imageNumber > 0) {
      if ((action == 't' || action == 'T') && data.isNotEmpty) {
        final reservation = manager.reserveExplicitImageIdForNumber(
          imageNumber,
          explicitImageId,
        );
        if (!reservation.accepted) {
          _respondToGraphicsFailure(
            args,
            'ENOSPC: image-number limit exceeded',
          );
          return;
        }
        imageNumberReservation = (
          number: imageNumber,
          imageId: explicitImageId,
          previousImageId: reservation.previousImageId,
        );
      } else {
        // Establish explicit id/number mappings before placement or async image
        // commands so every action in the stream observes the same association.
        if (!manager.registerImageNumber(imageNumber, explicitImageId)) {
          _respondToGraphicsFailure(
            args,
            'ENOSPC: image-number limit exceeded',
          );
          return;
        }
      }
    }
    if (action == 'p') {
      if (virtualPlacement) {
        _setVirtualGraphicsPlacement(args);
      } else {
        _placeStoredGraphics(args);
      }
      return;
    }

    if (imageNumberReservation == null &&
        (action == 't' || action == 'T') &&
        data.isNotEmpty &&
        (explicitImageId == null || explicitImageId <= 0) &&
        imageNumber != null &&
        imageNumber > 0) {
      final reserved = manager.reserveImageIdForNumber(imageNumber);
      if (reserved.imageId <= 0) {
        _respondToGraphicsFailure(
          args,
          'ENOSPC: image-number limit exceeded',
        );
        return;
      }
      imageNumberReservation = (
        number: imageNumber,
        imageId: reserved.imageId,
        previousImageId: reserved.previousImageId,
      );
    }
    final commandImageId = imageNumberReservation?.imageId ??
        _resolveGraphicsImageId(manager, args);
    final mutatesAnimation = action == 'f' ||
        action == 'c' ||
        (action == 'a' &&
            (args.containsKey('c') ||
                args.containsKey('s') ||
                args.containsKey('v') ||
                args.containsKey('r') ||
                args.containsKey('z')));
    final animationMutationImageId = mutatesAnimation ? commandImageId : null;
    if (animationMutationImageId != null) {
      manager.markImageAnimationDirty(animationMutationImageId);
    }
    if (action == 'd') {
      final selector = args['d'] ?? 'a';
      final buffer = _buffer;
      final position = (
        buffer: buffer,
        cursorCol: buffer.cursorX,
        cursorRow: buffer.absoluteCursorY,
        scrollBack: buffer.absoluteCursorY - buffer.cursorY,
      );
      if ((selector == 'i' ||
              selector == 'I' ||
              selector == 'n' ||
              selector == 'N') &&
          _graphicsOperationKey(manager, args) != null) {
        _scheduleGraphicsOperation(
          manager,
          args,
          () async => _deleteGraphics(
            args,
            position,
            commandImageId: commandImageId,
          ),
        );
      } else {
        _scheduleGraphicsBarrier(
          manager,
          () async => _deleteGraphics(
            args,
            position,
            commandImageId: commandImageId,
          ),
        );
      }
      return;
    }

    if (action == 'f') {
      _scheduleGraphicsOperation(
        manager,
        args,
        () async {
          try {
            await _finalizeAnimationFrame(
              args,
              data,
              manager,
              commandImageId: commandImageId,
            );
          } finally {
            if (animationMutationImageId != null) {
              manager.settleImageAnimationMutation(
                animationMutationImageId,
              );
            }
          }
        },
      );
      return;
    }
    if (action == 'a') {
      _scheduleGraphicsOperation(
        manager,
        args,
        () async {
          try {
            await _controlGraphicsAnimation(
              args,
              manager,
              commandImageId: commandImageId,
            );
          } finally {
            if (animationMutationImageId != null) {
              manager.settleImageAnimationMutation(
                animationMutationImageId,
              );
            }
          }
        },
      );
      return;
    }
    if (action == 'c') {
      _scheduleGraphicsOperation(
        manager,
        args,
        () async {
          try {
            await _composeGraphicsAnimationFrames(
              args,
              manager,
              commandImageId: commandImageId,
            );
          } finally {
            if (animationMutationImageId != null) {
              manager.settleImageAnimationMutation(
                animationMutationImageId,
              );
            }
          }
        },
      );
      return;
    }

    // Only transmit (a=t) and transmit-and-display (a=T) remain.
    if ((action != 't' && action != 'T') || data.isEmpty) {
      return;
    }
    // a=T transmits and displays at the cursor. When U=1 is also set the client
    // is using the Unicode placeholder protocol: the image is displayed by
    // U+10EEEE placeholder cells (see `_paintKittyPlaceholderGraphics`), not a
    // physical placement, so creating one here would draw a second, misplaced
    // copy. Only place — and advance the cursor — for a non-virtual a=T.
    final shouldPlace = action == 'T' && !virtualPlacement;
    if (virtualPlacement) {
      _setVirtualGraphicsPlacement(args);
    }

    // Anchor the placement to the cursor cell now, before the async decode or
    // any further output can move the cursor. Bind it to the buffer that is
    // active at command time so a later buffer switch can't misplace it.
    final buffer = _buffer;
    final anchor =
        shouldPlace ? buffer.currentLine.createAnchor(buffer.cursorX) : null;
    final generation = shouldPlace ? buffer.graphics.generation : null;
    if (anchor != null) {
      buffer.graphics.retainPendingPlacementAnchor(anchor);
    }

    // Move the cursor below the image so following output does not overlap it,
    // unless the client set the no-cursor-movement policy (C=1) — e.g. a client
    // redrawing a full-screen image in place keeps the cursor where it is, and
    // advancing it past the bottom margin would scroll the screen.
    final keepCursor = args['C'] == '1';
    _GraphicsPreinflation? preinflation;
    if (shouldPlace &&
        !keepCursor &&
        args['o'] == 'z' &&
        _graphicsDisplayNeedsPayloadDimensions(args)) {
      final observer = terminalGraphicsDecodeObserver;
      final stopwatch = observer == null ? null : (Stopwatch()..start());
      preinflation = (
        payload: inflateZlibData(data),
        micros: stopwatch?.elapsedMicroseconds ?? 0,
      );
    }
    final rows = shouldPlace && !keepCursor
        ? _graphicsDisplayRows(
            args,
            data,
            buffer.graphics,
            preinflation: preinflation,
            maxRows: buffer.viewHeight,
          )
        : 0;
    if (shouldPlace && !keepCursor) {
      _advanceGraphicsCursor(buffer, rows);
    }

    _scheduleGraphicsOperation(
      buffer.graphics,
      args,
      () async {
        try {
          await _finalizeGraphics(
            args,
            data,
            anchor,
            buffer.graphics,
            generation,
            preinflation: preinflation,
            commandImageId: commandImageId,
            imageNumberReservation: imageNumberReservation,
          );
        } finally {
          if (anchor != null) {
            buffer.graphics.releasePendingPlacementAnchor(anchor);
          }
        }
      },
    );
  }

  void _scheduleGraphicsOperation(
    GraphicsManager manager,
    Map<String, String> args,
    Future<void> Function() operation,
  ) {
    final key =
        _graphicsOperationKey(manager, args) ?? _graphicsUnkeyedOperationKey;
    final operations = _graphicsOperations.putIfAbsent(manager, () => {});
    final previous = operations[key];
    final barrier = operations[_graphicsBarrierOperationKey];
    final blockers = <Future<void>>{
      if (previous != null) previous,
      if (barrier != null) barrier,
    };
    final future = blockers.isEmpty
        ? operation()
        : Future.wait(blockers).then((_) => operation());
    operations[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(operations[key], future)) {
          operations.remove(key);
          if (operations.isEmpty) {
            _graphicsOperations.remove(manager);
          }
        }
      }),
    );
  }

  /// Runs a graphics operation after every earlier image operation and makes
  /// every later operation wait for it. Position/all-image deletes need this
  /// barrier because they have no image id to share a per-image queue with.
  void _scheduleGraphicsBarrier(
    GraphicsManager manager,
    Future<void> Function() operation,
  ) {
    final operations = _graphicsOperations.putIfAbsent(manager, () => {});
    final blockers = operations.values.toSet();
    final future = blockers.isEmpty
        ? operation()
        : Future.wait(blockers).then((_) => operation());
    operations[_graphicsBarrierOperationKey] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(operations[_graphicsBarrierOperationKey], future)) {
          operations.remove(_graphicsBarrierOperationKey);
          if (operations.isEmpty) {
            _graphicsOperations.remove(manager);
          }
        }
      }),
    );
  }

  String? _graphicsOperationKey(
    GraphicsManager manager,
    Map<String, String> args,
  ) {
    final imageId = int.tryParse(args['i'] ?? '');
    if (imageId != null && imageId > 0) {
      return 'i:$imageId';
    }
    final imageNumber = int.tryParse(args['I'] ?? '');
    if (imageNumber != null && imageNumber > 0) {
      final mappedId = manager.imageIdForNumber(imageNumber);
      return mappedId == null ? 'I:$imageNumber' : 'i:$mappedId';
    }
    return null;
  }

  int? _resolveGraphicsImageId(
    GraphicsManager manager,
    Map<String, String> args,
  ) {
    final imageId = int.tryParse(args['i'] ?? '');
    if (imageId != null && imageId > 0) {
      return imageId;
    }
    final imageNumber = int.tryParse(args['I'] ?? '');
    if (imageNumber == null || imageNumber <= 0) {
      return null;
    }
    return manager.imageIdForNumber(imageNumber);
  }

  Future<void> _finalizeAnimationFrame(
    Map<String, String> args,
    Uint8List data,
    GraphicsManager manager, {
    int? commandImageId,
  }) async {
    if (data.isEmpty) {
      _respondToGraphicsFailure(args, 'EINVAL: missing frame data');
      return;
    }
    manager.onChanged ??= notifyListeners;
    final imageId = commandImageId ?? _resolveGraphicsImageId(manager, args);
    if (imageId == null) {
      _respondToGraphicsFailure(args, 'ENOENT: image not found');
      return;
    }
    final image = await manager.resolveImage(imageId);
    if (image == null) {
      _respondToGraphicsFailure(args, 'ENOENT: image not found');
      return;
    }

    final observer = terminalGraphicsDecodeObserver;
    final compressed = args['o'] == 'z';
    var payload = data;
    var inflateMicros = 0;
    if (compressed) {
      final inflateStopwatch = observer == null ? null : (Stopwatch()..start());
      final inflated = inflateZlibData(data);
      inflateMicros = inflateStopwatch?.elapsedMicroseconds ?? 0;
      if (inflated == null) {
        observer?.call(
          payloadBytes: data.length,
          inflateMicros: inflateMicros,
          decodeMicros: 0,
          compressed: true,
          success: false,
          imageId: imageId.toString(),
          action: 'f',
        );
        _respondToGraphicsFailure(args, 'EINVAL: invalid compressed frame');
        return;
      }
      payload = inflated;
    }

    final format = _graphicsFormat(args);
    final blockWidth = int.tryParse(args['s'] ?? '') ?? image.sourceWidth;
    final blockHeight = int.tryParse(args['v'] ?? '') ?? image.sourceHeight;
    final decodeStopwatch = observer == null ? null : (Stopwatch()..start());
    await terminalGraphicsDecodeGate.acquire();
    final decoded = await () async {
      try {
        return await decodeTerminalImageFirstFrameSequence(
          payload,
          format: format,
          width: blockWidth,
          height: blockHeight,
        );
      } finally {
        terminalGraphicsDecodeGate.release();
      }
    }();
    observer?.call(
      payloadBytes: payload.length,
      inflateMicros: inflateMicros,
      decodeMicros: decodeStopwatch?.elapsedMicroseconds ?? 0,
      compressed: compressed,
      success: decoded != null,
      imageId: imageId.toString(),
      action: 'f',
      reused: false,
    );
    if (decoded == null) {
      _respondToGraphicsFailure(args, 'EINVAL: invalid frame data');
      return;
    }

    final result = await manager.addAnimationFrame(
      imageId,
      decoded,
      x: int.tryParse(args['x'] ?? '') ?? 0,
      y: int.tryParse(args['y'] ?? '') ?? 0,
      width: int.tryParse(args['s'] ?? '') ?? 0,
      height: int.tryParse(args['v'] ?? '') ?? 0,
      backgroundFrame: int.tryParse(args['c'] ?? '') ?? 0,
      backgroundColor: int.tryParse(args['Y'] ?? ''),
      replace: args['X'] == '1',
      editFrame: int.tryParse(args['r'] ?? '') ?? 0,
      gap: _graphicsAnimationGap(args),
    );
    final error = switch (result) {
      TerminalAnimationFrameResult.success => null,
      TerminalAnimationFrameResult.imageNotFound => 'ENOENT: image not found',
      TerminalAnimationFrameResult.frameNotFound =>
        'ENOENT: base or edit frame not found',
      TerminalAnimationFrameResult.invalidRectangle =>
        'EINVAL: invalid frame rectangle',
      TerminalAnimationFrameResult.noSpace =>
        'ENOSPC: image memory limit exceeded',
      TerminalAnimationFrameResult.rasterizationFailed =>
        'EINVAL: frame composition failed',
    };
    if (error == null) {
      _respondToGraphicsSuccess(args);
    } else {
      _respondToGraphicsFailure(args, error);
    }
  }

  Future<void> _controlGraphicsAnimation(
    Map<String, String> args,
    GraphicsManager manager, {
    int? commandImageId,
  }) async {
    manager.onChanged ??= notifyListeners;
    final imageId = commandImageId ?? _resolveGraphicsImageId(manager, args);
    final hasControl = args.containsKey('c') ||
        args.containsKey('s') ||
        args.containsKey('v') ||
        args.containsKey('r') ||
        args.containsKey('z');
    if (!hasControl) {
      if (imageId == null ||
          (manager.imageById(imageId) == null &&
              !manager.hasPendingImage(imageId))) {
        _respondToGraphicsFailure(args, 'ENOENT: image not found');
      }
      return;
    }
    if (imageId == null || await manager.resolveImage(imageId) == null) {
      _respondToGraphicsFailure(args, 'ENOENT: image not found');
      return;
    }

    final state = switch (int.tryParse(args['s'] ?? '')) {
      1 => TerminalAnimationState.stopped,
      2 => TerminalAnimationState.loading,
      3 => TerminalAnimationState.running,
      _ => null,
    };
    manager.controlAnimation(
      imageId,
      currentFrame: int.tryParse(args['c'] ?? ''),
      state: state,
      protocolLoopCount: int.tryParse(args['v'] ?? ''),
      gapFrame: int.tryParse(args['r'] ?? ''),
      gap: _graphicsAnimationGap(args),
    );
  }

  Future<void> _composeGraphicsAnimationFrames(
    Map<String, String> args,
    GraphicsManager manager, {
    int? commandImageId,
  }) async {
    manager.onChanged ??= notifyListeners;
    final imageId = commandImageId ?? _resolveGraphicsImageId(manager, args);
    if (imageId == null) {
      _respondToGraphicsFailure(args, 'ENOENT: image not found');
      return;
    }
    await manager.resolveImage(imageId);
    final sourceFrame = int.tryParse(args['r'] ?? '') ?? 0;
    final destinationFrame = int.tryParse(args['c'] ?? '') ?? 0;
    final result = await manager.composeAnimationFrames(
      imageId,
      sourceFrame: sourceFrame,
      destinationFrame: destinationFrame,
      // Kitty's reference implementation uses X/Y for the source and x/y for
      // the destination (matching the protocol's composition example).
      sourceX: int.tryParse(args['X'] ?? '') ?? 0,
      sourceY: int.tryParse(args['Y'] ?? '') ?? 0,
      destinationX: int.tryParse(args['x'] ?? '') ?? 0,
      destinationY: int.tryParse(args['y'] ?? '') ?? 0,
      width: int.tryParse(args['w'] ?? '') ?? 0,
      height: int.tryParse(args['h'] ?? '') ?? 0,
      replace: args['C'] == '1',
    );
    final error = switch (result) {
      TerminalAnimationCompositionResult.success => null,
      TerminalAnimationCompositionResult.imageNotFound ||
      TerminalAnimationCompositionResult.frameNotFound =>
        'ENOENT: image or frame not found',
      TerminalAnimationCompositionResult.invalidRectangle =>
        'EINVAL: invalid composition rectangle',
      TerminalAnimationCompositionResult.noSpace =>
        'ENOSPC: image memory limit exceeded',
      TerminalAnimationCompositionResult.rasterizationFailed =>
        'EINVAL: frame composition failed',
    };
    if (error == null) {
      _respondToGraphicsSuccess(args);
    } else {
      _respondToGraphicsFailure(args, error);
    }
  }

  Duration? _graphicsAnimationGap(Map<String, String> args) {
    final milliseconds = int.tryParse(args['z'] ?? '');
    if (milliseconds == null || milliseconds == 0) {
      return null;
    }
    return Duration(milliseconds: max(0, milliseconds));
  }

  void _respondToGraphicsFailure(
    Map<String, String> args,
    String error,
  ) {
    if (_graphicsResponseSuppressed(args, success: false)) {
      return;
    }
    final control = <String>[
      if (args['i'] case final imageId? when imageId.isNotEmpty) 'i=$imageId',
      if (args['I'] case final imageNumber? when imageNumber.isNotEmpty)
        'I=$imageNumber',
    ];
    onOutput?.call('\x1b_G${control.join(',')};$error\x1b\\');
  }

  void _respondToGraphicsSuccess(Map<String, String> args) {
    if (_graphicsResponseSuppressed(args, success: true)) {
      return;
    }
    final control = <String>[
      if (args['i'] case final imageId? when imageId.isNotEmpty) 'i=$imageId',
      if (args['I'] case final imageNumber? when imageNumber.isNotEmpty)
        'I=$imageNumber',
    ];
    onOutput?.call('\x1b_G${control.join(',')};OK\x1b\\');
  }

  Future<void> _finalizeGraphics(
    Map<String, String> args,
    Uint8List data,
    CellAnchor? anchor,
    GraphicsManager manager,
    int? generation, {
    _GraphicsPreinflation? preinflation,
    int? commandImageId,
    _GraphicsImageNumberReservation? imageNumberReservation,
  }) async {
    final format = _graphicsFormat(args);
    final width = int.tryParse(args['s'] ?? '') ?? 0;
    final height = int.tryParse(args['v'] ?? '') ?? 0;

    // Wire the deferred-decode repaint signal (idempotent). A lazily decoded
    // image calls this once it is ready so the painter recomposites it.
    manager.onChanged ??= notifyListeners;

    final observer = terminalGraphicsDecodeObserver;
    final compressed = args['o'] == 'z';

    // Inflate zlib-compressed payloads (o=z) before decoding. This runs
    // synchronously on the UI thread, so time it separately from the decode.
    var payload = data;
    var inflateMicros = 0;
    if (compressed) {
      final Uint8List? inflated;
      if (preinflation != null) {
        inflated = preinflation.payload;
        inflateMicros = preinflation.micros;
      } else {
        final inflateStopwatch =
            observer == null ? null : (Stopwatch()..start());
        inflated = inflateZlibData(data);
        inflateMicros = inflateStopwatch?.elapsedMicroseconds ?? 0;
      }
      if (inflated == null) {
        observer?.call(
          payloadBytes: data.length,
          inflateMicros: inflateMicros,
          decodeMicros: 0,
          compressed: true,
          success: false,
          imageId: args['i'],
          action: args['a'],
        );
        _rollbackGraphicsImageNumberReservation(
          manager,
          imageNumberReservation,
        );
        anchor?.dispose();
        return;
      }
      payload = inflated;
    }

    final parsedImageId = int.tryParse(args['i'] ?? '');
    final imageId = parsedImageId != null && parsedImageId > 0
        ? parsedImageId
        : commandImageId;
    // Signature over the base64-decoded payload *before* inflation. The
    // MonkeyMux server computes the same hash over the base64-decoded
    // transmission bytes (which it stores compressed for o=z), so hashing
    // pre-inflate lets the server match without having to decompress, and keeps
    // the client/server skip protocol in agreement.
    final signature = terminalGraphicsSourceSignature(data);

    // Dedup: if this id is already decoded from identical bytes, reuse it and
    // skip the expensive decode. A window switch replays the active window's
    // cached images, so flipping back to a window re-sends images the client
    // still holds; decoding them again wastes engine threads, memory and raster
    // compositing. The signature guards against an app that updates an id with
    // new content (different bytes -> miss -> decode).
    if (imageId != null && manager.hasImageWithSignature(imageId, signature)) {
      manager.imageById(imageId); // keep retained and bump LRU access
      observer?.call(
        payloadBytes: payload.length,
        inflateMicros: inflateMicros,
        decodeMicros: 0,
        compressed: compressed,
        success: true,
        imageId: args['i'],
        action: args['a'],
        reused: true,
      );
      _commitGraphicsImageNumberReservation(
        manager,
        imageNumberReservation,
      );
      _placeStoredImageId(manager, imageId, anchor, args, generation);
      return;
    }

    // Defer decoding of images that are not being placed right now (store-only
    // `a=t`, or a virtual `a=T,U=1` placeholder backing). A MonkeyMux window
    // switch replays every retained image up front, but the foreground app only
    // re-displays the few currently on screen, so decoding them all eagerly
    // burns CPU, memory and raster bandwidth on images the user never sees.
    // Keep the encoded payload and decode on first paint reference instead.
    // Compressed (`o=z`) and immediately-placed (`a=T`) images keep the eager
    // path: the former to avoid deferring the inflate/signature handling, the
    // latter because they must appear at the anchored cell straight away.
    if (anchor == null && imageId != null && !compressed) {
      if (imageNumberReservation != null ||
          !manager.hasPendingWithSignature(imageId, signature)) {
        final sourceDimensions = _graphicsPayloadDimensions(args, payload);
        manager.storePendingImage(
          imageId,
          payload: payload,
          format: format,
          width: width,
          height: height,
          sourceWidth: sourceDimensions?.width ?? 0,
          sourceHeight: sourceDimensions?.height ?? 0,
          sourceSignature: signature,
          imageNumber: imageNumberReservation?.number,
          mappedImageId: imageNumberReservation?.imageId,
          previousImageId: imageNumberReservation?.previousImageId,
        );
      }
      if (!manager.hasPendingImage(imageId)) {
        _rollbackGraphicsImageNumberReservation(
          manager,
          imageNumberReservation,
        );
        _respondToGraphicsFailure(
          args,
          'ENOSPC: pending image memory limit exceeded',
        );
        return;
      }
      _placeStoredImageId(manager, imageId, null, args, generation);
      notifyListeners();
      return;
    }

    final decodeStopwatch = observer == null ? null : (Stopwatch()..start());
    await terminalGraphicsDecodeGate.acquire();
    final decoded = await () async {
      try {
        return await decodeTerminalImageSequence(
          payload,
          format: format,
          width: width,
          height: height,
        );
      } finally {
        terminalGraphicsDecodeGate.release();
      }
    }();
    observer?.call(
      payloadBytes: payload.length,
      inflateMicros: inflateMicros,
      decodeMicros: decodeStopwatch?.elapsedMicroseconds ?? 0,
      compressed: compressed,
      success: decoded != null,
      imageId: args['i'],
      action: args['a'],
      reused: false,
    );

    // Skip placing if the decode failed, the anchored cell is gone, or the
    // screen was cleared while we were decoding (e.g. a MonkeyMux replay clear
    // racing this decode — placing now would leave a duplicate/stale image).
    if (decoded == null) {
      _rollbackGraphicsImageNumberReservation(
        manager,
        imageNumberReservation,
      );
      anchor?.dispose();
      return;
    }

    final storedImageId = imageId == null
        ? manager.storeDecodedImage(decoded, sourceSignature: signature)
        : manager.storeDecodedImageWithId(
            imageId,
            decoded,
            sourceSignature: signature,
          );
    if (storedImageId <= 0) {
      _rollbackGraphicsImageNumberReservation(
        manager,
        imageNumberReservation,
      );
      anchor?.dispose();
      _respondToGraphicsFailure(
        args,
        'ENOSPC: image memory limit exceeded',
      );
      return;
    }
    _commitGraphicsImageNumberReservation(
      manager,
      imageNumberReservation,
    );
    _placeStoredImageId(manager, storedImageId, anchor, args, generation);
  }

  void _rollbackGraphicsImageNumberReservation(
    GraphicsManager manager,
    _GraphicsImageNumberReservation? reservation,
  ) {
    if (reservation == null) {
      return;
    }
    manager.rollbackImageIdReservation(
      reservation.number,
      reservation.imageId,
      reservation.previousImageId,
    );
  }

  void _commitGraphicsImageNumberReservation(
    GraphicsManager manager,
    _GraphicsImageNumberReservation? reservation,
  ) {
    if (reservation == null) {
      return;
    }
    manager.commitImageIdReservation(
      reservation.number,
      reservation.imageId,
    );
  }

  /// Registers the image number, virtual placement and cell placement for an
  /// already-stored [storedImageId]. Shared by the fresh-decode and the
  /// dedup-reuse paths so both honor the same Kitty display keys and the
  /// decode-race anchor/generation check.
  void _placeStoredImageId(
    GraphicsManager manager,
    int storedImageId,
    CellAnchor? anchor,
    Map<String, String> args,
    int? generation,
  ) {
    // Associate a client image number (`I=`) with the stored id and answer the
    // handshake so the client learns the id it can address later.
    final imageNumber = int.tryParse(args['I'] ?? '');
    if (imageNumber != null && imageNumber > 0) {
      final explicitImageId = int.tryParse(args['i'] ?? '');
      if (explicitImageId == null || explicitImageId <= 0) {
        manager.registerImageNumber(imageNumber, storedImageId);
      }
      if (!_graphicsResponseSuppressed(args, success: true)) {
        onOutput?.call('\x1b_GI=$imageNumber,i=$storedImageId;OK\x1b\\');
      }
    }
    if (args['U'] == '1') {
      manager.setVirtualPlacement(
        storedImageId,
        cols: int.tryParse(args['c'] ?? '') ?? 0,
        rows: int.tryParse(args['r'] ?? '') ?? 0,
      );
    }
    if (anchor != null) {
      if (!anchor.attached || manager.generation != generation) {
        anchor.dispose();
        // The screen was cleared or the anchor cell evicted while this image
        // decoded, so it will never get a placement. Reclaim it now unless it is
        // retained for Unicode-placeholder reuse, rather than leaving it in the
        // cache until the next erase or memory-pressure eviction.
        manager.pruneUnreferencedImages();
        return;
      }
      _placeImageWithDisplayArgs(manager, storedImageId, anchor, args);
    }
    notifyListeners();
  }

  /// Creates a placement from the display-related Kitty graphics keys: cell span
  /// (`c`/`r`), z-index (`z`), source crop (`x`/`y`/`w`/`h`) and in-cell pixel
  /// offset (`X`/`Y`).
  void _placeImageWithDisplayArgs(
    GraphicsManager manager,
    int imageId,
    CellAnchor anchor,
    Map<String, String> args,
  ) {
    manager.placeImage(
      imageId,
      anchor,
      cols: int.tryParse(args['c'] ?? '') ?? 0,
      rows: int.tryParse(args['r'] ?? '') ?? 0,
      z: int.tryParse(args['z'] ?? '') ?? 0,
      clientPlacementId: int.tryParse(args['p'] ?? '') ?? 0,
      srcX: int.tryParse(args['x'] ?? '') ?? 0,
      srcY: int.tryParse(args['y'] ?? '') ?? 0,
      srcWidth: int.tryParse(args['w'] ?? '') ?? 0,
      srcHeight: int.tryParse(args['h'] ?? '') ?? 0,
      xOffset: int.tryParse(args['X'] ?? '') ?? 0,
      yOffset: int.tryParse(args['Y'] ?? '') ?? 0,
    );
  }

  void _placeStoredGraphics(Map<String, String> args) {
    final manager = _buffer.graphics;
    var imageId = int.tryParse(args['i'] ?? '');
    // a=p may address the image by number (`I=`) instead of id.
    if (imageId == null) {
      final number = int.tryParse(args['I'] ?? '');
      if (number != null) {
        imageId = manager.imageIdForNumber(number);
      }
    }
    if (imageId == null) {
      return;
    }
    final image = manager.imageById(imageId);
    if (image == null && !manager.hasPendingImage(imageId)) {
      return;
    }
    final anchor = _buffer.currentLine.createAnchor(_buffer.cursorX);
    _placeImageWithDisplayArgs(manager, imageId, anchor, args);
    // Respect the no-cursor-movement policy (C=1); otherwise drop below the
    // image so subsequent output does not overlap it.
    final keepCursor = args['C'] == '1';
    final dimensions = image == null
        ? manager.pendingImageDimensions(imageId)
        : (width: image.sourceWidth, height: image.sourceHeight);
    final rows = dimensions == null
        ? (int.tryParse(args['r'] ?? '') ?? 0)
        : _graphicsDisplayRowsForDimensions(
            args,
            manager,
            dimensions,
            maxRows: _buffer.viewHeight,
          );
    if (!keepCursor) {
      _advanceGraphicsCursor(_buffer, rows);
    }
    notifyListeners();
  }

  /// Handles a Kitty graphics delete command (`a=d`). Without this the image a
  /// client placed and then explicitly asked to remove (e.g. Copilot CLI closing
  /// its full-screen image viewer) would linger as a stale overlay behind later
  /// output.
  void _deleteGraphics(
    Map<String, String> args,
    _GraphicsDeletePosition position, {
    int? commandImageId,
  }) {
    final buffer = position.buffer;
    // Kitty `x`/`y` are 1-based cell coordinates in the cursor's (viewport)
    // space; translate the row into the absolute buffer coordinates placements
    // are tracked in.
    final x = int.tryParse(args['x'] ?? '');
    final y = int.tryParse(args['y'] ?? '');

    var what = args['d'] ?? 'a';
    var imageId = commandImageId ?? int.tryParse(args['i'] ?? '');
    // Delete-by-number (d=n/N): resolve the image number to its id and delete by
    // id, preserving the lower/upper free-data semantics.
    if (what == 'n' || what == 'N') {
      final number = int.tryParse(args['I'] ?? '');
      imageId ??=
          number == null ? null : buffer.graphics.imageIdForNumber(number);
      if (imageId == null) {
        return;
      }
      what = what == 'n' ? 'i' : 'I';
    }
    if ((what == 'i' || what == 'I') && imageId == null) {
      return;
    }

    final removed = buffer.graphics.deletePlacements(
      what: what,
      imageId: imageId,
      placementId: int.tryParse(args['p'] ?? ''),
      cursorCol: position.cursorCol,
      cursorRow: position.cursorRow,
      cellCol: x == null ? null : x - 1,
      cellRow: y == null ? null : (y - 1) + position.scrollBack,
    );
    if (removed) {
      notifyListeners();
    }
  }

  void _setVirtualGraphicsPlacement(Map<String, String> args) {
    var imageId = int.tryParse(args['i'] ?? '');
    if (imageId == null) {
      final imageNumber = int.tryParse(args['I'] ?? '');
      if (imageNumber != null) {
        imageId = _buffer.graphics.imageIdForNumber(imageNumber);
      }
    }
    if (imageId == null) {
      return;
    }
    _buffer.graphics.setVirtualPlacement(
      imageId,
      cols: int.tryParse(args['c'] ?? '') ?? 0,
      rows: int.tryParse(args['r'] ?? '') ?? 0,
    );
  }

  void _respondToGraphicsQuery(Map<String, String> args, Uint8List data) {
    final error = _graphicsQueryError(args, data);
    final success = error == null;
    if (_graphicsResponseSuppressed(args, success: success)) {
      return;
    }

    final control = <String>[];
    if (args['i'] case final imageId? when imageId.isNotEmpty) {
      control.add('i=$imageId');
    }
    if (args['I'] case final imageNumber? when imageNumber.isNotEmpty) {
      control.add('I=$imageNumber');
    }
    onOutput?.call(
      '\x1b_G${control.join(',')};${success ? 'OK' : error}\x1b\\',
    );
  }

  String? _graphicsQueryError(Map<String, String> args, Uint8List data) {
    if ((args['t'] ?? 'd') != 'd') {
      return 'EINVAL: unsupported transmission medium';
    }
    final compression = args['o'];
    if (compression != null && compression != 'z') {
      return 'EINVAL: unsupported compression';
    }
    if (data.isEmpty) {
      return 'EINVAL: missing image data';
    }

    var payload = data;
    if (compression == 'z') {
      final inflated = inflateZlibData(data);
      if (inflated == null) {
        return 'EINVAL: invalid compressed data';
      }
      payload = inflated;
    }

    final format = _graphicsFormat(args);
    if (format == 24 || format == 32) {
      final width = int.tryParse(args['s'] ?? '') ?? 0;
      final height = int.tryParse(args['v'] ?? '') ?? 0;
      if (width <= 0 || height <= 0) {
        return 'EINVAL: missing image dimensions';
      }
      final bytesPerPixel = format == 24 ? 3 : 4;
      if (payload.length < width * height * bytesPerPixel) {
        return 'EINVAL: invalid image data';
      }
      return null;
    }

    if (format == 100) {
      return _looksLikePng(payload) ? null : 'EINVAL: invalid PNG data';
    }

    return 'EINVAL: unsupported image format';
  }

  int _graphicsFormat(Map<String, String> args) =>
      int.tryParse(args['f'] ?? '') ?? 32;

  void _advanceGraphicsCursor(Buffer buffer, int rows) {
    // Once the requested span leaves the viewport Kitty declares the exact
    // cursor position undefined. A viewport's worth fully clears the visible
    // placement while bounding work for untrusted r= values.
    final boundedRows = min(max(0, rows), buffer.viewHeight);
    for (var i = 0; i < boundedRows; i++) {
      buffer.index();
    }
  }

  int _graphicsDisplayRows(
    Map<String, String> args,
    Uint8List data,
    GraphicsManager manager, {
    _GraphicsPreinflation? preinflation,
    required int maxRows,
  }) {
    if (maxRows <= 0) {
      return 0;
    }
    final explicitRows = int.tryParse(args['r'] ?? '') ?? 0;
    if (explicitRows > 0) {
      return explicitRows;
    }
    final columns = int.tryParse(args['c'] ?? '') ?? 0;
    if (columns <= 0) {
      return 0;
    }
    final dimensions = preinflation == null
        ? _graphicsPayloadDimensions(args, data)
        : preinflation.payload == null
            ? null
            : _graphicsPayloadDimensions(
                args,
                preinflation.payload!,
                payloadIsInflated: true,
              );
    if (dimensions == null) {
      return 1;
    }
    return _graphicsDisplayRowsForDimensions(
      args,
      manager,
      dimensions,
      maxRows: maxRows,
    );
  }

  bool _graphicsDisplayNeedsPayloadDimensions(Map<String, String> args) {
    final explicitRows = int.tryParse(args['r'] ?? '') ?? 0;
    final columns = int.tryParse(args['c'] ?? '') ?? 0;
    final rawWidth = int.tryParse(args['s'] ?? '') ?? 0;
    final rawHeight = int.tryParse(args['v'] ?? '') ?? 0;
    return explicitRows <= 0 &&
        columns > 0 &&
        (rawWidth <= 0 || rawHeight <= 0);
  }

  int _graphicsDisplayRowsForDimensions(
    Map<String, String> args,
    GraphicsManager manager,
    ({int width, int height}) dimensions, {
    required int maxRows,
  }) {
    final explicitRows = int.tryParse(args['r'] ?? '') ?? 0;
    if (explicitRows > 0) {
      return explicitRows;
    }
    final columns = int.tryParse(args['c'] ?? '') ?? 0;
    if (columns <= 0) {
      return 0;
    }
    final x = (int.tryParse(args['x'] ?? '') ?? 0).clamp(
      0,
      dimensions.width,
    );
    final y = (int.tryParse(args['y'] ?? '') ?? 0).clamp(
      0,
      dimensions.height,
    );
    final availableWidth = dimensions.width - x;
    final availableHeight = dimensions.height - y;
    final requestedWidth = int.tryParse(args['w'] ?? '') ?? 0;
    final requestedHeight = int.tryParse(args['h'] ?? '') ?? 0;
    final width = requestedWidth > 0
        ? min(requestedWidth, availableWidth)
        : availableWidth;
    final height = requestedHeight > 0
        ? min(requestedHeight, availableHeight)
        : availableHeight;
    if (width <= 0 || height <= 0) {
      return 1;
    }
    final rowsPerColumn = height / width * manager.cellPixelAspectRatio;
    if (!rowsPerColumn.isFinite || rowsPerColumn <= 0) {
      return 1;
    }
    if (columns >= maxRows / rowsPerColumn) {
      return maxRows;
    }
    return min(maxRows, max(1, (rowsPerColumn * columns).ceil()));
  }

  ({int width, int height})? _graphicsPayloadDimensions(
    Map<String, String> args,
    Uint8List data, {
    bool payloadIsInflated = false,
  }) {
    final rawWidth = int.tryParse(args['s'] ?? '') ?? 0;
    final rawHeight = int.tryParse(args['v'] ?? '') ?? 0;
    if (rawWidth > 0 && rawHeight > 0) {
      return (width: rawWidth, height: rawHeight);
    }

    var payload = data;
    if (!payloadIsInflated && args['o'] == 'z') {
      final inflated = inflateZlibData(data);
      if (inflated == null) {
        return null;
      }
      payload = inflated;
    }
    if (_looksLikePng(payload) && payload.length >= 24) {
      final width = _readGraphicsUint32(payload, 16);
      final height = _readGraphicsUint32(payload, 20);
      return width > 0 && height > 0 ? (width: width, height: height) : null;
    }
    if (payload.length >= 10 &&
        payload[0] == 0x47 &&
        payload[1] == 0x49 &&
        payload[2] == 0x46) {
      final width = payload[6] | (payload[7] << 8);
      final height = payload[8] | (payload[9] << 8);
      return width > 0 && height > 0 ? (width: width, height: height) : null;
    }
    final jpegDimensions = _graphicsJpegDimensions(payload);
    if (jpegDimensions != null) {
      return jpegDimensions;
    }
    return null;
  }

  ({int width, int height})? _graphicsJpegDimensions(Uint8List data) {
    if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) {
      return null;
    }
    var offset = 2;
    while (offset + 3 < data.length) {
      while (offset < data.length && data[offset] != 0xFF) {
        offset += 1;
      }
      while (offset < data.length && data[offset] == 0xFF) {
        offset += 1;
      }
      if (offset >= data.length) {
        return null;
      }
      final marker = data[offset++];
      if (marker == 0xD9 || marker == 0xDA) {
        return null;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        continue;
      }
      if (offset + 1 >= data.length) {
        return null;
      }
      final segmentLength = (data[offset] << 8) | data[offset + 1];
      if (segmentLength < 2 || offset + segmentLength > data.length) {
        return null;
      }
      if (_isGraphicsJpegStartOfFrame(marker) && segmentLength >= 7) {
        final height = (data[offset + 3] << 8) | data[offset + 4];
        final width = (data[offset + 5] << 8) | data[offset + 6];
        return width > 0 && height > 0 ? (width: width, height: height) : null;
      }
      offset += segmentLength;
    }
    return null;
  }

  bool _isGraphicsJpegStartOfFrame(int marker) =>
      marker >= 0xC0 &&
      marker <= 0xCF &&
      marker != 0xC4 &&
      marker != 0xC8 &&
      marker != 0xCC;

  int _readGraphicsUint32(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  bool _graphicsResponseSuppressed(
    Map<String, String> args, {
    required bool success,
  }) {
    final quiet = args['q'];
    return success ? quiet == '1' || quiet == '2' : quiet == '2';
  }

  bool _looksLikePng(Uint8List data) =>
      data.length >= 8 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47 &&
      data[4] == 0x0D &&
      data[5] == 0x0A &&
      data[6] == 0x1A &&
      data[7] == 0x0A;

  int? _kittyPlaceholderDiacriticValue(int char) =>
      _kittyPlaceholderDiacriticIndex[char];
}

/// Unicode code point used by Kitty graphics placeholder mode.
const kittyGraphicsPlaceholderCodePoint = 0x10EEEE;

/// Reverse lookup from a placeholder diacritic code point to its row/column
/// index. Placeholder-protocol clients (e.g. Copilot CLI) re-emit their full
/// placeholder grid on essentially every frame, so this O(1) map replaces a
/// linear scan of [_kittyPlaceholderDiacritics] for each placeholder cell.
final Map<int, int> _kittyPlaceholderDiacriticIndex = {
  for (var i = 0; i < _kittyPlaceholderDiacritics.length; i++)
    _kittyPlaceholderDiacritics[i]: i,
};

const _kittyPlaceholderDiacritics = <int>[
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
  0x0346,
  0x034A,
  0x034B,
  0x034C,
  0x0350,
  0x0351,
  0x0352,
  0x0357,
  0x035B,
  0x0363,
  0x0364,
  0x0365,
  0x0366,
  0x0367,
  0x0368,
  0x0369,
  0x036A,
  0x036B,
  0x036C,
  0x036D,
  0x036E,
  0x036F,
  0x0483,
  0x0484,
  0x0485,
  0x0486,
  0x0487,
  0x0592,
  0x0593,
  0x0594,
  0x0595,
  0x0597,
  0x0598,
  0x0599,
  0x059C,
  0x059D,
  0x059E,
  0x059F,
  0x05A0,
  0x05A1,
  0x05A8,
  0x05A9,
  0x05AB,
  0x05AC,
  0x05AF,
  0x05C4,
  0x0610,
  0x0611,
  0x0612,
  0x0613,
  0x0614,
  0x0615,
  0x0616,
  0x0617,
  0x0657,
  0x0658,
  0x0659,
  0x065A,
  0x065B,
  0x065D,
  0x065E,
  0x06D6,
  0x06D7,
  0x06D8,
  0x06D9,
  0x06DA,
  0x06DB,
  0x06DC,
  0x06DF,
  0x06E0,
  0x06E1,
  0x06E2,
  0x06E4,
  0x06E7,
  0x06E8,
  0x06EB,
  0x06EC,
  0x0730,
  0x0732,
  0x0733,
  0x0735,
  0x0736,
  0x073A,
  0x073D,
  0x073F,
  0x0740,
  0x0741,
  0x0743,
  0x0745,
  0x0747,
  0x0749,
  0x074A,
  0x07EB,
  0x07EC,
  0x07ED,
  0x07EE,
  0x07EF,
  0x07F0,
  0x07F1,
  0x07F3,
  0x0816,
  0x0817,
  0x0818,
  0x0819,
  0x081B,
  0x081C,
  0x081D,
  0x081E,
  0x081F,
  0x0820,
  0x0821,
  0x0822,
  0x0823,
  0x0825,
  0x0826,
  0x0827,
  0x0829,
  0x082A,
  0x082B,
  0x082C,
  0x082D,
  0x0951,
  0x0953,
  0x0954,
  0x0F82,
  0x0F83,
  0x0F86,
  0x0F87,
  0x135D,
  0x135E,
  0x135F,
  0x17DD,
  0x193A,
  0x1A17,
  0x1A75,
  0x1A76,
  0x1A77,
  0x1A78,
  0x1A79,
  0x1A7A,
  0x1A7B,
  0x1A7C,
  0x1B6B,
  0x1B6D,
  0x1B6E,
  0x1B6F,
  0x1B70,
  0x1B71,
  0x1B72,
  0x1B73,
  0x1CD0,
  0x1CD1,
  0x1CD2,
  0x1CDA,
  0x1CDB,
  0x1CE0,
  0x1DC0,
  0x1DC1,
  0x1DC3,
  0x1DC4,
  0x1DC5,
  0x1DC6,
  0x1DC7,
  0x1DC8,
  0x1DC9,
  0x1DCB,
  0x1DCC,
  0x1DD1,
  0x1DD2,
  0x1DD3,
  0x1DD4,
  0x1DD5,
  0x1DD6,
  0x1DD7,
  0x1DD8,
  0x1DD9,
  0x1DDA,
  0x1DDB,
  0x1DDC,
  0x1DDD,
  0x1DDE,
  0x1DDF,
  0x1DE0,
  0x1DE1,
  0x1DE2,
  0x1DE3,
  0x1DE4,
  0x1DE5,
  0x1DE6,
  0x1DFE,
  0x20D0,
  0x20D1,
  0x20D4,
  0x20D5,
  0x20D6,
  0x20D7,
  0x20DB,
  0x20DC,
  0x20E1,
  0x20E7,
  0x20E9,
  0x20F0,
  0x2CEF,
  0x2CF0,
  0x2CF1,
  0x2DE0,
  0x2DE1,
  0x2DE2,
  0x2DE3,
  0x2DE4,
  0x2DE5,
  0x2DE6,
  0x2DE7,
  0x2DE8,
  0x2DE9,
  0x2DEA,
  0x2DEB,
  0x2DEC,
  0x2DED,
  0x2DEE,
  0x2DEF,
  0x2DF0,
  0x2DF1,
  0x2DF2,
  0x2DF3,
  0x2DF4,
  0x2DF5,
  0x2DF6,
  0x2DF7,
  0x2DF8,
  0x2DF9,
  0x2DFA,
  0x2DFB,
  0x2DFC,
  0x2DFD,
  0x2DFE,
  0x2DFF,
  0xA66F,
  0xA67C,
  0xA67D,
  0xA6F0,
  0xA6F1,
  0xA8E0,
  0xA8E1,
  0xA8E2,
  0xA8E3,
  0xA8E4,
  0xA8E5,
];

class _PendingKittyPlaceholder {
  _PendingKittyPlaceholder({
    required this.foreground,
    required this.underlineColor,
    required this.anchor,
    required _PendingKittyPlaceholder? previous,
  }) {
    final sameImage = previous != null &&
        previous.foreground == foreground &&
        previous.underlineColor == underlineColor;
    row = sameImage ? previous.row : 0;
    col = sameImage ? previous.col + 1 : 0;
    highByte = sameImage ? previous.highByte : 0;
  }

  final int foreground;
  final int underlineColor;
  final CellAnchor anchor;
  late int row;
  late int col;
  late int highByte;
  var _diacriticCount = 0;
  TerminalImagePlaceholder? _placeholder;

  int get imageIdBitWidth =>
      (foreground & CellColor.typeMask) == CellColor.rgb ? 24 : 8;

  int get imageId {
    final lowBits = foreground & CellColor.valueMask;
    final low = imageIdBitWidth == 8 ? lowBits & 0xFF : lowBits;
    return low | (highByte << 24);
  }

  void bind(TerminalImagePlaceholder placeholder) {
    _placeholder = placeholder;
  }

  void addDiacritic(int value) {
    switch (_diacriticCount) {
      case 0:
        if (value != row) {
          col = 0;
        }
        row = value;
        break;
      case 1:
        col = value;
        break;
      case 2:
        highByte = value;
        break;
    }
    _diacriticCount += 1;
    final placeholder = _placeholder;
    if (placeholder != null) {
      placeholder.updateMetadata(
        imageId: imageId,
        imageIdBitWidth: imageIdBitWidth,
        row: row,
        col: col,
      );
    }
  }
}
