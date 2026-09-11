import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_attachment.dart';
import '../../domain/models/acp_updates.dart';
import '../controllers/acp_composer_controller.dart';
import 'acp_attachment_strip.dart';
import 'acp_slash_command_picker.dart';
import 'terminal_menu_style.dart';

/// Opens an attachment picker and returns the selected candidates.
typedef AcpAttachmentPick =
    Future<List<AcpAttachmentCandidate>> Function(BuildContext context);

/// The injectable attachment-picker entry points offered by the add menu.
///
/// Each entry is optional; only the provided sources appear in the menu. All
/// picker invocation goes through these callbacks so the composer can be
/// exercised in tests without any platform picker.
@immutable
class AcpComposerAttachmentActions {
  /// Creates attachment actions.
  const AcpComposerAttachmentActions({
    this.pickPhotos,
    this.pickFiles,
    this.pickRemoteFiles,
  });

  /// Picks photos or media from the device gallery/camera.
  final AcpAttachmentPick? pickPhotos;

  /// Picks arbitrary local files.
  final AcpAttachmentPick? pickFiles;

  /// Picks files from the remote host over SFTP.
  final AcpAttachmentPick? pickRemoteFiles;

  /// Whether at least one source is available.
  bool get hasAny =>
      pickPhotos != null || pickFiles != null || pickRemoteFiles != null;
}

/// Controls the native composer focus from the persistent terminal shell.
class AcpComposerFocusController {
  _AcpComposerState? _state;

  /// Whether the composer currently owns text focus.
  bool get hasFocus => _state?._focusNode.hasFocus ?? false;

  /// Focuses the composer and opens the platform keyboard.
  void requestFocus() => _state?._focusNode.requestFocus();

  /// Dismisses the platform keyboard without discarding the draft.
  void dismissKeyboard() => _state?._focusNode.unfocus();

  /// Inserts typed/snippet text at the current composer selection.
  void insertText(String text) => _state?._insertExternalText(text);

  /// Pastes clipboard text, collapsing large payloads into a removable chip.
  void pasteText(String text) =>
      _state?._insertExternalText(text, collapseLargePaste: true);

  /// Adds clipboard image bytes without opening a picker.
  void pasteImage(Uint8List bytes, {String mimeType = 'image/png'}) =>
      _state?._addPastedImage(bytes, mimeType: mimeType);

  /// Applies one special toolbar key to the composer selection.
  void sendSpecialKey(TerminalKey key) => _state?._handleExternalKey(key);

  /// Opens the composer's photo/media picker.
  Future<void> pickPhotos() async =>
      _state?._handleAddAction(_AcpAddAction.photos);

  /// Opens the composer's local-file picker.
  Future<void> pickFiles() async =>
      _state?._handleAddAction(_AcpAddAction.files);

  // ignore: use_setters_to_change_properties
  void _attach(_AcpComposerState state) => _state = state;

  void _detach(_AcpComposerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

/// A mobile-first, keyboard- and safe-area-aware ACP prompt composer.
///
/// The composer groups multiline input, attachments, session controls, and
/// send/stop actions into one familiar chat surface. Slash commands and errors
/// remain immediately above it. The layout expands upward, keeps every action
/// at least 44 logical pixels, and derives all colors from the active theme.
class AcpComposer extends StatefulWidget {
  /// Creates a composer bound to [controller].
  const AcpComposer({
    required this.controller,
    super.key,
    this.attachmentActions = const AcpComposerAttachmentActions(),
    this.focusController,
    this.onOpenConfig,
    this.controls,
    this.hintText = 'Message the agent',
    this.useBottomSafeArea = true,
  });

  /// The controller holding composer state and behaviour.
  final AcpComposerController controller;

  /// The attachment picker entry points to expose in the add menu.
  final AcpComposerAttachmentActions attachmentActions;

  /// Optional owner used by the terminal shell's persistent keyboard button.
  final AcpComposerFocusController? focusController;

  /// Opens the session configuration surface; hidden when null.
  final VoidCallback? onOpenConfig;

  /// Compact model, effort, mode, and permission controls shown in the toolbar.
  final Widget? controls;

  /// Placeholder text for the empty field.
  final String hintText;

  /// Whether the composer should reserve the device bottom safe area.
  final bool useBottomSafeArea;

  @override
  State<AcpComposer> createState() => _AcpComposerState();
}

class _AcpComposerState extends State<AcpComposer> {
  late final TextEditingController _text;
  late final FocusNode _focusNode;
  var _syncing = false;
  var _highlightedSlash = 0;

  AcpComposerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _controller.text);
    _focusNode = FocusNode(onKeyEvent: _handleKey)
      ..addListener(_onFocusChanged);
    _text.addListener(_onFieldChanged);
    _controller.addListener(_onControllerChanged);
    widget.focusController?._attach(this);
  }

