import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/color.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/byte_consumer.dart';
import 'package:xterm/src/utils/char_code.dart';
import 'package:xterm/src/utils/lookup_table.dart';

/// [EscapeParser] translates control characters and escape sequences into
/// function calls that the terminal can handle.
///
/// Design goals:
///  * Zero object allocation during processing.
///  * No internal state. Same input will always produce same output.
class EscapeParser {
  final EscapeHandler handler;

  EscapeParser(this.handler);

  final _queue = ByteConsumer();

  /// Start of sequence or character being processed. Useful for debugging.
  var tokenBegin = 0;

  /// End of sequence or character being processed. Useful for debugging.
  int get tokenEnd => _queue.totalConsumed;

  void write(String chunk) {
    _queue.unrefConsumedBlocks();
    _queue.add(chunk);
    _process();
  }

  void _process() {
    while (_queue.isNotEmpty) {
      tokenBegin = _queue.totalConsumed;
      final char = _queue.consume();

      if (char == Ascii.ESC) {
        final processed = _processEscape();
        if (!processed) {
          _queue.rollback(tokenEnd - tokenBegin);
          return;
        }
      } else {
        _processChar(char);
      }
    }
  }

  void _processChar(int char) {
    if (char > _sbcHandlers.maxIndex) {
      handler.writeChar(char);
      return;
    }

    final sbcHandler = _sbcHandlers[char];
    if (sbcHandler == null) {
      handler.unkownEscape(char);
      return;
    }

    sbcHandler();
  }

  /// Processes a sequence of characters that starts with an escape character.
  /// Returns [true] if the sequence was processed, [false] if it was not.
  bool _processEscape() {
    if (_queue.isEmpty) return false;

    final escapeChar = _queue.consume();

    // ECMA-48/VT500: ESC re-enters the escape state from anywhere, so `ESC ESC`
    // abandons the first introducer and starts a fresh sequence rather than
    // consuming the second ESC as this sequence's final byte. Roll it back so
    // the main loop dispatches it; without this a stray or duplicated ESC makes
    // the whole following sequence (e.g. `ESC ESC ] 8 ; id=...`) render as
    // literal text.
    if (escapeChar == Ascii.ESC) {
      _queue.rollback();
      return true;
    }

    final escapeHandler = _escHandlers[escapeChar];

    if (escapeHandler == null) {
      handler.unkownEscape(escapeChar);
      return true;
    }

    return escapeHandler();
  }

  /// Consumes the terminator of a string sequence (OSC/DCS/APC/SOS/PM) once its
  /// leading ESC has already been consumed.
  ///
  /// Returns [_SeqParse.complete] for a full ST (`ESC \`), [_SeqParse.incomplete]
  /// when the byte after ESC has not arrived yet, and [_SeqParse.aborted] for
  /// any other byte — in which case the ESC is rolled back so it can start a new
  /// sequence, as ECMA-48 requires.
  _SeqParse _consumeStringTerminator() {
    if (_queue.isEmpty) return _SeqParse.incomplete;
    if (_queue.peek() == Ascii.backslash) {
      _queue.consume();
      return _SeqParse.complete;
    }
    _queue.rollback();
    return _SeqParse.aborted;
  }

  late final _sbcHandlers = FastLookupTable<_SbcHandler>({
    0x07: handler.bell,
    0x08: handler.backspaceReturn,
    0x09: handler.tab,
    0x0a: handler.lineFeed,
    0x0b: handler.lineFeed,
    0x0c: handler.lineFeed,
    0x0d: handler.carriageReturn,
    0x0e: handler.shiftOut,
    0x0f: handler.shiftIn,
  });

  late final _escHandlers = FastLookupTable<_EscHandler>({
    '['.charCode: _escHandleCSI,
    ']'.charCode: _escHandleOSC,
    '7'.charCode: _escHandleSaveCursor,
    '8'.charCode: _escHandleRestoreCursor,
    'D'.charCode: _escHandleIndex,
    'E'.charCode: _escHandleNextLine,
    'H'.charCode: _escHandleTabSet,
    'M'.charCode: _escHandleReverseIndex,
    'P'.charCode: _escHandleDCS, // DCS - XTGETTCAP (others skipped to ST)
    // 'c'.charCode: _unsupportedHandler,
    // '#'.charCode: _unsupportedHandler,
    '('.charCode: _escHandleDesignateCharset0, //  SCS - G0
    ')'.charCode: _escHandleDesignateCharset1, //  SCS - G1
    '_'.charCode: _escHandleAPC, // APC - Kitty graphics protocol
    '*'.charCode: _escHandleDesignateCharset2, //  SCS - G2 (vt220)
    '+'.charCode: _escHandleDesignateCharset3, //  SCS - G3 (vt220)
    '>'.charCode: _escHandleResetAppKeypadMode, // Normal Keypad (DECKPNM)
    '='.charCode: _escHandleSetAppKeypadMode, // Application Keypad (DECKPAM)
  });

  /// `ESC 7` Save Cursor (DECSC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a7/
  bool _escHandleSaveCursor() {
    handler.saveCursor();
    return true;
  }

  /// `ESC 8` Restore Cursor (DECRC)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_a8/
  bool _escHandleRestoreCursor() {
    handler.restoreCursor();
    return true;
  }

  /// `ESC D` Index (IND)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cd/
  bool _escHandleIndex() {
    handler.index();
    return true;
  }

  /// `ESC E` Next Line (NEL)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ce/
  bool _escHandleNextLine() {
    handler.nextLine();
    return true;
  }

  /// `ESC H` Horizontal Tab Set (HTS)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_ch/
  bool _escHandleTabSet() {
    handler.setTapStop();
    return true;
  }

