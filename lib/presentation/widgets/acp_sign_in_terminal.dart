/// In-app interactive terminal for an ACP `terminal` sign-in method.
///
/// Runs the agent's own login flow on the remote host in a pseudo-terminal
/// and reports whether it exited with status zero, which the ACP spec defines
/// as success. Output, typed input, and links are never logged or stored.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

import '../../app/theme.dart';
import '../../domain/models/acp_authentication.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/ssh_service.dart';
import 'cursor_block.dart';
import 'keyboard_toolbar.dart';
import 'monkey_terminal_view.dart';
import 'terminal_text_input_handler.dart';
import 'terminal_text_style.dart';

/// An interactive login process attached to a pseudo-terminal.
abstract interface class AcpSignInProcess {
  /// Terminal output (stdout and stderr) as raw bytes.
  Stream<List<int>> get output;

  /// Exit status once the process ends, or `null` when it ended without one
  /// (for example after a signal or a dropped connection).
  Future<int?> get exitStatus;

  /// Sends raw input bytes to the process.
  void write(List<int> bytes);

  /// Informs the process of the visible terminal size.
  void resize(int columns, int rows);

  /// Ends the process and releases its channel.
  void close();
}

/// Starts an [AcpSignInProcess] sized to [columns] x [rows].
typedef AcpSignInProcessStarter = Future<AcpSignInProcess> Function({
  required int columns,
  required int rows,
});

/// Opens [command] over [session] as an interactive PTY exec channel.
///
/// Interactive channels are long-lived, so they bypass the short-command exec
/// queue just like the terminal shell does.
Future<AcpSignInProcess> startAcpSignInOverSsh(
  SshSession session,
  String command, {
  required int columns,
  required int rows,
}) async {
  final channel = await session.execute(
    command,
    pty: SSHPtyConfig(width: columns, height: rows),
  );
  return _SshSignInProcess(channel);
}

final class _SshSignInProcess implements AcpSignInProcess {
  _SshSignInProcess(this._channel) {
    void forward(Uint8List data) {
      if (!_output.isClosed) _output.add(data);
    }

    var openStreams = 2;
    void finish() {
      openStreams -= 1;
      if (openStreams == 0 && !_output.isClosed) unawaited(_output.close());
    }

    _subscriptions
      ..add(_channel.stdout.listen(forward, onDone: finish, onError: (_) {}))
      ..add(_channel.stderr.listen(forward, onDone: finish, onError: (_) {}));
  }

  final SSHSession _channel;
  final _output = StreamController<List<int>>.broadcast();
  final _subscriptions = <StreamSubscription<Uint8List>>[];

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  Future<int?> get exitStatus => _channel.done.then<int?>(
    (_) => _channel.exitCode,
    onError: (Object _) => null,
  );

  @override
  void write(List<int> bytes) {
    try {
      _channel.write(Uint8List.fromList(bytes));
    } on Object {
      // The channel is closing; the exit status reports the outcome.
    }
  }

  @override
  void resize(int columns, int rows) {
    if (columns <= 0 || rows <= 0) return;
    try {
      _channel.resizeTerminal(columns, rows);
    } on Object {
      // Resizing a closing channel is harmless to skip.
    }
  }

  @override
  void close() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    try {
      _channel.close();
    } on Object {
      // Already closed.
    }
    if (!_output.isClosed) unawaited(_output.close());
  }
}

/// Shows the sign-in terminal for [launch] and resolves to `true` only when
/// the login exited with status zero.
Future<bool> showAcpSignInTerminal(
  BuildContext context, {
  required AcpTerminalAuthLaunch launch,
  required AcpSignInProcessStarter start,
}) async {
  final succeeded = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (context) =>
          AcpSignInTerminalScreen(launch: launch, start: start),
    ),
  );
  return succeeded ?? false;
}

enum _SignInPhase { starting, running, failed, unavailable }

/// Full-screen terminal that runs one interactive sign-in and pops with
/// `true` after a zero exit status.
class AcpSignInTerminalScreen extends StatefulWidget {
  /// Creates the sign-in terminal.
  const AcpSignInTerminalScreen({
    required this.launch,
    required this.start,
    super.key,
  });

  /// The login being run.
  final AcpTerminalAuthLaunch launch;

  /// Starts the interactive process.
  final AcpSignInProcessStarter start;

  @override
  State<AcpSignInTerminalScreen> createState() =>
      _AcpSignInTerminalScreenState();
}

const _maxLinkScanCarry = 2048;
final _oscHyperlinkPattern = RegExp(r'\x1b\]8;[^;\x07\x1b]*;([^\x07\x1b]*)');
final _escapeSequencePattern = RegExp(
  r'\x1b\][\s\S]*?(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-_]',
);
final _urlPattern = RegExp(r'''https?://[^\s<>"'`\x00-\x1f\x7f]+''');
final _trailingUrlPunctuation = RegExp(r'[.,;:!?)\]}>]+$');

