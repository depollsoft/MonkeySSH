import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_metadata.dart';
import '../../app/theme.dart';
import '../../domain/services/auth_service.dart';
import '../widgets/cursor_block.dart';

/// Lock screen for PIN/biometric authentication.
class LockScreen extends ConsumerStatefulWidget {
  /// Creates a new [LockScreen].
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pinController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLoading = false;
  bool _isCheckingAuthMethod = true;
  bool _authMethodLoadFailed = false;
  String? _error;
  bool _showPin = false;
  AuthMethod _authMethod = AuthMethod.none;

  @override
  void initState() {
    super.initState();
    unawaited(_checkAuthMethod());
  }

  Future<void> _checkAuthMethod({bool refreshAuthState = false}) async {
    final authService = ref.read(authServiceProvider);
    try {
      final method = await authService.getAuthMethod();
      if (refreshAuthState) {
        await ref.read(authStateProvider.notifier).refresh();
      }
      if (!mounted) return;

      setState(() {
        _authMethod = method;
        _isCheckingAuthMethod = false;
        _authMethodLoadFailed = false;
      });

      // Auto-trigger biometric if available
      if (method == AuthMethod.biometric || method == AuthMethod.both) {
        unawaited(_authenticateWithBiometrics());
      }
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'auth',
          context: ErrorDescription(
            'while determining the available lock-screen authentication method',
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _isCheckingAuthMethod = false;
        _authMethodLoadFailed = true;
      });
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final success = await ref
        .read(authStateProvider.notifier)
        .unlockWithBiometrics();
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (!success) {
        _error = 'Biometric authentication failed';
      }
    });
  }

  Future<void> _authenticateWithPin() async {
    if (_pinController.text.isEmpty) {
      setState(() => _error = 'Enter your PIN');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final success = await ref
        .read(authStateProvider.notifier)
        .unlockWithPin(_pinController.text);
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (!success) {
        _error = 'Incorrect PIN';
      }
    });
    if (!success) {
      _pinController.clear();
      unawaited(HapticFeedback.heavyImpact());
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final appName = ref.watch(appDisplayNameProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isInitializing =
        authState == AuthState.unknown || _isCheckingAuthMethod;
    final isLockedWithoutAvailableAuth =
        authState == AuthState.locked &&
        !_isCheckingAuthMethod &&
        _authMethod == AuthMethod.none;
    final showAuthMethodError =
        authState != AuthState.unknown &&
        (_authMethodLoadFailed || isLockedWithoutAvailableAuth);
    final subtitle = switch ((isInitializing, showAuthMethodError)) {
      (true, _) => 'Checking your security settings…',
      (false, true) =>
        'Authentication data is unavailable or corrupted. The app will stay locked until authentication is ready.',
      (false, false) => 'Enter your PIN to unlock',
    };

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight > 48
                    ? constraints.maxHeight - 48
                    : 0,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo/icon
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          'assets/icons/monkeyssh_icon.png',
                          width: 112,
                          height: 112,
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: appName,
                              style: FluttyTheme.displayMono(
                                fontSize: 24,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: CursorBlock(
                                  size: 24,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 48),

                      if (isInitializing) ...[
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                      ],

                      // PIN input
                      if (!isInitializing &&
                          !showAuthMethodError &&
                          (_authMethod == AuthMethod.pin ||
                              _authMethod == AuthMethod.both)) ...[
                        SizedBox(
                          width: double.infinity,
                          child: TextField(
                            controller: _pinController,
                            focusNode: _focusNode,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            obscureText: !_showPin,
                            maxLength: 8,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              letterSpacing: 8,
                            ),
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: '••••',
                              errorText: _error,
                              prefixIcon: const SizedBox.shrink(),
                              prefixIconConstraints:
                                  const BoxConstraints.tightFor(
                                    width: 48,
                                    height: 48,
                                  ),
                              suffixIconConstraints:
                                  const BoxConstraints.tightFor(
                                    width: 48,
                                    height: 48,
                                  ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _showPin
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () =>
                                    setState(() => _showPin = !_showPin),
                              ),
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onSubmitted: (_) => _authenticateWithPin(),
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _authenticateWithPin,
                            child: _isLoading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Unlock'),
                          ),
                        ),
                      ],

                      // Biometric button
                      if (!isInitializing &&
                          !showAuthMethodError &&
                          (_authMethod == AuthMethod.biometric ||
                              _authMethod == AuthMethod.both)) ...[
                        const SizedBox(height: 24),
                        TextButton.icon(
                          onPressed: _isLoading
                              ? null
                              : _authenticateWithBiometrics,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Use biometrics'),
                        ),
                      ],

                      if (showAuthMethodError) ...[
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _isCheckingAuthMethod = true;
                                _authMethodLoadFailed = false;
                              });
                              unawaited(
                                _checkAuthMethod(refreshAuthState: true),
                              );
                            },
                            child: const Text('Retry'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
