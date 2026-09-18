import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../domain/services/app_review_demo_service.dart';
import '../providers/entity_list_providers.dart';

/// App Review demo entry point shown from Settings > About.
class AppReviewDemoScreen extends ConsumerStatefulWidget {
  /// Creates an App Review demo screen.
  const AppReviewDemoScreen({super.key});

  @override
  ConsumerState<AppReviewDemoScreen> createState() =>
      _AppReviewDemoScreenState();
}

class _AppReviewDemoScreenState extends ConsumerState<AppReviewDemoScreen> {
  bool _isPreparing = false;

  @override
  Widget build(BuildContext context) {
    final prepared = ref.watch(appReviewDemoPreparedProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('App Review Demo')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _DemoHeaderCard(
            prepared: prepared.asData?.value ?? false,
            isPreparing: _isPreparing,
            onPrepare: () => unawaited(_prepareDemo()),
          ),
          const SizedBox(height: 16),
          const _DemoSection(
            title: 'What gets loaded',
            children: [
              _DemoFeatureTile(
                icon: Icons.dns_outlined,
                title: 'Hosts and jump host',
                description: 'A MonkeyMux workspace, an agent workspace, an SFTP host, and a bastion jump host.',
              ),
              _DemoFeatureTile(
                icon: Icons.key_outlined,
                title: 'Key, snippets, and automation',
                description: 'A sample SSH key, review snippets, auto-connect review prompts, and coding-agent launch presets.',
              ),
              _DemoFeatureTile(
                icon: Icons.alt_route_outlined,
                title: 'Tunnels and Pro configuration examples',
                description: 'Local port-forward rules, host-specific terminal themes, and saved CLI YOLO preferences.',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _DemoSection(
            title: 'Review path',
            children: [
              const _DemoInstructionTile(
                number: '1',
                title: 'Load the sample workspace',
                description: 'Tap the primary button above. It only adds local sample data and never contacts an external server.',
              ),
              const _DemoInstructionTile(
                number: '2',
                title: 'Open the seeded app surfaces',
                description: 'Use Hosts, Keys, Snippets, and Port Forwards to inspect the pre-populated content.',
              ),
              const _DemoInstructionTile(
                number: '3',
                title: 'Review connection-dependent controls',
                description: 'Tap a seeded host to open an in-app local demo shell with sample SFTP files and tunnel responses.',
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => context.goNamed(Routes.home),
                      icon: const Icon(Icons.home_outlined, size: 18),
                      label: const Text('Open Hosts'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => context.go('/?tab=connections'),
                      icon: const Icon(Icons.terminal, size: 18),
                      label: const Text('Connections'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => context.pushNamed(Routes.portForwards),
                      icon: const Icon(Icons.alt_route_outlined, size: 18),
                      label: const Text('Port Forwards'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _DemoTerminalPreview(),
        ],
      ),
    );
  }

  Future<void> _prepareDemo() async {
    if (_isPreparing) {
      return;
    }
    setState(() => _isPreparing = true);
    try {
      final result = await ref.read(appReviewDemoServiceProvider).prepare();
      invalidateImportedEntityProviders(ref.invalidate);
      ref
        ..invalidate(appReviewDemoPreparedProvider)
        ..invalidate(appReviewDemoServiceProvider);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.createdAny
                ? 'App Review demo workspace loaded'
                : 'App Review demo workspace is already loaded',
          ),
        ),
      );
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'app_review_demo',
          context: ErrorDescription('while preparing App Review demo content'),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load App Review demo data')),
      );
    } finally {
      if (mounted) {
        setState(() => _isPreparing = false);
      }
    }
  }
}

class _DemoHeaderCard extends StatelessWidget {
  const _DemoHeaderCard({
    required this.prepared,
    required this.isPreparing,
    required this.onPrepare,
  });

  final bool prepared;
  final bool isPreparing;
  final VoidCallback onPrepare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withAlpha(26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.fact_check_outlined,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'offline review workspace',
                        style: FluttyTheme.displayMono(
                          fontSize: 16,
                          color: colorScheme.onSurface,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Pre-populated local data for App Review. No account, private SSH server, or demo video is required.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _StatusPill(prepared: prepared),
                const Spacer(),
                FilledButton.icon(
                  onPressed: isPreparing ? null : onPrepare,
                  icon: isPreparing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_for_offline_outlined),
                  label: Text(prepared ? 'Reload demo data' : 'Load demo data'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.prepared});

  final bool prepared;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: prepared
            ? colorScheme.primary.withAlpha(24)
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: prepared
              ? colorScheme.primary.withAlpha(120)
              : colorScheme.outline.withAlpha(120),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            prepared ? Icons.check_circle_outline : Icons.pending_outlined,
            size: 15,
            color: prepared
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            prepared ? 'Loaded' : 'Not loaded',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: prepared
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DemoSection extends StatelessWidget {
  const _DemoSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                title,
                style: FluttyTheme.displayMono(
                  fontSize: 13,
                  color: colorScheme.onSurface,
                  letterSpacing: 0,
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DemoFeatureTile extends StatelessWidget {
  const _DemoFeatureTile({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(description),
  );
}

class _DemoInstructionTile extends StatelessWidget {
  const _DemoInstructionTile({
    required this.number,
    required this.title,
    required this.description,
  });

  final String number;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: colorScheme.primary.withAlpha(28),
        child: Text(
          number,
          style: FluttyTheme.monoStyle.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(title),
      subtitle: Text(description),
    );
  }
}

class _DemoTerminalPreview extends StatelessWidget {
  const _DemoTerminalPreview();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: const Color(0xFF0D1A20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle(
          style: FluttyTheme.monoStyle.copyWith(
            color: const Color(0xFFD7E7E3),
            height: 1.45,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.terminal, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'demo transcript',
                    style: FluttyTheme.displayMono(
                      fontSize: 13,
                      color: const Color(0xFFF0F4F3),
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(r'$ monkeymux attach review-workspace'),
              const Text('✓ Copilot CLI · planning changes'),
              const Text('✓ Claude Code · running tests'),
              const Text('✓ OpenCode · editing README.md'),
              const SizedBox(height: 8),
              Text(
                'Sample rows loaded by this demo carry the same session, SFTP, theme, and tunnel configuration used by the production UI.',
                style: FluttyTheme.monoStyle.copyWith(
                  color: const Color(0xFFAEC6C2),
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
