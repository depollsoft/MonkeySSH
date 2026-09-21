// ignore_for_file: public_member_api_docs

import 'dart:async';

// Flutter depends on characters; keep the engine independent of widgets.dart.
// ignore: depend_on_referenced_packages
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../domain/models/auto_connect_command.dart';
import '../../domain/services/diagnostics_log_service.dart';
import 'terminal_key_input.dart';

const _deleteDetectionMarker = '\u200B\u200B';
final _leadingSwipeNewlineArtifactPattern = RegExp(r'^[\r\n]+ ?(?=\S)');
final _splitLeadingTokenCandidatePattern = RegExp(r'^\s*\S\s+\S');
final _terminalTextControlPattern = RegExp(r'[\x00-\x1f\x7f-\x9f]');
final _newlinePattern = RegExp(r'[\r\n]');
final _imeFinalisingSuffixPattern = RegExp(r'^[.,!?]{0,2}$');
bool _isNewlineCodeUnit(int codeUnit) => codeUnit == 0x0A || codeUnit == 0x0D;
const _enterCommitNewlineSequences = <String>['\r\n', '\n', '\r'];
bool _isAsciiLetterOrDigitCodeUnit(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

bool _isPromptWhitespaceCodeUnit(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

/// Longest unchanged trailing tail that is retyped (backspaced and re-sent)
/// instead of navigated around with arrow keys when an IME edits text just
/// before it while the caret stays at the end of the buffer.
///
/// Covers keyboard double-space on Android and iOS ("word " -> "word. "),
/// autocorrect-on-space
/// ("teh " -> "the ") and autocorrect before trailing punctuation
/// ("teh. " -> "the. ").
@visibleForTesting
const terminalTrailingSuffixRewriteLimit = 4;

/// Maximum delay between a modifier chord and its follow-up character for the
/// follow-up to be treated as part of the chord (e.g. tmux's Ctrl+b, c).
@visibleForTesting
const modifierChordFollowUpWindow = Duration(milliseconds: 500);

/// How long iOS keeps the IME buffer intact after a trailing backspace.
///
/// Held iOS backspace can briefly pause between native repeat phases, so keep
/// the buffer alive long enough that those pauses do not fall back to the slow
/// marker-deletion path.
@visibleForTesting
const terminalIosBackspaceRepeatSettleDelay = Duration(seconds: 2);

/// Hidden backspace sentinels to preload after iOS exhausts visible IME text.
@visibleForTesting
const terminalIosBackspaceRepeatRunwayLength = 96;

/// Runway length at which the hidden iOS backspace sentinels are replenished.
@visibleForTesting
const terminalIosBackspaceRepeatRunwayRefillThreshold = 12;

const _iosBackspaceRepeatRunwayCodeUnit = 0x200B;

/// Confirms suspicious text inserted through the system keyboard or IME.
typedef TerminalTextInputReviewCallback = Future<bool> Function(
  TerminalCommandReview review,
);

/// Builds the command text that should be reviewed for a pending IME delta.
typedef TerminalTextInputReviewTextBuilder = String Function(
  ({int deletedCount, String appendedText}) delta,
  String currentText,
);

/// Resolves the current terminal text that appears before the cursor.
typedef TerminalTextBeforeCursorResolver = String? Function();

/// Resolves active toolbar modifiers for non-text terminal key actions.
typedef TerminalKeyModifierResolver =
    ({bool ctrl, bool alt, bool shift}) Function();

/// Applies active toolbar modifiers to soft-keyboard terminal text.
typedef TerminalTextInputModifierApplier = String Function(String text);

/// Platform and configuration values used by the IME state machine.
class TerminalImeOptions {
  const TerminalImeOptions({
    required this.platform,
    this.isWeb = false,
    this.readOnly = false,
    this.deleteDetection = false,
    this.sensitiveInput = false,
    this.keyboardAppearance = Brightness.dark,
  });
  final TargetPlatform platform;
  final bool isWeb;
  final bool readOnly;
  final bool deleteDetection;
  final bool sensitiveInput;
  final Brightness keyboardAppearance;
}

/// Effects are invoked synchronously in input order, except for awaited review.
class TerminalImeEffects {
  const TerminalImeEffects({
    this.onUserInput,
    this.onReviewInsertedText,
    this.buildReviewTextForInsertedText,
    this.resolveTextBeforeCursor,
    this.resolveTerminalKeyModifiers,
    this.consumeTerminalKeyModifiers,
    this.applyTerminalTextInputModifiers,
    this.hasActiveToolbarModifier,
    this.canSyncEditingState,
    this.onEditingState,
  });
  final VoidCallback? onUserInput;
  final TerminalTextInputReviewCallback? onReviewInsertedText;
  final TerminalTextInputReviewTextBuilder? buildReviewTextForInsertedText;
  final TerminalTextBeforeCursorResolver? resolveTextBeforeCursor;
  final TerminalKeyModifierResolver? resolveTerminalKeyModifiers;
  final VoidCallback? consumeTerminalKeyModifiers;
  final TerminalTextInputModifierApplier? applyTerminalTextInputModifiers;
  final ValueGetter<bool>? hasActiveToolbarModifier;
  final bool Function()? canSyncEditingState;
  final void Function(TextEditingValue)? onEditingState;
}

enum TerminalImeResetReason { connection, toolbar, completions }

/// Owns terminal editing, composition, review revisions and deferred resets.
/// No widget, focus node or platform input connection is required.
class TerminalImeEngine {
  TerminalImeEngine({
    required this.terminal,
    required this.options,
    this.effects = const TerminalImeEffects(),
    this.now = DateTime.now,
    this.schedule = Timer.new,
  });
  Terminal terminal;
  TerminalImeOptions options;
  TerminalImeEffects effects;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) schedule;
  bool _active = true;
  TextEditingValue get editingValue => _currentEditingState;

  void reset(TerminalImeResetReason reason) {
    switch (reason) {
      case TerminalImeResetReason.connection:
        cancelDeferredTrailingBackspaceImeClear();
        resetConnectionEditingState();
      case TerminalImeResetReason.toolbar:
        clearImeBufferForFreshInput();
      case TerminalImeResetReason.completions:
        resetImeCompletions();
    }
  }

  /// Drops queued edits and makes outstanding review decisions stale.
  void invalidate() => _invalidatePendingEditingUpdates();

  /// Records a touch that may move the terminal caret independently of the IME.
  void prepareForTouchCursorMove() => _clearImeAfterNextTouchCursorMove = true;

  /// Ends the current IME paste framing before a hardware paste shortcut.
  void endFraming() => _isFramingImeText = false;

  /// Stops tracking a native Android backspace gesture.
  void cancelAndroidBackspace() => _activeAndroidImeBackspace = null;

  /// Coalesces a toolbar-modified hardware Enter with its later IME commit.
  void recordHardwareEnter() {
    if (_pendingEnterActionSuppressions < 1) {
      _pendingEnterActionSuppressions = 1;
    }
    _pendingPerformedEnterText = _lastSentText;
  }

  void dispose() {
    _active = false;
    cancelDeferredTrailingBackspaceImeClear();
    invalidate();
  }

  bool _sawImeComposition = false;

  /// Raw user text of the latest composing update, so a commit that matches
  /// it (dictation, a long composition) is recognised as previewed by the IME.
  String? _composedPreviewText;
  bool _isProcessingEditingValue = false;
  bool _lastProcessedUserSelectionWasValid = false;
  bool _lastProcessedSelectionWasCollapsed = true;
  bool _trimLeadingSuggestionSpaceAfterDelete = false;
  bool _trimLeadingSwipeSpaceAfterBufferClear = false;
  bool _allowSplitLeadingTokenNormalization = false;
  bool _clearImeAfterNextTouchCursorMove = false;
  bool _hasPendingPromptOutputImeReset = false;
  Timer? _deferredTrailingBackspaceImeClearTimer;
  ({String baselineText, int baselineCursorOffset, String? deletedSuffixText})?
  _deferredTrailingBackspaceImeClear;
  int _pendingAndroidHardwareBackspaces = 0;
  ({bool raw, bool ctrl, bool alt, bool shift})? _activeAndroidImeBackspace;
  DateTime? _modifierChordResetTime;
  String? _pendingDeleteResetBaselineText;
  int? _pendingDeleteResetBaselineCursorOffset;
  String? _pendingDeleteResetDeletedSuffixText;
  String _lastSentText = '';
  bool _isFramingImeText = false;
  int _lastSentCursorOffset = 0;

  /// Graphemes at the end of the most recent computed delta's appended text
  /// that merely retype an unchanged trailing tail (see
  /// [terminalTrailingSuffixRewriteLimit]). They are not new user input, so
  /// the inserted-text review must not count them.
  int _retypedTrailingTailLength = 0;
  int _iosBackspaceRunwayLength = 0;
  ({bool ctrl, bool alt, bool shift})? _pendingComposingEnterModifiers;
  String? _pendingComposingEnterText;
  String? _pendingComposingEnterStalePrefix;
  int? _pendingComposingEnterRevision;
  bool _pendingComposingEnterMayBeInText = false;
  bool _acceptNextPendingComposingEnterCommit = false;
  TextEditingValue? _pendingComposingEnterFollowUp;
  String? _pendingPerformedEnterText;
  int _pendingEnterActionSuppressions = 0;
  int _latestEditingValueRevision = 0;
  TextEditingValue? _queuedEditingValue;
  void _notifyUserInput() {
    effects.onUserInput?.call();
  }

  bool get _shouldDeferTrailingBackspaceImeClear =>
      !options.isWeb && options.platform == TargetPlatform.iOS;

  bool get _shouldUseIosBackspaceRunway =>
      options.deleteDetection && _shouldDeferTrailingBackspaceImeClear;

  void cancelDeferredTrailingBackspaceImeClear() {
    _deferredTrailingBackspaceImeClearTimer?.cancel();
    _deferredTrailingBackspaceImeClearTimer = null;
    _deferredTrailingBackspaceImeClear = null;
  }

  void _scheduleDeferredTrailingBackspaceImeClear({
    required String baselineText,
    required int baselineCursorOffset,
    required String? deletedSuffixText,
  }) {
    cancelDeferredTrailingBackspaceImeClear();
    _deferredTrailingBackspaceImeClear = (
      baselineText: baselineText,
      baselineCursorOffset: baselineCursorOffset,
      deletedSuffixText: deletedSuffixText,
    );
    _deferredTrailingBackspaceImeClearTimer = schedule(
      terminalIosBackspaceRepeatSettleDelay,
      () {
        if (!_active) {
          return;
        }
        final pendingClear = _deferredTrailingBackspaceImeClear;
        if (pendingClear == null) {
          return;
        }
        clearImeBufferForFreshInput(
          deleteResetBaselineText: pendingClear.baselineText,
          deleteResetBaselineCursorOffset: pendingClear.baselineCursorOffset,
          deleteResetDeletedSuffixText: pendingClear.deletedSuffixText,
        );
        _sawImeComposition = false;
      },
    );
  }

  bool sendHardwareTerminalKey(
    TerminalKey key, {
    required bool ctrl,
    required bool alt,
    required bool shift,
    required bool meta,
    required bool hasShortcutModifier,
    TerminalKeyEventType type = TerminalKeyEventType.press,
  }) {
    final handled = key == TerminalKey.enter
        ? sendTerminalEnterInput(
            terminal,
            shiftActive: shift,
            altActive: alt,
            ctrlActive: ctrl,
            metaActive: meta,
            type: type,
          )
        : terminal.keyInput(
            key,
            ctrl: ctrl,
            alt: alt,
            shift: shift,
            meta: meta,
            type: type,
          );

    if (handled) {
      // Hardware Enter and control keys bypass the IME commit/reset path.
      _isFramingImeText = false;
      _notifyUserInput();
      _trackHandledHardwareCursorKey(
        key,
        hasShortcutModifier: hasShortcutModifier,
      );
    }

    return handled;
  }

  void handleAndroidImeBackspace(
    TerminalKeyEventType type, {
    required ({bool ctrl, bool alt, bool shift})? toolbarModifiers,
  }) {
    final activeBackspace = _activeAndroidImeBackspace;
    if (type == TerminalKeyEventType.repeat && activeBackspace != null) {
      if (activeBackspace.raw) {
        _isFramingImeText = false;
        _notifyUserInput();
        terminal.textInput('\x7f');
        _pendingAndroidHardwareBackspaces++;
      } else if (sendHardwareTerminalKey(
        TerminalKey.backspace,
        ctrl: activeBackspace.ctrl,
        alt: activeBackspace.alt,
        shift: activeBackspace.shift,
        meta: false,
        hasShortcutModifier: false,
        type: TerminalKeyEventType.repeat,
      )) {
        _pendingAndroidHardwareBackspaces++;
      }
      return;
    }
    if (type == TerminalKeyEventType.release && activeBackspace != null) {
      if (!activeBackspace.raw) {
        sendHardwareTerminalKey(
          TerminalKey.backspace,
          ctrl: activeBackspace.ctrl,
          alt: activeBackspace.alt,
          shift: activeBackspace.shift,
          meta: false,
          hasShortcutModifier: false,
          type: TerminalKeyEventType.release,
        );
      }
      _activeAndroidImeBackspace = null;
      return;
    }
    if (type != TerminalKeyEventType.press) {
      return;
    }

    final hasToolbarModifier =
        toolbarModifiers != null &&
        (toolbarModifiers.ctrl ||
            toolbarModifiers.alt ||
            toolbarModifiers.shift);
    if (!hasToolbarModifier) {
      _isFramingImeText = false;
      _activeAndroidImeBackspace = (
        raw: true,
        ctrl: false,
        alt: false,
        shift: false,
      );
      _notifyUserInput();
      // Some Android IMEs omit the editing-value deletion after emitting a
      // standard-HID Backspace. Send DEL immediately, bypassing Kitty mode,
      // and only use a later IME deletion to synchronize local state.
      terminal.textInput('\x7f');
      _pendingAndroidHardwareBackspaces++;
      return;
    }

    _activeAndroidImeBackspace = (
      raw: false,
      ctrl: toolbarModifiers.ctrl,
      alt: toolbarModifiers.alt,
      shift: toolbarModifiers.shift,
    );
    final handled = sendHardwareTerminalKey(
      TerminalKey.backspace,
      ctrl: toolbarModifiers.ctrl,
      alt: toolbarModifiers.alt,
      shift: toolbarModifiers.shift,
      meta: false,
      hasShortcutModifier: false,
    );
    if (!handled) {
      _activeAndroidImeBackspace = null;
      return;
    }
    _pendingAndroidHardwareBackspaces++;
    effects.consumeTerminalKeyModifiers?.call();
  }

  ({
    String currentText,
    int? cursorOffset,
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  })
  _synchronizeAndroidHardwareBackspace({
    required String currentText,
    required int? cursorOffset,
    required ({int deletedCount, String appendedText, int deleteCursorOffset})
    delta,
  }) {
    if (_pendingAndroidHardwareBackspaces == 0) {
      return (
        currentText: currentText,
        cursorOffset: cursorOffset,
        delta: delta,
      );
    }
    if (delta.deletedCount == 0 && delta.appendedText.isEmpty) {
      return (
        currentText: currentText,
        cursorOffset: cursorOffset,
        delta: delta,
      );
    }

    final previousGraphemes = _lastSentText.characters.toList(growable: true);
    final deletionEnd = _clampTextOffset(
      _lastSentCursorOffset,
      previousGraphemes.length,
    );
    final suppressedCount = _pendingAndroidHardwareBackspaces < deletionEnd
        ? _pendingAndroidHardwareBackspaces
        : deletionEnd;
    final deletionStart = _clampTextOffset(
      deletionEnd - suppressedCount,
      deletionEnd,
    );
    final deletedGraphemes = previousGraphemes.sublist(
      deletionStart,
      deletionEnd,
    );
    previousGraphemes.removeRange(deletionStart, deletionEnd);
    _lastSentText = previousGraphemes.join();
    _lastSentCursorOffset = deletionStart;
    _pendingAndroidHardwareBackspaces = 0;

    final currentGraphemes = currentText.characters.toList(growable: true);
    var normalizedCursorOffset = cursorOffset;
    if (delta.deletedCount == 0 &&
        deletionEnd <= currentGraphemes.length &&
        listEquals(
          currentGraphemes.sublist(deletionStart, deletionEnd),
          deletedGraphemes,
        )) {
      currentGraphemes.removeRange(deletionStart, deletionEnd);
      if (normalizedCursorOffset != null &&
          normalizedCursorOffset > deletionStart) {
        normalizedCursorOffset = _clampTextOffset(
          normalizedCursorOffset - suppressedCount,
          currentGraphemes.length,
        );
      }
    }
    final normalizedCurrentText = currentGraphemes.join();
    return (
      currentText: normalizedCurrentText,
      cursorOffset: normalizedCursorOffset,
      delta: _computeTextDelta(
        normalizedCurrentText,
        cursorOffsetHint: normalizedCursorOffset,
      ),
    );
  }

  void _trackHandledHardwareCursorKey(
    TerminalKey key, {
    required bool hasShortcutModifier,
  }) {
    if (hasShortcutModifier) {
      return;
    }

    final maxOffset = _textLengthInGraphemes(_lastSentText);
    switch (key) {
      case TerminalKey.arrowLeft:
        _lastSentCursorOffset = _clampTextOffset(
          _lastSentCursorOffset - 1,
          maxOffset,
        );
        return;
      case TerminalKey.arrowRight:
        _lastSentCursorOffset = _clampTextOffset(
          _lastSentCursorOffset + 1,
          maxOffset,
        );
        return;
      case TerminalKey.arrowUp:
      case TerminalKey.arrowDown:
        if (_lastSentText.isNotEmpty || _lastSentCursorOffset != 0) {
          _resetCommittedInputState();
        }
        return;
      default:
        return;
    }
  }

  void clearImeBufferForFreshInput({
    bool armModifierChordWindow = false,
    bool armSplitLeadingTokenNormalization = false,
    String? deleteResetBaselineText,
    int? deleteResetBaselineCursorOffset,
    String? deleteResetDeletedSuffixText,
    bool flushPlatformContext = false,
    bool armIosBackspaceRunway = false,
  }) {
    cancelDeferredTrailingBackspaceImeClear();
    if (flushPlatformContext && (effects.canSyncEditingState?.call() ?? true)) {
      // Reset the editing state in-place rather than closing/reopening
      // the input connection. Closing triggers a keyboard dismiss+reshow
      // flicker on iPad.
      _currentEditingState = initEditingState.copyWith();
      effects.onEditingState?.call(_currentEditingState);
    }
    _invalidatePendingEditingUpdates();
    _resetCommittedInputState(
      clearPendingDeleteResetBaseline: false,
      armIosBackspaceRunway: armIosBackspaceRunway,
    );
    _sawImeComposition = false;
    _hasPendingPromptOutputImeReset = false;
    if (deleteResetBaselineText != null &&
        deleteResetBaselineCursorOffset != null) {
      _pendingDeleteResetBaselineText = deleteResetBaselineText;
      _pendingDeleteResetBaselineCursorOffset = deleteResetBaselineCursorOffset;
      _pendingDeleteResetDeletedSuffixText = deleteResetDeletedSuffixText;
    } else {
      _clearPendingDeleteResetBaseline();
    }
    _trimLeadingSuggestionSpaceAfterDelete = true;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _allowSplitLeadingTokenNormalization = armSplitLeadingTokenNormalization;
    _modifierChordResetTime = armModifierChordWindow ? now() : null;
  }

  void resetImeCompletions() {
    clearImeBufferForFreshInput(
      flushPlatformContext: true,
      armSplitLeadingTokenNormalization: true,
    );
  }

  void handleExternalTerminalOutput() {
    if (options.readOnly) {
      return;
    }
    if (!_hasPendingPromptOutputImeReset) {
      return;
    }
    if (_sawImeComposition || _lastSentText.isNotEmpty) {
      return;
    }
    if (_extractInputText(_currentEditingState.text).isNotEmpty) {
      return;
    }
    final textBeforeCursor = effects.resolveTextBeforeCursor?.call();
    if (textBeforeCursor == null ||
        !_currentLineLooksLikePromptPrefix(textBeforeCursor)) {
      return;
    }
    clearImeBufferForFreshInput(
      flushPlatformContext: true,
      armSplitLeadingTokenNormalization: true,
    );
  }

  void _invalidatePendingEditingUpdates() {
    _latestEditingValueRevision++;
    _queuedEditingValue = null;
  }

  bool _editingValueShowsImeInteraction(TextEditingValue value) =>
      value.text != initEditingState.text ||
      value.selection != initEditingState.selection ||
      !value.composing.isCollapsed;
  TextInputConfiguration buildTextInputConfiguration() =>
      TextInputConfiguration(
        // Keep these explicit because terminal IME behavior is central here.
        // ignore: avoid_redundant_argument_values
        inputType: TextInputType.text,
        // ignore: avoid_redundant_argument_values
        autocorrect: false,
        // ignore: avoid_redundant_argument_values
        inputAction: TextInputAction.newline,
        keyboardAppearance: options.keyboardAppearance,
        // Enable suggestions so the IME offers dictation and adds spaces
        // between swiped words. Autocorrect remains disabled above so command
        // tokens like "ls" are not rewritten when accepting a space.
        // ignore: avoid_redundant_argument_values
        enableSuggestions: !options.sensitiveInput,
        obscureText: options.sensitiveInput,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        // Let the keyboard behave like a normal text field; voice input can
        // depend on this on third-party IMEs.
        // ignore: avoid_redundant_argument_values
        enableIMEPersonalizedLearning: !options.sensitiveInput,
      );
  void resetConnectionEditingState() {
    _isFramingImeText = false;
    _invalidatePendingEditingUpdates();
    _sawImeComposition = false;
    _lastProcessedUserSelectionWasValid = false;
    _lastProcessedSelectionWasCollapsed = true;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _allowSplitLeadingTokenNormalization = false;
    _hasPendingPromptOutputImeReset = false;
    _modifierChordResetTime = null;
    _clearPendingDeleteResetBaseline();
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    _iosBackspaceRunwayLength = 0;
    _clearPendingComposingEnterAction();
    _pendingPerformedEnterText = null;
    _pendingEnterActionSuppressions = 0;
    _pendingAndroidHardwareBackspaces = 0;
    _activeAndroidImeBackspace = null;
    _currentEditingState = initEditingState.copyWith();
  }

  TextEditingValue get initEditingState => options.deleteDetection
      ? const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(
            offset: _deleteDetectionMarker.length,
          ),
        )
      : TextEditingValue.empty;

  late TextEditingValue _currentEditingState = initEditingState.copyWith();

  int _editingPrefixLength(String text) {
    if (!options.deleteDetection) {
      return 0;
    }

    var prefixLength = 0;
    while (prefixLength < text.length &&
        prefixLength < _deleteDetectionMarker.length &&
        text.codeUnitAt(prefixLength) ==
            _deleteDetectionMarker.codeUnitAt(prefixLength)) {
      prefixLength++;
    }
    return prefixLength;
  }

  int _commonGraphemePrefixLength(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    int? maxLength,
  }) {
    final sharedLength = previousGraphemes.length < currentGraphemes.length
        ? previousGraphemes.length
        : currentGraphemes.length;
    final prefixLimit = maxLength == null || maxLength > sharedLength
        ? sharedLength
        : maxLength;
    var index = 0;
    while (index < prefixLimit &&
        previousGraphemes[index] == currentGraphemes[index]) {
      index++;
    }
    return index;
  }

  int _longestCommonCaseInsensitiveGraphemeSubsequenceLength(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    required int maxLength,
  }) {
    if (previousGraphemes.isEmpty || currentGraphemes.isEmpty) {
      return 0;
    }

    final currentPositionsByGrapheme = <String, List<int>>{};
    for (var index = 0; index < currentGraphemes.length; index++) {
      final normalizedCurrentGrapheme = currentGraphemes[index].toLowerCase();
      currentPositionsByGrapheme
          .putIfAbsent(normalizedCurrentGrapheme, () => <int>[])
          .add(index);
    }

    var hasLengthOneMatch = false;
    int? shortestLengthOneEndIndex;
    for (final previousGrapheme in previousGraphemes) {
      final positions =
          currentPositionsByGrapheme[previousGrapheme.toLowerCase()];
      if (positions == null || positions.isEmpty) {
        continue;
      }

      if (maxLength == 1) {
        return 1;
      }

      hasLengthOneMatch = true;
      if (shortestLengthOneEndIndex != null &&
          positions.last > shortestLengthOneEndIndex) {
        return 2;
      }

      final firstPosition = positions.first;
      if (shortestLengthOneEndIndex == null ||
          firstPosition < shortestLengthOneEndIndex) {
        shortestLengthOneEndIndex = firstPosition;
      }
    }

    return hasLengthOneMatch ? 1 : 0;
  }

  int _commonGraphemeSuffixLength(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    required int commonPrefixLength,
  }) {
    final previousRemainingLength =
        previousGraphemes.length - commonPrefixLength;
    final currentRemainingLength = currentGraphemes.length - commonPrefixLength;
    var index = 0;
    while (index < previousRemainingLength &&
        index < currentRemainingLength &&
        previousGraphemes[previousGraphemes.length - 1 - index] ==
            currentGraphemes[currentGraphemes.length - 1 - index]) {
      index++;
    }
    return index;
  }

  String _extractRawInputText(String text) =>
      text.substring(_editingPrefixLength(text));

  String _stripLeakedDeleteSentinelPrefix(String text) {
    if (!_shouldUseIosBackspaceRunway || text.isEmpty) {
      return text;
    }

    // iOS can replay hidden backspace runway sentinels with the next composed
    // text update; those sentinels must never reach the terminal stream.
    final prefixLength = _leadingIosBackspaceRunwaySentinelLength(text);
    if (prefixLength == 0) {
      return text;
    }
    if (_iosBackspaceRunwayLength == 0 &&
        prefixLength < terminalIosBackspaceRepeatRunwayRefillThreshold) {
      return text;
    }
    return text.substring(prefixLength);
  }

  String _extractInputText(String text) {
    final extractedText = _stripLeakedDeleteSentinelPrefix(
      _extractRawInputText(text),
    );
    final sanitizedText = extractedText.replaceFirst(
      _leadingSwipeNewlineArtifactPattern,
      '',
    );
    if ((_sawImeComposition ||
            _trimLeadingSuggestionSpaceAfterDelete ||
            _trimLeadingSwipeSpaceAfterBufferClear) &&
        sanitizedText.startsWith(' ') &&
        !sanitizedText.startsWith('  ') &&
        sanitizedText.trimLeft().isNotEmpty &&
        _shouldTrimLeadingSwipeSpace()) {
      return sanitizedText.substring(1);
    }
    return sanitizedText;
  }

  bool _shouldTrimLeadingSwipeSpace() {
    if (_trimLeadingSwipeSpaceAfterBufferClear) {
      return true;
    }

    final textBeforeCursor = effects.resolveTextBeforeCursor?.call();
    if (textBeforeCursor == null || textBeforeCursor.isEmpty) {
      return true;
    }

    final trailingCodeUnit = textBeforeCursor.codeUnitAt(
      textBeforeCursor.length - 1,
    );
    if (trailingCodeUnit == 0x20 ||
        trailingCodeUnit == 0x09 ||
        trailingCodeUnit == 0x0A ||
        trailingCodeUnit == 0x0D) {
      return true;
    }

    return _currentLineLooksLikePromptPrefix(textBeforeCursor);
  }

  bool _currentLineLooksLikePromptPrefix(String textBeforeCursor) {
    var index = textBeforeCursor.length - 1;
    while (index >= 0) {
      final codeUnit = textBeforeCursor.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return true;
      }
      if (!_isPromptWhitespaceCodeUnit(codeUnit)) {
        break;
      }
      index--;
    }

    if (index < 0) {
      return true;
    }

    var visibleCodeUnitCount = 0;
    while (index >= 0) {
      final codeUnit = textBeforeCursor.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        break;
      }
      if (!_isPromptWhitespaceCodeUnit(codeUnit)) {
        visibleCodeUnitCount++;
        if (visibleCodeUnitCount > 4) {
          return false;
        }
        if (_isAsciiLetterOrDigitCodeUnit(codeUnit)) {
          return false;
        }
      }
      index--;
    }

    return true;
  }

  int _sendInputDelta(
    String currentText,
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta, {
    ({bool ctrl, bool alt, bool shift})? enterModifiers,
    bool beforeEnter = false,
  }) {
    _moveTerminalCursorTo(delta.deleteCursorOffset);

    final deletedCount = delta.deletedCount;
    if (deletedCount > 0 && delta.appendedText.isEmpty) {
      // End framing even when the IME buffer reset is deferred on iOS.
      _isFramingImeText = false;
    }

    for (var i = 0; i < deletedCount; i++) {
      terminal.keyInput(TerminalKey.backspace);
    }

    final appendedText = delta.appendedText;
    final retainedPrefixLength = delta.deleteCursorOffset - deletedCount;
    final newlineCount = _sendAppendedTerminalInput(
      appendedText,
      precedingGrapheme: retainedPrefixLength > 0
          ? _lastSentText.characters.elementAt(retainedPrefixLength - 1)
          : null,
      enterModifiers: enterModifiers,
      beforeEnter: beforeEnter,
    );

    _lastSentText = currentText;
    _lastSentCursorOffset =
        delta.deleteCursorOffset -
        deletedCount +
        appendedText.characters.length;
    return newlineCount;
  }

  int _terminalNewlineSequenceCount(String text) {
    var count = 0;
    var index = 0;
    while (index < text.length) {
      final codeUnit = text.codeUnitAt(index);
      if (codeUnit == 0x0D) {
        count++;
        index += index + 1 < text.length && text.codeUnitAt(index + 1) == 0x0A
            ? 2
            : 1;
      } else {
        if (codeUnit == 0x0A) {
          count++;
        }
        index++;
      }
    }
    return count;
  }

  int _sendAppendedTerminalInput(
    String text, {
    String? precedingGrapheme,
    ({bool ctrl, bool alt, bool shift})? enterModifiers,
    bool beforeEnter = false,
  }) {
    if (text.isEmpty) {
      return 0;
    }

    // Nothing visible before a newline on the line means it is a Return
    // press, not a paragraph break inside a block.
    final blockStart = precedingGrapheme == null
        ? _leadingReturnRunLength(text)
        : 0;
    final activeModifiers =
        enterModifiers ?? effects.resolveTerminalKeyModifiers?.call();
    final hasActiveEnterModifier =
        activeModifiers != null &&
        (activeModifiers.ctrl || activeModifiers.alt || activeModifiers.shift);
    // A one-shot toolbar modifier belongs to the next Enter, so modified
    // newlines stay on the key path.
    final blockEnd = hasActiveEnterModifier
        ? 0
        : _embeddedNewlineBlockEnd(text, start: blockStart);
    final modifierNewlineIndex = enterModifiers == null
        ? -1
        : _terminalNewlineSequenceCount(text) -
              (blockEnd > 0
                  ? _terminalNewlineSequenceCount(
                      text.substring(blockStart, blockEnd),
                    )
                  : 0) -
              1;
    var newlineCount = 0;
    var segmentStart = 0;
    var index = 0;
    while (index < text.length) {
      if (blockEnd > 0 && index == blockStart) {
        // Dictation commits several paragraphs in one editing update. Those
        // newlines were never Return presses: a bracketed-paste application
        // decides what a pasted line break means (agent composers insert a
        // line break; shells keep the block on the command line), exactly as
        // it does for a clipboard paste. Splitting them into separate pastes
        // with Enter in between submits the first paragraph on its own or
        // drops it. Only newlines after the last visible character remain
        // Return.
        _sendTerminalTextSegment(
          text.substring(blockStart, blockEnd),
          precedingGrapheme: blockStart == 0 ? precedingGrapheme : null,
          beforeEnter: beforeEnter || blockEnd < text.length,
          embedsNewlines: true,
        );
        index = blockEnd;
        segmentStart = blockEnd;
        continue;
      }
      final codeUnit = text.codeUnitAt(index);
      final newlineLength = codeUnit == 0x0D
          ? (index + 1 < text.length && text.codeUnitAt(index + 1) == 0x0A
                ? 2
                : 1)
          : codeUnit == 0x0A
          ? 1
          : 0;
      if (newlineLength == 0) {
        index++;
        continue;
      }

      _sendTerminalTextSegment(
        text.substring(segmentStart, index),
        precedingGrapheme: segmentStart == 0 ? precedingGrapheme : null,
        beforeEnter: true,
      );
      _sendTerminalEnterFromTextInput(
        modifiers: newlineCount == modifierNewlineIndex ? enterModifiers : null,
      );
      newlineCount++;
      index += newlineLength;
      segmentStart = index;
    }

    _sendTerminalTextSegment(
      text.substring(segmentStart),
      precedingGrapheme: segmentStart == 0 ? precedingGrapheme : null,
      beforeEnter: beforeEnter,
    );
    return newlineCount;
  }

  /// Length of the leading whitespace of [text] up to and including the last
  /// newline that precedes its first visible character.
  int _leadingReturnRunLength(String text) {
    var length = 0;
    var index = 0;
    while (index < text.length &&
        _isPromptWhitespaceCodeUnit(text.codeUnitAt(index))) {
      if (_isNewlineCodeUnit(text.codeUnitAt(index))) {
        length = index + 1;
      }
      index++;
    }
    return length;
  }

  /// End index of the block of [text] from [start] that ends at its last
  /// visible character and holds newlines in between, when that block can
  /// travel as one bracketed paste. Returns 0 when there is no such newline
  /// or the block must stay on the key input path.
  int _embeddedNewlineBlockEnd(String text, {required int start}) {
    if (!terminal.bracketedPasteMode) {
      return 0;
    }
    var end = text.length;
    while (end > start &&
        _isPromptWhitespaceCodeUnit(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (!_newlinePattern.hasMatch(text.substring(end))) {
      // Trailing spaces without a Return stay inside the block.
      end = text.length;
    }
    final block = text.substring(start, end);
    if (!_newlinePattern.hasMatch(block) ||
        _terminalTextControlPattern.hasMatch(
          block.replaceAll(_newlinePattern, ''),
        ) ||
        _applyTerminalTextInputModifiers(block) != block) {
      return 0;
    }
    return end;
  }

  void _sendTerminalTextSegment(
    String text, {
    String? precedingGrapheme,
    bool beforeEnter = false,
    bool embedsNewlines = false,
  }) {
    if (text.isEmpty) {
      return;
    }
    final input = _applyTerminalTextInputModifiers(text);
    final controlCheckText = embedsNewlines
        ? text.replaceAll(_newlinePattern, '')
        : text;
    if (terminal.bracketedPasteMode &&
        input == text &&
        (_isFramingImeText || beforeEnter || text.runes.length > 1) &&
        !_terminalTextControlPattern.hasMatch(controlCheckText)) {
      // IMEs commit whole words at once. Without explicit batch boundaries,
      // prompt TUIs such as Codex infer a paste from the rapid characters and
      // absorb the following Return as a pasted newline. Keep Enter outside
      // the batch, and keep shortcuts/control input on the key input path.
      // Even a single character can be held by the TUI's paste detector when
      // an IME commits it together with Return.
      // Keep framing later commits too: a separately typed question mark
      // after a swiped word can restart paste detection before Return.
      _isFramingImeText = true;
      var pasteText = text;
      if ((text.startsWith('.') ||
              text.startsWith('/') ||
              text.startsWith('~')) &&
          precedingGrapheme != null &&
          precedingGrapheme.length == 1 &&
          (_isAsciiLetterOrDigitCodeUnit(precedingGrapheme.codeUnitAt(0)) ||
              precedingGrapheme == '_')) {
        // Pi treats pastes starting with '.', '/' or '~' as file paths and
        // inserts a space after a word character. IME edits are literal text,
        // not file drops. Retype one known preceding character inside the
        // same paste so double-space punctuation stays "word. ", not
        // "word . ". Keep the batch boundary for other TUIs' Enter handling.
        terminal.keyInput(TerminalKey.backspace);
        pasteText = '$precedingGrapheme$text';
      }
      terminal.paste(pasteText);
    } else {
      _isFramingImeText = false;
      terminal.textInput(input);
    }
  }

  void _sendTerminalEnterFromTextInput({
    ({bool ctrl, bool alt, bool shift})? modifiers,
  }) {
    _isFramingImeText = false;
    final effectiveModifiers =
        modifiers ?? effects.resolveTerminalKeyModifiers?.call();
    sendTerminalEnterInput(
      terminal,
      shiftActive: effectiveModifiers?.shift ?? false,
      altActive: effectiveModifiers?.alt ?? false,
      ctrlActive: effectiveModifiers?.ctrl ?? false,
    );
    if (modifiers == null) {
      effects.consumeTerminalKeyModifiers?.call();
    }
  }

  void _resetCommittedInputState({
    int pendingEnterSuppressions = 0,
    bool clearPendingPerformedEnterText = true,
    bool clearPendingDeleteResetBaseline = true,
    bool armIosBackspaceRunway = false,
  }) {
    _isFramingImeText = false;
    cancelDeferredTrailingBackspaceImeClear();
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    // A composition abandoned by a reset must not vouch for a later commit.
    _composedPreviewText = null;
    _clearPendingComposingEnterAction();
    if (clearPendingPerformedEnterText) {
      _pendingPerformedEnterText = null;
    }
    _pendingEnterActionSuppressions = pendingEnterSuppressions;
    _pendingAndroidHardwareBackspaces = 0;
    _trimLeadingSuggestionSpaceAfterDelete = false;
    _trimLeadingSwipeSpaceAfterBufferClear = false;
    _clearImeAfterNextTouchCursorMove = false;
    _allowSplitLeadingTokenNormalization = false;
    _modifierChordResetTime = null;
    if (clearPendingDeleteResetBaseline) {
      _clearPendingDeleteResetBaseline();
    }
    if (armIosBackspaceRunway && _shouldUseIosBackspaceRunway) {
      _syncEditingStateWithIosBackspaceRunway();
    } else {
      _syncEditingStateWithUserText('');
    }
  }

  void _clearPendingDeleteResetBaseline() {
    _pendingDeleteResetBaselineText = null;
    _pendingDeleteResetBaselineCursorOffset = null;
    _pendingDeleteResetDeletedSuffixText = null;
  }

  ({
    String baselineText,
    int baselineCursorOffset,
    String? deletedSuffixText,
    List<String> baselineGraphemes,
    int tokenStart,
    String baselineToken,
  })?
  _deleteResetBaselineState() {
    final baselineText = _pendingDeleteResetBaselineText;
    final baselineCursorOffset = _pendingDeleteResetBaselineCursorOffset;
    final deletedSuffixText = _pendingDeleteResetDeletedSuffixText;
    if (baselineText == null || baselineCursorOffset == null) {
      return null;
    }

    final baselineGraphemes = baselineText.characters.toList(growable: false);
    var trimmedBaselineLength = baselineGraphemes.length;
    while (trimmedBaselineLength > 0 &&
        _isWhitespaceGrapheme(baselineGraphemes[trimmedBaselineLength - 1])) {
      trimmedBaselineLength--;
    }
    if (trimmedBaselineLength == 0) {
      return null;
    }

    var tokenStart = trimmedBaselineLength;
    while (tokenStart > 0 &&
        !_isWhitespaceGrapheme(baselineGraphemes[tokenStart - 1])) {
      tokenStart--;
    }

    return (
      baselineText: baselineText,
      baselineCursorOffset: baselineCursorOffset,
      deletedSuffixText: deletedSuffixText,
      baselineGraphemes: baselineGraphemes,
      tokenStart: tokenStart,
      baselineToken: baselineGraphemes
          .sublist(tokenStart, trimmedBaselineLength)
          .join(),
    );
  }

  bool _isWhitespaceGrapheme(String grapheme) =>
      grapheme == ' ' ||
      grapheme == '\t' ||
      grapheme == '\n' ||
      grapheme == '\r';

  ({
    int firstTokenStart,
    int firstTokenEnd,
    List<String> firstTokenGraphemes,
    List<String> trailingGraphemes,
  })?
  _leadingTokenInfo(List<String> graphemes) {
    var firstTokenStart = 0;
    while (firstTokenStart < graphemes.length &&
        _isWhitespaceGrapheme(graphemes[firstTokenStart])) {
      firstTokenStart++;
    }

    var firstTokenEnd = firstTokenStart;
    while (firstTokenEnd < graphemes.length &&
        !_isWhitespaceGrapheme(graphemes[firstTokenEnd])) {
      firstTokenEnd++;
    }

    if (firstTokenEnd == firstTokenStart) {
      return null;
    }

    return (
      firstTokenStart: firstTokenStart,
      firstTokenEnd: firstTokenEnd,
      firstTokenGraphemes: graphemes.sublist(firstTokenStart, firstTokenEnd),
      trailingGraphemes: graphemes.sublist(firstTokenEnd),
    );
  }

  bool _tokenLooksRelatedToDeleteResetReplacement({
    required String currentToken,
    required String baselineToken,
    String? deletedSuffixText,
  }) {
    final currentTokenGraphemes = currentToken.characters.toList(
      growable: false,
    );
    if (currentTokenGraphemes.isEmpty) {
      return false;
    }

    final relatedReplacementTokenGraphemes = deletedSuffixText == null
        ? baselineToken.characters.toList(growable: false)
        : (baselineToken + deletedSuffixText).characters.toList(
            growable: false,
          );
    final replacementRelationThreshold =
        relatedReplacementTokenGraphemes.length < currentTokenGraphemes.length
        ? relatedReplacementTokenGraphemes.length
        : currentTokenGraphemes.length;
    final requiredReplacementRelationLength = replacementRelationThreshold < 2
        ? replacementRelationThreshold
        : 2;
    return _longestCommonCaseInsensitiveGraphemeSubsequenceLength(
          relatedReplacementTokenGraphemes,
          currentTokenGraphemes,
          maxLength: requiredReplacementRelationLength,
        ) >=
        requiredReplacementRelationLength;
  }

  ({String currentText, int? cursorOffset})?
  _normalizeDeleteResetLeadingFragment(
    String currentText, {
    int? cursorOffsetHint,
  }) {
    if (!_trimLeadingSuggestionSpaceAfterDelete || currentText.isEmpty) {
      return null;
    }

    final baselineState = _deleteResetBaselineState();
    if (baselineState == null) {
      return null;
    }

    final deletedSuffixText = baselineState.deletedSuffixText;
    if (deletedSuffixText == null || deletedSuffixText.characters.length < 2) {
      return null;
    }

    final currentGraphemes = currentText.characters.toList(growable: false);
    final tokenInfo = _leadingTokenInfo(currentGraphemes);
    if (tokenInfo == null ||
        tokenInfo.firstTokenGraphemes.length != 1 ||
        tokenInfo.trailingGraphemes.isEmpty ||
        !tokenInfo.trailingGraphemes.any(
          (grapheme) => !_isWhitespaceGrapheme(grapheme),
        )) {
      return null;
    }

    final firstToken = tokenInfo.firstTokenGraphemes.join();
    if (_tokenLooksRelatedToDeleteResetReplacement(
      currentToken: firstToken,
      baselineToken: baselineState.baselineToken,
      deletedSuffixText: deletedSuffixText,
    )) {
      return null;
    }

    final removedGraphemeCount = tokenInfo.firstTokenEnd;
    return (
      currentText: tokenInfo.trailingGraphemes.join(),
      cursorOffset: cursorOffsetHint == null
          ? null
          : cursorOffsetHint <= removedGraphemeCount
          ? 0
          : cursorOffsetHint - removedGraphemeCount,
    );
  }

  ({
    String previousText,
    int previousCursorOffset,
    String currentText,
    int? cursorOffset,
  })?
  _resolveDeleteResetContinuation(String currentText, {int? cursorOffsetHint}) {
    final baselineState = _deleteResetBaselineState();
    if (baselineState == null ||
        !_trimLeadingSuggestionSpaceAfterDelete ||
        currentText.isEmpty) {
      return null;
    }
    final baselineText = baselineState.baselineText;
    final baselineCursorOffset = baselineState.baselineCursorOffset;
    final deletedSuffixText = baselineState.deletedSuffixText;
    final baselineGraphemes = baselineState.baselineGraphemes;
    final tokenStart = baselineState.tokenStart;
    final baselineToken = baselineState.baselineToken;

    final currentGraphemes = currentText.characters.toList(growable: false);
    final hasLeadingReplacementSeparator =
        currentGraphemes.length > 1 &&
        _isWhitespaceGrapheme(currentGraphemes.first) &&
        !_isWhitespaceGrapheme(currentGraphemes[1]);
    final hasTrailingReplacementSeparator =
        currentGraphemes.isNotEmpty &&
        _isWhitespaceGrapheme(currentGraphemes.last);
    if (currentGraphemes.isEmpty ||
        (!hasLeadingReplacementSeparator && !hasTrailingReplacementSeparator)) {
      return null;
    }
    var mergedCurrentText = currentText;
    var mergedCursorOffsetHint = cursorOffsetHint;
    if (hasLeadingReplacementSeparator) {
      // After a delete-reset, the IME can prepend a separator to the
      // replacement token even though we're already replacing the current word.
      // Trim that separator before merging with the preserved baseline.
      mergedCurrentText = currentGraphemes.sublist(1).join();
      if (mergedCursorOffsetHint != null && mergedCursorOffsetHint > 0) {
        mergedCursorOffsetHint--;
      }
    }

    final mergedCurrentTokenGraphemes = mergedCurrentText.characters.toList(
      growable: false,
    );
    final mergedTokenInfo = _leadingTokenInfo(mergedCurrentTokenGraphemes);
    if (mergedTokenInfo == null) {
      return null;
    }
    final mergedCurrentToken = mergedTokenInfo.firstTokenGraphemes.join();
    final replacementLooksRelated = _tokenLooksRelatedToDeleteResetReplacement(
      currentToken: mergedCurrentToken,
      baselineToken: baselineToken,
      deletedSuffixText: deletedSuffixText,
    );

    final shouldAppendToBaseline =
        hasLeadingReplacementSeparator &&
        deletedSuffixText != null &&
        deletedSuffixText.isNotEmpty &&
        mergedCurrentToken.startsWith(deletedSuffixText);
    final shouldReplaceCurrentToken =
        !shouldAppendToBaseline &&
        ((hasTrailingReplacementSeparator && replacementLooksRelated) ||
            mergedCurrentToken.startsWith(baselineToken));
    if (!shouldReplaceCurrentToken && !shouldAppendToBaseline) {
      return null;
    }
    final mergedText = shouldReplaceCurrentToken
        ? baselineGraphemes.sublist(0, tokenStart).join() + mergedCurrentText
        : baselineText + mergedCurrentText;
    return (
      previousText: baselineText,
      previousCursorOffset: baselineCursorOffset,
      currentText: mergedText,
      cursorOffset: mergedCursorOffsetHint == null
          ? null
          : (shouldReplaceCurrentToken ? tokenStart : baselineCursorOffset) +
                mergedCursorOffsetHint,
    );
  }

  ({String? currentText, bool strippedPendingEnter, bool ignored})
  _normalizePendingPerformedEnterText(String currentText) {
    final pendingPerformedEnterText = _pendingPerformedEnterText;
    if (pendingPerformedEnterText == null) {
      return (
        currentText: currentText,
        strippedPendingEnter: false,
        ignored: false,
      );
    }

    if (currentText.isEmpty || currentText == pendingPerformedEnterText) {
      return (currentText: null, strippedPendingEnter: false, ignored: true);
    }

    for (final newlineSequence in _enterCommitNewlineSequences) {
      final prefix = '$pendingPerformedEnterText$newlineSequence';
      if (currentText == prefix) {
        _pendingPerformedEnterText = null;
        return (currentText: null, strippedPendingEnter: false, ignored: false);
      }
      if (currentText.startsWith(prefix)) {
        _pendingPerformedEnterText = null;
        return (
          currentText: currentText.substring(prefix.length),
          strippedPendingEnter: true,
          ignored: false,
        );
      }
    }

    _pendingPerformedEnterText = null;
    return (
      currentText: currentText,
      strippedPendingEnter: false,
      ignored: false,
    );
  }

  String _trailingToken(String text) {
    final graphemes = text.characters.toList(growable: false);
    var tokenEnd = graphemes.length;
    while (tokenEnd > 0 && _isWhitespaceGrapheme(graphemes[tokenEnd - 1])) {
      tokenEnd--;
    }
    if (tokenEnd == 0) {
      return '';
    }

    var tokenStart = tokenEnd;
    while (tokenStart > 0 &&
        !_isWhitespaceGrapheme(graphemes[tokenStart - 1])) {
      tokenStart--;
    }
    return graphemes.sublist(tokenStart, tokenEnd).join();
  }

  ({String currentText, int? cursorOffset})? _normalizeSplitLeadingToken(
    String currentText, {
    int? cursorOffsetHint,
  }) {
    if (!_allowSplitLeadingTokenNormalization ||
        _lastSentText.isEmpty ||
        !_splitLeadingTokenCandidatePattern.hasMatch(currentText)) {
      return null;
    }

    final previousTrailingToken = _trailingToken(_lastSentText);
    if (previousTrailingToken.characters.length < 2) {
      return null;
    }

    final currentGraphemes = currentText.characters.toList(growable: false);
    final currentTextLength = currentGraphemes.length;
    final previousTextLength = _textLengthInGraphemes(_lastSentText);
    if (_lastSentCursorOffset != previousTextLength ||
        cursorOffsetHint == null ||
        cursorOffsetHint != currentTextLength) {
      return null;
    }
    final tokenInfo = _leadingTokenInfo(currentGraphemes);
    if (tokenInfo == null ||
        tokenInfo.firstTokenGraphemes.length != 1 ||
        tokenInfo.trailingGraphemes.isEmpty) {
      return null;
    }

    var separatorLength = 0;
    while (separatorLength < tokenInfo.trailingGraphemes.length &&
        _isWhitespaceGrapheme(tokenInfo.trailingGraphemes[separatorLength])) {
      separatorLength++;
    }
    if (separatorLength == 0 ||
        separatorLength == tokenInfo.trailingGraphemes.length) {
      return null;
    }

    var nextTokenEnd = separatorLength;
    while (nextTokenEnd < tokenInfo.trailingGraphemes.length &&
        !_isWhitespaceGrapheme(tokenInfo.trailingGraphemes[nextTokenEnd])) {
      nextTokenEnd++;
    }
    if (nextTokenEnd == separatorLength) {
      return null;
    }

    final mergedLeadingToken =
        tokenInfo.firstTokenGraphemes.join() +
        tokenInfo.trailingGraphemes
            .sublist(separatorLength, nextTokenEnd)
            .join();
    final continuesPreviousTrailingToken =
        mergedLeadingToken.startsWith(previousTrailingToken) ||
        previousTrailingToken.startsWith(mergedLeadingToken);
    if (!continuesPreviousTrailingToken) {
      return null;
    }

    _allowSplitLeadingTokenNormalization = false;
    final separatorStart = tokenInfo.firstTokenEnd;
    final separatorEnd = separatorStart + separatorLength;
    final leadingPrefix = currentGraphemes
        .sublist(0, tokenInfo.firstTokenStart)
        .join();
    final normalizedCursorOffset = cursorOffsetHint <= separatorStart
        ? cursorOffsetHint
        : cursorOffsetHint <= separatorEnd
        ? separatorStart
        : cursorOffsetHint - separatorLength;
    return (
      currentText:
          leadingPrefix +
          tokenInfo.firstTokenGraphemes.join() +
          tokenInfo.trailingGraphemes.sublist(separatorLength).join(),
      cursorOffset: normalizedCursorOffset,
    );
  }

  int _textLengthInGraphemes(String text) => text.characters.length;

  bool _clearImeForPendingTouchCursorMove(
    TextEditingValue value,
    String currentText,
  ) {
    if (!_clearImeAfterNextTouchCursorMove || currentText != _lastSentText) {
      return false;
    }

    final targetCursorOffset = _collapsedSelectionCursorOffset(
      currentText,
      value,
    );
    if (targetCursorOffset == null ||
        targetCursorOffset == _lastSentCursorOffset) {
      return false;
    }

    _notifyUserInput();
    _moveTerminalCursorTo(targetCursorOffset);
    _clearImeAfterNextTouchCursorMove = false;
    clearImeBufferForFreshInput();
    return true;
  }

  bool _sendSingleBackspaceForPendingTouchDeletion({
    required ({int deletedCount, String appendedText, int deleteCursorOffset})
    delta,
  }) {
    if (!_clearImeAfterNextTouchCursorMove ||
        delta.deletedCount == 0 ||
        delta.appendedText.isNotEmpty) {
      return false;
    }

    _notifyUserInput();
    terminal.keyInput(TerminalKey.backspace);
    _clearImeAfterNextTouchCursorMove = false;
    clearImeBufferForFreshInput();
    return true;
  }

  int _graphemeOffsetForCodeUnitOffset(String text, int codeUnitOffset) => text
      .substring(0, _clampTextOffset(codeUnitOffset, text.length))
      .characters
      .length;

  TextSelection? _userSelectionForEditingValue(
    String userText,
    TextEditingValue value,
  ) {
    final rawPrefixLength = _editingPrefixLength(value.text);
    final rawUserText = _extractRawInputText(value.text);
    final trimmedLeadingCharacters = rawUserText.length - userText.length;
    return _normalizeSelectionForUserText(
      selection: value.selection,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: userText.length,
    );
  }

  int? _collapsedSelectionCursorOffset(
    String userText,
    TextEditingValue value,
  ) {
    final userSelection = _userSelectionForEditingValue(userText, value);
    if (userSelection == null || !userSelection.isCollapsed) {
      return null;
    }
    return _graphemeOffsetForCodeUnitOffset(
      userText,
      userSelection.extentOffset,
    );
  }

  void _moveTerminalCursorTo(int targetOffset) {
    final maxOffset = _textLengthInGraphemes(_lastSentText);
    final clampedTargetOffset = _clampTextOffset(targetOffset, maxOffset);
    final currentOffset = _lastSentCursorOffset;
    final isCurrentOffsetValid =
        currentOffset >= 0 && currentOffset <= maxOffset;
    if (!isCurrentOffsetValid) {
      _lastSentCursorOffset = clampedTargetOffset;
      return;
    }

    if (clampedTargetOffset == currentOffset) {
      return;
    }

    final key = clampedTargetOffset < currentOffset
        ? TerminalKey.arrowLeft
        : TerminalKey.arrowRight;
    final moveCount = (clampedTargetOffset - currentOffset).abs();
    for (var index = 0; index < moveCount; index++) {
      terminal.keyInput(key);
    }
    _lastSentCursorOffset = clampedTargetOffset;
  }

  ({int deletedCount, String appendedText, int deleteCursorOffset})
  _computeTextDelta(
    String currentText, {
    int? cursorOffsetHint,
    String? previousTextOverride,
    int? lastCursorOffsetOverride,
  }) {
    final previousText = previousTextOverride ?? _lastSentText;
    final lastCursorOffset = lastCursorOffsetOverride ?? _lastSentCursorOffset;
    _retypedTrailingTailLength = 0;
    final previousGraphemes = previousText.characters.toList(growable: false);
    final currentGraphemes = currentText.characters.toList(growable: false);
    final defaultDelta = _computeTextDeltaCandidate(
      previousGraphemes,
      currentGraphemes,
    );
    if (cursorOffsetHint == null) {
      return defaultDelta;
    }

    final anchoredPrefixLimit = lastCursorOffset < cursorOffsetHint
        ? lastCursorOffset
        : cursorOffsetHint;
    final anchoredDelta = _computeTextDeltaCandidate(
      previousGraphemes,
      currentGraphemes,
      maxCommonPrefixLength: anchoredPrefixLimit,
    );
    final preferredDelta = _selectPreferredTextDelta(
      defaultDelta: defaultDelta,
      anchoredDelta: anchoredDelta,
      cursorOffsetHint: cursorOffsetHint,
      lastCursorOffset: lastCursorOffset,
    );
    if (!_shouldRewriteTrailingSuffix(
      preferredDelta,
      previousGraphemes: previousGraphemes,
      currentLength: currentGraphemes.length,
      cursorOffsetHint: cursorOffsetHint,
      lastCursorOffset: lastCursorOffset,
    )) {
      return preferredDelta;
    }
    _retypedTrailingTailLength =
        previousGraphemes.length - preferredDelta.deleteCursorOffset;
    // The IME edited text just before an unchanged trailing tail while the
    // caret stayed at the end (e.g. Gboard or iOS double-space turning "word "
    // into "word. "). Sending arrow keys around that tail is fragile: prompts
    // and TUIs that ignore cursor movement end up with the tail dropped or
    // misplaced ("word.next"). Retyping the short tail keeps the terminal
    // cursor at the end of the line using only backspaces and text.
    return _computeTextDeltaCandidate(
      previousGraphemes,
      currentGraphemes,
      rewriteCommonSuffix: true,
    );
  }

  bool _shouldRewriteTrailingSuffix(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta, {
    required List<String> previousGraphemes,
    required int currentLength,
    required int cursorOffsetHint,
    required int lastCursorOffset,
  }) {
    final previousLength = previousGraphemes.length;
    if (cursorOffsetHint != currentLength ||
        lastCursorOffset != previousLength) {
      return false;
    }
    if (delta.appendedText.isEmpty) {
      return false;
    }
    final commonSuffixLength = previousLength - delta.deleteCursorOffset;
    if (commonSuffixLength <= 0 ||
        commonSuffixLength > terminalTrailingSuffixRewriteLimit) {
      return false;
    }
    // Retyping control input would repeat an action rather than restore text
    // (a newline re-sends Enter, a tab reruns completion); keep the
    // cursor-move path for any control tail.
    final tail = previousGraphemes.sublist(delta.deleteCursorOffset).join();
    return !_terminalTextControlPattern.hasMatch(tail);
  }

  ({int deletedCount, String appendedText, int deleteCursorOffset})
  _computeTextDeltaCandidate(
    List<String> previousGraphemes,
    List<String> currentGraphemes, {
    int? maxCommonPrefixLength,
    bool rewriteCommonSuffix = false,
  }) {
    final commonPrefix = _commonGraphemePrefixLength(
      previousGraphemes,
      currentGraphemes,
      maxLength: maxCommonPrefixLength,
    );
    final commonSuffix = rewriteCommonSuffix
        ? 0
        : _commonGraphemeSuffixLength(
            previousGraphemes,
            currentGraphemes,
            commonPrefixLength: commonPrefix,
          );
    final deleteCursorOffset = previousGraphemes.length - commonSuffix;
    return (
      deletedCount: previousGraphemes.length - commonPrefix - commonSuffix,
      appendedText: currentGraphemes
          .sublist(commonPrefix, currentGraphemes.length - commonSuffix)
          .join(),
      deleteCursorOffset: deleteCursorOffset,
    );
  }

  int _deltaPostEditCursorOffset(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) =>
      delta.deleteCursorOffset -
      delta.deletedCount +
      delta.appendedText.characters.length;

  String _applyTerminalTextInputModifiers(String text) {
    final applyModifiers = effects.applyTerminalTextInputModifiers;
    if (applyModifiers == null) {
      return text;
    }

    final normalizedText = text == '\n' ? '\r' : text;
    return applyModifiers(normalizedText);
  }

  String _lastGrapheme(String text) => text.characters.last;

  int _deltaCursorScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
    int cursorOffsetHint,
  ) => (_deltaPostEditCursorOffset(delta) - cursorOffsetHint).abs();

  int _deltaMovementScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
    int lastCursorOffset,
  ) => (delta.deleteCursorOffset - lastCursorOffset).abs();

  int _deltaRewriteScore(
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) => delta.deletedCount + delta.appendedText.characters.length;

  ({int deletedCount, String appendedText, int deleteCursorOffset})
  _selectPreferredTextDelta({
    required ({int deletedCount, String appendedText, int deleteCursorOffset})
    defaultDelta,
    required ({int deletedCount, String appendedText, int deleteCursorOffset})
    anchoredDelta,
    required int cursorOffsetHint,
    required int lastCursorOffset,
  }) {
    final defaultCursorScore = _deltaCursorScore(
      defaultDelta,
      cursorOffsetHint,
    );
    final anchoredCursorScore = _deltaCursorScore(
      anchoredDelta,
      cursorOffsetHint,
    );
    if (anchoredCursorScore != defaultCursorScore) {
      return anchoredCursorScore < defaultCursorScore
          ? anchoredDelta
          : defaultDelta;
    }

    final defaultMovementScore = _deltaMovementScore(
      defaultDelta,
      lastCursorOffset,
    );
    final anchoredMovementScore = _deltaMovementScore(
      anchoredDelta,
      lastCursorOffset,
    );
    if (anchoredMovementScore != defaultMovementScore) {
      return anchoredMovementScore < defaultMovementScore
          ? anchoredDelta
          : defaultDelta;
    }

    final defaultRewriteScore = _deltaRewriteScore(defaultDelta);
    final anchoredRewriteScore = _deltaRewriteScore(anchoredDelta);
    if (anchoredRewriteScore != defaultRewriteScore) {
      return anchoredRewriteScore < defaultRewriteScore
          ? anchoredDelta
          : defaultDelta;
    }

    return defaultDelta;
  }

  TerminalCommandReview? _reviewForInsertedText(
    String currentText,
    ({int deletedCount, String appendedText, int deleteCursorOffset}) delta,
  ) {
    if (effects.onReviewInsertedText == null) {
      return null;
    }
    final insertedText = _insertedTextExcludingRetypedTail(delta.appendedText);
    final insertedTextLength = insertedText.characters.length;
    if (insertedTextLength <= 1) {
      return null;
    }

    final reviewText =
        effects.buildReviewTextForInsertedText?.call((
          deletedCount: delta.deletedCount,
          appendedText: delta.appendedText,
        ), currentText) ??
        currentText;
    final review = assessKeyboardInsertedCommand(
      reviewText,
      insertedText: insertedText,
      previewedByIme: _commitMatchesComposedPreview(),
      bracketedPasteModeEnabled: terminal.bracketedPasteMode,
    );
    if (review.requiresReview) {
      DiagnosticsLogService.instance.debug(
        'terminal.keyboard',
        'review_inserted_text',
        fields: {
          'insertedLength': insertedTextLength,
          'deletedCount': delta.deletedCount,
          'reasonCount': review.reasons.length,
          'largeInsertion': review.reasons.contains(
            TerminalCommandReviewReason.largeKeyboardInsertion,
          ),
          'multiline': review.reasons.contains(
            TerminalCommandReviewReason.multiline,
          ),
          'controlCharacters': review.reasons.contains(
            TerminalCommandReviewReason.controlCharacters,
          ),
        },
      );
    }
    return review.requiresReview ? review : null;
  }

  /// Whether the editing value being committed is the text the IME was just
  /// composing, allowing for trailing whitespace and up to two characters of
  /// punctuation the IME may add when it finalises dictation.
  bool _commitMatchesComposedPreview() {
    final preview = _composedPreviewText?.trimRight();
    if (!_sawImeComposition || preview == null || preview.isEmpty) {
      return false;
    }
    final committed = _extractRawInputText(_currentEditingState.text)
        .trimRight();
    return committed.startsWith(preview) &&
        _imeFinalisingSuffixPattern.hasMatch(
          committed.substring(preview.length),
        );
  }

  String _insertedTextExcludingRetypedTail(String appendedText) {
    if (_retypedTrailingTailLength <= 0) {
      return appendedText;
    }
    final graphemes = appendedText.characters;
    if (_retypedTrailingTailLength >= graphemes.length) {
      return '';
    }
    return graphemes.skipLast(_retypedTrailingTailLength).toString();
  }

  int _clampTextOffset(int offset, int maxOffset) {
    if (offset < 0) {
      return 0;
    }
    if (offset > maxOffset) {
      return maxOffset;
    }
    return offset;
  }

  int _normalizeUserOffset({
    required int rawOffset,
    required int rawPrefixLength,
    required int trimmedLeadingCharacters,
    required int userTextLength,
  }) => _clampTextOffset(
    rawOffset - rawPrefixLength - trimmedLeadingCharacters,
    userTextLength,
  );

  TextSelection? _normalizeSelectionForUserText({
    required TextSelection selection,
    required int rawPrefixLength,
    required int trimmedLeadingCharacters,
    required int userTextLength,
  }) {
    if (!selection.isValid) {
      return null;
    }

    return TextSelection(
      baseOffset: _normalizeUserOffset(
        rawOffset: selection.baseOffset,
        rawPrefixLength: rawPrefixLength,
        trimmedLeadingCharacters: trimmedLeadingCharacters,
        userTextLength: userTextLength,
      ),
      extentOffset: _normalizeUserOffset(
        rawOffset: selection.extentOffset,
        rawPrefixLength: rawPrefixLength,
        trimmedLeadingCharacters: trimmedLeadingCharacters,
        userTextLength: userTextLength,
      ),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  TextRange _normalizeComposingForUserText({
    required TextRange composing,
    required int rawPrefixLength,
    required int trimmedLeadingCharacters,
    required int userTextLength,
  }) {
    if (!composing.isValid || composing.isCollapsed) {
      return TextRange.empty;
    }

    final start = _normalizeUserOffset(
      rawOffset: composing.start,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: userTextLength,
    );
    final end = _normalizeUserOffset(
      rawOffset: composing.end,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: userTextLength,
    );
    if (start >= end) {
      return TextRange.empty;
    }
    return TextRange(start: start, end: end);
  }

  TextEditingValue _editingStateForUserText({
    required String userText,
    TextSelection? userSelection,
    TextRange userComposing = TextRange.empty,
  }) {
    final prefixLength = options.deleteDetection
        ? initEditingState.text.length
        : 0;
    final text = options.deleteDetection
        ? '${initEditingState.text}$userText'
        : userText;
    final selection = userSelection == null
        ? TextSelection.collapsed(offset: prefixLength + userText.length)
        : TextSelection(
            baseOffset: prefixLength + userSelection.baseOffset,
            extentOffset: prefixLength + userSelection.extentOffset,
            affinity: userSelection.affinity,
            isDirectional: userSelection.isDirectional,
          );
    final composing = userComposing.isValid && !userComposing.isCollapsed
        ? TextRange(
            start: prefixLength + userComposing.start,
            end: prefixLength + userComposing.end,
          )
        : TextRange.empty;
    return TextEditingValue(
      text: text,
      selection: selection,
      composing: composing,
    );
  }

  String _iosBackspaceRunwayPayload(int length) =>
      String.fromCharCodes(List<int>.filled(length, 0x200B));

  TextEditingValue _editingStateForIosBackspaceRunway() {
    final text =
        '$_deleteDetectionMarker'
        '${_iosBackspaceRunwayPayload(terminalIosBackspaceRepeatRunwayLength)}';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _syncEditingStateWithIosBackspaceRunway() {
    if (!_shouldUseIosBackspaceRunway) {
      _syncEditingStateWithUserText('');
      return;
    }

    _iosBackspaceRunwayLength = terminalIosBackspaceRepeatRunwayLength;
    _currentEditingState = _editingStateForIosBackspaceRunway();
    if (effects.canSyncEditingState?.call() ?? true) {
      effects.onEditingState?.call(_currentEditingState);
    }
  }

  int _leadingIosBackspaceRunwaySentinelLength(
    String rawUserText, {
    int? maxLength,
  }) {
    final limit = maxLength == null || rawUserText.length < maxLength
        ? rawUserText.length
        : maxLength;
    var length = 0;
    while (length < limit &&
        rawUserText.codeUnitAt(length) == _iosBackspaceRepeatRunwayCodeUnit) {
      length++;
    }
    return length;
  }

  int _leadingIosBackspaceRunwayLength(String rawUserText) =>
      _leadingIosBackspaceRunwaySentinelLength(
        rawUserText,
        maxLength: _iosBackspaceRunwayLength,
      );

  int _offsetAfterRemovedRange({
    required int offset,
    required int start,
    required int length,
  }) {
    if (offset < 0 || offset <= start) {
      return offset;
    }
    final end = start + length;
    if (offset <= end) {
      return start;
    }
    return offset - length;
  }

  TextSelection _selectionAfterRemovedRange(
    TextSelection selection, {
    required int start,
    required int length,
  }) => TextSelection(
    baseOffset: _offsetAfterRemovedRange(
      offset: selection.baseOffset,
      start: start,
      length: length,
    ),
    extentOffset: _offsetAfterRemovedRange(
      offset: selection.extentOffset,
      start: start,
      length: length,
    ),
    affinity: selection.affinity,
    isDirectional: selection.isDirectional,
  );

  TextRange _rangeAfterRemovedRange(
    TextRange range, {
    required int start,
    required int length,
  }) {
    if (!range.isValid || range.isCollapsed) {
      return range;
    }
    final shiftedStart = _offsetAfterRemovedRange(
      offset: range.start,
      start: start,
      length: length,
    );
    final shiftedEnd = _offsetAfterRemovedRange(
      offset: range.end,
      start: start,
      length: length,
    );
    if (shiftedStart >= shiftedEnd) {
      return TextRange.empty;
    }
    return TextRange(start: shiftedStart, end: shiftedEnd);
  }

  TextEditingValue _editingValueWithoutIosBackspaceRunway(
    TextEditingValue value,
    int runwayPrefixLength,
  ) {
    final markerLength = initEditingState.text.length;
    final text = value.text.replaceRange(
      markerLength,
      markerLength + runwayPrefixLength,
      '',
    );
    return TextEditingValue(
      text: text,
      selection: _selectionAfterRemovedRange(
        value.selection,
        start: markerLength,
        length: runwayPrefixLength,
      ),
      composing: _rangeAfterRemovedRange(
        value.composing,
        start: markerLength,
        length: runwayPrefixLength,
      ),
    );
  }

  bool _handleIosBackspaceRunwayDeletion(TextEditingValue value) {
    if (!_shouldUseIosBackspaceRunway || _iosBackspaceRunwayLength == 0) {
      return false;
    }
    if (_editingPrefixLength(value.text) != initEditingState.text.length) {
      _iosBackspaceRunwayLength = 0;
      return false;
    }

    final rawUserText = _extractRawInputText(value.text);
    final runwaySentinelLength = _leadingIosBackspaceRunwaySentinelLength(
      rawUserText,
    );
    final runwayPrefixLength = _leadingIosBackspaceRunwayLength(rawUserText);
    if (runwayPrefixLength == 0) {
      _iosBackspaceRunwayLength = 0;
      return false;
    }
    if (runwaySentinelLength < rawUserText.length) {
      return false;
    }
    if (runwaySentinelLength > _iosBackspaceRunwayLength) {
      _syncEditingStateWithIosBackspaceRunway();
      return true;
    }

    final deletedCount = _iosBackspaceRunwayLength - runwayPrefixLength;
    if (deletedCount > 0) {
      _notifyUserInput();
      for (var index = 0; index < deletedCount; index++) {
        terminal.keyInput(TerminalKey.backspace);
      }
    }
    _lastSentText = '';
    _lastSentCursorOffset = 0;
    _iosBackspaceRunwayLength = runwayPrefixLength;
    _currentEditingState = value;

    if (_iosBackspaceRunwayLength <=
        terminalIosBackspaceRepeatRunwayRefillThreshold) {
      _syncEditingStateWithIosBackspaceRunway();
    }
    return true;
  }

  void _preserveIosBackspaceRunwayForComposing(TextEditingValue value) {
    if (!_shouldUseIosBackspaceRunway || _iosBackspaceRunwayLength == 0) {
      _iosBackspaceRunwayLength = 0;
      return;
    }
    if (_editingPrefixLength(value.text) != initEditingState.text.length) {
      _iosBackspaceRunwayLength = 0;
      return;
    }

    final runwayPrefixLength = _leadingIosBackspaceRunwayLength(
      _extractRawInputText(value.text),
    );
    _iosBackspaceRunwayLength = runwayPrefixLength;
  }

  TextEditingValue _stripIosBackspaceRunway(TextEditingValue value) {
    if (!_shouldUseIosBackspaceRunway || _iosBackspaceRunwayLength == 0) {
      return value;
    }
    if (_editingPrefixLength(value.text) != initEditingState.text.length) {
      _iosBackspaceRunwayLength = 0;
      return value;
    }

    final rawUserText = _extractRawInputText(value.text);
    final runwayPrefixLength = _leadingIosBackspaceRunwaySentinelLength(
      rawUserText,
    );
    if (runwayPrefixLength == 0) {
      _iosBackspaceRunwayLength = 0;
      return value;
    }
    _iosBackspaceRunwayLength = 0;
    return _editingValueWithoutIosBackspaceRunway(value, runwayPrefixLength);
  }

  void _syncEditingStateWithUserText(
    String userText, {
    TextEditingValue? sourceValue,
    bool forceResyncState = false,
  }) {
    _iosBackspaceRunwayLength = 0;
    final rawPrefixLength = sourceValue == null
        ? initEditingState.text.length
        : _editingPrefixLength(sourceValue.text);
    final rawUserText = sourceValue == null
        ? userText
        : _extractRawInputText(sourceValue.text);
    final trimmedLeadingCharacters = rawUserText.length - userText.length;
    final userSelection = sourceValue == null
        ? null
        : _normalizeSelectionForUserText(
            selection: sourceValue.selection,
            rawPrefixLength: rawPrefixLength,
            trimmedLeadingCharacters: trimmedLeadingCharacters,
            userTextLength: userText.length,
          );
    final userComposing = sourceValue == null
        ? TextRange.empty
        : _normalizeComposingForUserText(
            composing: sourceValue.composing,
            rawPrefixLength: rawPrefixLength,
            trimmedLeadingCharacters: trimmedLeadingCharacters,
            userTextLength: userText.length,
          );
    final nextState = _editingStateForUserText(
      userText: userText,
      userSelection: userSelection,
      userComposing: userComposing,
    );
    final hasActiveReplacementSelection =
        sourceValue != null &&
        sourceValue.selection.isValid &&
        !sourceValue.selection.isCollapsed;
    final shouldResyncText =
        forceResyncState ||
        sourceValue == null ||
        (sourceValue.text != nextState.text &&
            !(trimmedLeadingCharacters > 0 && hasActiveReplacementSelection));
    _currentEditingState = nextState;
    if (shouldResyncText && (effects.canSyncEditingState?.call() ?? true)) {
      effects.onEditingState?.call(nextState);
    }
  }

  bool _sendComposingDeletionIfNeeded(TextEditingValue value) {
    final currentText = _extractInputText(value.text);
    if (_lastSentText.isEmpty || currentText == _lastSentText) {
      return false;
    }

    final targetCursorOffset = _collapsedSelectionCursorOffset(
      currentText,
      value,
    );
    var delta = _computeTextDelta(
      currentText,
      cursorOffsetHint: targetCursorOffset,
    );
    if (delta.deletedCount == 0 || delta.appendedText.isNotEmpty) {
      return false;
    }

    final synchronizedBackspace = _synchronizeAndroidHardwareBackspace(
      currentText: currentText,
      cursorOffset: targetCursorOffset,
      delta: delta,
    );
    delta = synchronizedBackspace.delta;
    if (delta.deletedCount > 0) {
      _notifyUserInput();
    }
    _sendInputDelta(synchronizedBackspace.currentText, delta);
    if (synchronizedBackspace.cursorOffset != null &&
        synchronizedBackspace.cursorOffset != _lastSentCursorOffset) {
      _moveTerminalCursorTo(synchronizedBackspace.cursorOffset!);
    }
    _trimLeadingSuggestionSpaceAfterDelete = true;
    _trimLeadingSwipeSpaceAfterBufferClear = currentText.isEmpty;
    return true;
  }

  // -- Editing updates --

  bool _capturePendingComposingEnterFollowUp(TextEditingValue value) {
    final pendingText = _pendingComposingEnterText;
    if (pendingText == null) {
      return false;
    }

    final currentText = _canonicalPendingComposingEnterText(
      _extractInputText(value.text),
      stalePrefix: _pendingComposingEnterStalePrefix,
    );
    final isRedundantCommit = currentText == pendingText;
    final pendingTextEndsWithNewline = _textEndsWithEnterSequence(pendingText);
    final isSuffixAfterPendingNewline =
        pendingTextEndsWithNewline && currentText.startsWith(pendingText);
    final isNewlineFollowUp = _enterCommitNewlineSequences.any(
      (newlineSequence) =>
          currentText.startsWith('$pendingText$newlineSequence'),
    );
    if (!isRedundantCommit &&
        !isSuffixAfterPendingNewline &&
        !isNewlineFollowUp) {
      return false;
    }

    _pendingComposingEnterFollowUp = _canonicalEditingStateForUserText(
      value,
      currentText,
    );
    return true;
  }

  TextEditingValue _canonicalEditingStateForUserText(
    TextEditingValue sourceValue,
    String userText,
  ) {
    final rawPrefixLength = _editingPrefixLength(sourceValue.text);
    final rawUserText = _extractRawInputText(sourceValue.text);
    final trimmedLeadingCharacters = rawUserText.length - userText.length;
    return _editingStateForUserText(
      userText: userText,
      userSelection: _normalizeSelectionForUserText(
        selection: sourceValue.selection,
        rawPrefixLength: rawPrefixLength,
        trimmedLeadingCharacters: trimmedLeadingCharacters,
        userTextLength: userText.length,
      ),
      userComposing: _normalizeComposingForUserText(
        composing: sourceValue.composing,
        rawPrefixLength: rawPrefixLength,
        trimmedLeadingCharacters: trimmedLeadingCharacters,
        userTextLength: userText.length,
      ),
    );
  }

  bool _textEndsWithEnterSequence(String text) =>
      _enterCommitNewlineSequences.any(text.endsWith);

  String _canonicalPendingComposingEnterText(
    String currentText, {
    String? stalePrefix,
  }) {
    final previousEnterText = stalePrefix ?? _pendingPerformedEnterText;
    if (previousEnterText == null) {
      return currentText;
    }
    if (currentText == previousEnterText) {
      return '';
    }
    for (final newlineSequence in _enterCommitNewlineSequences) {
      final prefix = '$previousEnterText$newlineSequence';
      if (currentText.startsWith(prefix)) {
        return currentText.substring(prefix.length);
      }
    }
    return currentText;
  }

  TextEditingValue? _pendingComposingEnterFollowUpSuffixValue() {
    final pendingText = _pendingComposingEnterText;
    final followUp = _pendingComposingEnterFollowUp;
    if (pendingText == null || followUp == null) {
      return null;
    }

    final currentText = _extractInputText(followUp.text);
    final pendingTextEndsWithNewline = _enterCommitNewlineSequences.any(
      pendingText.endsWith,
    );
    if (pendingTextEndsWithNewline && currentText.startsWith(pendingText)) {
      final suffix = currentText.substring(pendingText.length);
      return suffix.isEmpty
          ? null
          : _canonicalEditingStateForUserText(followUp, suffix);
    }
    for (final newlineSequence in _enterCommitNewlineSequences) {
      final prefix = '$pendingText$newlineSequence';
      if (currentText.startsWith(prefix)) {
        final suffix = currentText.substring(prefix.length);
        return suffix.isEmpty
            ? null
            : _canonicalEditingStateForUserText(followUp, suffix);
      }
    }
    return null;
  }

  TextEditingValue _editingStateWithPrependedUserText(
    TextEditingValue sourceValue,
    String prefix,
  ) {
    final suffix = _extractInputText(sourceValue.text);
    final userSelection = _userSelectionForEditingValue(suffix, sourceValue);
    final rawPrefixLength = _editingPrefixLength(sourceValue.text);
    final rawUserText = _extractRawInputText(sourceValue.text);
    final trimmedLeadingCharacters = rawUserText.length - suffix.length;
    final userComposing = _normalizeComposingForUserText(
      composing: sourceValue.composing,
      rawPrefixLength: rawPrefixLength,
      trimmedLeadingCharacters: trimmedLeadingCharacters,
      userTextLength: suffix.length,
    );
    final prefixLength = prefix.length;
    return _editingStateForUserText(
      userText: '$prefix$suffix',
      userSelection: userSelection == null
          ? null
          : TextSelection(
              baseOffset: prefixLength + userSelection.baseOffset,
              extentOffset: prefixLength + userSelection.extentOffset,
              affinity: userSelection.affinity,
              isDirectional: userSelection.isDirectional,
            ),
      userComposing: userComposing.isValid && !userComposing.isCollapsed
          ? TextRange(
              start: prefixLength + userComposing.start,
              end: prefixLength + userComposing.end,
            )
          : TextRange.empty,
    );
  }

  void _restoreEditingValue(TextEditingValue value) {
    _currentEditingState = value;
    if (effects.canSyncEditingState?.call() ?? true) {
      effects.onEditingState?.call(value);
    }
    updateEditingValue(value);
  }

  void updateEditingValue(TextEditingValue value) {
    if (!_active || options.readOnly) {
      return;
    }

    if (_acceptNextPendingComposingEnterCommit) {
      _acceptNextPendingComposingEnterCommit = false;
    } else if (_capturePendingComposingEnterFollowUp(value)) {
      return;
    }

    if (_editingValueShowsImeInteraction(value)) {
      _hasPendingPromptOutputImeReset = true;
    }

    if (!value.composing.isCollapsed) {
      _sawImeComposition = true;
      final rawPreview = _extractRawInputText(value.text);
      _composedPreviewText = rawPreview.substring(
        _leadingIosBackspaceRunwaySentinelLength(rawPreview),
      );
    }

    _currentEditingState = value;
    _queuedEditingValue = value;
    _latestEditingValueRevision++;

    if (_isProcessingEditingValue) {
      return;
    }

    _isProcessingEditingValue = true;
    unawaited(_drainEditingValueQueue());
  }

  Future<void> _drainEditingValueQueue() async {
    try {
      while (_active && _queuedEditingValue != null) {
        final value = _queuedEditingValue!;
        final revision = _latestEditingValueRevision;
        _queuedEditingValue = null;
        await _updateEditingValue(value, revision);
      }
    } finally {
      _isProcessingEditingValue = false;
    }

    if (_active && _queuedEditingValue != null && !_isProcessingEditingValue) {
      _isProcessingEditingValue = true;
      unawaited(_drainEditingValueQueue());
    }
  }

  Future<void> _updateEditingValue(
    TextEditingValue incomingValue,
    int revision,
  ) async {
    var value = incomingValue;
    _currentEditingState = value;
    var processedUserSelectionWasValid = false;
    var processedUserSelection = const TextSelection.collapsed(offset: 0);
    try {
      final pendingTouchCursorCurrentText = _extractInputText(value.text);
      if (_clearImeForPendingTouchCursorMove(
        value,
        pendingTouchCursorCurrentText,
      )) {
        _sawImeComposition = false;
        return;
      }

      // Handle composing (IME input in progress).
      if (!value.composing.isCollapsed) {
        cancelDeferredTrailingBackspaceImeClear();
        _preserveIosBackspaceRunwayForComposing(value);
        if (_sendComposingDeletionIfNeeded(value)) {
          _sawImeComposition = true;
          return;
        }
        _sawImeComposition = true;
        return;
      }

      if (_handleIosBackspaceRunwayDeletion(value)) {
        _sawImeComposition = false;
        return;
      }
      value = _stripIosBackspaceRunway(value);
      _currentEditingState = value;

      // IMEs can replace the whole editing buffer, including the hidden
      // backspace markers, when committing dictation or replacement text.
      // Only marker loss without remaining text is a delete signal. Otherwise
      // process the text normally and restore the markers during the sync below.
      if (_editingPrefixLength(value.text) < initEditingState.text.length &&
          _extractRawInputText(value.text).isEmpty) {
        final deletedCount = _textLengthInGraphemes(_lastSentText);
        final clearedBufferedInput = deletedCount > 0;
        if (_pendingAndroidHardwareBackspaces > 0) {
          _pendingAndroidHardwareBackspaces--;
        } else {
          _notifyUserInput();
          _moveTerminalCursorTo(deletedCount);
          if (clearedBufferedInput) {
            for (var index = 0; index < deletedCount; index++) {
              terminal.keyInput(TerminalKey.backspace);
            }
          } else {
            terminal.keyInput(TerminalKey.backspace);
          }
        }
        _sawImeComposition = false;
        _resetCommittedInputState(
          armIosBackspaceRunway: _shouldUseIosBackspaceRunway,
        );
        _trimLeadingSwipeSpaceAfterBufferClear = clearedBufferedInput;
        return;
      }

      final normalizedPendingEnter = _normalizePendingPerformedEnterText(
        _extractInputText(value.text),
      );
      if (normalizedPendingEnter.ignored) {
        cancelDeferredTrailingBackspaceImeClear();
        _syncEditingStateWithUserText('');
        _completePendingComposingEnterAction(revision);
        _sawImeComposition = false;
        return;
      }
      if (normalizedPendingEnter.currentText == null) {
        _resetCommittedInputState();
        _sawImeComposition = false;
        return;
      }

      final currentText = normalizedPendingEnter.currentText!;
      final userSelection = _userSelectionForEditingValue(currentText, value);
      processedUserSelectionWasValid = userSelection != null;
      processedUserSelection =
          userSelection ?? TextSelection.collapsed(offset: currentText.length);
      final targetCursorOffset = _collapsedSelectionCursorOffset(
        currentText,
        value,
      );
      final normalizedSplitLeadingToken = _normalizeSplitLeadingToken(
        currentText,
        cursorOffsetHint: targetCursorOffset,
      );
      final splitNormalizedCurrentText =
          normalizedSplitLeadingToken?.currentText ?? currentText;
      final splitNormalizedTargetCursorOffset =
          normalizedSplitLeadingToken?.cursorOffset ?? targetCursorOffset;
      final normalizedDeleteResetLeadingFragment =
          _normalizeDeleteResetLeadingFragment(
            splitNormalizedCurrentText,
            cursorOffsetHint: splitNormalizedTargetCursorOffset,
          );
      final normalizedCurrentText =
          normalizedDeleteResetLeadingFragment?.currentText ??
          splitNormalizedCurrentText;
      final normalizedTargetCursorOffset =
          normalizedDeleteResetLeadingFragment?.cursorOffset ??
          splitNormalizedTargetCursorOffset;
      if (normalizedCurrentText == _lastSentText) {
        final collapsedMoveAwayFromReplacement =
            !_lastProcessedSelectionWasCollapsed &&
            normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset &&
            normalizedTargetCursorOffset != _lastSentCursorOffset + 1;
        final movedCollapsedCursor =
            _lastProcessedUserSelectionWasValid &&
            (_lastProcessedSelectionWasCollapsed ||
                collapsedMoveAwayFromReplacement) &&
            normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset;
        final shouldClearAfterCollapsedCursorMove =
            _clearImeAfterNextTouchCursorMove &&
            normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset;
        if (normalizedTargetCursorOffset != null &&
            normalizedTargetCursorOffset != _lastSentCursorOffset) {
          _notifyUserInput();
          _moveTerminalCursorTo(normalizedTargetCursorOffset);
        }
        _clearImeAfterNextTouchCursorMove = false;
        if (shouldClearAfterCollapsedCursorMove) {
          clearImeBufferForFreshInput();
          _sawImeComposition = false;
          return;
        }
        cancelDeferredTrailingBackspaceImeClear();
        _syncEditingStateWithUserText(
          normalizedCurrentText,
          sourceValue: value,
          forceResyncState: movedCollapsedCursor,
        );
        _completePendingComposingEnterAction(revision);
        _sawImeComposition = false;
        return;
      }

      final deleteResetContinuation = _resolveDeleteResetContinuation(
        normalizedCurrentText,
        cursorOffsetHint: normalizedTargetCursorOffset,
      );
      var effectiveCurrentText =
          deleteResetContinuation?.currentText ?? normalizedCurrentText;
      var effectiveTargetCursorOffset =
          deleteResetContinuation?.cursorOffset ?? normalizedTargetCursorOffset;
      final deltaPreviousText =
          deleteResetContinuation?.previousText ?? _lastSentText;
      final deltaPreviousCursorOffset =
          deleteResetContinuation?.previousCursorOffset ??
          _lastSentCursorOffset;
      var delta = _computeTextDelta(
        effectiveCurrentText,
        cursorOffsetHint: effectiveTargetCursorOffset,
        previousTextOverride: deleteResetContinuation?.previousText,
        lastCursorOffsetOverride: deleteResetContinuation?.previousCursorOffset,
      );
      if (deleteResetContinuation == null) {
        final synchronizedBackspace = _synchronizeAndroidHardwareBackspace(
          currentText: effectiveCurrentText,
          cursorOffset: effectiveTargetCursorOffset,
          delta: delta,
        );
        effectiveCurrentText = synchronizedBackspace.currentText;
        effectiveTargetCursorOffset = synchronizedBackspace.cursorOffset;
        delta = synchronizedBackspace.delta;
      } else {
        _pendingAndroidHardwareBackspaces = 0;
      }
      final pendingEnterActionOwnedBeforeReview =
          revision == _pendingComposingEnterRevision;
      final hadActiveToolbarModifier =
          effects.hasActiveToolbarModifier?.call() ?? false;
      // Newlines must use the Enter key path (same as a physical Return), not
      // the single-grapheme text modifier path.
      final appendedOnlyEnterNewline = _enterCommitNewlineSequences.contains(
        delta.appendedText,
      );
      if (!pendingEnterActionOwnedBeforeReview &&
          hadActiveToolbarModifier &&
          delta.appendedText.isNotEmpty &&
          !appendedOnlyEnterNewline) {
        // One-shot terminal modifiers apply to a single key. Some IMEs can send
        // stale composing text in the same batch, so keep only the newest key.
        cancelDeferredTrailingBackspaceImeClear();
        _notifyUserInput();
        terminal.textInput(
          _applyTerminalTextInputModifiers(_lastGrapheme(delta.appendedText)),
        );
        clearImeBufferForFreshInput(
          armModifierChordWindow: true,
          armSplitLeadingTokenNormalization: true,
        );
        _sawImeComposition = false;
        return;
      }
      if (_sendSingleBackspaceForPendingTouchDeletion(delta: delta)) {
        _sawImeComposition = false;
        return;
      }
      _clearImeAfterNextTouchCursorMove = false;
      final pendingInputIsTrailingPureDeletion =
          deltaPreviousText.isNotEmpty &&
          delta.deletedCount > 0 &&
          delta.appendedText.isEmpty &&
          delta.deleteCursorOffset == deltaPreviousText.characters.length;
      if (!pendingInputIsTrailingPureDeletion) {
        cancelDeferredTrailingBackspaceImeClear();
      }
      final review = _reviewForInsertedText(effectiveCurrentText, delta);
      if (review != null) {
        final shouldInsert = await effects.onReviewInsertedText!(review);
        if (!_active) {
          return;
        }
        if (revision != _latestEditingValueRevision) {
          _clearPendingComposingEnterAction(revision: revision);
          return;
        }
        if (!shouldInsert) {
          cancelDeferredTrailingBackspaceImeClear();
          final followUpSuffix = _pendingComposingEnterFollowUpSuffixValue();
          _clearPendingComposingEnterAction(revision: revision);
          _syncEditingStateWithUserText(_lastSentText);
          if (followUpSuffix != null) {
            _restoreEditingValue(
              _editingStateWithPrependedUserText(followUpSuffix, _lastSentText),
            );
          }
          _sawImeComposition = false;
          return;
        }
      }

      if (effectiveCurrentText != _lastSentText) {
        _notifyUserInput();
      }
      final previousText = deltaPreviousText;

      if (deleteResetContinuation != null) {
        _lastSentText = deltaPreviousText;
        _lastSentCursorOffset = deltaPreviousCursorOffset;
      }
      final pendingEnterActionOwnsRevision =
          revision == _pendingComposingEnterRevision;
      final pendingEnterActionArrived =
          pendingEnterActionOwnsRevision &&
          _pendingComposingEnterModifiers != null;
      final pendingEnterRepresentedByPayloadNewline =
          pendingEnterActionArrived &&
          _pendingComposingEnterMayBeInText &&
          _pendingComposingEnterText != null &&
          _textEndsWithEnterSequence(_pendingComposingEnterText!);
      final newlineCount = _sendInputDelta(
        effectiveCurrentText,
        delta,
        beforeEnter: pendingEnterActionArrived,
        enterModifiers: pendingEnterRepresentedByPayloadNewline
            ? _pendingComposingEnterModifiers
            : null,
      );
      if (newlineCount > 0) {
        if (pendingEnterActionArrived &&
            !pendingEnterRepresentedByPayloadNewline) {
          _completePendingComposingEnterAction(revision);
          _trimLeadingSuggestionSpaceAfterDelete = true;
          _sawImeComposition = false;
          return;
        }
        final followUpSuffix = pendingEnterActionArrived
            ? _pendingComposingEnterFollowUpSuffixValue()
            : null;
        _resetCommittedInputState(
          pendingEnterSuppressions: pendingEnterActionArrived
              ? newlineCount - 1
              : newlineCount,
        );
        _trimLeadingSuggestionSpaceAfterDelete = true;
        if (followUpSuffix != null) {
          _restoreEditingValue(followUpSuffix);
        }
        _sawImeComposition = false;
        return;
      }

      // Detect non-additive operations that should clear the IME suggestion
      // context: pure deletions (backspace with no replacement text).
      //
      // IME replacements (e.g. autocorrect changing "teh" to "the") may
      // also shorten text but include appended replacement text, so they
      // are NOT treated as pure deletions.
      final wasPureDeletion =
          previousText.isNotEmpty &&
          delta.deletedCount > 0 &&
          delta.appendedText.isEmpty;
      final wasTrailingPureDeletion =
          wasPureDeletion && pendingInputIsTrailingPureDeletion;

      // Also detect the second character of a two-part chord like tmux's
      // Ctrl+b, c. After the first modifier character resets, the follow-up
      // character is sent without a modifier but is still part of the chord
      // and should not accumulate in the IME suggestion context.
      //
      // A short time window (500 ms) distinguishes rapid chord follow-ups
      // from normal typing after a standalone modifier like Ctrl+C.
      final chordResetTime = _modifierChordResetTime;
      final chordElapsed = chordResetTime == null
          ? null
          : now().difference(chordResetTime);
      final wasChordFollowUp =
          chordElapsed != null &&
          !chordElapsed.isNegative &&
          chordElapsed < modifierChordFollowUpWindow &&
          delta.deletedCount == 0 &&
          delta.appendedText.characters.length == 1;

      if (wasChordFollowUp) {
        // The character is the follow-up of a two-part chord, so it should not
        // remain in the IME suggestion context.
        clearImeBufferForFreshInput(armSplitLeadingTokenNormalization: true);
        _sawImeComposition = false;
        return;
      }

      // Any non-chord input clears the chord follow-up window.
      _modifierChordResetTime = null;

      if (wasTrailingPureDeletion) {
        final previousGraphemes = previousText.characters.toList(
          growable: false,
        );
        final currentGraphemes = effectiveCurrentText.characters.toList(
          growable: false,
        );
        final deletedSuffixText = previousGraphemes
            .sublist(currentGraphemes.length)
            .join();
        if (_shouldDeferTrailingBackspaceImeClear) {
          _trimLeadingSuggestionSpaceAfterDelete = true;
          if (effectiveCurrentText.isEmpty) {
            clearImeBufferForFreshInput(
              deleteResetBaselineText: effectiveCurrentText,
              deleteResetBaselineCursorOffset: _lastSentCursorOffset,
              deleteResetDeletedSuffixText: deletedSuffixText,
              armIosBackspaceRunway: true,
            );
          } else {
            _scheduleDeferredTrailingBackspaceImeClear(
              baselineText: effectiveCurrentText,
              baselineCursorOffset: _lastSentCursorOffset,
              deletedSuffixText: deletedSuffixText,
            );
          }
        } else {
          clearImeBufferForFreshInput(
            deleteResetBaselineText: effectiveCurrentText,
            deleteResetBaselineCursorOffset: _lastSentCursorOffset,
            deleteResetDeletedSuffixText: deletedSuffixText,
          );
        }
        _sawImeComposition = false;
        return;
      }

      cancelDeferredTrailingBackspaceImeClear();
      _clearPendingDeleteResetBaseline();

      // For IME replacements that shorten text (e.g. autocorrect), keep the
      // suggestion-space-trim flag since the IME may prepend a space to the
      // next swiped word.
      _trimLeadingSuggestionSpaceAfterDelete =
          previousText.isNotEmpty &&
          effectiveCurrentText.characters.length <
              previousText.characters.length;
      _trimLeadingSwipeSpaceAfterBufferClear =
          previousText.isNotEmpty && effectiveCurrentText.isEmpty;
      if (effectiveTargetCursorOffset != null) {
        _moveTerminalCursorTo(effectiveTargetCursorOffset);
      }
      _syncEditingStateWithUserText(
        effectiveCurrentText,
        sourceValue:
            normalizedPendingEnter.strippedPendingEnter ||
                normalizedSplitLeadingToken != null ||
                normalizedDeleteResetLeadingFragment != null ||
                effectiveCurrentText != normalizedCurrentText
            ? null
            : value,
      );
      _completePendingComposingEnterAction(revision);
      _sawImeComposition = false;
    } finally {
      _lastProcessedUserSelectionWasValid = processedUserSelectionWasValid;
      _lastProcessedSelectionWasCollapsed = processedUserSelection.isCollapsed;
    }
  }

  void _sendPerformedEnter(({bool ctrl, bool alt, bool shift}) modifiers) {
    _hasPendingPromptOutputImeReset = true;
    _notifyUserInput();
    sendTerminalEnterInput(
      terminal,
      shiftActive: modifiers.shift,
      altActive: modifiers.alt,
      ctrlActive: modifiers.ctrl,
    );
    _pendingPerformedEnterText = _lastSentText;
    _resetCommittedInputState(clearPendingPerformedEnterText: false);
    _trimLeadingSuggestionSpaceAfterDelete = true;
    _sawImeComposition = false;
  }

  void _clearPendingComposingEnterAction({int? revision}) {
    if (revision != null && revision != _pendingComposingEnterRevision) {
      return;
    }
    _pendingComposingEnterModifiers = null;
    _pendingComposingEnterText = null;
    _pendingComposingEnterStalePrefix = null;
    _pendingComposingEnterRevision = null;
    _pendingComposingEnterMayBeInText = false;
    _acceptNextPendingComposingEnterCommit = false;
    _pendingComposingEnterFollowUp = null;
  }

  void _completePendingComposingEnterAction(int revision) {
    if (revision != _pendingComposingEnterRevision) {
      return;
    }
    final modifiers = _pendingComposingEnterModifiers;
    if (modifiers == null) {
      return;
    }
    final followUp = _pendingComposingEnterFollowUp;
    final followUpSuffix = _pendingComposingEnterFollowUpSuffixValue();
    _clearPendingComposingEnterAction();
    _sendPerformedEnter(modifiers);
    final replayValue = followUpSuffix ?? followUp;
    if (replayValue != null) {
      _restoreEditingValue(replayValue);
    }
  }

  void performAction(TextInputAction action) {
    if (!_active || options.readOnly) return;

    if (action == TextInputAction.newline || action == TextInputAction.done) {
      if (_pendingEnterActionSuppressions > 0) {
        _pendingEnterActionSuppressions--;
        return;
      }
      if (_pendingComposingEnterModifiers != null) {
        return;
      }
      final modifiers =
          effects.resolveTerminalKeyModifiers?.call() ??
          (ctrl: false, alt: false, shift: false);
      _hasPendingPromptOutputImeReset = true;
      effects.consumeTerminalKeyModifiers?.call();
      final stalePrefix = _pendingPerformedEnterText;
      final currentText = _canonicalPendingComposingEnterText(
        _extractInputText(_currentEditingState.text),
        stalePrefix: stalePrefix,
      );
      final hasUncommittedComposition =
          !_currentEditingState.composing.isCollapsed &&
          currentText != _lastSentText;
      final hasPendingEditingValue =
          currentText != _lastSentText &&
          (_isProcessingEditingValue || _queuedEditingValue != null);
      if (hasUncommittedComposition || hasPendingEditingValue) {
        final pendingRevision = hasUncommittedComposition
            ? _latestEditingValueRevision + 1
            : _latestEditingValueRevision;
        _pendingComposingEnterModifiers = modifiers;
        _pendingComposingEnterText = currentText;
        _pendingComposingEnterStalePrefix = stalePrefix;
        _pendingComposingEnterRevision = pendingRevision;
        _pendingComposingEnterMayBeInText =
            !hasUncommittedComposition && hasPendingEditingValue;
        if (hasUncommittedComposition) {
          _acceptNextPendingComposingEnterCommit = true;
          updateEditingValue(
            _currentEditingState.copyWith(composing: TextRange.empty),
          );
        }
        return;
      }
      _sendPerformedEnter(modifiers);
    }
  }
}
