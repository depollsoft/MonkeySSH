import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import 'adaptive_button_row.dart';
import 'brand_empty_state.dart';
import 'public_key_share_sheet.dart';

/// Icon representing an SSH key algorithm.
IconData sshKeyIcon(String keyType) {
  final lower = keyType.toLowerCase();
  if (lower.contains('ed25519')) {
    return Icons.enhanced_encryption;
  }
  if (lower.contains('rsa')) {
    return Icons.key;
  }
  if (lower.contains('ecdsa')) {
    return Icons.security;
  }
  if (lower.contains('dsa')) {
    return Icons.key_off;
  }
  return Icons.vpn_key;
}

/// Human-readable uppercase label for an SSH key's algorithm.
String sshKeyTypeLabel(SshKey sshKey) {
  final type = sshKey.keyType.toLowerCase();
  if (type == 'unknown') {
    final pubKey = sshKey.publicKey.trim();
    final firstSpace = pubKey.indexOf(' ');
    if (firstSpace > 0) {
      return pubKey.substring(0, firstSpace).toUpperCase();
    }
    return 'SSH Key';
  }
  return sshKey.keyType.toUpperCase();
}

/// Shared empty state shown when no SSH keys have been added yet.
Widget buildKeysEmptyState(BuildContext context) => Center(
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

/// Opens the modal bottom sheet displaying details for [sshKey].
void showSshKeyDetailsSheet(BuildContext context, SshKey sshKey) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => SshKeyDetailsSheet(
          sshKey: sshKey,
          scrollController: scrollController,
        ),
      ),
    ),
  );
}

/// Scrollable bottom sheet displaying an SSH key's public material and gated
/// private key access.
class SshKeyDetailsSheet extends StatelessWidget {
  /// Creates a details sheet for [sshKey].
  const SshKeyDetailsSheet({
    required this.sshKey,
    required this.scrollController,
    super.key,
  });

  /// Key being inspected.
  final SshKey sshKey;

  /// Scroll controller supplied by [DraggableScrollableSheet].
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
          Text(sshKey.name, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            sshKeyTypeLabel(sshKey),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
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
          AdaptiveButtonRow(
            children: [
              OutlinedButton.icon(
                onPressed: () => _copyToClipboard(context, sshKey.publicKey),
                icon: const Icon(Icons.copy),
                label: const Text('Copy Public Key'),
              ),
              OutlinedButton.icon(
                onPressed: () => showPublicKeyShareSheet(context, sshKey),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('QR & Share'),
              ),
            ],
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
    unawaited(Clipboard.setData(ClipboardData(text: text)));
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
    if (confirmed != true || !context.mounted) {
      return;
    }
    _copyToClipboard(context, sshKey.privateKey);
  }
}
