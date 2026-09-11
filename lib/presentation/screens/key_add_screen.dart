import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/key_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../widgets/premium_access.dart';
import '../widgets/premium_badge.dart';
import '../widgets/unsaved_changes_guard.dart';
import 'transfer_screen.dart';

typedef _GenerateKeyDraft = ({
  String name,
  String passphrase,
  String keyType,
  int rsaBits,
});

typedef _ImportKeyDraft = ({String name, String privateKey, String passphrase});

/// Screen for adding or importing SSH keys.
class KeyAddScreen extends ConsumerStatefulWidget {
  /// Creates a new [KeyAddScreen].
  const KeyAddScreen({this.initialTabIndex = 0, super.key});

  /// Initially selected tab index.
  final int initialTabIndex;

  @override
  ConsumerState<KeyAddScreen> createState() => _KeyAddScreenState();
}

class _KeyAddScreenState extends ConsumerState<KeyAddScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _generateHasUnsavedChanges = false;
  bool _importHasUnsavedChanges = false;
  bool _isLeavingWithoutPrompt = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      initialIndex: widget.initialTabIndex < 0
          ? 0
          : widget.initialTabIndex > 1
          ? 1
          : widget.initialTabIndex,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    hasUnsavedChanges: _hasUnsavedChanges,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Add SSH Key'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Generate'),
            Tab(text: 'Import'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _GenerateKeyTab(
            onSaved: _closeWithoutUnsavedPrompt,
            onUnsavedChangesChanged: _handleGenerateUnsavedChangesChanged,
          ),
          _ImportKeyTab(
            onSaved: _closeWithoutUnsavedPrompt,
            onUnsavedChangesChanged: _handleImportUnsavedChangesChanged,
          ),
        ],
      ),
    ),
  );

  bool get _hasUnsavedChanges =>
      !_isLeavingWithoutPrompt &&
      (_generateHasUnsavedChanges || _importHasUnsavedChanges);

  void _handleGenerateUnsavedChangesChanged(bool hasUnsavedChanges) {
    if (_generateHasUnsavedChanges == hasUnsavedChanges) {
      return;
    }
    setState(() => _generateHasUnsavedChanges = hasUnsavedChanges);
  }

  void _handleImportUnsavedChangesChanged(bool hasUnsavedChanges) {
    if (_importHasUnsavedChanges == hasUnsavedChanges) {
      return;
    }
    setState(() => _importHasUnsavedChanges = hasUnsavedChanges);
  }

  void _closeWithoutUnsavedPrompt(SnackBar snackBar) {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _isLeavingWithoutPrompt = true;
      _generateHasUnsavedChanges = false;
      _importHasUnsavedChanges = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.pop();
      messenger.showSnackBar(snackBar);
    });
  }
}

class _GenerateKeyTab extends ConsumerStatefulWidget {
  const _GenerateKeyTab({
    required this.onSaved,
    required this.onUnsavedChangesChanged,
  });

  final ValueChanged<SnackBar> onSaved;
  final ValueChanged<bool> onUnsavedChangesChanged;

  @override
  ConsumerState<_GenerateKeyTab> createState() => _GenerateKeyTabState();
}