  @override
  void didUpdateWidget(AcpComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusController, widget.focusController)) {
      oldWidget.focusController?._detach(this);
      widget.focusController?._attach(this);
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _highlightedSlash = 0;
      // Re-sync the field to the newly bound controller's text/caret.
      _syncFieldFromController();
      _clampHighlight();
    }
  }

  @override
  void dispose() {
    widget.focusController?._detach(this);
    _text.removeListener(_onFieldChanged);
    _focusNode.removeListener(_onFocusChanged);
    // Detach from whichever controller is currently bound.
    _controller.removeListener(_onControllerChanged);
    _text.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onFieldChanged() {
    if (_syncing) {
      return;
    }
    final previous = _controller.text;
    final next = _text.text;
    final insertion = _largePastedInsertion(previous, next);
    if (insertion != null) {
      final remaining = next.replaceRange(
        insertion.start,
        insertion.start + insertion.text.length,
        '',
      );
      _controller
        ..setText(remaining, caret: insertion.start)
        ..addPastedText(insertion.text);
      return;
    }
    final selection = _text.selection;
    final caret = selection.isValid ? selection.baseOffset : next.length;
    _controller.setText(next, caret: caret);
  }

  ({int start, String text})? _largePastedInsertion(
    String previous,
    String next,
  ) {
    if (next.length <= previous.length) return null;
    var prefix = 0;
    final prefixLimit = previous.length.clamp(0, next.length);
    while (prefix < prefixLimit && previous[prefix] == next[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < previous.length - prefix &&
        suffix < next.length - prefix &&
        previous[previous.length - 1 - suffix] ==
            next[next.length - 1 - suffix]) {
      suffix++;
    }
    final inserted = next.substring(prefix, next.length - suffix);
    return shouldCollapseAcpComposerPaste(inserted)
        ? (start: prefix, text: inserted)
        : null;
  }

  void _onControllerChanged() {
    _syncFieldFromController();
    _clampHighlight();
    if (_controller.isSlashActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.isSlashActive && !_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _syncFieldFromController() {
    if (_controller.text != _text.text ||
        _controller.caret != _text.selection.baseOffset) {
      _syncing = true;
      _text.value = TextEditingValue(
        text: _controller.text,
        selection: TextSelection.collapsed(
          offset: _controller.caret.clamp(0, _controller.text.length),
        ),
      );
      _syncing = false;
    }
  }

  void _clampHighlight() {
    final count = _controller.slashCommands.length;
    if (count == 0) {
      _highlightedSlash = 0;
      return;
    }
    if (_highlightedSlash >= count) {
      _highlightedSlash = count - 1;
    }
    if (_highlightedSlash < 0) {
      _highlightedSlash = 0;
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final sendShortcut =
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter);
    if (sendShortcut && _controller.canSend) {
      unawaited(_controller.send());
      return KeyEventResult.handled;
    }
    if (!_controller.isSlashActive) {
      return KeyEventResult.ignored;
    }
    final commands = _controller.slashCommands;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        setState(
          () => _highlightedSlash = (_highlightedSlash + 1) % commands.length,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        setState(
          () => _highlightedSlash =
              (_highlightedSlash - 1 + commands.length) % commands.length,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _selectSlash(commands[_highlightedSlash.clamp(0, commands.length - 1)]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _controller.dismissSlash();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _selectSlash(AcpAvailableCommand command) {
    _controller.selectSlashCommand(command);
    setState(() => _highlightedSlash = 0);
    _focusNode.requestFocus();
  }

  void _insertExternalText(String text, {bool collapseLargePaste = false}) {
    if (!_controller.isEditable || text.isEmpty) {
      return;
    }
    if (collapseLargePaste && shouldCollapseAcpComposerPaste(text)) {
      _controller.addPastedText(text);
      _focusNode.requestFocus();
      return;
    }
    final selection = _text.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, _text.text.length)
        : _controller.caret;
    final end = selection.isValid
        ? selection.end.clamp(start, _text.text.length)
        : start;
    final next = _text.text.replaceRange(start, end, text);
    _controller.setText(next, caret: start + text.length);
    _focusNode.requestFocus();
  }

  void _handleInsertedContent(KeyboardInsertedContent content) {
    final bytes = content.data;
    if (bytes == null ||
        bytes.isEmpty ||
        !content.mimeType.startsWith('image/')) {
      return;
    }
    _addPastedImage(bytes, mimeType: content.mimeType);
  }

  void _addPastedImage(Uint8List bytes, {required String mimeType}) {
    if (!_controller.isEditable || bytes.isEmpty) return;
    final extension = switch (mimeType.toLowerCase()) {
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };
    _controller.addAttachment(
      AcpAttachmentCandidate.memory(
        name: 'Pasted image.$extension',
        bytes: bytes,
        mimeType: mimeType,
      ),
    );
    _focusNode.requestFocus();
  }

  void _handleExternalKey(TerminalKey key) {
    final caret = _controller.caret.clamp(0, _controller.text.length);
    switch (key) {
      case TerminalKey.escape:
        _controller.dismissSlash();
        _focusNode.unfocus();
      case TerminalKey.tab:
        _insertExternalText('\t');
      case TerminalKey.enter:
        _insertExternalText('\n');
      case TerminalKey.arrowLeft:
        _controller.setText(
          _controller.text,
          caret: (caret - 1).clamp(0, _controller.text.length),
        );
      case TerminalKey.arrowRight:
        _controller.setText(
          _controller.text,
          caret: (caret + 1).clamp(0, _controller.text.length),
        );
      case TerminalKey.arrowUp || TerminalKey.pageUp || TerminalKey.home:
        _controller.setText(_controller.text, caret: 0);
      case TerminalKey.arrowDown || TerminalKey.pageDown || TerminalKey.end:
        _controller.setText(_controller.text, caret: _controller.text.length);
      default:
        return;
    }
    _focusNode.requestFocus();
  }

  Future<void> _handleAddAction(_AcpAddAction action) async {
    final actions = widget.attachmentActions;
    switch (action) {
      case _AcpAddAction.photos:
        await _addAttachments(actions.pickPhotos);
      case _AcpAddAction.files:
        await _addAttachments(actions.pickFiles);
      case _AcpAddAction.remoteFiles:
        await _addAttachments(actions.pickRemoteFiles);
    }
  }

  Future<void> _addAttachments(AcpAttachmentPick? source) async {
    if (source == null || !_controller.canAddAttachment) {
      return;
    }
    final candidates = await source(context);
    if (!mounted) {
      return;
    }
    for (final candidate in candidates) {
      if (!_controller.addAttachment(candidate)) {
        break;
      }
    }
    _focusNode.requestFocus();
  }

  Future<void> _handlePrimaryAction() async {
    if (!_controller.canSend) return;
    await _controller.send();
    if (!mounted) return;
    final error = _controller.error;
    if (error != null &&
        error.isUploadRecoverable &&
        _controller.attachments.isNotEmpty) {
      await _confirmRemoteUpload();
    }
  }

  Future<void> _stopActiveTurn() => _controller.cancel();

  Future<void> _confirmRemoteUpload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upload to the server?'),
        content: const Text(
          'These attachments are too large or not supported inline. Upload '
          'them to the host\'s private directory and attach a link instead?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    _controller.enableRemoteUploadFallback();
    await _controller.send();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        _clampHighlight();
        final busy = _controller.activity != AcpComposerActivity.idle;
        final queueing = busy && _controller.canSend;
        return SafeArea(
          top: false,
          bottom: widget.useBottomSafeArea,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              FluttyTheme.spacingSm,
              6,
              FluttyTheme.spacingSm,
              FluttyTheme.spacingSm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_controller.isSlashActive)
                  KeyedSubtree(
                    key: const ValueKey('acp-slash-picker'),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: AcpSlashCommandPicker(
                        commands: _controller.slashCommands,
                        highlightedIndex: _highlightedSlash,
                        onHighlightChanged: (index) =>
                            setState(() => _highlightedSlash = index),
                        onSelected: _selectSlash,
                      ),
                    ),
                  ),
                if (_controller.error != null)
                  KeyedSubtree(
                    key: const ValueKey('acp-error-banner'),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _ErrorBanner(
                        error: _controller.error!,
                        onDismiss: _controller.clearError,
                        onUpload:
                            _controller.error!.isUploadRecoverable &&
                                _controller.attachments.isNotEmpty
                            ? _confirmRemoteUpload
                            : null,
                      ),
                    ),
                  ),
                AnimatedContainer(
                  key: const ValueKey('acp-composer-surface'),
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(FluttyTheme.radiusLg),
                    border: Border.all(
                      color: _focusNode.hasFocus
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: _focusNode.hasFocus ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_controller.attachments.isNotEmpty)
                        KeyedSubtree(
                          key: const ValueKey('acp-attachments'),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                            child: AcpAttachmentStrip(
                              attachments: _controller.attachments,
                              enabled: _controller.isEditable,
                              onRemove: _controller.removeAttachment,
                              onRetry: _controller.retryAttachment,
                            ),
                          ),
                        ),
                      KeyedSubtree(
                        key: const ValueKey('acp-input-row'),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: 56,
                            maxHeight: 168,
                          ),
                          child: TextField(
                            key: const ValueKey('acp-composer-field'),
                            controller: _text,
                            focusNode: _focusNode,
                            readOnly: !_controller.isEditable,
                            minLines: 1,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            textCapitalization: TextCapitalization.sentences,
                            textAlignVertical: TextAlignVertical.top,
                            contentInsertionConfiguration:
                                ContentInsertionConfiguration(
                                  onContentInserted: _handleInsertedContent,
                                ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface,
                              fontSize: 15.5,
                              height: 1.45,
                            ),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              isDense: true,
                              filled: false,
                              contentPadding: const EdgeInsets.fromLTRB(
                                14,
                                14,
                                14,
                                10,
                              ),
                              hintText: widget.hintText,
                              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontSize: 15.5,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        key: const ValueKey('acp-composer-toolbar'),
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                        child: Row(
                          children: [
                            _AddButton(
                              actions: widget.attachmentActions,
                              enabled:
                                  _controller.isEditable &&
                                  widget.attachmentActions.hasAny,
                              attachmentsEnabled: _controller.canAddAttachment,
                              onSelected: _handleAddAction,
                            ),
                            if (widget.controls != null) ...[
                              const SizedBox(width: 2),
                              Expanded(child: widget.controls!),
                              const SizedBox(width: 2),
                            ] else
                              const Spacer(),
                            if (widget.onOpenConfig != null) ...[
                              _ComposerToolbarButton(
                                tooltip: 'Session settings',
                                icon: Icons.tune,
                                onPressed: widget.onOpenConfig,
                              ),
                              const SizedBox(width: 2),
                            ],
                            if (queueing) ...[
                              _StopTurnButton(onPressed: _stopActiveTurn),
                              const SizedBox(width: 2),
                            ],
                            _PrimaryActionButton(
                              activity: _controller.activity,
                              canSend: _controller.canSend,
                              canCancel: _controller.canCancel,
                              onSend: _handlePrimaryAction,
                              onStop: _stopActiveTurn,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

const _composerControlTapDimension = 44.0;
const _composerControlVisualDimension = 38.0;

enum _AcpAddAction { photos, files, remoteFiles }

class _ComposerToolbarButton extends StatelessWidget {
  const _ComposerToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.foregroundColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: _composerControlTapDimension,
      child: Center(
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(
            width: _composerControlVisualDimension,
            height: _composerControlVisualDimension,
          ),
          style: IconButton.styleFrom(
            minimumSize: const Size.square(_composerControlVisualDimension),
            maximumSize: const Size.square(_composerControlVisualDimension),
            backgroundColor: scheme.surfaceContainerHighest,
            foregroundColor: foregroundColor ?? scheme.onSurfaceVariant,
            disabledBackgroundColor: scheme.surfaceContainerHighest.withAlpha(
              90,
            ),
            disabledForegroundColor: scheme.onSurfaceVariant.withAlpha(90),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.actions,
    required this.enabled,
    required this.attachmentsEnabled,
    required this.onSelected,
  });

  final AcpComposerAttachmentActions actions;
  final bool enabled;
  final bool attachmentsEnabled;
  final ValueChanged<_AcpAddAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itemStyle = TerminalMenuStyles.itemButtonStyle(context);
    return MenuAnchor(
      animated: true,
      alignmentOffset: const Offset(0, TerminalMenuStyles.cascadeGap),
      style: TerminalMenuStyles.menuStyle(
        context,
        minimumSize: const Size(210, 0),
      ).copyWith(alignment: AlignmentDirectional.bottomStart),
      menuChildren: [
        if (actions.pickPhotos != null)
          MenuItemButton(
            style: itemStyle,
            leadingIcon: const Icon(Icons.photo_library_outlined),
            onPressed: attachmentsEnabled
                ? () => onSelected(_AcpAddAction.photos)
                : null,
            child: const Text('Photo or video'),
          ),
        if (actions.pickFiles != null)
          MenuItemButton(
            style: itemStyle,
            leadingIcon: const Icon(Icons.attach_file),
            onPressed: attachmentsEnabled
                ? () => onSelected(_AcpAddAction.files)
                : null,
            child: const Text('Choose file'),
          ),
        if (actions.pickRemoteFiles != null)
          MenuItemButton(
            style: itemStyle,
            leadingIcon: const Icon(Icons.cloud_outlined),
            onPressed: attachmentsEnabled
                ? () => onSelected(_AcpAddAction.remoteFiles)
                : null,
            child: const Text('Remote file (SFTP)'),
          ),
      ],
      builder: (context, menuController, _) => SizedBox.square(
        dimension: _composerControlTapDimension,
        child: Center(
          child: IconButton(
            tooltip: 'Add to prompt',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: _composerControlVisualDimension,
              height: _composerControlVisualDimension,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(_composerControlVisualDimension),
              maximumSize: const Size.square(_composerControlVisualDimension),
              padding: EdgeInsets.zero,
            ),
            onPressed: enabled
                ? () => menuController.isOpen
                      ? menuController.close()
                      : menuController.open()
                : null,
            icon: DecoratedBox(
              key: const ValueKey('acp-add-button-visual'),
              decoration: BoxDecoration(
                color: enabled
                    ? scheme.surfaceContainerHighest
                    : scheme.surfaceContainerHighest.withAlpha(90),
                shape: BoxShape.circle,
              ),
              child: SizedBox.square(
                dimension: _composerControlVisualDimension,
                child: Icon(
                  Icons.add,
                  size: 22,
                  color: enabled
                      ? scheme.onSurfaceVariant
                      : scheme.onSurfaceVariant.withAlpha(90),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({
    required this.activity,
    required this.canSend,
    required this.canCancel,
    required this.onSend,
    required this.onStop,
  });

  final AcpComposerActivity activity;
  final bool canSend;
  final bool canCancel;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = activity != AcpComposerActivity.idle;
    final queueing = busy && canSend;
    final stopping = busy && !queueing;
    final enabled = stopping ? canCancel : canSend;
    final label = stopping
        ? 'Stop active turn'
        : (queueing ? 'Queue message' : 'Send');
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: SizedBox.square(
        dimension: _composerControlTapDimension,
        child: Center(
          child: IconButton.filled(
            key: const ValueKey('acp-primary-button-visual'),
            tooltip: label,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: _composerControlVisualDimension,
              height: _composerControlVisualDimension,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(_composerControlVisualDimension),
              maximumSize: const Size.square(_composerControlVisualDimension),
              padding: EdgeInsets.zero,
              backgroundColor: stopping ? scheme.onSurface : scheme.primary,
              foregroundColor: stopping ? scheme.surface : scheme.onPrimary,
              disabledBackgroundColor: scheme.surfaceContainerHighest,
              disabledForegroundColor: scheme.onSurfaceVariant.withAlpha(110),
            ),
            onPressed: enabled ? (stopping ? onStop : onSend) : null,
            icon: Icon(
              stopping ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              size: stopping ? 17 : 20,
            ),
          ),
        ),
      ),
    );
  }
}

class _StopTurnButton extends StatelessWidget {
  const _StopTurnButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => _ComposerToolbarButton(
    tooltip: 'Stop active turn',
    icon: Icons.stop_rounded,
    foregroundColor: Theme.of(context).colorScheme.error,
    onPressed: onPressed,
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.error,
    required this.onDismiss,
    this.onUpload,
  });

  final AcpComposerError error;
  final VoidCallback onDismiss;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          border: Border.all(color: scheme.error.withAlpha(90)),
        ),
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingMd,
          FluttyTheme.spacingSm,
          FluttyTheme.spacingSm,
          FluttyTheme.spacingSm,
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                error.message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            if (onUpload != null)
              TextButton(onPressed: onUpload, child: const Text('Upload')),
            IconButton(
              tooltip: 'Dismiss error',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(Icons.close, size: 18, color: scheme.onErrorContainer),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