  /// `ESC M` Reverse Index (RI)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  bool _escHandleReverseIndex() {
    handler.reverseIndex();
    return true;
  }

  /// `ESC ( / ) / * / +  <name>` Designate character set (SCS).
  ///
  /// An ESC in the name slot re-enters the escape state instead of being taken
  /// as the charset name, so a stray or duplicated ESC cannot swallow the
  /// introducer of the sequence that follows.
  bool _escHandleDesignateCharset(int g) {
    if (_queue.isEmpty) return false;
    final name = _queue.consume();
    if (name == Ascii.ESC) {
      _queue.rollback();
      return true;
    }
    handler.designateCharset(g, name);
    return true;
  }

  bool _escHandleDesignateCharset0() => _escHandleDesignateCharset(0);

  bool _escHandleDesignateCharset1() => _escHandleDesignateCharset(1);

  /// `ESC * <name>` Designate G2 Character Set (SCS)
  bool _escHandleDesignateCharset2() => _escHandleDesignateCharset(2);

  /// `ESC + <name>` Designate G3 Character Set (SCS)
  bool _escHandleDesignateCharset3() => _escHandleDesignateCharset(3);

  /// `ESC =` Set Application Keypad Mode (DECKPAM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3d_equals/
  bool _escHandleSetAppKeypadMode() {
    handler.setAppKeypadMode(true);
    return true;
  }

  /// `ESC >` Reset Application Keypad Mode (DECKPNM)
  ///
  /// https://terminalguide.namepad.de/seq/a_esc_x3c_greater_than/
  bool _escHandleResetAppKeypadMode() {
    handler.setAppKeypadMode(false);
    return true;
  }

  bool _escHandleCSI() {
    final result = _consumeCsi();
    if (result == _SeqParse.incomplete) return false;
    if (result == _SeqParse.aborted) return true;

    if (_csi.finalByte == Ascii.u && _handleKittyKeyboardProtocol()) {
      return true;
    }

    final csiHandler = _csiHandlers[_csi.finalByte];

    if (csiHandler == null) {
      handler.unknownCSI(_csi.finalByte);
    } else {
      csiHandler();
    }

    return true;
  }

  bool _handleKittyKeyboardProtocol() {
    final flags = _csi.params.isEmpty ? 0 : _csi.params[0];
    final mode = _csi.params.length > 1 ? _csi.params[1] : 1;
    switch (_csi.prefix) {
      case Ascii.equal:
        handler.setKittyKeyboardFlags(flags, mode);
        return true;
      case Ascii.greaterThan:
        handler.pushKittyKeyboardFlags(flags);
        return true;
      case Ascii.lessThan:
        handler.popKittyKeyboardFlags(flags == 0 ? 1 : flags);
        return true;
      case Ascii.questionMark:
        handler.sendKittyKeyboardFlags();
        return true;
      default:
        return false;
    }
  }

  /// The last parsed [_Csi]. This is a mutable singletion by design to reduce
  /// object allocations.
  final _csi = _Csi(finalByte: 0, params: []);

  /// Parse a CSI from the head of the queue. Returns [_SeqParse.incomplete] if
  /// the CSI isn't complete and [_SeqParse.aborted] if ESC, CAN or SUB cut it short.
  /// After a CSI is successfully parsed, [_csi] is updated.
  _SeqParse _consumeCsi() {
    if (_queue.isEmpty) {
      return _SeqParse.incomplete;
    }

    _csi.params.clear();
    _csi.subParams.clear();

    // test whether the csi is a `CSI ? Ps ...` or `CSI Ps ...`
    final prefix = _queue.peek();
    if (prefix >= Ascii.lessThan && prefix <= Ascii.questionMark) {
      _csi.prefix = prefix;
      _queue.consume();
    } else {
      _csi.prefix = null;
    }

    _csi.intermediate = null;

    var param = 0;
    var hasParam = false;
    var pendingEmptyParam = false;
    // Sub-parameters of the parameter currently being parsed, populated once a
    // `:` is seen. `null` while the current parameter has no sub-parameters.
    List<int>? sub;
    // Cap the number of (sub-)parameters to avoid unbounded memory growth from
    // malformed sequences such as `CSI 1;1;1;...m`, matching kterm.dart.
    const maxParams = 256;

    void commitParam({bool emptyAsZero = false}) {
      if (sub != null) {
        if (sub!.length < maxParams) sub!.add(param);
      } else if ((hasParam || emptyAsZero) && _csi.params.length < maxParams) {
        _csi.params.add(param);
        _csi.subParams.add(const []);
      }
      param = 0;
      hasParam = false;
      pendingEmptyParam = false;
      sub = null;
    }

    while (true) {
      // The sequence isn't completed, just ignore it.
      if (_queue.isEmpty) {
        return _SeqParse.incomplete;
      }

      final char = _queue.consume();

      // ESC aborts the CSI and starts a new sequence. Without this the ESC
      // falls into the intermediate-byte range below and is silently absorbed,
      // letting a truncated CSI swallow the sequence that follows it.
      if (char == Ascii.ESC) {
        _queue.rollback();
        return _SeqParse.aborted;
      }

      // CAN and SUB cancel the sequence and return to ground state. Unlike
      // ESC, the cancellation byte is consumed rather than reprocessed.
      if (char == Ascii.CAN || char == Ascii.SUB) {
        return _SeqParse.aborted;
      }

      if (char == Ascii.semicolon) {
        commitParam(emptyAsZero: true);
        pendingEmptyParam = true;
        continue;
      }

      if (char == Ascii.colon) {
        // The first `:` promotes the accumulated value to the primary parameter
        // and begins collecting sub-parameters; subsequent `:` push the next
        // sub-parameter value.
        if (sub == null) {
          if (_csi.params.length < maxParams) {
            sub = <int>[];
            _csi.params.add(param);
            _csi.subParams.add(sub!);
          }
        } else if (sub!.length < maxParams) {
          sub!.add(param);
        }
        param = 0;
        hasParam = true;
        pendingEmptyParam = false;
        continue;
      }

      if (char >= Ascii.num0 && char <= Ascii.num9) {
        hasParam = true;
        pendingEmptyParam = false;
        // Saturate before integer overflow can turn a count or position negative.
        param = (param * 10 + char - Ascii.num0).clamp(0, 0x7fffffff);
        continue;
      }

      if (char > Ascii.NULL && char < Ascii.num0) {
        // Intermediate byte (0x20-0x2F). Only the last one is retained; it
        // disambiguates finals such as `p` (DECRQM `$p` vs DECSTR `!p`).
        _csi.intermediate = char;
        continue;
      }

      if (char >= Ascii.atSign && char <= Ascii.tilde) {
        commitParam(emptyAsZero: pendingEmptyParam);

        _csi.finalByte = char;
        return _SeqParse.complete;
      }
    }
  }

  late final _csiHandlers = FastLookupTable<_CsiHandler>({
    // 'a'.codeUnitAt(0): _csiHandleCursorHorizontalRelative,
    'b'.codeUnitAt(0): _csiHandleRepeatPreviousCharacter,
    'c'.codeUnitAt(0): _csiHandleSendDeviceAttributes,
    'd'.codeUnitAt(0): _csiHandleLinePositionAbsolute,
    'f'.codeUnitAt(0): _csiHandleCursorPosition,
    'g'.codeUnitAt(0): _csiHandelClearTabStop,
    'h'.codeUnitAt(0): _csiHandleMode,
    'l'.codeUnitAt(0): _csiHandleMode,
    'm'.codeUnitAt(0): _csiHandleSgr,
    'n'.codeUnitAt(0): _csiHandleDeviceStatusReport,
    'q'.codeUnitAt(0): _csiHandleRequestTerminalVersion,
    'p'.codeUnitAt(0): _csiHandleRequestMode,
    'r'.codeUnitAt(0): _csiHandleSetMargins,
    't'.codeUnitAt(0): _csiWindowManipulation,
    'A'.codeUnitAt(0): _csiHandleCursorUp,
    'B'.codeUnitAt(0): _csiHandleCursorDown,
    'C'.codeUnitAt(0): _csiHandleCursorForward,
    'D'.codeUnitAt(0): _csiHandleCursorBackward,
    'E'.codeUnitAt(0): _csiHandleCursorNextLine,
    'F'.codeUnitAt(0): _csiHandleCursorPrecedingLine,
    'G'.codeUnitAt(0): _csiHandleCursorHorizontalAbsolute,
    'H'.codeUnitAt(0): _csiHandleCursorPosition,
    'J'.codeUnitAt(0): _csiHandleEraseDisplay,
    'K'.codeUnitAt(0): _csiHandleEraseLine,
    'L'.codeUnitAt(0): _csiHandleInsertLines,
    'M'.codeUnitAt(0): _csiHandleDeleteLines,
    'P'.codeUnitAt(0): _csiHandleDelete,
    'S'.codeUnitAt(0): _csiHandleScrollUp,
    'T'.codeUnitAt(0): _csiHandleScrollDown,
    'X'.codeUnitAt(0): _csiHandleEraseCharacters,
    '@'.codeUnitAt(0): _csiHandleInsertBlankCharacters,
  });

  /// `ESC [ Ps a` Cursor Horizontal Position Relative (HPR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sa/
  // void _csiHandleCursorHorizontalRelative() {
  //   if (_csi.params.isEmpty) {
  //     handler.cursorHorizontal(1);
  //   } else {
  //     handler.cursorHorizontal(_csi.params[0]);
  //   }
  // }

  /// `ESC [ Ps b` Repeat Previous Character (REP)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sb/
  void _csiHandleRepeatPreviousCharacter() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.repeatPreviousCharacter(amount);
  }

  /// `ESC [ Ps c` Device Attributes (DA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sc/
  void _csiHandleSendDeviceAttributes() {
    switch (_csi.prefix) {
      case Ascii.greaterThan:
        return handler.sendSecondaryDeviceAttributes();
      case Ascii.equal:
        return handler.sendTertiaryDeviceAttributes();
      default:
        handler.sendPrimaryDeviceAttributes();
    }
  }

  /// `ESC [ > q` Request Terminal Name and Version (XTVERSION)
  ///
  /// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  void _csiHandleRequestTerminalVersion() {
    // Only the `>` form is XTVERSION. Other `q` finals (DECSCUSR cursor style
    // with a space intermediate, DECSCA with a `"` intermediate) are not
    // handled here.
    if (_csi.prefix == Ascii.greaterThan) {
      handler.sendTerminalVersion();
    }
  }

  /// `ESC [ Ps $ p` Request ANSI Mode (DECRQM).
  ///
  /// Only the ANSI-mode form (no prefix) is answered here. The DEC-private form
  /// (`CSI ? Ps $ p`) is answered by the MonkeySSH app layer, which scans shell
  /// output and has the extra state it needs (notably DEC mode 2031 colour
  /// scheme updates); answering it here as well would send the program two
  /// replies. The `$` intermediate distinguishes DECRQM from the other `p`
  /// finals (`CSI ! p` DECSTR, `CSI Ps " p` DECSCL, `CSI > Ps p` XTSMPOINTER),
  /// which fall through to [EscapeHandler.unknownCSI].
  ///
  /// https://vt100.net/docs/vt510-rm/DECRQM.html
  void _csiHandleRequestMode() {
    if (_csi.intermediate != Ascii.dollarSign) {
      handler.unknownCSI(_csi.finalByte);
      return;
    }

    if (_csi.prefix == null) {
      final mode = _csi.params.isEmpty ? 0 : _csi.params[0];
      handler.sendModeReport(mode);
    } else if (_csi.prefix != Ascii.questionMark) {
      // `?` (DEC private) is consumed without a reply so the app layer can
      // answer it; any other prefix is an unrecognized `$ p` sequence.
      handler.unknownCSI(_csi.finalByte);
    }
  }

  /// `ESC [ Ps d` Cursor Vertical Position Absolute (VPA)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sd/
  void _csiHandleLinePositionAbsolute() {
    var y = 1;

    if (_csi.params.isNotEmpty) {
      y = _csi.params[0];
    }

    handler.setCursorY(y - 1);
  }

  /// `ESC [ Ps ; Ps f` Alias: Set Cursor Position
  ///
  /// https://terminalguide.namepad.de/seq/csi_sf/
  void _csiHandleCursorPosition() {
    final row = _csi.params.isNotEmpty ? _csi.params[0] : 1;
    final col = _csi.params.length > 1 ? _csi.params[1] : 1;
    handler.setCursor(col > 0 ? col - 1 : 0, row > 0 ? row - 1 : 0);
  }

  /// `ESC [ Ps g` Tab Clear (TBC)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sg/
  void _csiHandelClearTabStop() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.clearTabStopUnderCursor();
      default:
        return handler.clearAllTabStops();
    }
  }

  /// - `ESC [ [ Pm ] h Set Mode (SM)` https://terminalguide.namepad.de/seq/csi_sm/
  /// - `ESC [ ? [ Pm ] h` Set Mode (?) (SM) https://terminalguide.namepad.de/seq/csi_sh__p/
  /// - `ESC [ [ Pm ] l` Reset Mode (RM) https://terminalguide.namepad.de/seq/csi_rm/
  /// - `ESC [ ? [ Pm ] l` Reset Mode (?) (RM) https://terminalguide.namepad.de/seq/csi_sl__p/
  void _csiHandleMode() {
    final isEnabled = _csi.finalByte == Ascii.h;

    final isDecModes = _csi.prefix == Ascii.questionMark;

    if (isDecModes) {
      for (var mode in _csi.params) {
        _setDecMode(mode, isEnabled);
      }
    } else {
      for (var mode in _csi.params) {
        _setMode(mode, isEnabled);
      }
    }
  }

  /// `ESC [ [ Ps ] m` Select Graphic Rendition (SGR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sm/
  void _csiHandleSgr() {
    final params = _csi.params;

    if (params.isEmpty) {
      return handler.resetCursorStyle();
    }

    // This is a workaround for a bug in the analyzer.
    // ignore: dead_code
    for (var i = 0; i < _csi.params.length; i++) {
      final param = params[i];
      switch (param) {
        case 0:
          handler.resetCursorStyle();
          continue;
        case 1:
          handler.setCursorBold();
          continue;
        case 2:
          handler.setCursorFaint();
          continue;
        case 3:
          handler.setCursorItalic();
          continue;
        case 4:
          {
            final sub = _csi.subParamsOf(i);
            if (sub.isNotEmpty) {
              handler.setCursorUnderlineStyle(_underlineStyleFromParam(sub[0]));
            } else {
              handler.setCursorUnderline();
            }
          }
          continue;
        case 5:
          handler.setCursorBlink();
          continue;
        case 7:
          handler.setCursorInverse();
          continue;
        case 8:
          handler.setCursorInvisible();
          continue;
        case 9:
          handler.setCursorStrikethrough();
          continue;

        case 21:
          // Doubly underlined (matches xterm.js; ECMA-48 also allows "not
          // bold" here, but xterm/xterm.js treat 21 as double underline).
          handler.setCursorUnderlineStyle(UnderlineStyle.double);
          continue;
        case 22:
          // Neither bold nor faint.
          handler.unsetCursorBold();
          handler.unsetCursorFaint();
          continue;
        case 23:
          handler.unsetCursorItalic();
          continue;
        case 24:
          handler.unsetCursorUnderline();
          continue;
        case 25:
          handler.unsetCursorBlink();
          continue;
        case 27:
          handler.unsetCursorInverse();
          continue;
        case 28:
          handler.unsetCursorInvisible();
          continue;
        case 29:
          handler.unsetCursorStrikethrough();
          continue;

        case 53:
          handler.setCursorOverline();
          continue;
        case 55:
          handler.unsetCursorOverline();
          continue;

        case 30:
          handler.setForegroundColor16(NamedColor.black);
          continue;
        case 31:
          handler.setForegroundColor16(NamedColor.red);
          continue;
        case 32:
          handler.setForegroundColor16(NamedColor.green);
          continue;
        case 33:
          handler.setForegroundColor16(NamedColor.yellow);
          continue;
        case 34:
          handler.setForegroundColor16(NamedColor.blue);
          continue;
        case 35:
          handler.setForegroundColor16(NamedColor.magenta);
          continue;
        case 36:
          handler.setForegroundColor16(NamedColor.cyan);
          continue;
        case 37:
          handler.setForegroundColor16(NamedColor.white);
          continue;
        case 38:
          i += _handleSgrColor(38, i);
          continue;
        case 39:
          handler.resetForeground();
          continue;

        case 40:
          handler.setBackgroundColor16(NamedColor.black);
          continue;
        case 41:
          handler.setBackgroundColor16(NamedColor.red);
          continue;
        case 42:
          handler.setBackgroundColor16(NamedColor.green);
          continue;
        case 43:
          handler.setBackgroundColor16(NamedColor.yellow);
          continue;
        case 44:
          handler.setBackgroundColor16(NamedColor.blue);
          continue;
        case 45:
          handler.setBackgroundColor16(NamedColor.magenta);
          continue;
        case 46:
          handler.setBackgroundColor16(NamedColor.cyan);
          continue;
        case 47:
          handler.setBackgroundColor16(NamedColor.white);
          continue;
        case 48:
          i += _handleSgrColor(48, i);
          continue;
        case 49:
          handler.resetBackground();
          continue;

        case 58:
          i += _handleSgrColor(58, i);
          continue;
        case 59:
          handler.resetUnderlineColor();
          continue;

        case 90:
          handler.setForegroundColor16(NamedColor.brightBlack);
          continue;
        case 91:
          handler.setForegroundColor16(NamedColor.brightRed);
          continue;
        case 92:
          handler.setForegroundColor16(NamedColor.brightGreen);
          continue;
        case 93:
          handler.setForegroundColor16(NamedColor.brightYellow);
          continue;
        case 94:
          handler.setForegroundColor16(NamedColor.brightBlue);
          continue;
        case 95:
          handler.setForegroundColor16(NamedColor.brightMagenta);
          continue;
        case 96:
          handler.setForegroundColor16(NamedColor.brightCyan);
          continue;
        case 97:
          handler.setForegroundColor16(NamedColor.brightWhite);
          continue;

        case 100:
          handler.setBackgroundColor16(NamedColor.brightBlack);
          continue;
        case 101:
          handler.setBackgroundColor16(NamedColor.brightRed);
          continue;
        case 102:
          handler.setBackgroundColor16(NamedColor.brightGreen);
          continue;
        case 103:
          handler.setBackgroundColor16(NamedColor.brightYellow);
          continue;
        case 104:
          handler.setBackgroundColor16(NamedColor.brightBlue);
          continue;
        case 105:
          handler.setBackgroundColor16(NamedColor.brightMagenta);
          continue;
        case 106:
          handler.setBackgroundColor16(NamedColor.brightCyan);
          continue;
        case 107:
          handler.setBackgroundColor16(NamedColor.brightWhite);
          continue;

        default:
          handler.unsupportedStyle(param);
          continue;
      }
    }
  }

  /// Resolves an extended color SGR (`38` foreground, `48` background) whose
  /// arguments begin at top-level parameter [i].
  ///
  /// Supports both the legacy semicolon form (`CSI 38;2;r;g;b m`,
  /// `CSI 38;5;n m`) and the ITU-T T.416 colon sub-parameter form
  /// (`CSI 38:2::r:g:b m`, `CSI 38:5:n m`). Incomplete legacy semicolon forms
  /// are skipped without leaking color-mode bytes into later SGR parameters.
  /// Returns the number of *extra* top-level parameters consumed (always `0`
  /// for the colon form).
  int _handleSgrColor(int code, int i) {
    final params = _csi.params;
    final sub = _csi.subParamsOf(i);

    // Colon (sub-parameter) form: the whole color lives in `sub`.
    if (sub.isNotEmpty) {
      final mode = sub[0];
      if (mode == 2) {
        // sub = [2, r, g, b] or [2, colorSpaceId, r, g, b] (id ignored).
        final off = sub.length >= 5 ? 2 : 1;
        _applySgrColorRgb(
          code,
          _sub(sub, off),
          _sub(sub, off + 1),
          _sub(sub, off + 2),
        );
      } else if (mode == 5) {
        _applySgrColorIndexed(code, _sub(sub, 1));
      }
      return 0;
    }

    // Legacy semicolon form: read the following top-level parameters.
    final mode = i + 1 < params.length ? params[i + 1] : 0;
    if (mode == 2) {
      if (i + 4 >= params.length) {
        return 2;
      }
      final r = i + 2 < params.length ? params[i + 2] : 0;
      final g = i + 3 < params.length ? params[i + 3] : 0;
      final b = i + 4 < params.length ? params[i + 4] : 0;
      _applySgrColorRgb(code, r, g, b);
      return 4;
    } else if (mode == 5) {
      if (i + 2 >= params.length) {
        return 2;
      }
      _applySgrColorIndexed(code, i + 2 < params.length ? params[i + 2] : 0);
      return 2;
    }
    return i + 1 < params.length ? 1 : 0;
  }

  int _sub(List<int> sub, int i) => i < sub.length ? sub[i] : 0;

  /// Maps an SGR `4 : x` sub-parameter to an [UnderlineStyle]. Invalid values
  /// fall back to a single underline, matching xterm.js.
  UnderlineStyle _underlineStyleFromParam(int value) {
    if (value < 0 || value >= UnderlineStyle.values.length) {
      return UnderlineStyle.single;
    }
    return UnderlineStyle.values[value];
  }

  void _applySgrColorRgb(int code, int r, int g, int b) {
    if (code == 38) {
      handler.setForegroundColorRgb(r, g, b);
    } else if (code == 48) {
      handler.setBackgroundColorRgb(r, g, b);
    } else if (code == 58) {
      handler.setUnderlineColorRgb(r, g, b);
    }
  }

  void _applySgrColorIndexed(int code, int index) {
    if (code == 38) {
      handler.setForegroundColor256(index);
    } else if (code == 48) {
      handler.setBackgroundColor256(index);
    } else if (code == 58) {
      handler.setUnderlineColor256(index);
    }
  }

  /// `ESC [ Ps n` Device Status Report [Dispatch] (DSR)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sn/
  void _csiHandleDeviceStatusReport() {
    if (_csi.params.isEmpty) return;

    switch (_csi.params[0]) {
      case 5:
        return handler.sendOperatingStatus();
      case 6:
        return handler.sendCursorPosition();
    }
  }

  /// `ESC [ Ps ; Ps r` Set Top and Bottom Margins (DECSTBM)
  ///
  /// https://terminalguide.namepad.de/seq/csi_sr/
  void _csiHandleSetMargins() {
    var top = 1;
    int? bottom;

    if (_csi.params.length > 2) return;

    if (_csi.params.isNotEmpty) {
      top = _csi.params[0];

      if (_csi.params.length == 2) {
        bottom = _csi.params[1] - 1;
      }
    }

    handler.setMargins(top - 1, bottom);
  }

  /// `ESC [ Ps t` Window operations [DISPATCH]
  ///
  /// https://terminalguide.namepad.de/seq/csi_st/
  void _csiWindowManipulation() {
    // The sequence needs at least one parameter.
    if (_csi.params.isEmpty) {
      return;
    }
    // Most the commands in this group are either of the scope of this package,
    // or should be disabled for security risks.
    switch (_csi.params.first) {
      // Window handling is currently not in the scope of the package.
      case 1: // Restore Terminal Window (show window if minimized)
      case 2: // Minimize Terminal Window
      case 3: // Set Terminal Window Position
      case 4: // Set Terminal Window Size in Pixels
      case 5: // Raise Terminal Window
      case 6: // Lower Terminal Window
      case 7: // Refresh/Redraw Terminal Window
        return;
      case 8: // Set Terminal Window Size (in characters)
        // This CSI contains 2 more parameters: width and height.
        if (_csi.params.length != 3) {
          return;
        }
        final rows = _csi.params[1];
        final cols = _csi.params[2];
        if (_csi.prefix == Ascii.questionMark) {
          handler.resizeFromHost(cols, rows);
        } else {
          handler.resize(cols, rows);
        }
        return;
      // Window handling is currently no in the scope of the package.
      case 9: // Maximize Terminal Window
      case 10: // Alias: Maximize Terminal Window
      case 11: // Report Terminal Window State
      case 13: // Report Terminal Window Position
      case 14: // Report text area size in pixels (answered by the app layer)
      case 15: // Report screen size in pixels (answered by the app layer)
      case 16: // Report cell size in pixels (answered by the app layer)
        return;
      case 18: // Report Terminal Size (in characters)
        handler.sendSize();
        return;
      // Screen handling is currently no in the scope of the package.
      case 19: // Report Screen Size (in characters)
      // Disabled as these can a security risk.
      case 20: // Get Icon Title
      case 21: // Get Terminal Title
      // Not implemented.
      case 22: // Push Terminal Title
      case 23: // Pop Terminal Title
        return;
      // Unknown CSI.
      default:
        return;
    }
  }

  /// `ESC [ Ps A` Cursor Up (CUU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ca/
  void _csiHandleCursorUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(-amount);
  }

  /// `ESC [ Ps B` Cursor Down (CUD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cb/
  void _csiHandleCursorDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorY(amount);
  }

  /// `ESC [ Ps C` Cursor Right (CUF)
  ///
  /// Cursor Right (CUF)
  void _csiHandleCursorForward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(amount);
  }

  /// `ESC [ Ps D` Cursor Left (CUB)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cd/
  void _csiHandleCursorBackward() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.moveCursorX(-amount);
  }

  /// `ESC [ Ps E` Cursor Next Line (CNL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ce/
  void _csiHandleCursorNextLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorNextLine(amount);
  }

  /// `ESC [ Ps F` Cursor Previous Line (CPL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cf/
  void _csiHandleCursorPrecedingLine() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
      if (amount == 0) amount = 1;
    }

    handler.cursorPrecedingLine(amount);
  }

  void _csiHandleCursorHorizontalAbsolute() {
    var x = 1;

    if (_csi.params.isNotEmpty) {
      x = _csi.params[0];
      if (x == 0) x = 1;
    }

    handler.setCursorX(x - 1);
  }

  /// ESC [ Ps J Erase Display [Dispatch] (ED)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cj/
  void _csiHandleEraseDisplay() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseDisplayBelow();
      case 1:
        return handler.eraseDisplayAbove();
      case 2:
        return handler.eraseDisplay();
      case 3:
        return handler.eraseScrollbackOnly();
    }
  }

  /// `ESC [ Ps K` Erase Line [Dispatch] (EL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ck/
  void _csiHandleEraseLine() {
    var cmd = 0;

    if (_csi.params.length == 1) {
      cmd = _csi.params[0];
    }

    switch (cmd) {
      case 0:
        return handler.eraseLineRight();
      case 1:
        return handler.eraseLineLeft();
      case 2:
        return handler.eraseLine();
    }
  }

  /// `ESC [ Ps L` Insert Line (IL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cl/
  void _csiHandleInsertLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertLines(amount);
  }

  /// ESC [ Ps M Delete Line (DL)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cm/
  void _csiHandleDeleteLines() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteLines(amount);
  }

  /// ESC [ Ps P Delete Character (DCH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cp/
  void _csiHandleDelete() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.deleteChars(amount);
  }

  /// `ESC [ Ps S` Scroll Up (SU)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cs/
  void _csiHandleScrollUp() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollUp(amount);
  }

  /// `ESC [ Ps T `Scroll Down (SD)
  ///
  /// https://terminalguide.namepad.de/seq/csi_ct_1param/
  void _csiHandleScrollDown() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.scrollDown(amount);
  }

  /// `ESC [ Ps X` Erase Character (ECH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_cx/
  void _csiHandleEraseCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.eraseChars(amount);
  }

  /// `ESC [ Ps @` Insert Blanks (ICH)
  ///
  /// https://terminalguide.namepad.de/seq/csi_x40_at/
  ///
  /// Inserts amount spaces at current cursor position moving existing cell
  /// contents to the right. The contents of the amount right-most columns in
  /// the scroll region are lost. The cursor position is not changed.
  void _csiHandleInsertBlankCharacters() {
    var amount = 1;

    if (_csi.params.isNotEmpty) {
      amount = _csi.params[0];
    }

    handler.insertBlankChars(amount);
  }

  void _setMode(int mode, bool enabled) {
    switch (mode) {
      case 4:
        return handler.setInsertMode(enabled);
      case 20:
        return handler.setLineFeedMode(enabled);
      default:
        return handler.setUnknownMode(mode, enabled);
    }
  }

  void _setDecMode(int mode, bool enabled) {
    switch (mode) {
      case 1:
        return handler.setCursorKeysMode(enabled);
      case 2:
        return handler.setAnsiMode(enabled);
      case 3:
        return handler.setColumnMode(enabled);
      case 5:
        return handler.setReverseDisplayMode(enabled);
      case 6:
        return handler.setOriginMode(enabled);
      case 7:
        return handler.setAutoWrapMode(enabled);
      case 9:
        return enabled
            ? handler.setMouseMode(MouseMode.clickOnly)
            : handler.setMouseMode(MouseMode.none);
      case 12:
      case 13:
        return handler.setCursorBlinkMode(enabled);
      case 25:
        return handler.setCursorVisibleMode(enabled);
      case 47:
        if (enabled) {
          return handler.useAltBuffer();
        } else {
          return handler.useMainBuffer();
        }
      case 66:
        return handler.setAppKeypadMode(enabled);
      case 1000:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1001:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScroll)
            : handler.setMouseMode(MouseMode.none);
      case 1002:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollDrag)
            : handler.setMouseMode(MouseMode.none);
      case 1003:
        return enabled
            ? handler.setMouseMode(MouseMode.upDownScrollMove)
            : handler.setMouseMode(MouseMode.none);
      case 1004:
        return handler.setReportFocusMode(enabled);
      case 1005:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.utf)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1006:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.sgr)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1007:
        return handler.setAltBufferMouseScrollMode(enabled);
      case 1015:
        return enabled
            ? handler.setMouseReportMode(MouseReportMode.urxvt)
            : handler.setMouseReportMode(MouseReportMode.normal);
      case 1047:
        if (enabled) {
          handler.useAltBuffer();
        } else {
          handler.clearAltBuffer();
          handler.useMainBuffer();
        }
        return;
      case 1048:
        if (enabled) {
          return handler.saveCursor();
        } else {
          return handler.restoreCursor();
        }
      case 1049:
        if (enabled) {
          handler.saveCursor();
          handler.clearAltBuffer();
          handler.useAltBuffer();
        } else {
          handler.useMainBuffer();
        }
        return;
      case 2004:
        return handler.setBracketedPasteMode(enabled);
      default:
        return handler.setUnknownDecMode(mode, enabled);
    }
  }

  /// Parse a OSC sequence from the queue. Returns true if a sequence was
  /// found and handled.
  bool _escHandleOSC() {
    final result = _consumeOsc();
    if (result == _SeqParse.incomplete) {
      return false;
    }
    // An ESC cut the OSC short, so its parameters are truncated (a hyperlink
    // URL, a title, ...). Discard them rather than acting on a partial payload.
    if (result == _SeqParse.aborted) {
      return true;
    }

    if (_osc.isEmpty) {
      return true;
    }

    // Common OSCs
    if (_osc.length >= 2) {
      final ps = _osc[0];
      final pt = _osc[1];

      switch (ps) {
        case '0':
          handler.setTitle(pt);
          handler.setIconName(pt);
          return true;
        case '1':
          handler.setIconName(pt);
          return true;
        case '2':
          handler.setTitle(pt);
          return true;
      }
    }

    // Private extensions
    handler.unknownOSC(_osc[0], _osc.sublist(1));

    return true;
  }

  final _osc = <String>[];

  _SeqParse _consumeOsc() {
    _osc.clear();
    final param = StringBuffer();

    while (true) {
      if (_queue.isEmpty) {
        return _SeqParse.incomplete;
      }

      final char = _queue.consume();

      // OSC terminates with BEL
      if (char == Ascii.BEL) {
        _osc.add(param.toString());
        return _SeqParse.complete;
      }

      /// OSC terminates with ST
      if (char == Ascii.ESC) {
        final terminator = _consumeStringTerminator();
        if (terminator == _SeqParse.complete) {
          _osc.add(param.toString());
        }
        return terminator;
      }

      /// Parse next parameter
      if (char == Ascii.semicolon) {
        _osc.add(param.toString());
        param.clear();
        continue;
      }

      param.writeCharCode(char);
    }
  }

  /// `ESC P ... ST` Device Control String (DCS).
  ///
  /// XTGETTCAP (`ESC P + q <hex> ; <hex> ... ST`, a terminfo/termcap capability
  /// query) and DECRQSS (`ESC P $ q <Pt> ST`, request the current setting of a
  /// control function) are understood; any other DCS string (Sixel `q`, ...) is
  /// consumed and ignored so its payload is not rendered as text. Returns false
  /// when the sequence is incomplete so the caller can wait for more data.
  ///
  /// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
  bool _escHandleDCS() {
    final body = StringBuffer();

    while (true) {
      if (_queue.isEmpty) return false;
      final char = _queue.consume();

      // DCS terminates with ST (`ESC \`).
      if (char == Ascii.ESC) {
        final terminator = _consumeStringTerminator();
        if (terminator == _SeqParse.complete) break;
        // Incomplete: wait for more data. Aborted: the ESC starts a new
        // sequence and this DCS is discarded without reporting.
        return terminator != _SeqParse.incomplete;
      }
      // BEL is tolerated as a terminator for robustness.
      if (char == Ascii.BEL) break;

      body.writeCharCode(char);
    }

    final payload = body.toString();
    // XTGETTCAP request: `+ q <hexcap> [ ; <hexcap> ]...`.
    if (payload.length >= 2 && payload[0] == '+' && payload[1] == 'q') {
      final caps = payload.substring(2).split(';');
      handler.sendTermcapReport(caps);
      return true;
    }
    // DECRQSS (Request Status String): `$ q <Pt>`, where <Pt> is the
    // intermediate/final of the control function being queried (for example
    // `r` for DECSTBM, `m` for SGR, ` q` for DECSCUSR).
    if (payload.length >= 2 && payload[0] == '\$' && payload[1] == 'q') {
      handler.sendStatusStringReport(payload.substring(2));
    }
    return true;
  }

  /// `ESC _ ... ST` Application Program Command (APC).
  ///
  /// Only the Kitty graphics protocol (`ESC _ G <args> ; <payload> ST`) is
  /// understood; any other APC string is consumed and ignored so its payload is
  /// not rendered as text. Returns false when the sequence is incomplete so the
  /// caller can wait for more data.
  bool _escHandleAPC() {
    if (_queue.isEmpty) return false;

    if (_queue.peek() != 'G'.charCode) {
      return _skipToStringTerminator();
    }
    _queue.consume(); // consume 'G'

    final args = <String, String>{};
    final argsResult = _parseGraphicsArgs(args);
    if (argsResult == _ApcParse.incomplete) return false;
    if (argsResult == _ApcParse.aborted) {
      handler.graphicsCommandAbort();
      return true;
    }

    final payload = <int>[];
    if (argsResult == _ApcParse.payloadFollows) {
      final payloadResult = _parseGraphicsPayload(payload);
      if (payloadResult == _SeqParse.incomplete) return false;
      if (payloadResult == _SeqParse.aborted) {
        handler.graphicsCommandAbort();
        return true;
      }
    }

    // The full command is buffered before dispatching so an incomplete payload
    // that rolls back never double-delivers a command.
    handler.graphicsCommandStart(args);
    if (payload.isNotEmpty) {
      handler.graphicsDataChunk(payload);
    }
    if (args['m'] != '1') {
      handler.graphicsCommandEnd();
    }
    return true;
  }

  /// Parses `key=value` pairs (comma separated) up to the `;` that begins the
  /// payload or the terminating ST.
  _ApcParse _parseGraphicsArgs(Map<String, String> args) {
    final key = StringBuffer();
    final value = StringBuffer();
    var inKey = true;

    void flush() {
      if (key.isNotEmpty) {
        args[key.toString()] = value.toString();
      }
      key.clear();
      value.clear();
      inKey = true;
    }

    while (true) {
      if (_queue.isEmpty) return _ApcParse.incomplete;
      final char = _queue.consume();

      if (char == Ascii.semicolon) {
        flush();
        return _ApcParse.payloadFollows;
      }
      if (char == Ascii.ESC) {
        final terminator = _consumeStringTerminator();
        if (terminator == _SeqParse.complete) {
          flush();
          return _ApcParse.terminated;
        }
        return terminator == _SeqParse.aborted
            ? _ApcParse.aborted
            : _ApcParse.incomplete;
      }
      if (char == Ascii.BEL) {
        flush();
        return _ApcParse.terminated;
      }
      if (char == 0x2c) {
        // ,
        flush();
        continue;
      }
      if (char == 0x3d) {
        // =
        inKey = false;
        continue;
      }
      (inKey ? key : value).writeCharCode(char);
    }
  }

  /// Reads the base64 payload up to ST and decodes it into [out]. Returns false
  /// if the sequence is incomplete.
  ///
  /// The payload is decoded inline as it is consumed: each base64 character is
  /// translated through [_base64DecodeTable] and the accumulated 6-bit groups
  /// are emitted as bytes directly into [out]. This avoids buffering the entire
  /// payload as a String and the extra full passes that a
  /// `StringBuffer` + whitespace `RegExp` strip + `base64.decode` would cost.
  /// A window switch can replay several megabytes of Kitty image transmissions
  /// on the parse critical path (ahead of the visible redraw), so the cheaper
  /// the payload decode, the sooner the screen repaints. Non-base64 bytes
  /// (whitespace, stray padding) are skipped, matching the previous lenient
  /// decoder.
  _SeqParse _parseGraphicsPayload(List<int> out) {
    var accumulator = 0;
    var bits = 0;

    while (true) {
      if (_queue.isEmpty) return _SeqParse.incomplete;
      final char = _queue.consume();

      if (char == Ascii.ESC) {
        final terminator = _consumeStringTerminator();
        if (terminator == _SeqParse.complete) break;
        return terminator;
      }
      if (char == Ascii.BEL) break;

      final value = char >= 0 && char < 128 ? _base64DecodeTable[char] : -1;
      if (value < 0) continue; // whitespace, padding or non-base64 byte
      accumulator = (accumulator << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.add((accumulator >> bits) & 0xff);
        accumulator = bits == 0 ? 0 : accumulator & ((1 << bits) - 1);
      }
    }

    return _SeqParse.complete;
  }

  /// Skips an unrecognized string sequence up to ST. Returns false when the
  /// terminator has not arrived yet.
  bool _skipToStringTerminator() {
    while (true) {
      if (_queue.isEmpty) return false;
      final char = _queue.consume();
      if (char == Ascii.ESC) {
        final terminator = _consumeStringTerminator();
        // Aborted counts as handled: the rolled-back ESC starts a new sequence.
        return terminator != _SeqParse.incomplete;
      }
      if (char == Ascii.BEL) return true;
    }
  }
}