class _GenerateKeyTabState extends ConsumerState<_GenerateKeyTab> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _passphraseController = TextEditingController();

  String _keyType = 'ed25519';
  int _rsaBits = 4096;
  bool _isGenerating = false;
  bool _showPassphrase = false;
  late final _GenerateKeyDraft _initialDraft;

  @override
  void initState() {
    super.initState();
    _initialDraft = _currentDraft();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    onChanged: _notifyUnsavedChangesChanged,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Name
        TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Key Name',
            hintText: 'My SSH Key',
            prefixIcon: Icon(Icons.label),
          ),
          textInputAction: TextInputAction.next,
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter a name';
            }
            return null;
          },
        ),
        const SizedBox(height: 24),

        // Key type
        Text('Key Type', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'ed25519',
              label: Text('Ed25519', style: FluttyTheme.monoStyle),
              icon: const Icon(Icons.enhanced_encryption),
            ),
            ButtonSegment(
              value: 'rsa',
              label: Text('RSA', style: FluttyTheme.monoStyle),
              icon: const Icon(Icons.key),
            ),
          ],
          selected: {_keyType},
          onSelectionChanged: (value) {
            setState(() => _keyType = value.first);
            _notifyUnsavedChangesChanged();
          },
        ),
        const SizedBox(height: 16),

        // RSA bits (only shown for RSA)
        if (_keyType == 'rsa') ...[
          Text('RSA Key Size', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 2048, label: Text('2048')),
              ButtonSegment(value: 4096, label: Text('4096')),
            ],
            selected: {_rsaBits},
            onSelectionChanged: (value) {
              setState(() => _rsaBits = value.first);
              _notifyUnsavedChangesChanged();
            },
          ),
          const SizedBox(height: 16),
        ],

        // Passphrase (optional)
        TextFormField(
          controller: _passphraseController,
          decoration: InputDecoration(
            labelText: 'Passphrase (optional)',
            hintText: 'Leave empty for no passphrase',
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              icon: Icon(
                _showPassphrase ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () =>
                  setState(() => _showPassphrase = !_showPassphrase),
            ),
          ),
          obscureText: !_showPassphrase,
        ),
        const SizedBox(height: 8),
        Text(
          'A passphrase adds extra security. You will need to enter it each time you use this key.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 32),

        // Generate button
        FilledButton.icon(
          onPressed: _isGenerating ? null : _generateKey,
          icon: _isGenerating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: Text(_isGenerating ? 'Generating...' : 'Generate Key'),
        ),

        if (_keyType == 'ed25519') ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Ed25519 is recommended for its security and performance.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Future<void> _generateKey() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isGenerating = true);

    try {
      final keyService = ref.read(keyServiceProvider);
      final passphrase = _passphraseController.text.isEmpty
          ? null
          : _passphraseController.text;
      final keyType = switch (_keyType) {
        'ed25519' => SshKeyType.ed25519,
        _ => switch (_rsaBits) {
          2048 => SshKeyType.rsa2048,
          _ => SshKeyType.rsa4096,
        },
      };
      final result = await keyService.generateKey(
        name: _nameController.text.trim(),
        keyType: keyType,
        passphrase: passphrase,
      );

      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        if (result == null) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Failed to generate key')),
          );
        } else {
          unawaited(
            ref.read(telemetryServiceProvider).logKeyAdded(method: 'generated'),
          );
          widget.onSaved(
            const SnackBar(content: Text('Key generated successfully')),
          );
        }
      }
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'keys',
          context: ErrorDescription('while generating an SSH key'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not generate key. Try again.')),
        );
      }
    } finally {
      if (mounted) {
        _passphraseController.clear();
        _notifyUnsavedChangesChanged();
        setState(() => _isGenerating = false);
      }
    }
  }

  bool get _hasUnsavedChanges => _currentDraft() != _initialDraft;

  _GenerateKeyDraft _currentDraft() => (
    name: _nameController.text,
    passphrase: _passphraseController.text,
    keyType: _keyType,
    rsaBits: _rsaBits,
  );

  void _notifyUnsavedChangesChanged() =>
      widget.onUnsavedChangesChanged(_hasUnsavedChanges);
}

class _ImportKeyTab extends ConsumerStatefulWidget {
  const _ImportKeyTab({
    required this.onSaved,
    required this.onUnsavedChangesChanged,
  });

  final ValueChanged<SnackBar> onSaved;
  final ValueChanged<bool> onUnsavedChangesChanged;

  @override
  ConsumerState<_ImportKeyTab> createState() => _ImportKeyTabState();
}

