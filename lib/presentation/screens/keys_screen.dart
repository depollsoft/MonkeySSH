import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';
import '../providers/entity_list_providers.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/brand_list_skeleton.dart';
import '../widgets/delete_confirmation_dialog.dart';
import '../widgets/key_details_sheet.dart';
import '../widgets/system_vertical_bar.dart';

/// Screen displaying list of SSH keys.
class KeysScreen extends ConsumerWidget {
  /// Creates a new [KeysScreen].
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keysAsync = ref.watch(allKeysProvider);

    return Scaffold(
      appBar: VerticalBarAppBar(AppBar(title: const Text('SSH Keys'))),
      body: SafeArea(
        top: false,
        bottom: false,
        child: keysAsync.when(
          loading: () => const BrandListSkeleton(),
          error: (error, stack) => BrandErrorState(
            title: 'couldn’t load keys',
            message: 'Your SSH keys didn’t load.',
            onRetry: () => ref.invalidate(allKeysProvider),
          ),
          data: (keys) => _buildKeysList(context, ref, keys),
        ),
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
      return buildKeysEmptyState(context);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final key = keys[index];
        return _KeyListTile(
          sshKey: key,
          onTap: () => showSshKeyDetailsSheet(context, key),
          onDelete: () => _deleteKey(context, ref, key),
        );
      },
    );
  }

  Future<void> _deleteKey(
    BuildContext context,
    WidgetRef ref,
    SshKey key,
  ) async {
    final confirmed = await showDeleteConfirmationDialog(
      context,
      title: 'Delete Key',
      message: 'Are you sure you want to delete "${key.name}"?',
    );

    if (confirmed) {
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
        child: Icon(
          sshKeyIcon(sshKey.keyType),
          size: 20,
          color: theme.colorScheme.primary,
        ),
      ),
      title: Text(sshKey.name),
      subtitle: Text(
        sshKeyTypeLabel(sshKey),
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
}
