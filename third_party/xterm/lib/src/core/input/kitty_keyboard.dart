import 'package:xterm/src/core/input/handler.dart';
import 'package:xterm/src/core/input/keys.dart';

/// Kitty keyboard progressive-enhancement flag values.
abstract final class KittyKeyboardFlags {
  /// Encode ambiguous legacy escape/control keys with CSI-u forms.
  static const disambiguateEscapeCodes = 1;

  /// Include repeat/release event types in encoded key events.
  static const reportEventTypes = 2;

  /// Include alternate shifted/base key values where known.
  static const reportAlternateKeys = 4;

  /// Encode text-producing keys as escape sequences too.
  static const reportAllKeysAsEscapeCodes = 8;

  /// Include associated text codepoints when reporting all keys.
  static const reportAssociatedText = 16;
}

/// State for one Kitty keyboard protocol screen buffer.
class KittyKeyboardState {
  static const _maxStackDepth = 32;

  final List<int> _stack = <int>[];

  /// Active progressive-enhancement flags.
  int flags = 0;

  /// Applies [requestedFlags] using Kitty's mode semantics.
  void setFlags(int requestedFlags, int mode) {
    switch (mode) {
      case 1:
        flags = requestedFlags;
        return;
      case 2:
        flags |= requestedFlags;
        return;
      case 3:
        flags &= ~requestedFlags;
        return;
      default:
        flags = requestedFlags;
        return;
    }
  }

  /// Saves the current flags, then replaces them with [requestedFlags].
  void pushFlags(int requestedFlags) {
    if (_stack.length == _maxStackDepth) {
      _stack.removeAt(0);
    }
    _stack.add(flags);
    flags = requestedFlags;
  }

  /// Clears the flags and the whole push/pop stack.
  ///
  /// RIS resets the progressive-enhancement state, as the Kitty keyboard
  /// protocol requires; a program that dies with flags pushed would otherwise
  /// leave the next program's keys encoded in a form it does not understand.
  void reset() {
    _stack.clear();
    flags = 0;
  }

  /// Restores [count] saved flag frames, or resets flags if the stack empties.
  void popFlags(int count) {
    final framesToPop = count <= 0 ? 1 : count;
    for (var i = 0; i < framesToPop; i += 1) {
      if (_stack.isEmpty) {
        flags = 0;
        return;
      }
      flags = _stack.removeLast();
    }
  }
}

/// Encodes [event] with Kitty keyboard protocol, or returns `null` when the
/// active [flags] should leave the existing legacy/text input path in charge.
String? encodeKittyKeyboardEvent(TerminalKeyboardEvent event, int flags) {
  if (flags == 0) {
    return null;
  }

  final key = _kittyKeyFor(event.key);
  if (key == null) {
    return null;
  }

  final reportAll = flags & KittyKeyboardFlags.reportAllKeysAsEscapeCodes != 0;
  final reportEventTypes = flags & KittyKeyboardFlags.reportEventTypes != 0;
  final disambiguate =
      reportAll || flags & KittyKeyboardFlags.disambiguateEscapeCodes != 0;
  final hasModifiers = event.shift || event.alt || event.ctrl || event.meta;
  final isRelease = event.type == TerminalKeyEventType.release;
  final isRepeat = event.type == TerminalKeyEventType.repeat;
  final isLegacyTextControl = event.key == TerminalKey.enter ||
      event.key == TerminalKey.tab ||
      event.key == TerminalKey.backspace;

  if (isRelease) {
    if (!reportEventTypes) {
      return null;
    }
    if (!reportAll && (key.isText || isLegacyTextControl)) {
      return null;
    }
  }

  if (key.isText) {
    if (!reportAll) {
      if (!disambiguate || !hasModifiers) {
        return null;
      }
      if (event.shift && !event.alt && !event.ctrl && !event.meta) {
        return null;
      }
    }
  } else if (isLegacyTextControl && !reportAll && !hasModifiers) {
    return null;
  } else if (!disambiguate && !reportAll && !isRelease && !isRepeat) {
    return null;
  }

  final eventType = reportEventTypes && isRepeat
      ? 2
      : reportEventTypes && isRelease
          ? 3
          : null;
  return key.encode(
    modifiers: _kittyModifierValue(event),
    eventType: eventType,
    includeAlternateKeys: flags & KittyKeyboardFlags.reportAlternateKeys != 0,
    includeAssociatedText:
        reportAll && flags & KittyKeyboardFlags.reportAssociatedText != 0,
  );
}

/// Encodes IME/text-only input when Kitty report-all + associated-text mode is
/// active. Returns `null` when text should be sent unchanged.
String? encodeKittyTextInput(String text, int flags) {
  final reportAll = flags & KittyKeyboardFlags.reportAllKeysAsEscapeCodes != 0;
  final reportAssociatedText =
      flags & KittyKeyboardFlags.reportAssociatedText != 0;
  if (!reportAll || !reportAssociatedText) {
    return null;
  }

  final codepoints = text.runes
      .where(_isAllowedAssociatedTextCodepoint)
      .map((rune) => rune.toString())
      .join(':');
  if (codepoints.isEmpty) {
    return null;
  }
  return '\x1b[0;;${codepoints}u';
}