class _AcpSignInTerminalScreenState extends State<AcpSignInTerminalScreen> {
  final _terminal = Terminal(maxLines: 5000);
  final _terminalFocus = FocusNode(debugLabel: 'acp-sign-in-terminal');
  final _toolbar = KeyboardToolbarController();
  ByteConversionSink? _decodeSink;
  AcpSignInProcess? _process;
  StreamSubscription<List<int>>? _outputSubscription;
  var _phase = _SignInPhase.starting;
  var _attempt = 0;
  int? _exitStatus;
  String? _link;
  var _linkScanCarry = '';
  var _closed = false;

  @override
  void initState() {
    super.initState();
    _terminal
      ..onOutput = _sendText
      ..onResize = (columns, rows, _, _) => _process?.resize(columns, rows);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    _closed = true;
    _stopProcess();
    _terminalFocus.dispose();
    _toolbar.dispose();
    super.dispose();
  }

  void _stopProcess() {
    unawaited(_outputSubscription?.cancel());
    _outputSubscription = null;
    _decodeSink?.close();
    _decodeSink = null;
    _process?.close();
    _process = null;
  }

  Future<void> _run() async {
    if (_closed) return;
    final attempt = ++_attempt;
    _stopProcess();
    setState(() {
      _phase = _SignInPhase.starting;
      _exitStatus = null;
    });
    final AcpSignInProcess process;
    try {
      process = await widget.start(
        columns: _terminal.viewWidth,
        rows: _terminal.viewHeight,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'acp.auth',
        'terminal_start_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (!mounted || attempt != _attempt) return;
      setState(() => _phase = _SignInPhase.unavailable);
      return;
    }
    if (_closed || attempt != _attempt) {
      process.close();
      return;
    }
    _process = process;
    _decodeSink = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_TerminalWriterSink(_onDecodedOutput));
    _outputSubscription = process.output.listen(
      (bytes) => _decodeSink?.addSlice(bytes, 0, bytes.length, false),
    );
    setState(() => _phase = _SignInPhase.running);
    DiagnosticsLogService.instance.info('acp.auth', 'terminal_started');
    final status = await process.exitStatus;
    if (_closed || attempt != _attempt || !mounted) return;
    DiagnosticsLogService.instance.info(
      'acp.auth',
      'terminal_exited',
      fields: {'succeeded': status == 0, 'hasStatus': status != null},
    );
    if (status == 0) {
      _stopProcess();
      Navigator.of(context).pop(true);
      return;
    }
    _terminalFocus.unfocus();
    setState(() {
      _phase = _SignInPhase.failed;
      _exitStatus = status;
    });
  }

  void _onDecodedOutput(String text) {
    if (_closed) return;
    _terminal.write(text);
    _scanForLink(text);
  }

  /// Remembers the most recent http(s) link the login printed, so a device
  /// or OAuth URL can be opened on this phone. Never logged or stored.
  void _scanForLink(String text) {
    final scan = '$_linkScanCarry$text';
    String? found;
    for (final match in _oscHyperlinkPattern.allMatches(scan)) {
      final target = match.group(1);
      if (target != null && _urlPattern.hasMatch(target)) found = target;
    }
    final plain = scan.replaceAll(_escapeSequencePattern, '');
    for (final match in _urlPattern.allMatches(plain)) {
      found = match.group(0)!.replaceFirst(_trailingUrlPunctuation, '');
    }
    _linkScanCarry = scan.length <= _maxLinkScanCarry
        ? scan
        : scan.substring(scan.length - _maxLinkScanCarry);
    if (found != null && found != _link && mounted) {
      setState(() => _link = found);
    }
  }

  void _sendText(String text) {
    _process?.write(utf8.encode(text));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    _terminal.paste(text);
  }

