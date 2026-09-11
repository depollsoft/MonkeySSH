/// Full-screen ACP agent chat.
///
/// A single conversation surface on mobile (with an app-bar session switcher)
/// and a persistent session rail plus conversation pane on wide layouts. It
/// watches the multi-host [AcpSessionManager], reconnects recent/detached
/// sessions on open, renders the live/replay timeline with auto-scroll that
/// respects the user's scroll position, and hosts the composer, permission
/// surface, and configuration controls.
///
/// The screen is a pure function of its opaque route identifiers; it never
/// persists or logs transcript content.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_attachment.dart';
import '../../domain/models/acp_native_preview.dart';
import '../../domain/models/acp_protocol.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_timeline.dart' as domain;
import '../../domain/services/acp_attachment_service.dart';
import '../../domain/services/acp_concurrency_policy.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/host_cli_launch_preferences_service.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/pi_model_scope_metadata_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../controllers/acp_composer_controller.dart';
import '../controllers/acp_sftp_client_cache.dart';
import '../models/acp_attachment_picker_adapters.dart';
import '../models/acp_timeline.dart' as ui;
import '../models/acp_timeline_mapper.dart';
import '../widgets/acp_chat_typography.dart';
import '../widgets/acp_composer.dart';
import '../widgets/acp_concurrency_choice.dart';
import '../widgets/acp_config_option_controls.dart';
import '../widgets/acp_connection_support.dart';
import '../widgets/acp_inline_image.dart';
import '../widgets/acp_message_thread.dart';
import '../widgets/acp_new_session_sheet.dart';
import '../widgets/acp_permission_surface.dart';
import '../widgets/acp_session_presentation.dart';
import '../widgets/acp_session_switcher.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/cursor_block.dart';
import '../widgets/terminal_overlay_focus.dart';
import '../widgets/terminal_pinch_zoom_gesture_handler.dart';
import '../widgets/terminal_text_style.dart';
import 'sftp_screen.dart';

/// Builds the attachment picker actions for a chat session. Overridable in
/// tests so the composer can be exercised without platform pickers.
typedef AcpChatAttachmentActionsBuilder =
    AcpComposerAttachmentActions Function(int hostId, int? connectionId);

/// Receives a connection-card preview together with its originating session.
typedef AcpChatPreviewChanged =
    void Function(AcpSessionKey sessionKey, String? preview);

/// Receives a role-aware native preview together with its originating session.
typedef AcpChatNativePreviewChanged =
    void Function(AcpSessionKey sessionKey, AcpNativePreviewSnapshot? preview);

/// Session-owned conversation scroll state retained across embedded remounts.
@immutable
class AcpChatScrollState {
  /// Creates a retained transcript position.
  const AcpChatScrollState({required this.offset, required this.autoScroll});

  /// Logical scroll offset from the top of the transcript.
  final double offset;

  /// Whether new output should continue following the bottom.
  final bool autoScroll;
}

/// Receives retained scroll state together with its originating session.
typedef AcpChatScrollChanged =
    void Function(AcpSessionKey sessionKey, AcpChatScrollState state);

/// Wide-layout breakpoint for the session rail.
const double kAgentChatWideBreakpoint = 840;

/// Clamps native agent text to the same supported range as terminal text.
double clampAgentChatFontSize(num size) {
  if (!size.isFinite) {
    return 8;
  }
  return size.clamp(8, 32).toDouble();
}

/// Full-screen agent chat for one ACP session.
class AgentChatScreen extends ConsumerStatefulWidget {
  /// Creates an agent chat screen from its opaque session identifiers.
  const AgentChatScreen({
    required this.hostId,
    required this.providerId,
    required this.bridgeId,
    required this.acpSessionId,
    this.attachmentActionsBuilder,
    this.composerFocusController,
    this.embedded = false,
    this.connectOnMount = true,
    this.preferredFontSize,
    this.preferredFontFamily,
    this.onFontSizeCommitted,
    this.onExitEmbedded,
    this.onSessionChanged,
    this.onPreviewChanged,
    this.onNativePreviewChanged,
    this.initialScrollState,
    this.onScrollChanged,
    super.key,
  });

  /// Saved host identifier.
  final int hostId;

  /// ACP provider identifier.
  final String providerId;

  /// Opaque remote bridge identifier.
  final String bridgeId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Optional attachment picker override for tests.
  final AcpChatAttachmentActionsBuilder? attachmentActionsBuilder;

  /// Lets the containing terminal shell control the native composer keyboard.
  final AcpComposerFocusController? composerFocusController;

  /// Whether the conversation replaces a terminal viewport inside its shell.
  final bool embedded;

  /// Whether this view owns reconnecting a session absent from manager state.
  ///
  /// The terminal shell disables this while it already owns the same reconnect
  /// future, avoiding a duplicate attempt during an immediate native handoff.
  final bool connectOnMount;

  /// Terminal/session font size used by the embedded conversation.
  final double? preferredFontSize;

  /// Terminal/host font family used by the embedded conversation.
  final String? preferredFontFamily;

  /// Persists a font size committed by a completed pinch gesture.
  final ValueChanged<double>? onFontSizeCommitted;

  /// Returns an embedded conversation to the terminal viewport.
  final VoidCallback? onExitEmbedded;

  /// Replaces the active embedded conversation after a fork.
  final ValueChanged<AcpSessionKey>? onSessionChanged;

  /// Publishes a bounded conversation preview for connection cards.
  final AcpChatPreviewChanged? onPreviewChanged;

  /// Publishes a bounded role-aware preview for connection cards.
  final AcpChatNativePreviewChanged? onNativePreviewChanged;

  /// Retained transcript position for an embedded session remount.
  final AcpChatScrollState? initialScrollState;

  /// Persists transcript position for the containing terminal session.
  final AcpChatScrollChanged? onScrollChanged;

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen> {
  late AcpSessionKey _key;
  late final AcpComposerController _composer;
  late final ScrollController _scroll;

  late bool _autoScroll;
  late bool _showJumpToLatest;
  var _initialScrollSettled = false;
  var _initialScrollScheduled = false;
  Timer? _initialScrollSettleTimer;
  var _userDraggingTranscript = false;
  var _connecting = true;
  AcpSessionError? _connectError;
  final AcpTimelineMapperCache _timelineMapperCache = AcpTimelineMapperCache();
  final AcpSftpClientCache _sftpCache = AcpSftpClientCache();
  Timer? _previewPublishTimer;
  AcpSessionState? _pendingPreviewSession;
  List<ui.AcpTimelineEntry>? _pendingPreviewEntries;
  AcpStatusDisplay? _pendingPreviewActivity;
  String? _lastPublishedPreview;
  AcpNativePreviewSnapshot? _lastPublishedNativePreview;
  String? _piModelScopeIdentity;
  List<String>? _piEnabledModelPatterns;
  var _piModelScopeLoading = false;

  @override
  void initState() {
    super.initState();
    _key = AcpSessionKey.of(
      hostId: widget.hostId,
      providerId: widget.providerId,
      bridgeId: widget.bridgeId,
      acpSessionId: widget.acpSessionId,
    );
    final retainedScroll = widget.initialScrollState;
    _autoScroll = retainedScroll?.autoScroll ?? true;
    _showJumpToLatest = !_autoScroll;
    _scroll = ScrollController(
      initialScrollOffset: retainedScroll?.offset ?? 0,
    );
    final manager = ref.read(acpSessionManagerProvider);
    _composer = AcpComposerController(
      manager: manager,
      sessionKey: _key,
      uploaderBuilder: _buildUploader,
      initialSession: manager.state.byKeyValue(_key.value),
    );
    _scroll.addListener(_onScroll);
    if (widget.connectOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureConnected());
    }
  }