bool _isAllowedAssociatedTextCodepoint(int rune) =>
    (rune >= 0x20 && rune != 0x7f && rune < 0x80) || rune > 0x9f;

int _kittyModifierValue(TerminalKeyboardEvent event) {
  var modifiers = 1;
  if (event.shift) modifiers += 1;
  if (event.alt) modifiers += 2;
  if (event.ctrl) modifiers += 4;
  if (event.meta) modifiers += 8;
  return modifiers;
}

_KittyKey? _kittyKeyFor(TerminalKey key) {
  final letter = _letterKeyCode(key);
  if (letter != null) {
    return _KittyKey.u(letter, isText: true, shiftedCode: letter - 32);
  }

  final digit = _digitKeyCode(key);
  if (digit != null) {
    return _KittyKey.u(digit, isText: true);
  }

  switch (key) {
    case TerminalKey.enter:
      return _KittyKey.u(13);
    case TerminalKey.escape:
      return _KittyKey.u(27);
    case TerminalKey.backspace:
      return _KittyKey.u(127);
    case TerminalKey.tab:
      return _KittyKey.u(9);
    case TerminalKey.space:
      return _KittyKey.u(32, isText: true);
    case TerminalKey.minus:
      return _KittyKey.u(45, isText: true, shiftedCode: 95);
    case TerminalKey.equal:
      return _KittyKey.u(61, isText: true, shiftedCode: 43);
    case TerminalKey.bracketLeft:
      return _KittyKey.u(91, isText: true, shiftedCode: 123);
    case TerminalKey.bracketRight:
      return _KittyKey.u(93, isText: true, shiftedCode: 125);
    case TerminalKey.backslash:
    case TerminalKey.intlBackslash:
      return _KittyKey.u(92, isText: true, shiftedCode: 124);
    case TerminalKey.semicolon:
      return _KittyKey.u(59, isText: true, shiftedCode: 58);
    case TerminalKey.quote:
      return _KittyKey.u(39, isText: true, shiftedCode: 34);
    case TerminalKey.backquote:
      return _KittyKey.u(96, isText: true, shiftedCode: 126);
    case TerminalKey.comma:
      return _KittyKey.u(44, isText: true, shiftedCode: 60);
    case TerminalKey.period:
      return _KittyKey.u(46, isText: true, shiftedCode: 62);
    case TerminalKey.slash:
      return _KittyKey.u(47, isText: true, shiftedCode: 63);
    case TerminalKey.insert:
      return _KittyKey.legacy(2, '~');
    case TerminalKey.delete:
      return _KittyKey.legacy(3, '~');
    case TerminalKey.arrowLeft:
      return _KittyKey.legacy(1, 'D', omitBareCode: true);
    case TerminalKey.arrowRight:
      return _KittyKey.legacy(1, 'C', omitBareCode: true);
    case TerminalKey.arrowUp:
      return _KittyKey.legacy(1, 'A', omitBareCode: true);
    case TerminalKey.arrowDown:
      return _KittyKey.legacy(1, 'B', omitBareCode: true);
    case TerminalKey.pageUp:
      return _KittyKey.legacy(5, '~');
    case TerminalKey.pageDown:
      return _KittyKey.legacy(6, '~');
    case TerminalKey.home:
      return _KittyKey.legacy(1, 'H', omitBareCode: true);
    case TerminalKey.end:
      return _KittyKey.legacy(1, 'F', omitBareCode: true);
    case TerminalKey.capsLock:
      return _KittyKey.u(57358);
    case TerminalKey.scrollLock:
      return _KittyKey.u(57359);
    case TerminalKey.numLock:
      return _KittyKey.u(57360);
    case TerminalKey.printScreen:
      return _KittyKey.u(57361);
    case TerminalKey.pause:
      return _KittyKey.u(57362);
    case TerminalKey.contextMenu:
      return _KittyKey.u(57363);
    case TerminalKey.f1:
      return _KittyKey.legacy(1, 'P', omitBareCode: true);
    case TerminalKey.f2:
      return _KittyKey.legacy(1, 'Q', omitBareCode: true);
    case TerminalKey.f3:
      return _KittyKey.legacy(13, '~');
    case TerminalKey.f4:
      return _KittyKey.legacy(1, 'S', omitBareCode: true);
    case TerminalKey.f5:
      return _KittyKey.legacy(15, '~');
    case TerminalKey.f6:
      return _KittyKey.legacy(17, '~');
    case TerminalKey.f7:
      return _KittyKey.legacy(18, '~');
    case TerminalKey.f8:
      return _KittyKey.legacy(19, '~');
    case TerminalKey.f9:
      return _KittyKey.legacy(20, '~');
    case TerminalKey.f10:
      return _KittyKey.legacy(21, '~');
    case TerminalKey.f11:
      return _KittyKey.legacy(23, '~');
    case TerminalKey.f12:
      return _KittyKey.legacy(24, '~');
    case TerminalKey.f13:
      return _KittyKey.u(57376);
    case TerminalKey.f14:
      return _KittyKey.u(57377);
    case TerminalKey.f15:
      return _KittyKey.u(57378);
    case TerminalKey.f16:
      return _KittyKey.u(57379);
    case TerminalKey.f17:
      return _KittyKey.u(57380);
    case TerminalKey.f18:
      return _KittyKey.u(57381);
    case TerminalKey.f19:
      return _KittyKey.u(57382);
    case TerminalKey.f20:
      return _KittyKey.u(57383);
    case TerminalKey.f21:
      return _KittyKey.u(57384);
    case TerminalKey.f22:
      return _KittyKey.u(57385);
    case TerminalKey.f23:
      return _KittyKey.u(57386);
    case TerminalKey.f24:
      return _KittyKey.u(57387);
    case TerminalKey.numpad0:
      return _KittyKey.u(57399);
    case TerminalKey.numpad1:
      return _KittyKey.u(57400);
    case TerminalKey.numpad2:
      return _KittyKey.u(57401);
    case TerminalKey.numpad3:
      return _KittyKey.u(57402);
    case TerminalKey.numpad4:
      return _KittyKey.u(57403);
    case TerminalKey.numpad5:
      return _KittyKey.u(57404);
    case TerminalKey.numpad6:
      return _KittyKey.u(57405);
    case TerminalKey.numpad7:
      return _KittyKey.u(57406);
    case TerminalKey.numpad8:
      return _KittyKey.u(57407);
    case TerminalKey.numpad9:
      return _KittyKey.u(57408);
    case TerminalKey.numpadDecimal:
      return _KittyKey.u(57409);
    case TerminalKey.numpadDivide:
      return _KittyKey.u(57410);
    case TerminalKey.numpadMultiply:
      return _KittyKey.u(57411);
    case TerminalKey.numpadSubtract:
      return _KittyKey.u(57412);
    case TerminalKey.numpadAdd:
      return _KittyKey.u(57413);
    case TerminalKey.numpadEnter:
      return _KittyKey.u(57414);
    case TerminalKey.numpadEqual:
      return _KittyKey.u(57415);
    case TerminalKey.numpadComma:
      return _KittyKey.u(57416);
    case TerminalKey.controlLeft:
      return _KittyKey.u(57442);
    case TerminalKey.shiftLeft:
      return _KittyKey.u(57441);
    case TerminalKey.altLeft:
      return _KittyKey.u(57443);
    case TerminalKey.metaLeft:
      return _KittyKey.u(57444);
    case TerminalKey.controlRight:
      return _KittyKey.u(57448);
    case TerminalKey.shiftRight:
      return _KittyKey.u(57447);
    case TerminalKey.altRight:
      return _KittyKey.u(57449);
    case TerminalKey.metaRight:
      return _KittyKey.u(57450);
    default:
      return null;
  }
}

