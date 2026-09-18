import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/entity_list_providers.dart';
import '../widgets/brand_empty_state.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/brand_list_skeleton.dart';
import 'port_forward_browser_screen.dart';

/// Screen displaying list of port forwards grouped by host.
class PortForwardsScreen extends ConsumerWidget {
  /// Creates a new [PortForwardsScreen].
  const PortForwardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portForwardsAsync = ref.watch(allPortForwardsProvider);
    final hostsAsync = ref.watch(allHostsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Port Forwards')),
      body: portForwardsAsync.when(
        loading: () => const BrandListSkeleton(),
        error: (_, _) => BrandErrorState(
          title: 'couldn’t load forwards',
          message: 'Your port forwards didn’t load.',
          onRetry: () => ref.invalidate(allPortForwardsProvider),
        ),
        data: (portForwards) => hostsAsync.when(
          loading: () => const BrandListSkeleton(),
          error: (_, _) => BrandErrorState(
            title: 'couldn’t load hosts',
            message: 'Your saved hosts didn’t load.',
            onRetry: () => ref.invalidate(allHostsProvider),
          ),
          data: (hosts) =>
              _buildPortForwardsList(context, ref, portForwards, hosts),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/port-forwards/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add Forward'),
      ),
    );
  }

  Widget _buildPortForwardsList(
    BuildContext context,
    WidgetRef ref,
    List<PortForward> portForwards,
    List<Host> hosts,
  ) {
    if (portForwards.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: BrandEmptyState(
            title: 'no forwards yet',
            message: 'Tunnel a port when you need one — tap + to add a rule.',
          ),
        ),
      );
    }

    // Group port forwards by host
    final hostMap = {for (final h in hosts) h.id: h};
    final grouped = <int, List<PortForward>>{};
    for (final pf in portForwards) {
      grouped.putIfAbsent(pf.hostId, () => []).add(pf);
    }

    final hostIds = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: hostIds.length,
      itemBuilder: (context, index) {
        final hostId = hostIds[index];
        final host = hostMap[hostId];
        final forwards = grouped[hostId]!;

        return _HostGroup(
          hostLabel: host?.label ?? 'Unknown Host',
          portForwards: forwards,
          onEdit: (pf) => context.push('/port-forwards/edit/${pf.id}'),
          onDelete: (pf) => _deletePortForward(context, ref, pf),
          onOpenBrowser: (pf) =>
              unawaited(_openPortForwardBrowser(context, ref, pf)),
        );
      },
    );
  }

  Future<void> _openPortForwardBrowser(
    BuildContext context,
    WidgetRef ref,
    PortForward portForward,
  ) async {
    if (!canOpenPortForwardInBrowser(portForward)) {
      _showPortForwardMessage(
        context,
        'Only loopback local port forwards can open in the browser.',
      );
      return;
    }

    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final existingConnectionId =
        sessionsNotifier.getConnectionForActiveLocalForward(portForward.id) ??
        sessionsNotifier.getPreferredConnectionForHost(portForward.hostId);

    final int connectionId;
    if (existingConnectionId == null) {
      _showPortForwardMessage(
        context,
        'Connecting to start "${portForward.name}"…',
      );
      final result = await sessionsNotifier.connect(portForward.hostId);
      if (!context.mounted) return;
      final resultConnectionId = result.connectionId;
      if (!result.success || resultConnectionId == null) {
        _showPortForwardMessage(
          context,
          result.error ?? 'Could not connect to start the port forward.',
        );
        return;
      }
      connectionId = resultConnectionId;
    } else {
      connectionId = existingConnectionId;
    }

    final session = sessionsNotifier.getSession(connectionId);
    if (session == null) {
      _showPortForwardMessage(
        context,
        'Could not find the active SSH session.',
      );
      return;
    }

    final started = await session.startLocalForward(
      portForwardId: portForward.id,
      localHost: portForward.localHost,
      localPort: portForward.localPort,
      remoteHost: portForward.remoteHost,
      remotePort: portForward.remotePort,
    );
    if (!context.mounted) return;
    if (!started) {
      _showPortForwardMessage(
        context,
        'Could not start "${portForward.name}". Check the local port.',
      );
      return;
    }

    ActiveTunnelInfo? activeTunnel;
    for (final tunnel in session.activeTunnels) {
      if (tunnel.portForwardId == portForward.id && tunnel.isLocal) {
        activeTunnel = tunnel;
        break;
      }
    }
    if (activeTunnel == null || activeTunnel.localPort < 1) {
      _showPortForwardMessage(
        context,
        'Could not find the active local port for "${portForward.name}".',
      );
      return;
    }
    final browserHost = activeTunnel.browserHost;
    final browserPort = activeTunnel.browserPort;
    if (browserHost == null || browserPort == null || browserPort < 1) {
      _showPortForwardMessage(
        context,
        'Could not create an isolated browser endpoint for "${portForward.name}".',
      );
      return;
    }
    final browserUri = buildPortForwardBrowserUriForBind(
      localHost: browserHost,
      localPort: browserPort,
    );
    final sourceUri = buildPortForwardBrowserUriForBind(
      localHost: activeTunnel.localHost,
      localPort: activeTunnel.localPort,
    );
    final fallbackHost = activeTunnel.browserFallbackHost;
    final fallbackUri = fallbackHost == null
        ? null
        : buildPortForwardBrowserUriForBind(
            localHost: fallbackHost,
            localPort: activeTunnel.localPort,
          );

    await context.pushNamed<void>(
      Routes.portForwardBrowser,
      extra: PortForwardBrowserLaunch(
        tabs: [
          PortForwardBrowserInitialTab(
            uri: browserUri,
            sourceUri: sourceUri,
            fallbackUri: fallbackUri,
            title: portForward.name,
          ),
        ],
      ),
    );
  }

  void _showPortForwardMessage(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _deletePortForward(
    BuildContext context,
    WidgetRef ref,
    PortForward portForward,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Port Forward'),
        content: Text('Delete "${portForward.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      try {
        await stopPortForwardOnConnectedSessions(
          sessions: ref.read(activeSessionsProvider.notifier),
          portForward: portForward,
        );
        await ref.read(portForwardRepositoryProvider).delete(portForward.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted "${portForward.name}"')),
          );
        }
      } on Exception catch (error, stackTrace) {
        restorePortForwardAfterFailedDeletion(portForward);
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'port forwards',
            context: ErrorDescription('while deleting a port forward'),
          ),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not delete port forward. Try again.'),
            ),
          );
        }
      }
    }
  }
}