  void _openLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
  }

  void _copyLink(String link) {
    unawaited(Clipboard.setData(ClipboardData(text: link)));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  void _cancel() {
    // Cancellation is a failed sign-in; end the remote login right away.
    _attempt++;
    _stopProcess();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final terminalTheme = TerminalThemes.defaultThemeForBrightness(
      theme.brightness,
    );
    final keyboardAppearance = terminalTheme.isDark
        ? Brightness.dark
        : Brightness.light;
    final isMobile =
        theme.platform == TargetPlatform.iOS ||
        theme.platform == TargetPlatform.android;
    final running = _phase == _SignInPhase.running;
    final description = widget.launch.method.description?.trim();
    final methodName = widget.launch.method.name.trim();

    Widget terminal = MonkeyTerminalView(
      _terminal,
      key: const ValueKey('acp-sign-in-terminal'),
      focusNode: _terminalFocus,
      cursorFocusNode: isMobile ? _terminalFocus : null,
      theme: terminalTheme.toXtermTheme(),
      textStyle: TerminalStyle.fromTextStyle(
        resolveMonospaceTextStyle(
          'monospace',
          platform: theme.platform,
          fontSize: 13,
        ),
      ),
      padding: const EdgeInsets.all(FluttyTheme.spacingSm),
      keyboardAppearance: keyboardAppearance,
      readOnly: !running,
      autofocus: running && !isMobile,
      hardwareKeyboardOnly: isMobile,
      onPasteText: _paste,
    );
    if (isMobile) {
      terminal = TerminalTextInputHandler(
        terminal: _terminal,
        focusNode: _terminalFocus,
        // The terminal view already owns this focus node.
        manageFocus: false,
        keyboardAppearance: keyboardAppearance,
        deleteDetection: true,
        // Logins prompt for codes, tokens, and passwords: keep the platform
        // keyboard from suggesting, dictating, or learning what is typed.
        sensitiveInput: true,
        readOnly: !running,
        onPasteText: _paste,
        resolveTerminalKeyModifiers: () => (
          ctrl: _toolbar.isCtrlActive,
          alt: _toolbar.isAltActive,
          shift: _toolbar.isShiftActive,
        ),
        consumeTerminalKeyModifiers: _toolbar.consumeOneShot,
        applyTerminalTextInputModifiers: _toolbar.applySystemKeyboardModifiers,
        hasActiveToolbarModifier: () =>
            _toolbar.isCtrlActive || _toolbar.isAltActive,
        child: terminal,
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Cancel sign-in',
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Sign in to ${widget.launch.providerLabel}',
              style: FluttyTheme.displayMono(fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
            if (methodName.isNotEmpty)
              Text(
                methodName,
                style: FluttyTheme.monoStyle.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SignInStatusBanner(
            phase: _phase,
            exitStatus: _exitStatus,
            touchInput: isMobile,
            onRetry: () => unawaited(_run()),
          ),
          if (description != null && description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingMd,
                FluttyTheme.spacingSm,
                FluttyTheme.spacingMd,
                FluttyTheme.spacingSm,
              ),
              child: Text(
                description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: ColoredBox(
              color: terminalTheme.background,
              child: SafeArea(top: false, bottom: false, child: terminal),
            ),
          ),
          if (_link case final link?)
            _SignInLinkBar(
              link: link,
              onOpen: () => _openLink(link),
              onCopy: () => _copyLink(link),
            ),
          if (isMobile && running)
            KeyboardToolbar(
              controller: _toolbar,
              terminal: _terminal,
              onPasteRequested: _paste,
              terminalFocusNode: _terminalFocus,
            )
          else
            SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }
}

/// Adapts a chunked UTF-8 decoder to the terminal writer.
final class _TerminalWriterSink implements Sink<String> {
  _TerminalWriterSink(this._write);

  final void Function(String text) _write;

  @override
  void add(String data) {
    if (data.isNotEmpty) _write(data);
  }

  @override
  void close() {}
}

/// Status strip in the chat banner's voice: icon plus lowercase mono label.
class _SignInStatusBanner extends StatelessWidget {
  const _SignInStatusBanner({
    required this.phase,
    required this.exitStatus,
    required this.touchInput,
    required this.onRetry,
  });

  final _SignInPhase phase;
  final int? exitStatus;
  final bool touchInput;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed =
        phase == _SignInPhase.failed || phase == _SignInPhase.unavailable;
    final (message, icon) = switch (phase) {
      _SignInPhase.starting => ('opening terminal on host', Icons.link),
      _SignInPhase.running => (
        touchInput
            ? 'sign-in running · tap to type'
            : 'sign-in running · closes when done',
        Icons.login,
      ),
      _SignInPhase.failed => (
        exitStatus == null
            ? 'sign-in ended without reporting success'
            : 'sign-in exited with status $exitStatus',
        Icons.error_outline,
      ),
      _SignInPhase.unavailable => (
        'couldn’t open a terminal on this host',
        Icons.error_outline,
      ),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FluttyTheme.spacingMd,
              vertical: FluttyTheme.spacingXs,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: failed ? scheme.error : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          message,
                          style: FluttyTheme.monoStyle.copyWith(
                            color: failed ? scheme.error : scheme.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (!failed) ...[
                        const SizedBox(width: FluttyTheme.spacingSm),
                        CursorBlock(color: scheme.onSurface, size: 10),
                      ],
                    ],
                  ),
                ),
                if (failed)
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('Run again'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The most recent link the login printed, ready to open on this device.
class _SignInLinkBar extends StatelessWidget {
  const _SignInLinkBar({
    required this.link,
    required this.onOpen,
    required this.onCopy,
  });

  final String link;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(
          left: FluttyTheme.spacingMd,
          right: FluttyTheme.spacingXs,
        ),
        child: Row(
          children: [
            Icon(Icons.link, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                link,
                key: const ValueKey('acp-sign-in-link'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FluttyTheme.monoStyle.copyWith(
                  color: scheme.onSurface,
                  fontSize: 12,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy link',
              icon: const Icon(Icons.copy_rounded, size: 18),
              color: scheme.onSurfaceVariant,
              onPressed: onCopy,
            ),
            TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open'),
            ),
          ],
        ),
      ),
    );
  }
}
