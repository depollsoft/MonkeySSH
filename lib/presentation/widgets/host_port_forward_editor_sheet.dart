import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/ssh_service.dart';
import 'port_forward_fields.dart';
import 'unsaved_changes_guard.dart';

/// Result returned after saving a host-scoped port forward.
class HostPortForwardEditorResult {
  /// Creates a result with the user-facing save [message].
  const HostPortForwardEditorResult({required this.message});

  /// Message describing the persistence and live-activation outcome.
  final String message;
}

/// Opens the host-scoped port-forward editor used by Host Editor.
Future<HostPortForwardEditorResult?> showHostPortForwardEditorSheet({
  required BuildContext context,
  required int hostId,
  PortForward? existing,
  int? preferredConnectionId,
  bool? requestFocus,
}) => showModalBottomSheet<HostPortForwardEditorResult>(
  context: context,
  isScrollControlled: true,
  isDismissible: false,
  enableDrag: false,
  requestFocus: requestFocus,
  builder: (context) => SafeArea(
    child: AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: PortForwardEditorForm(
        hostId: hostId,
        existing: existing,
        preferredConnectionId: preferredConnectionId,
        defaultRemoteHost: 'localhost',
        defaultAutoStart: true,
        onSaved: (result) => Navigator.pop(context, result),
      ),
    ),
  ),
);

typedef _PortForwardEditDraft = ({
  String name,
  String localHost,
  String localPort,
  String remoteHost,
  String remotePort,
  bool autoStart,
  String forwardType,
  int? selectedHostId,
});

/// Form shared by the standalone and host-scoped port-forward editors.
class PortForwardEditorForm extends ConsumerStatefulWidget {
  /// Creates an editor with a fixed host or a selectable list of hosts.
  const PortForwardEditorForm({
    required this.onSaved,
    this.hostId,
    this.hosts = const [],
    this.existing,
    this.preferredConnectionId,
    this.defaultRemoteHost = '',
    this.defaultAutoStart = false,
    super.key,
  });

  /// Fixed host for the compact sheet, or null to show a host selector.
  final int? hostId;

  /// Hosts available for selection in the standalone screen.
  final List<Host> hosts;

  /// Rule to edit, or null to create a rule.
  final PortForward? existing;

  /// Connection to prefer when applying the saved rule live.
  final int? preferredConnectionId;

  /// Remote host for a new rule.
  final String defaultRemoteHost;

  /// Whether a new rule starts automatically.
  final bool defaultAutoStart;

  /// Called after persistence and any live activation attempt complete.
  final ValueChanged<HostPortForwardEditorResult> onSaved;

  @override
  ConsumerState<PortForwardEditorForm> createState() =>
      _PortForwardEditorFormState();
}