class _HostGroup extends StatelessWidget {
  const _HostGroup({
    required this.hostLabel,
    required this.portForwards,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenBrowser,
  });

  final String hostLabel;
  final List<PortForward> portForwards;
  final void Function(PortForward) onEdit;
  final void Function(PortForward) onDelete;
  final void Function(PortForward) onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            hostLabel,
            style: FluttyTheme.displayMono(
              fontSize: 14,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        ...portForwards.map(
          (pf) => Dismissible(
            key: ValueKey(pf.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: theme.colorScheme.error,
              child: Icon(Icons.delete, color: theme.colorScheme.onError),
            ),
            confirmDismiss: (_) async {
              onDelete(pf);
              return false;
            },
            child: _PortForwardListTile(
              portForward: pf,
              onTap: () => onEdit(pf),
              onOpenBrowser: () => onOpenBrowser(pf),
            ),
          ),
        ),
        const Divider(),
      ],
    );
  }
}

class _PortForwardListTile extends StatelessWidget {
  const _PortForwardListTile({
    required this.portForward,
    required this.onTap,
    required this.onOpenBrowser,
  });

  final PortForward portForward;
  final VoidCallback onTap;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canOpenInBrowser =
        isPortForwardBrowserSupported() &&
        canOpenPortForwardInBrowser(portForward);
    final isLocal = portForward.forwardType == 'local';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isLocal
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.secondaryContainer,
        child: Icon(
          isLocal ? Icons.arrow_forward : Icons.arrow_back,
          color: isLocal
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text(portForward.name),
      subtitle: Text(
        isLocal
            ? 'L ${portForward.localHost}:${portForward.localPort} → ${portForward.remoteHost}:${portForward.remotePort}'
            : 'R ${portForward.remoteHost}:${portForward.remotePort} → ${portForward.localHost}:${portForward.localPort}',
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 12,
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canOpenInBrowser)
            IconButton(
              tooltip: 'Open in app browser',
              icon: const Icon(Icons.open_in_browser),
              onPressed: onOpenBrowser,
            ),
          if (portForward.autoStart)
            Tooltip(
              message: 'Auto-start enabled',
              child: Icon(
                Icons.play_circle_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
          const SizedBox(width: 8),
          Chip(
            label: Text(
              isLocal ? 'Local' : 'Remote',
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurface,
              ),
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
