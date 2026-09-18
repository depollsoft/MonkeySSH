import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/services/device_debug_service.dart';

/// Opens the Android Wireless ADB setup and status sheet.
Future<void> showDeviceDebugSheet({
  required BuildContext context,
  required DeviceDebugSessionController controller,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _DeviceDebugSheet(controller: controller),
);

class _DeviceDebugSheet extends StatefulWidget {
  const _DeviceDebugSheet({required this.controller});

  final DeviceDebugSessionController controller;

  @override
  State<_DeviceDebugSheet> createState() => _DeviceDebugSheetState();
}

class _DeviceDebugSheetState extends State<_DeviceDebugSheet>
    with WidgetsBindingObserver {
  bool _refreshAfterSettings = false;

  DeviceDebugSessionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_handleControllerChanged);
    if (_controller.state.phase == DeviceDebugPhase.off) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.state.phase == DeviceDebugPhase.off) {
          unawaited(_controller.enable());
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_refreshAfterSettings) {
      return;
    }
    _refreshAfterSettings = false;
    if (!_controller.state.isBusy && !_controller.state.isActive) {
      unawaited(_controller.enable());
    }
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final state = _controller.state;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report_outlined, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Device debugging',
                    style: FluttyTheme.displayMono(
                      fontSize: 18,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Connect the SSH host’s ADB client to this Android device over '
              'the current SSH session.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            _DeviceDebugStatus(state: state),
            if (state.isBusy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (state.phase == DeviceDebugPhase.waitingForPairingCode) ...[
              const SizedBox(height: 20),
              const _PairingSteps(),
              if (_controller.pairingPromptUnavailable) ...[
                const SizedBox(height: 12),
                Text(
                  'MonkeySSH needs notification permission to collect the '
                  'pairing code. Enable notifications, then try again.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
            ],
            if (state.remoteAddress case final address?
                when state.isActive) ...[
              const SizedBox(height: 20),
              Text(
                'Remote ADB serial',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          address,
                          style: FluttyTheme.monoStyle.copyWith(
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _copyRemoteAddress(address),
                        icon: const Icon(Icons.copy_rounded),
                        tooltip: 'Copy ADB serial',
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            ..._buildActions(state),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActions(DeviceDebugState state) {
    switch (state.phase) {
      case DeviceDebugPhase.off:
      case DeviceDebugPhase.searching:
      case DeviceDebugPhase.pairing:
      case DeviceDebugPhase.connecting:
      case DeviceDebugPhase.stopping:
        return const [];
      case DeviceDebugPhase.waitingForWirelessDebugging:
        return [
          FilledButton.icon(
            onPressed: _openDeveloperOptions,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Wireless debugging'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _controller.enable,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Search again'),
          ),
        ];
      case DeviceDebugPhase.waitingForPairingCode:
        return [
          FilledButton.icon(
            onPressed: _openDeveloperOptions,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Wireless debugging'),
          ),
        ];
      case DeviceDebugPhase.active:
        return [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _turnOff,
            child: const Text('Turn off device debugging'),
          ),
        ];
      case DeviceDebugPhase.error:
        return [
          FilledButton.icon(
            onPressed: _controller.enable,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
          if (state.errorKind == DeviceDebugErrorKind.discoveryFailed ||
              state.errorKind == DeviceDebugErrorKind.settingsUnavailable) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _openDeveloperOptions,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Open Wireless debugging'),
            ),
          ],
        ];
    }
  }

  Future<void> _openDeveloperOptions() async {
    final opened = await _controller.openDeveloperOptions();
    _refreshAfterSettings = opened;
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Developer options.')),
      );
    }
  }

  Future<void> _turnOff() async {
    await _controller.stop();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _copyRemoteAddress(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ADB serial copied')));
    }
  }
}

class _PairingSteps extends StatelessWidget {
  const _PairingSteps();

  static const _steps = <String>[
    'Open Wireless debugging, then tap “Pair device with pairing code.”',
    'Leave that screen open — Android cancels pairing if you switch apps.',
    'Swipe down and reply to the MonkeySSH notification with the code.',
    'MonkeySSH reopens once pairing succeeds.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, step) in _steps.indexed) ...[
          if (index > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}.',
                  style: FluttyTheme.monoStyle.copyWith(
                    color: colorScheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  step,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _DeviceDebugStatus extends StatelessWidget {
  const _DeviceDebugStatus({required this.state});

  final DeviceDebugState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (state.phase) {
      DeviceDebugPhase.active => (
        Icons.check_circle_outline_rounded,
        colorScheme.primary,
      ),
      DeviceDebugPhase.error => (
        Icons.error_outline_rounded,
        colorScheme.error,
      ),
      DeviceDebugPhase.waitingForPairingCode when state.errorKind != null => (
        Icons.error_outline_rounded,
        colorScheme.error,
      ),
      DeviceDebugPhase.waitingForWirelessDebugging ||
      DeviceDebugPhase.waitingForPairingCode => (
        Icons.info_outline_rounded,
        colorScheme.tertiary,
      ),
      _ => (Icons.sync_rounded, colorScheme.primary),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                state.message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