  @override
  void dispose() {
    _previewPublishTimer?.cancel();
    _initialScrollSettleTimer?.cancel();
    _publishScrollState();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _composer.dispose();
    super.dispose();
  }

  void _queuePreviewPublish(
    AcpSessionState session,
    List<ui.AcpTimelineEntry> entries,
    AcpStatusDisplay activity,
  ) {
    if (widget.onPreviewChanged == null &&
        widget.onNativePreviewChanged == null) {
      return;
    }
    // Keep only immutable references during high-frequency tool streaming.
    // Building both previews walks the transcript, so do that work once at the
    // throttle boundary rather than synchronously for every incoming chunk.
    _pendingPreviewSession = session;
    _pendingPreviewEntries = entries;
    _pendingPreviewActivity = activity;
    _previewPublishTimer ??= Timer(const Duration(milliseconds: 250), () {
      _previewPublishTimer = null;
      final nextSession = _pendingPreviewSession;
      final nextEntries = _pendingPreviewEntries;
      final nextActivity = _pendingPreviewActivity;
      _pendingPreviewSession = null;
      _pendingPreviewEntries = null;
      _pendingPreviewActivity = null;
      if (!mounted ||
          nextSession == null ||
          nextEntries == null ||
          nextActivity == null) {
        return;
      }
      if (widget.onPreviewChanged != null) {
        final nextText = _timelineMapperCache.preview(nextSession);
        if (nextText != _lastPublishedPreview) {
          _lastPublishedPreview = nextText;
          widget.onPreviewChanged?.call(_key, nextText);
        }
      }
      if (widget.onNativePreviewChanged != null) {
        final nextNative = _buildNativePreview(nextEntries, nextActivity);
        if (nextNative != _lastPublishedNativePreview) {
          _lastPublishedNativePreview = nextNative;
          widget.onNativePreviewChanged?.call(_key, nextNative);
        }
      }
    });
  }

  AcpAttachmentUploader? _buildUploader() {
    final connectionId = _currentConnectionId();
    final client = _sftpCache.clientForConnection(connectionId);
    // Never upload through a client owned by a stale SSH connection: if the
    // host reconnected under a new connectionId, the cache returns null here
    // and we kick off a reopen so the next attempt uses the live connection.
    if (client == null) {
      _sftpCache.invalidateIfStale(connectionId);
      unawaited(_ensureSftpClient());
      return null;
    }
    return SftpAcpAttachmentUploader(sftp: client);
  }

  int? _currentConnectionId() => ref
      .read(sshServiceProvider)
      .getSessionsForHost(widget.hostId)
      .firstOrNull
      ?.connectionId;

