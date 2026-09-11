import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../widgets/host_port_forward_editor_sheet.dart';

/// Screen for adding or editing a port forward rule.
class PortForwardEditScreen extends ConsumerStatefulWidget {
  /// Creates a new [PortForwardEditScreen].
  const PortForwardEditScreen({this.portForwardId, super.key});

  /// The port forward ID to edit, or null for a new port forward.
  final int? portForwardId;

  @override
  ConsumerState<PortForwardEditScreen> createState() =>
      _PortForwardEditScreenState();
}

class _PortForwardEditScreenState extends ConsumerState<PortForwardEditScreen> {
  bool _isLoading = true;
  String? _loadError;
  PortForward? _existing;
  List<Host> _hosts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _hosts = await ref.read(hostRepositoryProvider).getAll();
      if (!mounted) return;
      if (widget.portForwardId != null) {
        _existing = await ref
            .read(portForwardRepositoryProvider)
            .getById(widget.portForwardId!);
        if (_existing == null) _loadError = 'Port forward not found.';
      }
    } on Object {
      _loadError = 'Could not load port forward. Try again.';
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.portForwardId != null ? 'Edit Port Forward' : 'Add Port Forward',
      ),
    ),
    body: _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _loadError != null
        ? Center(child: Text(_loadError!))
        : PortForwardEditorForm(
            hosts: _hosts,
            existing: _existing,
            onSaved: (result) {
              final messenger = ScaffoldMessenger.of(context);
              context.pop();
              messenger.showSnackBar(SnackBar(content: Text(result.message)));
            },
          ),
  );
}
