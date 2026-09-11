import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Confirms exposing a listener beyond its loopback interface.
Future<bool> confirmPortForwardExposure({
  required BuildContext context,
  required String host,
  required bool isRemote,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        isRemote ? 'Expose remote port forward?' : 'Expose port forward?',
      ),
      content: Text(
        isRemote
            ? 'Binding the remote listener to $host may make this forward '
                  'reachable from other devices that can access the SSH host.'
            : 'Binding to $host may make this forward reachable from other '
                  'devices on your local network.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Forward direction controls shared by both editors.
class PortForwardTypeField extends StatelessWidget {
  /// Creates the direction selector.
  const PortForwardTypeField({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// Current direction.
  final String value;

  /// Updates the draft, or disables editing when null.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Forward Type',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(
            value: 'local',
            label: Text('Local'),
            icon: Icon(Icons.arrow_forward),
          ),
          ButtonSegment(
            value: 'remote',
            label: Text('Remote'),
            icon: Icon(Icons.arrow_back),
          ),
        ],
        selected: {value},
        onSelectionChanged: onChanged == null
            ? null
            : (selected) => onChanged!(selected.first),
      ),
      const SizedBox(height: 8),
      Text(
        value == 'local'
            ? 'Forward local port to remote host'
            : 'Forward remote port to local host',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    ],
  );
}

/// Host and port fields for one forwarding endpoint.
class PortForwardEndpointFields extends StatelessWidget {
  /// Creates an endpoint row, preserving the sheet's compact field styling.
  const PortForwardEndpointFields({
    required this.label,
    required this.hostController,
    required this.portController,
    required this.hostHint,
    required this.portHint,
    this.enabled = true,
    this.compact = false,
    this.portInputAction = TextInputAction.next,
    super.key,
  });

  /// Endpoint label.
  final String label;

  /// Draft host.
  final TextEditingController hostController;

  /// Draft port.
  final TextEditingController portController;

  /// Example host.
  final String hostHint;

  /// Example port.
  final String portHint;

  /// Whether the fields are editable.
  final bool enabled;

  /// Uses outlined fields and compact spacing for the sheet.
  final bool compact;

  /// Keyboard action for the port.
  final TextInputAction portInputAction;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: hostController,
              enabled: enabled,
              decoration: InputDecoration(
                labelText: 'Host',
                hintText: hostHint,
                border: compact ? const OutlineInputBorder() : null,
              ),
              textInputAction: compact ? null : TextInputAction.next,
              validator: (value) =>
                  value == null || value.isEmpty ? 'Required' : null,
            ),
          ),
          SizedBox(width: compact ? 12 : 16),
          Expanded(
            child: TextFormField(
              controller: portController,
              enabled: enabled,
              decoration: InputDecoration(
                labelText: 'Port',
                hintText: portHint,
                border: compact ? const OutlineInputBorder() : null,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: compact ? null : portInputAction,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return compact ? 'Required' : 'Please enter a port';
                }
                final port = int.tryParse(value);
                if (port == null || port < 1 || port > 65535) {
                  return compact
                      ? 'Invalid port (1-65535)'
                      : 'Port must be between 1 and 65535';
                }
                return null;
              },
            ),
          ),
        ],
      ),
    ],
  );
}