  Future<void> _ensureConnected() async {
    final manager = ref.read(acpSessionManagerProvider);
    final existing = manager.state.byKeyValue(_key.value);
    if (existing != null && existing.isLive) {
      unawaited(manager.selectSession(_key));
      unawaited(_ensureSftpClient());
      return;
    }
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      final recents = await manager.loadRecentSessions();
      final match = recents.where((r) => r.key.value == _key.value).firstOrNull;
      final result = await _reconnect(cwd: match?.cwd ?? '~');
      if (!mounted) {
        return;
      }
      switch (result) {
        case AcpSessionLaunchStarted(:final key):
          final keyChanged = key != _key;
          setState(() {
            _key = key;
            _connecting = false;
          });
          if (keyChanged) {
            _composer.rebindSession(
              key,
              session: manager.state.byKeyValue(key.value),
            );
            if (widget.embedded) {
              widget.onSessionChanged?.call(key);
            }
          }
          unawaited(manager.selectSession(key));
          unawaited(_ensureSftpClient());
        case AcpSessionLaunchFailed(:final error):
          setState(() {
            _connecting = false;
            _connectError = error;
          });
        case AcpSessionLaunchBlocked() || null:
          setState(() => _connecting = false);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = const AcpSessionError(
            kind: AcpSessionErrorKind.unknown,
            message: 'Could not reconnect to this session.',
          );
        });
      }
    }
  }

  Future<AcpSessionLaunchResult?> _reconnect({
    required String cwd,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) async {
    final manager = ref.read(acpSessionManagerProvider);
    final connection = await ensureAcpHostConnection(context, ref, _key.hostId);
    if (!connection.success) {
      return AcpSessionLaunchFailed(
        _key,
        AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message:
              connection.error ?? 'Could not establish the SSH connection.',
        ),
      );
    }
    final launchPreferences = await ref
        .read(hostCliLaunchPreferencesServiceProvider)
        .getPreferencesForHost(_key.hostId);
    if (!mounted) return null;
    final result = await manager.reconnectSession(
      hostId: _key.hostId,
      providerId: _key.providerId,
      bridgeId: _key.bridgeId,
      acpSessionId: _key.acpSessionId,
      cwd: cwd,
      confirmInstall: (request) => confirmAcpMonkeyMuxInstall(context, request),
      autoApprovePermissions: launchPreferences.startInYoloMode,
      replace: replace,
    );
    if (result is AcpSessionLaunchBlocked && mounted) {
      final choice = await showAcpConcurrencyChoice(
        context,
        decision: result.decision,
        managerState: manager.state,
      );
      if (choice == null) {
        return null;
      }
      return _resolveConcurrency(choice, result.decision, cwd);
    }
    return result;
  }

  Future<AcpSessionLaunchResult?> _resolveConcurrency(
    AcpConcurrencyChoice choice,
    AcpConcurrencyRequiresChoice decision,
    String cwd,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    switch (choice) {
      case AcpConcurrencyChoice.stopAndContinue:
        final blocking = [
          for (final value in decision.blockingSessionKeys)
            manager.state.byKeyValue(value)?.key,
        ].whereType<AcpSessionKey>().toList(growable: false);
        return _reconnect(cwd: cwd, replace: blocking);
      case AcpConcurrencyChoice.upgrade:
        await context.push<void>('/upgrade?feature=concurrentAcpSessions');
        if (!mounted) {
          return null;
        }
        final unlocked = ref
            .read(monetizationServiceProvider)
            .currentState
            .isProUnlocked;
        return unlocked ? _reconnect(cwd: cwd) : null;
    }
  }

  /// Returns a live SFTP client owned by the host's current SSH connection,
  /// reopening it when the cached client belongs to a stale connectionId (for
  /// example after a host reconnect) or has not been opened yet.
  Future<SftpClient?> _ensureSftpClient() async {
    final session = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull;
    if (session == null) {
      return _sftpCache.ensure(connectionId: null, open: _throwNoSession);
    }
    return _sftpCache.ensure(
      connectionId: session.connectionId,
      open: session.sftp,
    );
  }

  static Future<SftpClient> _throwNoSession() =>
      throw StateError('No SSH session');

  void _ensurePiModelScope(AcpSessionState session) {
    if (_key.providerId != AcpBuiltinProviderIds.pi) {
      return;
    }
    final connectionId = _currentConnectionId();
    if (connectionId == null) {
      return;
    }
    final identity = '$connectionId:${session.cwd}';
    if (_piModelScopeLoading || _piModelScopeIdentity == identity) {
      return;
    }
    _piModelScopeLoading = true;
    unawaited(_loadPiModelScope(identity, session.cwd));
  }

  Future<void> _loadPiModelScope(String identity, String? cwd) async {
    List<String>? patterns;
    try {
      final sftp = await _ensureSftpClient();
      if (sftp != null) {
        patterns = await const PiModelScopeMetadataService().load(
          sftp,
          cwd: cwd,
        );
      }
    } on Object {
      patterns = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _piModelScopeIdentity = identity;
      _piEnabledModelPatterns = patterns;
      _piModelScopeLoading = false;
    });
  }

  void _publishScrollState() {
    if (!_scroll.hasClients) return;
    widget.onScrollChanged?.call(
      _key,
      AcpChatScrollState(offset: _scroll.offset, autoScroll: _autoScroll),
    );
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Programmatic jumps while a lazy Markdown list is still discovering its
    // extent are not evidence that the user left the tail. Only explicit user
    // scroll notifications in [_handleTranscriptScroll] may disable follow.
    _publishScrollState();
  }

  bool _handleTranscriptScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final isUserStart =
        notification is ScrollStartNotification &&
        notification.dragDetails != null;
    final isUserMove =
        notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle;
    if ((isUserStart || isUserMove) && !_userDraggingTranscript) {
      setState(() {
        _userDraggingTranscript = true;
        _autoScroll = false;
        _showJumpToLatest = true;
      });
    } else if (notification is ScrollEndNotification &&
        _userDraggingTranscript) {
      final nearBottom =
          notification.metrics.pixels >=
          notification.metrics.maxScrollExtent - 2;
      setState(() {
        _userDraggingTranscript = false;
        _autoScroll = nearBottom;
        _showJumpToLatest = !nearBottom;
      });
      _publishScrollState();
    }
    return false;
  }

  void _scheduleInitialScrollRestore() {
    if (_initialScrollSettled || _initialScrollScheduled) return;
    _initialScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialScrollScheduled = false;
      if (!mounted || _initialScrollSettled || !_scroll.hasClients) return;
      final retained = widget.initialScrollState;
      if (retained != null && !retained.autoScroll) {
        _initialScrollSettled = true;
        _publishScrollState();
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      _initialScrollSettleTimer ??= Timer(const Duration(milliseconds: 60), () {
        _initialScrollSettleTimer = null;
        if (!mounted || !_scroll.hasClients) return;
        if (!_autoScroll || _userDraggingTranscript) {
          _initialScrollSettled = true;
          _publishScrollState();
          return;
        }
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        _initialScrollSettled = true;
        _publishScrollState();
      });
    });
  }

  void _handleStickyPromptTap() {
    if (_autoScroll || !_showJumpToLatest) {
      setState(() {
        _autoScroll = false;
        _showJumpToLatest = true;
      });
    }
    _publishScrollState();
  }

  void _scheduleAutoScroll() {
    if (!_autoScroll) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_autoScroll) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) {
      return;
    }
    setState(() {
      _autoScroll = true;
      _showJumpToLatest = false;
    });
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  AcpComposerAttachmentActions _attachmentActions(AcpSessionState session) {
    final connectionId = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull
        ?.connectionId;
    final builder = widget.attachmentActionsBuilder;
    if (builder != null) {
      return builder(widget.hostId, connectionId);
    }
    return AcpComposerAttachmentActions(
      pickPhotos: _pickPhotos,
      pickFiles: _pickFiles,
      pickRemoteFiles: (context) =>
          _pickRemoteFiles(context, connectionId, session.cwd),
    );
  }

  Future<List<AcpAttachmentCandidate>> _pickPhotos(BuildContext context) async {
    // Pick images and videos together, preserving the existing XFile adapter
    // and the composer's size/count limits.
    final files = await ImagePicker().pickMultipleMedia();
    return [
      for (final file in files) await acpAttachmentCandidateFromXFile(file),
    ];
  }

  Future<List<AcpAttachmentCandidate>> _pickFiles(BuildContext context) async {
    // pickFiles selects multiple files by default in the current file_picker
    // (the explicit allowMultiple flag is deprecated); adapters/limits are
    // preserved by the shared PlatformFile adapter below.
    final files = await FilePicker.pickFiles();
    return [
      for (final file in files)
        await acpAttachmentCandidateFromPlatformFile(file),
    ];
  }

  Future<List<AcpAttachmentCandidate>> _pickRemoteFiles(
    BuildContext context,
    int? connectionId,
    String startDirectory,
  ) async {
    final selection = await showRemoteFilePicker(
      context: context,
      hostId: widget.hostId,
      connectionId: connectionId,
      startDirectory: startDirectory,
      constraints: const RemoteFilePickerConstraints(allowMultiple: true),
    );
    if (selection == null) {
      return const [];
    }
    return [
      for (final file in selection)
        acpAttachmentCandidateFromRemoteFileSelection(file),
    ];
  }

  Widget? _buildQuickConfigControls(AcpSessionState session) {
    final selectors = _quickConfigSelectors(session);
    if (selectors.isEmpty) {
      return null;
    }
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        key: const ValueKey('acp-composer-controls'),
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: selectors.length,
          separatorBuilder: (_, _) =>
              const SizedBox(width: FluttyTheme.spacingXs),
          itemBuilder: (context, index) {
            final selector = selectors[index];
            return _AcpQuickSelector(
              key: selector.label == 'Permission'
                  ? const ValueKey('permission-mode-pill')
                  : ValueKey(selector.label),
              selector: selector,
            );
          },
        ),
      ),
    );
  }

  List<_AcpQuickSelectorData> _quickConfigSelectors(AcpSessionState session) {
    final manager = ref.read(acpSessionManagerProvider);
    final generic = session.configOptions.whereType<AcpSelectConfigOption>();
    AcpSelectConfigOption? firstMatching(
      bool Function(AcpSelectConfigOption option) matches,
    ) => generic.where(matches).firstOrNull;

    final modelOption = firstMatching(
      (option) => (option.category ?? '').toLowerCase() == 'model',
    );
    final effortOption = firstMatching(_quickConfigOptionIsEffort);
    final permissionOption = firstMatching(_quickConfigOptionIsPermissionMode);
    final permissionToggle = session.configOptions
        .whereType<AcpBooleanConfigOption>()
        .where(_quickConfigOptionIsPermissionMode)
        .firstOrNull;
    final modeOption = firstMatching(
      (option) =>
          (option.category ?? '').toLowerCase() == 'mode' &&
          !_quickConfigOptionIsEffort(option) &&
          !_quickConfigOptionIsPermissionMode(option),
    );
    final selectors = <_AcpQuickSelectorData>[];
    final displayedOptionIds = <String>{};

    void addGeneric(
      String label,
      AcpSelectConfigOption? option, {
      bool scopePiModels = false,
    }) {
      if (option == null) {
        return;
      }
      final allChoices = _quickConfigChoices(option);
      if (allChoices.isEmpty) {
        return;
      }
      displayedOptionIds.add(option.id);
      final partition = scopePiModels
          ? _partitionPiModelChoices(allChoices, option.currentValue)
          : (visible: allChoices, hidden: const <_AcpQuickChoice>[]);
      selectors.add(
        _AcpQuickSelectorData(
          label: label,
          currentValue: option.currentValue,
          choices: partition.visible,
          hiddenChoices: partition.hidden,
          onSelected: (value) =>
              manager.setConfigOption(_key, configId: option.id, value: value),
        ),
      );
    }

    addGeneric('Model', modelOption, scopePiModels: true);
    if (modelOption == null) {
      final state = session.modelState;
      if (state != null && state.availableModels.isNotEmpty) {
        final allChoices = [
          for (final model in state.availableModels)
            _AcpQuickChoice(
              value: model.id,
              label: model.name.isEmpty ? model.id : model.name,
              description: model.description,
            ),
        ];
        final partition = _partitionPiModelChoices(
          allChoices,
          state.currentModelId,
        );
        selectors.add(
          _AcpQuickSelectorData(
            label: 'Model',
            currentValue: state.currentModelId,
            choices: partition.visible,
            hiddenChoices: partition.hidden,
            onSelected: (value) => manager.setModel(_key, value),
          ),
        );
      }
    }

    addGeneric('Effort', effortOption);
    final legacyModeState = session.modeState;
    final legacyModeIsEffort =
        legacyModeState != null && _legacyModeStateIsEffort(legacyModeState);
    if (legacyModeState != null &&
        legacyModeState.availableModes.isNotEmpty &&
        (legacyModeIsEffort ? effortOption == null : modeOption == null)) {
      selectors.add(
        _AcpQuickSelectorData(
          label: legacyModeIsEffort ? 'Effort' : 'Mode',
          currentValue: legacyModeState.currentModeId,
          choices: [
            for (final mode in legacyModeState.availableModes)
              _AcpQuickChoice(
                value: mode.id,
                label: mode.name.isEmpty ? mode.id : mode.name,
                description: mode.description,
              ),
          ],
          onSelected: (value) => manager.setMode(_key, value),
        ),
      );
    }
    addGeneric('Mode', modeOption);

    addGeneric('Permission', permissionOption);
    if (permissionOption == null) {
      if (permissionToggle != null) {
        displayedOptionIds.add(permissionToggle.id);
      }
      final autoApprove =
          permissionToggle?.currentValue ?? session.autoApprovePermissions;
      final onSelected = permissionToggle != null
          ? (String value) => manager.setConfigOption(
              _key,
              configId: permissionToggle.id,
              value: value == 'true',
            )
          : (String value) => manager.setAutoApprovePermissions(
              _key,
              enabled: value == 'true',
            );
      selectors.add(
        _AcpQuickSelectorData(
          label: 'Permission',
          currentValue: autoApprove ? 'true' : 'false',
          choices: const [
            _AcpQuickChoice(
              value: 'false',
              label: 'Ask',
              description: 'Ask before protected actions.',
            ),
            _AcpQuickChoice(
              value: 'true',
              label: 'YOLO',
              description: 'Auto-approve supported actions for this session.',
            ),
          ],
          onSelected: onSelected,
        ),
      );
    }

    // ACP providers may use extension categories such as Codex's
    // model_config (Fast mode) or collaboration_mode. Preserve the canonical
    // Model / Effort / Mode ordering above, then surface every remaining
    // advertised select option instead of silently hiding it.
    for (final option in generic) {
      if (!displayedOptionIds.contains(option.id)) {
        addGeneric(option.name.isEmpty ? option.id : option.name, option);
      }
    }
    return selectors;
  }

  bool _quickConfigOptionIsPermissionMode(AcpSessionConfigOption option) {
    final category = (option.category ?? '').toLowerCase();
    final identity = '${option.id} ${option.name}'.toLowerCase();
    return category == 'permission' ||
        category == 'permissions' ||
        identity.contains('permission') ||
        identity.contains('approval') ||
        identity.contains('auto-approve') ||
        identity.contains('yolo');
  }

  bool _quickConfigOptionIsEffort(AcpSelectConfigOption option) {
    final identity = '${option.id} ${option.name}'.toLowerCase();
    if (identity.contains('effort') ||
        identity.contains('reasoning') ||
        identity.contains('thinking')) {
      return true;
    }
    final values = [
      for (final value in option.options) value.value,
      for (final group in option.groups)
        for (final value in group.options) value.value,
    ];
    return values.any(_isEffortStrengthLevel) && values.every(_isEffortLevel);
  }

  bool _legacyModeStateIsEffort(AcpSessionModeState state) =>
      state.availableModes.any(
        (mode) =>
            _isEffortStrengthLevel(mode.id) ||
            _isEffortStrengthLevel(mode.name),
      ) &&
      state.availableModes.every(
        (mode) => _isEffortLevel(mode.id) || _isEffortLevel(mode.name),
      );

  bool _isEffortStrengthLevel(String value) => const {
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
  }.contains(_normalizedConfigValue(value));

  bool _isEffortLevel(String value) {
    final normalized = _normalizedConfigValue(value);
    return const {
      'off',
      'none',
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
      'auto',
      'default',
    }.contains(normalized);
  }

  String _normalizedConfigValue(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

  List<_AcpQuickChoice> _quickConfigChoices(AcpSelectConfigOption option) => [
    for (final value in option.options)
      _AcpQuickChoice(
        value: value.value,
        label: value.name.isEmpty ? value.value : value.name,
        description: value.description,
      ),
    for (final group in option.groups)
      for (final value in group.options)
        _AcpQuickChoice(
          value: value.value,
          label: group.name.isEmpty
              ? (value.name.isEmpty ? value.value : value.name)
              : '${group.name} · ${value.name.isEmpty ? value.value : value.name}',
          description: value.description,
        ),
  ];

  ({List<_AcpQuickChoice> visible, List<_AcpQuickChoice> hidden})
  _partitionPiModelChoices(
    List<_AcpQuickChoice> allChoices,
    String currentValue,
  ) {
    final patterns = _piEnabledModelPatterns;
    if (_key.providerId != AcpBuiltinProviderIds.pi ||
        patterns == null ||
        patterns.isEmpty) {
      return (visible: allChoices, hidden: const <_AcpQuickChoice>[]);
    }
    final byValue = <String, _AcpQuickChoice>{
      for (final choice in allChoices) choice.value: choice,
    };
    final scopedIds = resolvePiScopedModelIds(
      patterns: patterns,
      availableModelIds: byValue.keys.toList(growable: false),
      modelNames: <String, String>{
        for (final choice in allChoices) choice.value: choice.label,
      },
    );
    final visible = <_AcpQuickChoice>[for (final id in scopedIds) ?byValue[id]];
    final current = byValue[currentValue];
    if (current != null &&
        !visible.any((choice) => choice.value == currentValue)) {
      visible.insert(0, current);
    }
    final visibleValues = visible.map((choice) => choice.value).toSet();
    final hidden = allChoices
        .where((choice) => !visibleValues.contains(choice.value))
        .toList(growable: false);
    return (
      visible: List<_AcpQuickChoice>.unmodifiable(visible),
      hidden: List<_AcpQuickChoice>.unmodifiable(hidden),
    );
  }

  Future<void> _openConfig() => showAcpConfigOptions(context, sessionKey: _key);

  List<AcpPermissionPrompt> _prompts(AcpSessionState session) {
    final manager = ref.read(acpSessionManagerProvider);
    final toolTitles = session.pendingPermissions.isEmpty
        ? const <String, String>{}
        : <String, String>{
            for (final entry
                in session.timeline.entries
                    .whereType<domain.AcpToolCallEntry>())
              if (entry.title?.trim().isNotEmpty ?? false)
                entry.toolCallId: entry.title!.trim(),
          };
    return [
      for (final pending in session.pendingPermissions)
        acpToolPromptFromSession(
          pending,
          onSelect: (optionId) =>
              manager.respondToPermission(_key, pending.requestKey, optionId),
          onCancel: () => manager.cancelPermission(_key, pending.requestKey),
          toolTitle: toolTitles[pending.toolCallId],
        ),
      for (final write in session.pendingWrites)
        AcpWritePermissionPrompt(
          stableKey: 'write:${write.sessionId}:${write.requestKey}',
          fileName: _basename(write.path),
          contentBytes: write.contentByteLength,
          onApprove: () => manager.approveWrite(_key, write.requestKey),
          onReject: () => manager.rejectWrite(_key, write.requestKey),
          revealContent: () =>
              manager.pendingWriteContent(_key, write.requestKey) ?? '',
        ),
    ];
  }

  /// Resolves a chat image to bounded bytes without ever implicitly fetching
  /// over the network.
  ///
  /// In-memory and `data:` images are handled by [AcpInlineImage] itself and
  /// never reach here. Same-host `file:` (or absolute-path) URIs are read via
  /// SFTP up to the shared inline image byte cap; `http(s)`/unknown URIs are
  /// never fetched and resolve to `null`.
  Future<Uint8List?> _resolveChatImage(ui.AcpImageContent image) async {
    final inline = image.bytes;
    if (inline != null) {
      return inline;
    }
    final uri = image.uri;
    if (uri == null || uri.isEmpty || uri.startsWith('data:')) {
      return null;
    }
    if (uri.startsWith('file:')) {
      final parsed = Uri.tryParse(uri);
      final path = parsed?.path;
      return (path != null && path.isNotEmpty)
          ? _readRemoteImageBytes(path)
          : null;
    }
    if (uri.startsWith('/')) {
      return _readRemoteImageBytes(uri);
    }
    // http(s) and unknown schemes are never fetched implicitly.
    return null;
  }

  /// Reads a same-host remote file over SFTP, bounded to the shared inline
  /// image byte cap. Oversized files (declared or streamed) resolve to `null`
  /// so a hostile path can never force an unbounded read into memory.
  Future<Uint8List?> _readRemoteImageBytes(String path) async {
    final sftp = await _ensureSftpClient();
    if (sftp == null) {
      return null;
    }
    try {
      final stat = await sftp.stat(path);
      final size = stat.size;
      if (size != null && size > kAcpMaxInlineImageBytes) {
        return null;
      }
      final file = await sftp.open(path);
      final builder = BytesBuilder(copy: false);
      try {
        await for (final chunk in file.read()) {
          builder.add(chunk);
          if (builder.length > kAcpMaxInlineImageBytes) {
            return null;
          }
        }
      } finally {
        await file.close();
      }
      return builder.takeBytes();
    } on Object {
      return null;
    }
  }

  void _openImageViewer(ui.AcpImageContent image) {
    final size = MediaQuery.sizeOf(context);
    showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierColor: Colors.black,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SizedBox(
          key: const ValueKey('acp-image-viewer'),
          width: size.width,
          height: size.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 8,
                  boundaryMargin: const EdgeInsets.all(96),
                  clipBehavior: Clip.none,
                  child: Center(
                    child: AcpInlineImage(
                      image: image,
                      resolver: _resolveChatImage,
                      maxWidth: size.width,
                      maxHeight: size.height,
                      showFrame: false,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(FluttyTheme.spacingSm),
                    child: IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        foregroundColor: Colors.white,
                      ),
                      tooltip: 'Close image',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMarkdownLink(String text, String? href, String title) {
    final target = href?.trim();
    if (target == null || target.isEmpty) return;
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    switch (uri.scheme.toLowerCase()) {
      case 'http' || 'https' || 'mailto':
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      case 'file':
        _openRemotePath(uri.path);
      case '':
        if (target.startsWith('/') ||
            target.startsWith('~/') ||
            target.startsWith('./') ||
            target.startsWith('../')) {
          _openRemotePath(target);
        }
      default:
        return;
    }
  }

  void _openResource(ui.AcpResourceRef resource) {
    final uri = resource.uri;
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      final parsed = Uri.tryParse(uri);
      if (parsed != null) {
        unawaited(launchUrl(parsed, mode: LaunchMode.externalApplication));
      }
      return;
    }
    _openRemotePath(uri.startsWith('file:') ? Uri.parse(uri).path : uri);
  }

  void _openRemotePath(String path) {
    final connectionId = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull
        ?.connectionId;
    final location = Uri(
      path: '/sftp/${widget.hostId}',
      queryParameters: {
        'path': path,
        if (connectionId != null) 'connectionId': '$connectionId',
      },
    ).toString();
    context.push<void>(location);
  }

  void _copyToClipboard(String value, String label) {
    unawaited(Clipboard.setData(ClipboardData(text: value)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  @override
  Widget build(BuildContext context) {
    final sessionProvider = acpSessionManagerStateProvider.select(
      (state) => state.asData?.value.byKeyValue(_key.value),
    );
    ref.listen<AcpSessionState?>(sessionProvider, (previousSession, session) {
      _composer.updateSession(session);
      if (!identical(previousSession?.timeline, session?.timeline)) {
        _scheduleAutoScroll();
      }
      if (session != null && session.status == AcpConnectionStatus.ready) {
        unawaited(_ensureSftpClient());
      }
    });

    final session = ref.watch(sessionProvider);
    _scheduleInitialScrollRestore();
    final fontSize = clampAgentChatFontSize(
      widget.preferredFontSize ?? ref.watch(fontSizeNotifierProvider),
    );
    final fontFamily =
        widget.preferredFontFamily ??
        ref.watch(fontFamilyNotifierProvider) ??
        'monospace';
    final onFontSizeCommitted =
        widget.onFontSizeCommitted ??
        (double size) => unawaited(
          ref.read(fontSizeNotifierProvider.notifier).setFontSize(size),
        );
    Widget wrapContent(Widget child) => _AgentChatZoomSurface(
      fontSize: fontSize,
      fontFamily: fontFamily,
      onFontSizeCommitted: onFontSizeCommitted,
      child: child,
    );

    final isWide = MediaQuery.sizeOf(context).width >= kAgentChatWideBreakpoint;
    if (isWide && !widget.embedded) {
      return Scaffold(
        body: Row(
          children: [
            AcpSessionRail(currentKey: _key),
            Expanded(
              child: _buildConversation(
                session,
                showBack: true,
                contentWrapper: wrapContent,
              ),
            ),
          ],
        ),
      );
    }
    return _buildConversation(
      session,
      showBack: !widget.embedded,
      contentWrapper: wrapContent,
    );
  }

  AcpNativePreviewSnapshot? _buildNativePreview(
    List<ui.AcpTimelineEntry> entries,
    AcpStatusDisplay activity,
  ) {
    final lines = <AcpNativePreviewLine>[];
    void add(AcpNativePreviewLine line) {
      if (line.text.isEmpty) return;
      lines.insert(0, line);
      if (lines.length > 6) lines.removeLast();
    }

    for (final entry in entries.reversed) {
      switch (entry) {
        case ui.AcpUserPromptEntry(:final parts):
          final content = parts
              .map(
                (part) => switch (part) {
                  ui.AcpTextPart(:final text) => text,
                  ui.AcpImagePart() => '[image]',
                  ui.AcpResourcePart(:final resource) =>
                    '[${resource.displayName}]',
                },
              )
              .join(' ');
          add(
            AcpNativePreviewLine(
              kind: AcpNativePreviewKind.user,
              text: _boundedNativePreviewText(content),
            ),
          );
        case ui.AcpAssistantMessageEntry(:final markdown, :final status):
          add(
            AcpNativePreviewLine(
              kind: AcpNativePreviewKind.agent,
              text: _boundedNativePreviewText(markdown),
              active: status == ui.AcpStreamStatus.streaming,
            ),
          );
        case ui.AcpToolCallEntry(:final toolCall):
          add(
            AcpNativePreviewLine(
              kind: AcpNativePreviewKind.tool,
              text: _boundedNativePreviewText(toolCall.title),
              active:
                  toolCall.status == ui.AcpToolStatus.pending ||
                  toolCall.status == ui.AcpToolStatus.running,
            ),
          );
        case ui.AcpStatusEntry(:final message):
          add(
            AcpNativePreviewLine(
              kind: AcpNativePreviewKind.status,
              text: _boundedNativePreviewText(message),
            ),
          );
        case ui.AcpThoughtEntry(:final status):
          if (status == ui.AcpStreamStatus.streaming) {
            add(
              const AcpNativePreviewLine(
                kind: AcpNativePreviewKind.status,
                text: 'Thinking',
                active: true,
              ),
            );
          }
        case ui.AcpSubagentTranscriptEntry() ||
            ui.AcpPlanEntry() ||
            ui.AcpUsageEntry():
          break;
      }
      if (lines.length >= 6) break;
    }
    if (lines.isEmpty && activity.isReady) return null;
    return AcpNativePreviewSnapshot(
      lines: lines,
      progressFraction: activity.progressFraction,
      indeterminate: activity.indeterminate,
    );
  }

  String _boundedNativePreviewText(String value) {
    final normalized = value
        .replaceAll(RegExp('[`*_>#]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length <= 180) return normalized;
    return '${normalized.substring(0, 179)}…';
  }

  Widget _buildConversation(
    AcpSessionState? session, {
    required bool showBack,
    required Widget Function(Widget child) contentWrapper,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (session == null) {
      final content = _connectError != null
          ? _buildConnectError(_connectError!)
          : _connecting
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: TextButton.icon(
                onPressed: _ensureConnected,
                icon: const Icon(Icons.refresh),
                label: const Text('Reconnect'),
              ),
            );
      return Scaffold(
        resizeToAvoidBottomInset: !widget.embedded,
        appBar: widget.embedded
            ? null
            : AppBar(
                automaticallyImplyLeading: showBack,
                title: Text('Agent', style: FluttyTheme.displayMono()),
              ),
        body: contentWrapper(content),
      );
    }

    _ensurePiModelScope(session);
    final entries = _timelineMapperCache.map(session);
    final activity = acpSessionActivityDisplay(session);
    _queuePreviewPublish(session, entries, activity);
    final prompts = _prompts(session);
    final quickConfigControls = _buildQuickConfigControls(session);

    return Scaffold(
      resizeToAvoidBottomInset: !widget.embedded,
      appBar: widget.embedded
          ? null
          : AppBar(
              automaticallyImplyLeading: showBack,
              titleSpacing: 0,
              title: Tooltip(
                message: 'Switch agent session',
                child: InkWell(
                  onTap: widget.embedded
                      ? null
                      : () => showAcpSessionSwitcher(context, currentKey: _key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FluttyTheme.spacingSm,
                      vertical: FluttyTheme.spacingXs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                acpSessionDisplayTitle(session),
                                style: FluttyTheme.displayMono(fontSize: 16),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${session.providerLabel} · '
                                '${acpCwdSummary(session.cwd)} · '
                                '${activity.label}',
                                style: FluttyTheme.monoStyle.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (!widget.embedded)
                          const Icon(Icons.expand_more, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                if (!widget.embedded)
                  IconButton(
                    tooltip: 'MonkeyMux windows',
                    icon: const Icon(Icons.window_outlined),
                    onPressed: _openMonkeyMuxWindows,
                  ),
                _buildOverflowMenu(session),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            child: contentWrapper(
              SafeArea(
                top: false,
                bottom: !widget.embedded,
                child: Column(
                  children: [
                    if (session.status != AcpConnectionStatus.ready)
                      _buildSessionStatusBanner(session)
                    else if (!activity.isReady && activity.label != 'working')
                      _SessionStatusBanner(
                        message: switch (activity.label) {
                          'working' => 'agent is working',
                          'sending' => 'sending prompt',
                          'cancelling' => 'cancelling current turn',
                          _ => activity.label,
                        },
                        icon: activity.icon,
                        tone: activity.tone,
                        transitioning:
                            session.promptStatus != AcpPromptStatus.idle &&
                            !activity.needsInput,
                        progressFraction: widget.embedded
                            ? null
                            : activity.progressFraction,
                        indeterminateProgress:
                            !widget.embedded && activity.indeterminate,
                      ),
                    Expanded(
                      child: Stack(
                        children: [
                          if (entries.isEmpty)
                            _AcpEmptyConversation(
                              providerLabel: session.providerLabel,
                              cwd: acpCwdSummary(session.cwd),
                            )
                          else
                            NotificationListener<ScrollMetricsNotification>(
                              onNotification: (_) {
                                _scheduleAutoScroll();
                                return false;
                              },
                              child: NotificationListener<ScrollNotification>(
                                onNotification: _handleTranscriptScroll,
                                child: AcpMessageThread(
                                  entries: entries,
                                  controller: _scroll,
                                  followTail: _autoScroll,
                                  onStickyPromptTap: _handleStickyPromptTap,
                                  footer:
                                      session.promptStatus ==
                                          AcpPromptStatus.idle
                                      ? null
                                      : IgnorePointer(
                                          key: const ValueKey(
                                            'acp-running-cursor',
                                          ),
                                          child: CursorBlock(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            size: 12,
                                          ),
                                        ),
                                  imageResolver: _resolveChatImage,
                                  onTapImage: _openImageViewer,
                                  onOpenResource: _openResource,
                                  onCopyResource: (resource) =>
                                      _copyToClipboard(
                                        resource.uri,
                                        'Resource',
                                      ),
                                  onTapLink: _openMarkdownLink,
                                  onCopyCode: (code) =>
                                      _copyToClipboard(code, 'Code'),
                                  onOpenLocation: (location) =>
                                      _openRemotePath(location.path),
                                ),
                              ),
                            ),
                          if (_showJumpToLatest)
                            Positioned(
                              right: FluttyTheme.spacingMd,
                              bottom: FluttyTheme.spacingMd,
                              child: SizedBox.square(
                                dimension: 44,
                                child: FloatingActionButton.small(
                                  heroTag: 'acp-jump-latest',
                                  tooltip: 'Jump to latest',
                                  onPressed: _jumpToLatest,
                                  child: const Icon(Icons.arrow_downward),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (prompts.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.34,
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FluttyTheme.spacingMd,
                          ),
                          child: AcpPermissionSurface(prompts: prompts),
                        ),
                      ),
                    AcpComposer(
                      controller: _composer,
                      attachmentActions: _attachmentActions(session),
                      focusController: widget.composerFocusController,
                      controls: quickConfigControls,
                      useBottomSafeArea: !widget.embedded,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionStatusBanner(AcpSessionState session) {
    final status = session.status;
    final transitioning =
        status == AcpConnectionStatus.idle ||
        status == AcpConnectionStatus.connecting ||
        status == AcpConnectionStatus.initializing ||
        status == AcpConnectionStatus.reconnecting;
    final (message, icon) = switch (status) {
      AcpConnectionStatus.idle => ('agent is getting ready', Icons.schedule),
      AcpConnectionStatus.connecting => ('connecting to agent', Icons.link),
      AcpConnectionStatus.initializing => (
        'initializing native chat',
        Icons.settings_outlined,
      ),
      AcpConnectionStatus.reconnecting => ('reattaching session', Icons.sync),
      AcpConnectionStatus.authenticationRequired => (
        'agent sign-in required',
        Icons.lock_outline,
      ),
      AcpConnectionStatus.detached => (
        'session is detached',
        Icons.pause_circle_outline,
      ),
      AcpConnectionStatus.bridgeExpired => (
        'remote session expired',
        Icons.history_toggle_off,
      ),
      AcpConnectionStatus.providerExited => (
        'agent process exited',
        Icons.exit_to_app,
      ),
      AcpConnectionStatus.failed => (
        'agent connection failed',
        Icons.error_outline,
      ),
      AcpConnectionStatus.closed => ('session is closed', Icons.link_off),
      AcpConnectionStatus.ready => ('ready', Icons.check_circle_outline),
    };
    return _SessionStatusBanner(
      message: message,
      icon: icon,
      transitioning: transitioning,
      actionLabel: status == AcpConnectionStatus.authenticationRequired
          ? 'Open terminal'
          : (transitioning ? null : 'Reconnect'),
      onAction: status == AcpConnectionStatus.authenticationRequired
          ? _openTerminalForAuth
          : (transitioning ? null : _ensureConnected),
    );
  }

  Widget _buildConnectError(AcpSessionError error) {
    final canOpenTerminal =
        error.kind == AcpSessionErrorKind.authenticationRequired;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandErrorState(
              title: 'couldn’t open this session',
              message: error.message,
              onRetry: _ensureConnected,
            ),
            const SizedBox(height: FluttyTheme.spacingLg),
            if (canOpenTerminal)
              OutlinedButton.icon(
                onPressed: _openTerminalForAuth,
                icon: const Icon(Icons.terminal),
                label: const Text('Open Terminal'),
              ),
            const SizedBox(height: FluttyTheme.spacingSm),
            TextButton.icon(
              onPressed: _leaveChat,
              icon: const Icon(Icons.window_outlined),
              label: const Text('Back to windows'),
            ),
          ],
        ),
      ),
    );
  }

  void _openMonkeyMuxWindows() {
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
      return;
    }
    if (context.canPop()) {
      context.pop();
      return;
    }
    unawaited(context.push<void>('/terminal/${widget.hostId}'));
  }

  void _leaveChat() {
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
      return;
    }
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(buildAcpSessionFallbackLocation());
  }

  void _openTerminalForAuth() {
    final authCommand = acpTerminalAuthCommandFor(widget.providerId);
    if (authCommand != null) {
      unawaited(
        Clipboard.setData(ClipboardData(text: authCommand.argv.join(' '))),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign-in command copied — run it in the terminal.'),
        ),
      );
    }
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
    } else {
      context.push<void>('/terminal/${widget.hostId}');
    }
  }

  Widget _buildOverflowMenu(AcpSessionState session) {
    final sessionCaps = session.capabilities.session;
    return PopupMenuButton<_ChatAction>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => _handleAction(action, session),
      itemBuilder: (context) => [
        if (session.status == AcpConnectionStatus.ready)
          const PopupMenuItem(
            value: _ChatAction.settings,
            child: ListTile(
              leading: Icon(Icons.tune),
              title: Text('Session settings'),
            ),
          ),
        if (!session.isLive ||
            session.status == AcpConnectionStatus.reconnecting)
          const PopupMenuItem(
            value: _ChatAction.reconnect,
            child: ListTile(
              leading: Icon(Icons.refresh),
              title: Text('Reconnect'),
            ),
          ),
        const PopupMenuItem(
          value: _ChatAction.detach,
          child: ListTile(
            leading: Icon(Icons.pause_circle_outline),
            title: Text('Detach'),
          ),
        ),
        const PopupMenuItem(
          value: _ChatAction.stop,
          child: ListTile(
            leading: Icon(Icons.stop_circle_outlined),
            title: Text('Stop session'),
          ),
        ),
        if (sessionCaps.fork)
          const PopupMenuItem(
            value: _ChatAction.fork,
            child: ListTile(
              leading: Icon(Icons.call_split),
              title: Text('Fork session'),
            ),
          ),
        if (sessionCaps.delete)
          const PopupMenuItem(
            value: _ChatAction.delete,
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Delete session'),
            ),
          ),
      ],
    );
  }

  Future<bool> _confirmDeleteSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete session?'),
        content: const Text(
          'This permanently removes the session from the agent. This action '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete session'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _handleAction(
    _ChatAction action,
    AcpSessionState session,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    try {
      switch (action) {
        case _ChatAction.settings:
          await _openConfig();
        case _ChatAction.reconnect:
          await _ensureConnected();
        case _ChatAction.detach:
          await manager.detachSession(_key);
          if (mounted) _leaveChat();
        case _ChatAction.stop:
          await manager.stopSession(_key);
          if (mounted) _leaveChat();
        case _ChatAction.fork:
          await _fork();
        case _ChatAction.delete:
          if (!await _confirmDeleteSession() || !mounted) return;
          await manager.deleteSession(_key);
          if (mounted) _leaveChat();
      }
    } on Object {
      if (!mounted) return;
      final actionLabel = switch (action) {
        _ChatAction.delete => 'delete',
        _ChatAction.stop => 'stop',
        _ => 'update',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Couldn’t $actionLabel this session. It is still available to retry.',
          ),
        ),
      );
    }
  }

  /// Forks the current session, resolving a free-tier concurrency block with
  /// the same stop-and-continue vs. Pro-upgrade choice used elsewhere, then
  /// opening the new session or surfacing a safe error.
  Future<void> _fork() async {
    final manager = ref.read(acpSessionManagerProvider);
    var result = await manager.forkSession(_key);

    if (result is AcpSessionLaunchBlocked) {
      if (!mounted) {
        return;
      }
      final decision = result.decision;
      final choice = await showAcpConcurrencyChoice(
        context,
        decision: decision,
        managerState: manager.state,
        allowStopAndContinue: !decision.blockingSessionKeys.contains(
          _key.value,
        ),
      );
      if (choice == null || !mounted) {
        return;
      }
      switch (choice) {
        case AcpConcurrencyChoice.stopAndContinue:
          // forkSession has no replace parameter, so free capacity first by
          // stopping the blocking live session(s), then retry the fork.
          for (final value in decision.blockingSessionKeys) {
            final blockingKey = manager.state.byKeyValue(value)?.key;
            if (blockingKey != null) {
              await manager.stopSession(blockingKey);
            }
          }
          if (!mounted) {
            return;
          }
          result = await manager.forkSession(_key);
        case AcpConcurrencyChoice.upgrade:
          await context.push<void>('/upgrade?feature=concurrentAcpSessions');
          if (!mounted) {
            return;
          }
          final unlocked = ref
              .read(monetizationServiceProvider)
              .currentState
              .isProUnlocked;
          if (!unlocked) {
            return;
          }
          result = await manager.forkSession(_key);
      }
    }

    if (!mounted) {
      return;
    }
    switch (result) {
      case AcpSessionLaunchStarted(:final key):
        if (widget.embedded) {
          widget.onSessionChanged?.call(key);
        } else {
          context.replace(
            buildAgentChatLocation(
              hostId: key.hostId,
              providerId: key.providerId,
              bridgeId: key.bridgeId,
              acpSessionId: key.acpSessionId,
            ),
          );
        }
      case AcpSessionLaunchFailed(:final error):
        _showSnack(error.message);
      case AcpSessionLaunchBlocked():
        // Still blocked after the resolution attempt: leave the session as-is.
        break;
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _basename(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final separator = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    final segment = separator >= 0 ? trimmed.substring(separator + 1) : trimmed;
    return segment.isEmpty ? path : segment;
  }
}

@immutable
class _AcpQuickChoice {
  const _AcpQuickChoice({
    required this.value,
    required this.label,
    this.description,
  });

  final String value;
  final String label;
  final String? description;
}

@immutable
class _AcpQuickSelectorData {
  const _AcpQuickSelectorData({
    required this.label,
    required this.currentValue,
    required this.choices,
    required this.onSelected,
    this.hiddenChoices = const <_AcpQuickChoice>[],
  });

  final String label;
  final String currentValue;
  final List<_AcpQuickChoice> choices;
  final List<_AcpQuickChoice> hiddenChoices;
  final Future<void> Function(String value) onSelected;
}

enum _AcpQuickMenuAction { showAll, showScoped }

class _AcpQuickSelector extends StatefulWidget {
  const _AcpQuickSelector({required this.selector, super.key});

  final _AcpQuickSelectorData selector;

  @override
  State<_AcpQuickSelector> createState() => _AcpQuickSelectorState();
}

class _AcpQuickSelectorState extends State<_AcpQuickSelector> {
  final _menuKey = GlobalKey<PopupMenuButtonState<Object>>();
  var _showAll = false;

  _AcpQuickSelectorData get selector => widget.selector;

  @override
  void didUpdateWidget(covariant _AcpQuickSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (selector.hiddenChoices.isEmpty ||
        selector.label != oldWidget.selector.label) {
      _showAll = false;
    }
  }

  Future<void> _onSelected(Object value) async {
    if (value case final _AcpQuickMenuAction action) {
      setState(() => _showAll = action == _AcpQuickMenuAction.showAll);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _menuKey.currentState?.showButtonMenu();
        }
      });
      return;
    }
    try {
      await selector.onSelected(value as String);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not change ${selector.label.toLowerCase()}.'),
          ),
        );
      }
    }
  }

  PopupMenuItem<Object> _choiceItem(
    _AcpQuickChoice choice,
    ColorScheme scheme,
  ) => PopupMenuItem<Object>(
    value: choice.value,
    child: Row(
      children: [
        SizedBox(
          width: 24,
          child: choice.value == selector.currentValue
              ? const Icon(Icons.check, size: 18)
              : null,
        ),
        const SizedBox(width: FluttyTheme.spacingXs),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(choice.label),
              if ((choice.description ?? '').trim().isNotEmpty)
                Text(
                  choice.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allChoices = <_AcpQuickChoice>[
      ...selector.choices,
      ...selector.hiddenChoices,
    ];
    final current = allChoices
        .where((choice) => choice.value == selector.currentValue)
        .firstOrNull;
    final hasScope = selector.hiddenChoices.isNotEmpty;
    final visibleChoices = _showAll ? allChoices : selector.choices;
    return PopupMenuButton<Object>(
      key: _menuKey,
      tooltip: 'Change ${selector.label.toLowerCase()}',
      borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
      onSelected: _onSelected,
      itemBuilder: (context) => <PopupMenuEntry<Object>>[
        PopupMenuItem<Object>(
          enabled: false,
          height: 36,
          child: Text(
            selector.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (hasScope)
          PopupMenuItem<Object>(
            enabled: false,
            height: 28,
            child: Text(
              _showAll ? 'All models' : 'Scoped models',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        for (final choice in visibleChoices) _choiceItem(choice, scheme),
        if (hasScope) ...[
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            value: _showAll
                ? _AcpQuickMenuAction.showScoped
                : _AcpQuickMenuAction.showAll,
            child: Row(
              children: [
                Icon(
                  _showAll ? Icons.unfold_less : Icons.unfold_more,
                  size: 18,
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Flexible(
                  child: Text(
                    _showAll ? 'Show scoped models' : 'Show all models',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(
          child: Ink(
            key: ValueKey('acp-quick-selector-pill-${selector.label}'),
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
            ),
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    current?.label ?? selector.currentValue,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurface,
                      fontSize: 12,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: FluttyTheme.spacingXs),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionStatusBanner extends StatelessWidget {
  const _SessionStatusBanner({
    required this.message,
    required this.icon,
    required this.transitioning,
    this.tone = AcpStatusTone.neutral,
    this.progressFraction,
    this.indeterminateProgress = false,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final bool transitioning;
  final AcpStatusTone tone;
  final double? progressFraction;
  final bool indeterminateProgress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = acpStatusColor(scheme, tone);
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingMd,
            vertical: FluttyTheme.spacingSm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: statusColor),
                  const SizedBox(width: FluttyTheme.spacingSm),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            message,
                            style: AcpChatTypography.monoStyleOf(context)
                                .copyWith(
                                  color: scheme.onSurface,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        if (transitioning) ...[
                          const SizedBox(width: FluttyTheme.spacingSm),
                          SizedBox.square(
                            dimension: 10,
                            child: CircularProgressIndicator.adaptive(
                              strokeWidth: 1.5,
                              valueColor: AlwaysStoppedAnimation(statusColor),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (actionLabel != null)
                    TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ),
              if (progressFraction != null || indeterminateProgress) ...[
                const SizedBox(height: FluttyTheme.spacingXs),
                LinearProgressIndicator(
                  value: indeterminateProgress ? null : progressFraction,
                  minHeight: 2,
                  color: statusColor,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AcpEmptyConversation extends StatelessWidget {
  const _AcpEmptyConversation({required this.providerLabel, required this.cwd});

  final String providerLabel;
  final String cwd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, color: scheme.primary, size: 22),
            const SizedBox(height: FluttyTheme.spacingMd),
            Text(
              'ready when you are',
              style: FluttyTheme.displayMono(
                fontSize: 17,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingXs),
            Text(
              '$providerLabel · $cwd',
              style: FluttyTheme.monoStyle.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
            Text(
              'Type / for commands · Ctrl/⌘ + Enter to send · pinch to resize.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: FluttyTheme.spacingXs),
            Text(
              'Tap the title for sessions; windows stay in the top bar.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentChatZoomSurface extends StatefulWidget {
  const _AgentChatZoomSurface({
    required this.fontSize,
    required this.fontFamily,
    required this.onFontSizeCommitted,
    required this.child,
  });

  final double fontSize;
  final String fontFamily;
  final ValueChanged<double> onFontSizeCommitted;
  final Widget child;

  @override
  State<_AgentChatZoomSurface> createState() => _AgentChatZoomSurfaceState();
}

class _AgentChatZoomSurfaceState extends State<_AgentChatZoomSurface> {
  double? _gestureBaseFontSize;
  double? _localFontSize;
  bool _isPinching = false;
  bool _pinchChangedFontSize = false;

  @override
  void didUpdateWidget(_AgentChatZoomSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isPinching && oldWidget.fontSize != widget.fontSize) {
      _localFontSize = null;
    }
  }

  void _handlePinchStart() {
    final current = _localFontSize ?? widget.fontSize;
    _gestureBaseFontSize = current;
    _pinchChangedFontSize = false;
    setState(() => _isPinching = true);
  }

  void _handlePinchUpdate(double scale) {
    final base = _gestureBaseFontSize;
    if (base == null || !scale.isFinite || scale <= 0) {
      return;
    }
    final next = clampAgentChatFontSize(base * scale);
    if (_localFontSize == next) {
      return;
    }
    setState(() {
      _localFontSize = next;
      _pinchChangedFontSize = next != base;
    });
  }

  void _handlePinchEnd() {
    final committed = _localFontSize ?? widget.fontSize;
    final shouldCommit = _pinchChangedFontSize;
    _gestureBaseFontSize = null;
    _pinchChangedFontSize = false;
    setState(() => _isPinching = false);
    if (shouldCommit) {
      widget.onFontSizeCommitted(committed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = clampAgentChatFontSize(_localFontSize ?? widget.fontSize);
    final mediaQuery = MediaQuery.of(context);
    final inheritedScale = mediaQuery.textScaler.scale(14) / 14;
    final textScaler = TextScaler.linear(inheritedScale * fontSize / 14);
    final theme = Theme.of(context);
    final configuredMono = resolveMonospaceTextStyle(
      widget.fontFamily,
      platform: theme.platform,
    );
    final monoStyle = FluttyTheme.monoStyle.merge(configuredMono);
    Widget child = MediaQuery(
      data: mediaQuery.copyWith(textScaler: textScaler),
      child: AcpChatTypography(monoStyle: monoStyle, child: widget.child),
    );
    if (_isPinching) {
      child = Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            top: 12,
            right: 12,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.inverseSurface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluttyTheme.spacingSm,
                    vertical: FluttyTheme.spacingXs,
                  ),
                  child: Text(
                    '${fontSize.toStringAsFixed(0)} pt',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return TerminalPinchZoomGestureHandler(
      onPinchStart: _handlePinchStart,
      onPinchUpdate: _handlePinchUpdate,
      onPinchEnd: _handlePinchEnd,
      child: child,
    );
  }
}

enum _ChatAction { settings, reconnect, detach, stop, fork, delete }
