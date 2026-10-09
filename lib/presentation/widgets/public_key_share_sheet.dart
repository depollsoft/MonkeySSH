import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/services/authorized_key_install_service.dart';

/// Renders [data] as a QR code: dark modules on white with a quiet zone, in
/// every theme, so cameras can read it.
class PublicKeyQrCode extends StatelessWidget {
  /// Creates a QR code for [data].
  const PublicKeyQrCode({
    required this.data,
    required this.semanticLabel,
    this.size = 240,
    super.key,
  });

  /// Text to encode.
  final String data;

  /// Accessible description of what the code holds.
  final String semanticLabel;

  /// Edge length in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    QrImage? image;
    try {
      image = QrImage(
        QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
      );
    } on Exception {
      image = null;
    }
    if (image == null) {
      return SizedBox(
        width: size,
        child: Text(
          'This key is too long for a QR code. Copy or share it instead.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Semantics(
      label: semanticLabel,
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
        child: CustomPaint(size: Size.square(size), painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  static const _quietZoneModules = 4;

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final modules = image.moduleCount + _quietZoneModules * 2;
    final moduleSize = size.shortestSide / modules;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    // Exact cells: drawing them wider would shrink the light modules beside
    // them, which matters for dense codes such as RSA-4096 keys.
    final path = Path();
    for (var row = 0; row < image.moduleCount; row++) {
      for (var column = 0; column < image.moduleCount; column++) {
        if (!image.isDark(row, column)) continue;
        path.addRect(
          Rect.fromLTWH(
            (column + _quietZoneModules) * moduleSize,
            (row + _quietZoneModules) * moduleSize,
            moduleSize,
            moduleSize,
          ),
        );
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}

/// Shows [sshKey]'s public key as a QR code with copy and share actions,
/// including a one-line command that authorizes it on a server.
Future<void> showPublicKeyShareSheet(BuildContext context, SshKey sshKey) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => PublicKeyShareSheet(sshKey: sshKey),
    );

/// Body of [showPublicKeyShareSheet].
class PublicKeyShareSheet extends StatelessWidget {
  /// Creates the sheet for [sshKey].
  const PublicKeyShareSheet({required this.sshKey, super.key});

  /// The key to share. Only its public half is shown.
  final SshKey sshKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    String? keyLine;
    try {
      keyLine = buildAuthorizedKeyLine(sshKey.publicKey, comment: sshKey.name);
    } on FormatException {
      keyLine = null;
    }
    final command = keyLine == null
        ? null
        : buildManualAuthorizedKeyCommand(keyLine);
    final publicKey = keyLine ?? sshKey.publicKey.trim();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        0,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Share Public Key',
            style: FluttyTheme.displayMono(color: colorScheme.onSurface),
          ),
          const SizedBox(height: FluttyTheme.spacingXs),
          Text(
            'Scan it from another device, or send the install command and '
            'paste it into a terminal on the server.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: FluttyTheme.spacingMd),
          Center(
            child: PublicKeyQrCode(
              data: publicKey,
              semanticLabel: 'QR code of the public key ${sshKey.name}',
            ),
          ),
          const SizedBox(height: FluttyTheme.spacingMd),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                publicKey,
                style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: FluttyTheme.spacingMd),
          if (command != null)
            Builder(
              builder: (buttonContext) => FilledButton.icon(
                onPressed: () => SharePlus.instance.share(
                  ShareParams(
                    text: command,
                    subject: 'Authorize an SSH key',
                    sharePositionOrigin: _originOf(buttonContext),
                  ),
                ),
                icon: const Icon(Icons.ios_share),
                label: const Text('Share Install Command'),
              ),
            ),
          const SizedBox(height: FluttyTheme.spacingSm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: _compactButton,
                  onPressed: () =>
                      _copy(context, publicKey, 'Public key copied'),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy Key'),
                ),
              ),
              if (command != null) ...[
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(
                  child: OutlinedButton.icon(
                    style: _compactButton,
                    onPressed: () =>
                        _copy(context, command, 'Install command copied'),
                    icon: const Icon(Icons.terminal),
                    label: const Text('Copy Command'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static final _compactButton = OutlinedButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
  );

  // iPad anchors the share popover to the button that opened it.
  static Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _copy(BuildContext context, String text, String message) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