int? _letterKeyCode(TerminalKey key) {
  if (key.index < TerminalKey.keyA.index ||
      key.index > TerminalKey.keyZ.index) {
    return null;
  }
  return 97 + key.index - TerminalKey.keyA.index;
}

int? _digitKeyCode(TerminalKey key) {
  if (key == TerminalKey.digit0) {
    return 48;
  }
  if (key.index < TerminalKey.digit1.index ||
      key.index > TerminalKey.digit9.index) {
    return null;
  }
  return 49 + key.index - TerminalKey.digit1.index;
}

class _KittyKey {
  const _KittyKey.u(this.code, {this.isText = false, this.shiftedCode})
      : suffix = 'u',
        omitBareCode = false;

  const _KittyKey.legacy(this.code, this.suffix, {this.omitBareCode = false})
      : isText = false,
        shiftedCode = null;

  final int code;
  final String suffix;
  final bool isText;
  final int? shiftedCode;
  final bool omitBareCode;

  String encode({
    required int modifiers,
    required int? eventType,
    required bool includeAlternateKeys,
    required bool includeAssociatedText,
  }) {
    if (suffix != 'u') {
      return _encodeLegacy(modifiers: modifiers, eventType: eventType);
    }

    final keyCode = includeAlternateKeys && shiftedCode != null
        ? '$code:$shiftedCode'
        : '$code';
    final modifierField =
        eventType == null ? '$modifiers' : '$modifiers:$eventType';
    final associatedText = includeAssociatedText && isText ? '$code' : null;
    if (associatedText != null) {
      return '\x1b[$keyCode;$modifierField;${associatedText}u';
    }
    if (modifiers != 1 || eventType != null) {
      return '\x1b[$keyCode;${modifierField}u';
    }
    return '\x1b[${keyCode}u';
  }

  String _encodeLegacy({required int modifiers, required int? eventType}) {
    final hasModifierOrEvent = modifiers != 1 || eventType != null;
    if (!hasModifierOrEvent && omitBareCode) {
      return '\x1b[$suffix';
    }
    if (!hasModifierOrEvent) {
      return '\x1b[$code$suffix';
    }
    final modifierField =
        eventType == null ? '$modifiers' : '$modifiers:$eventType';
    return '\x1b[$code;$modifierField$suffix';
  }
}
