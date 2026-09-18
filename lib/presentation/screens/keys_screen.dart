import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';
import '../providers/entity_list_providers.dart';
import '../widgets/brand_empty_state.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/brand_list_skeleton.dart';

/// Screen displaying list of SSH keys.
class KeysScreen extends ConsumerWidget {
  /// Creates a new [KeysScreen].
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keysAsync = ref.watch(allKeysProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('SSH Keys')),
      body: keysAsync.when(
        loading: () => const BrandListSkeleton(),
        error: (error, stack) => BrandErrorState(
          title: 'couldn’t load keys',
          message: 'Your SSH keys didn’t load.',
          onRetry: () => ref.invalidate(allKeysProvider),
        ),
        data: (keys) => _buildKeysList(context, ref, keys),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/keys/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add Key'),
      ),
    );
  }

  Widget _buildKeysList(
    BuildContext context,
    WidgetRef ref,
    List<SshKey> keys,
  ) {
    if (keys.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: BrandEmptyState(
            title: 'no keys yet',
            message: 'Generate a key and stop saving server passwords.',
            primaryLabel: 'Generate Key',
            primaryIcon: Icons.enhanced_encryption,
            onPrimary: () => context.push('/keys/add'),
            secondaryActions: [
              BrandEmptyAction(
                icon: Icons.upload_file_outlined,
                label: 'Import Key',
                onTap: () => context.push('/keys/add?tab=import'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final key = keys[index];
        return _KeyListTile(
          sshKey: key,
          onTap: () => _showKeyDetails(context, key),
          onDelete: () => _deleteKey(context, ref, key),
        );
      },
    );
  }

  void _showKeyDetails(BuildContext context, SshKey key) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) =>
            _KeyDetailsSheet(sshKey: key, scrollController: scrollController),
      ),
    );
  }

  Future<void> _deleteKey(
    BuildContext context,
    WidgetRef ref,
    SshKey key,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Are you sure you want to delete "${key.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await ref.read(keyRepositoryProvider).delete(key.id);
      ref.invalidate(allKeysProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Deleted "${key.name}"')));
      }
    }
  }
}

class _KeyListTile extends StatelessWidget {
  const _KeyListTile({
    required this.sshKey,
    required this.onTap,
    required this.onDelete,
  });

  final SshKey sshKey;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withAlpha(isDark ? 25 : 15),
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
        ),
        child: Icon(_getKeyIcon(), size: 20, color: theme.colorScheme.primary),
      ),
      title: Text(sshKey.name),
      subtitle: Text(
        _getKeyTypeLabel(),
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 11,
          color: theme.colorScheme.onSurface.withAlpha(160),
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          switch (action) {
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  IconData _getKeyIcon() {
    if (sshKey.keyType.toLowerCase().contains('ed25519')) {
      return Icons.enhanced_encryption;
    } else if (sshKey.keyType.toLowerCase().contains('rsa')) {
      return Icons.key;
    } else if (sshKey.keyType.toLowerCase().contains('ecdsa')) {
      return Icons.security;
    } else if (sshKey.keyType.toLowerCase().contains('dsa')) {
      return Icons.key_off;
    }
    return Icons.vpn_key;
  }

  String _getKeyTypeLabel() {
    final type = sshKey.keyType.toLowerCase();
    if (type == 'unknown') {
      // Try to extract from public key prefix
      final pubKey = sshKey.publicKey.trim();
      final firstSpace = pubKey.indexOf(' ');
      if (firstSpace > 0) {
        return pubKey.substring(0, firstSpace).toUpperCase();
      }
      return 'SSH Key';
    }
    return sshKey.keyType.toUpperCase();
  }
}

class _KeyDetailsSheet extends StatelessWidget {
  const _KeyDetailsSheet({
    required this.sshKey,
    required this.scrollController,
  });

  final SshKey sshKey;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var isPrivateKeyVisible = false;

    return Container(
      padding: const EdgeInsets.all(16),
      child: ListView(
        controller: scrollController,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outline.withAlpha(100),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Key name and type
          Text(sshKey.name, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            _getKeyTypeLabel(),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),

          // Public key
          Text('Public Key', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              sshKey.publicKey,
              style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyToClipboard(context, sshKey.publicKey),
            icon: const Icon(Icons.copy),
            label: const Text('Copy Public Key'),
          ),
          if (sshKey.privateKey.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Private Key', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            StatefulBuilder(
              builder: (context, setPrivateKeyState) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: isPrivateKeyVisible
                        ? SelectableText(
                            sshKey.privateKey,
                            style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
                          )
                        : const Text(
                            'Private key hidden. Tap "Reveal Private Key" to view.',
                          ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => setPrivateKeyState(
                      () => isPrivateKeyVisible = !isPrivateKeyVisible,
                    ),
                    icon: Icon(
                      isPrivateKeyVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    label: Text(
                      isPrivateKeyVisible
                          ? 'Hide Private Key'
                          : 'Reveal Private Key',
                    ),
                  ),
                  if (isPrivateKeyVisible) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _confirmAndCopyPrivateKey(context),
                      icon: const Icon(Icons.key),
                      label: const Text('Copy Private Key'),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Created date
          Text('Created', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            sshKey.createdAt.toString().split('.').first,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  Future<void> _confirmAndCopyPrivateKey(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Copy private key?'),
        content: const Text(
          'Private keys are sensitive. Other apps may read clipboard contents.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    _copyToClipboard(context, sshKey.privateKey);
  }

  String _getKeyTypeLabel() {
    final type = sshKey.keyType.toLowerCase();
    if (type == 'unknown') {
      // Try to extract from public key prefix
      final pubKey = sshKey.publicKey.trim();
      final firstSpace = pubKey.indexOf(' ');
      if (firstSpace > 0) {
        return pubKey.substring(0, firstSpace).toUpperCase();
      }
      return 'SSH Key';
    }
    return sshKey.keyType.toUpperCase();
  }
}