/// Maps an ASCII byte to its 6-bit base64 value, or -1 when the byte is not a
/// base64 digit (whitespace, padding `=`, or any other character). Indexed by
/// code unit (0-127) so [_parseGraphicsPayload] can decode the payload inline
/// without allocating intermediate strings.
final List<int> _base64DecodeTable = _buildBase64DecodeTable();

List<int> _buildBase64DecodeTable() {
  final table = List<int>.filled(128, -1);
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  for (var i = 0; i < alphabet.length; i++) {
    table[alphabet.codeUnitAt(i)] = i;
  }
  return table;
}

/// Result of parsing the key/value header of an APC graphics command.
enum _ApcParse { incomplete, payloadFollows, terminated, aborted }

/// Outcome of parsing a sequence whose end is only known once its terminator
/// arrives.
///
/// [aborted] means an ESC appeared where the terminator was expected. ECMA-48
/// treats that ESC as the start of a new sequence, so the consumer rolls it
/// back and discards whatever it had gathered.
enum _SeqParse { complete, incomplete, aborted }

class _Csi {
  _Csi({
    required this.params,
    required this.finalByte,
    // required this.intermediates,
  });

  int? prefix;

  /// The last intermediate byte (range `0x20`-`0x2F`) seen before the final
  /// byte, or `null` when the sequence had no intermediate. Most sequences
  /// ignore intermediates, but a few finals are disambiguated by them — for
  /// example `CSI Ps $ p` (DECRQM) versus `CSI ! p` (DECSTR), which share the
  /// `p` final but differ by their `$` / `!` intermediate.
  int? intermediate;

  List<int> params;

  /// Colon-separated sub-parameters (ITU-T T.416 / ISO 8613-6), aligned by
  /// index with [params]. `subParams[i]` holds the values that followed
  /// `params[i]` after a `:`, or an empty list when that parameter had none.
  ///
  /// For example `CSI 38:2::1:2:3 m` yields `params = [38]` and
  /// `subParams = [[2, 0, 1, 2, 3]]`.
  final List<List<int>> subParams = [];

  int finalByte;
  // final List<int> intermediates;

  /// The sub-parameters that followed `params[index]`, or an empty list when
  /// none were present.
  List<int> subParamsOf(int index) {
    return index < subParams.length ? subParams[index] : const [];
  }

  @override
  String toString() {
    return params.join(';') + String.fromCharCode(finalByte);
  }
}

/// Function that handles a sequence of characters that starts with an escape.
/// Returns [true] if the sequence was processed, [false] if it was not.
typedef _EscHandler = bool Function();

typedef _SbcHandler = void Function();

typedef _CsiHandler = void Function();