class _PortForwardEditorFormState extends ConsumerState<PortForwardEditorForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _localHostController;
  late final TextEditingController _localPortController;
  late final TextEditingController _remoteHostController;
  late final TextEditingController _remotePortController;
  late bool _autoStart;
  late String _forwardType;
  bool _isSaving = false;
  int? _selectedHostId;
  late _PortForwardEditDraft _initialDraft;

  bool get _compact => widget.hostId != null;

  _PortForwardEditDraft _currentDraft() => (
    name: _nameController.text,
    localHost: _localHostController.text,
    localPort: _localPortController.text,
    remoteHost: _remoteHostController.text,
    remotePort: _remotePortController.text,
    autoStart: _autoStart,
    forwardType: _forwardType,
    selectedHostId: _selectedHostId,
  );

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _localHostController = TextEditingController(
      text: existing?.localHost ?? '127.0.0.1',
    );
    _localPortController = TextEditingController(
      text: existing?.localPort.toString() ?? '',
    );
    _remoteHostController = TextEditingController(
      text: existing?.remoteHost ?? widget.defaultRemoteHost,
    );
    _remotePortController = TextEditingController(
      text: existing?.remotePort.toString() ?? '',
    );
    _autoStart = existing?.autoStart ?? widget.defaultAutoStart;
    _forwardType = existing?.forwardType ?? 'local';
    _selectedHostId = widget.hostId ?? existing?.hostId;
    _initialDraft = _currentDraft();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _localHostController.dispose();
    _localPortController.dispose();
    _remoteHostController.dispose();
    _remotePortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    hasUnsavedChanges: !_compact && _currentDraft() != _initialDraft,
    child: PopScope(
      canPop: !_isSaving,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(_compact ? 20 : 16),
        child: Form(
          key: _formKey,
          onChanged: () => setState(() {}),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_compact) ...[
                Text(
                  _isEditing ? 'Edit Port Forward' : 'Add Port Forward',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
              ],
              TextFormField(
                controller: _nameController,
                enabled: !_isSaving,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: _compact ? 'e.g., Database Tunnel' : 'Web Server',
                  border: _compact ? const OutlineInputBorder() : null,
                  prefixIcon: _compact ? null : const Icon(Icons.label),
                ),
                textInputAction: TextInputAction.next,
                validator: (value) => value == null || value.isEmpty
                    ? (_compact ? 'Name is required' : 'Please enter a name')
                    : null,
              ),
              const SizedBox(height: 16),
              if (!_compact) ...[
                DropdownButtonFormField<int>(
                  initialValue: _selectedHostId,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    prefixIcon: Icon(Icons.computer),
                  ),
                  items: widget.hosts
                      .map(
                        (host) => DropdownMenuItem(
                          value: host.id,
                          child: Text(host.label),
                        ),
                      )
                      .toList(),
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() => _selectedHostId = value),
                  validator: (value) {
                    if (value == null) {
                      return 'Please select a host';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
              ],
              PortForwardTypeField(
                value: _forwardType,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _forwardType = value),
              ),
              const SizedBox(height: 20),
              PortForwardEndpointFields(
                label: 'Local',
                hostController: _localHostController,
                portController: _localPortController,
                hostHint: '127.0.0.1',
                portHint: _compact ? '3306' : '8080',
                compact: _compact,
                enabled: !_isSaving,
              ),
              const SizedBox(height: 16),
              PortForwardEndpointFields(
                label: 'Remote',
                hostController: _remoteHostController,
                portController: _remotePortController,
                hostHint: 'localhost',
                portHint: _compact ? '3306' : '80',
                portInputAction: TextInputAction.done,
                compact: _compact,
                enabled: !_isSaving,
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                title: const Text('Auto-start'),
                subtitle: Text(
                  _compact
                      ? 'Start this forward when connecting'
                      : 'Start forwarding when connecting to host',
                ),
                value: _autoStart,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _autoStart = value),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_compact)
                    TextButton(
                      onPressed: _isSaving
                          ? null
                          : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _isSaving ? null : _save,
                    child: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _compact
                                ? (_isEditing ? 'Save' : 'Add')
                                : (_isEditing
                                      ? 'Save Changes'
                                      : 'Add Port Forward'),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final isRemote = _forwardType == 'remote';
    final bindHost = isRemote
        ? _remoteHostController.text.trim()
        : _localHostController.text.trim();
    if (!isPortForwardLoopbackHost(bindHost)) {
      final confirmed = await confirmPortForwardExposure(
        context: context,
        host: bindHost,
        isRemote: isRemote,
      );
      if (!confirmed || !mounted) {
        return;
      }
    }
    final name = _nameController.text;
    final localHost = _localHostController.text;
    final localPort = int.parse(_localPortController.text);
    final remoteHost = _remoteHostController.text;
    final remotePort = int.parse(_remotePortController.text);
    final autoStart = _autoStart;
    final forwardType = _forwardType;
    final previous = widget.existing;
    final repository = ref.read(portForwardRepositoryProvider);
    final sessions = ref.read(activeSessionsProvider.notifier);
    setState(() => _isSaving = true);

    try {
      late final PortForward savedPortForward;
      if (previous != null) {
        savedPortForward = previous.copyWith(
          name: name,
          hostId: _selectedHostId,
          forwardType: forwardType,
          localHost: localHost,
          localPort: localPort,
          remoteHost: remoteHost,
          remotePort: remotePort,
          autoStart: autoStart,
        );
        await repository.update(savedPortForward);
      } else {
        final portForwardId = await repository.insert(
          PortForwardsCompanion.insert(
            hostId: _selectedHostId!,
            name: name,
            forwardType: forwardType,
            localHost: drift.Value(localHost),
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            autoStart: drift.Value(autoStart),
          ),
        );
        savedPortForward = PortForward(
          id: portForwardId,
          name: name,
          hostId: _selectedHostId!,
          forwardType: forwardType,
          localHost: localHost,
          localPort: localPort,
          remoteHost: remoteHost,
          remotePort: remotePort,
          autoStart: autoStart,
          createdAt: DateTime.now(),
        );
      }

      PortForwardActivationResult? activationResult;
      if (shouldApplyPortForwardLive(
        sessions: sessions,
        portForward: savedPortForward,
        previous: previous,
      )) {
        try {
          activationResult = await activatePortForwardOnConnectedSession(
            sessions: sessions,
            portForward: savedPortForward,
            previous: previous,
            preferredConnectionId: widget.preferredConnectionId,
          );
        } on Exception catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'port forwards',
              context: ErrorDescription(
                'while applying a host port forward live',
              ),
            ),
          );
          activationResult = const PortForwardActivationResult(
            status: PortForwardActivationStatus.failed,
          );
        }
      }

      if (mounted) {
        final result = HostPortForwardEditorResult(
          message: _saveResultMessage(activationResult),
        );
        setState(() {
          _initialDraft = _currentDraft();
          _isSaving = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onSaved(result);
        });
      }
    } on Exception catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'port forwards',
          context: ErrorDescription('while saving a host port forward'),
        ),
      );
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save port forward. Try again.'),
          ),
        );
      }
    }
  }

  String _saveResultMessage(PortForwardActivationResult? activationResult) {
    switch (activationResult?.status) {
      case PortForwardActivationStatus.started:
        return _isEditing
            ? 'Port forward updated and applied live'
            : 'Port forward added and started';
      case PortForwardActivationStatus.failed:
        return 'Port forward saved, but it couldn’t start. '
            'Check the configured ports.';
      case PortForwardActivationStatus.alreadyActive:
      case PortForwardActivationStatus.noConnectedSession:
      case PortForwardActivationStatus.superseded:
      case null:
        return _isEditing ? 'Port forward updated' : 'Port forward added';
    }
  }
}