class _ImportKeyTabState extends ConsumerState<_ImportKeyTab> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _passphraseController = TextEditingController();

  bool _isImporting = false;
  bool _showPassphrase = false;
  late final _ImportKeyDraft _initialDraft;

  @override
  void initState() {
    super.initState();
    _initialDraft = _currentDraft();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    onChanged: _notifyUnsavedChangesChanged,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Secure device transfer',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                const PremiumBadge(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isImporting
                            ? null
                            : _handleEncryptedImportTap,
                        icon: const Icon(Icons.file_open),
                        label: const Text('Import Encrypted File'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Name
        TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Key Name',
            hintText: 'Imported Key',
            prefixIcon: Icon(Icons.label),
          ),
          textInputAction: TextInputAction.next,
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter a name';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),

        // Private key content
        TextFormField(
          controller: _privateKeyController,
          decoration: const InputDecoration(
            labelText: 'Private Key (PEM format)',
            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
            alignLabelWithHint: true,
          ),
          maxLines: 8,
          style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter the private key';
            }
            if (!value.contains('-----BEGIN') || !value.contains('-----END')) {
              return 'Invalid PEM format';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),

        // Passphrase (if encrypted)
        TextFormField(
          controller: _passphraseController,
          decoration: InputDecoration(
            labelText: 'Passphrase (if encrypted)',
            hintText: 'Leave empty if key is not encrypted',
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              icon: Icon(
                _showPassphrase ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () =>
                  setState(() => _showPassphrase = !_showPassphrase),
            ),
          ),
          obscureText: !_showPassphrase,
        ),
        const SizedBox(height: 32),

        // Import button
        FilledButton.icon(
          onPressed: _isImporting ? null : _importKey,
          icon: _isImporting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(_isImporting ? 'Importing...' : 'Import Key'),
        ),
        const SizedBox(height: 16),

        // Import from file button
        OutlinedButton.icon(
          onPressed: _isImporting ? null : _importFromFile,
          icon: const Icon(Icons.file_open),
          label: const Text('Import from File'),
        ),
      ],
    ),
  );

  Future<void> _importKey() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isImporting = true);

    try {
      final keyService = ref.read(keyServiceProvider);
      final passphrase = _passphraseController.text.isEmpty
          ? null
          : _passphraseController.text;

      final result = await keyService.importKey(
        name: _nameController.text,
        privateKeyPem: _privateKeyController.text,
        passphrase: passphrase,
      );

      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid key format or incorrect passphrase'),
            ),
          );
        }
        return;
      }

      if (mounted) {
        _privateKeyController.clear();
        unawaited(
          ref.read(telemetryServiceProvider).logKeyAdded(method: 'import'),
        );
        widget.onSaved(
          const SnackBar(content: Text('Key imported successfully')),
        );
      }
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'keys',
          context: ErrorDescription('while importing an SSH key'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not import key. Try again.')),
        );
      }
    } finally {
      if (mounted) {
        _passphraseController.clear();
        _notifyUnsavedChangesChanged();
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _importFromFile() async {
    if (_isImporting) {
      return;
    }
    final file = await FilePicker.pickFile();

    if (!mounted || file == null) {
      return;
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to read selected file')),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }

    _privateKeyController.text = utf8.decode(bytes, allowMalformed: true);
    if (_nameController.text.trim().isEmpty) {
      final dotIndex = file.name.lastIndexOf('.');
      _nameController.text = dotIndex > 0
          ? file.name.substring(0, dotIndex)
          : file.name;
    }
    _notifyUnsavedChangesChanged();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Loaded "${file.name}"')));
  }

  Future<void> _importFromEncryptedFile() async {
    if (_isImporting) {
      return;
    }
    final encodedPayload = await pickTransferPayloadFromFile(context);
    await _importFromTransferPayload(encodedPayload);
  }

  Future<void> _handleEncryptedImportTap() async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
      blockedAction: 'Import encrypted key file',
      blockedOutcome:
          'Unlock Pro to decrypt this key transfer and add it to your keyring.',
    );
    if (!hasAccess) {
      return;
    }
    await _importFromEncryptedFile();
  }

  Future<void> _importFromTransferPayload(String? encodedPayload) async {
    if (!mounted || encodedPayload == null || encodedPayload.isEmpty) {
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Key transfer passphrase',
    );
    if (!mounted || transferPassphrase == null) {
      return;
    }

    setState(() => _isImporting = true);
    try {
      final transferService = ref.read(secureTransferServiceProvider);
      final payload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: transferPassphrase,
      );
      if (payload.type != TransferPayloadType.key) {
        throw const FormatException(
          'This transfer payload does not contain an SSH key',
        );
      }
      if (!mounted) {
        return;
      }
      final confirmed = await showTransferPayloadImportConfirmationDialog(
        context: context,
        payload: payload,
      );
      if (!mounted || !confirmed) {
        return;
      }
      final importedKey = await transferService.importKeyPayload(payload);
      if (!mounted) {
        return;
      }
      widget.onSaved(
        SnackBar(content: Text('Imported key: ${importedKey.name}')),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${error.message}')),
      );
    } on Exception catch (error) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          library: 'keys',
          context: ErrorDescription(
            'while importing an encrypted key transfer',
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Import failed. Check the file and try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  bool get _hasUnsavedChanges => _currentDraft() != _initialDraft;

  _ImportKeyDraft _currentDraft() => (
    name: _nameController.text,
    privateKey: _privateKeyController.text,
    passphrase: _passphraseController.text,
  );

  void _notifyUnsavedChangesChanged() =>
      widget.onUnsavedChangesChanged(_hasUnsavedChanges);
}
