import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_metadata.dart';
import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../domain/models/host_cli_launch_preferences.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/background_ssh_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/telemetry_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../providers/entity_list_providers.dart';
import '../widgets/font_family_picker.dart';
import '../widgets/message_of_the_day.dart';
import '../widgets/premium_access.dart';
import '../widgets/premium_badge.dart';
import '../widgets/terminal_text_style.dart';
import '../widgets/terminal_theme_picker.dart';
import 'transfer_screen.dart';

const _githubUrl = 'https://github.com/depollsoft/MonkeySSH';

/// Settings screen with appearance, security, terminal, import/export,
/// background and about sections.
class SettingsScreen extends ConsumerWidget {
  /// Creates a new [SettingsScreen].
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      children: [
        const _SubscriptionSection(),
        const _AppearanceSection(),
        const _SecuritySection(),
        const _PrivacySection(),
        const _TerminalSection(),
        const _ImportExportSection(),
        if (BackgroundSshService.supportsBatteryOptimizationControls)
          const _AndroidBackgroundSection(),
        if (isDiagnosticsLoggingEnabled) const _DiagnosticsSection(),
        const _AboutSection(),
      ],
    ),
  );
}

final _biometricSettingsStateProvider =
    FutureProvider.autoDispose<_BiometricSettingsState>((ref) async {
      final authService = ref.watch(authServiceProvider);
      final availability = await authService.getBiometricAvailability();
      final isEnabled = await authService.isBiometricEnabled();

      return _BiometricSettingsState(
        availability: availability,
        isEnabled: isEnabled,
      );
    });

class _BiometricSettingsState {
  const _BiometricSettingsState({
    required this.availability,
    required this.isEnabled,
  });

  final BiometricAvailability availability;
  final bool isEnabled;

  bool get canAuthenticateWithBiometrics =>
      availability.canAuthenticateWithBiometrics;

  bool get isBiometricHardwareSupported =>
      availability.isBiometricHardwareSupported;

  bool get isDeviceAuthSupported => availability.isDeviceAuthSupported;

  bool get needsBiometricEnrollment => availability.needsBiometricEnrollment;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: FluttyTheme.displayMono(
              fontSize: 13,
              color: theme.colorScheme.onSurface,
              letterSpacing: 0,
            ),
          ),
          if (subtitle case final subtitle?) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionSection extends ConsumerWidget {
  const _SubscriptionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'MonkeySSH Pro',
          subtitle: 'Subscription status and Pro-only workflows',
        ),
        ListTile(
          leading: Icon(
            state.isProUnlocked
                ? Icons.workspace_premium_rounded
                : Icons.workspace_premium_outlined,
          ),
          title: const Text('Subscription'),
          subtitle: Text(
            state.isProUnlocked
                ? state.isLifetimeUnlocked
                      ? 'Lifetime — unlocked on this device'
                      : 'Unlocked on this device'
                : 'Unlock transfers, automation, and agent launch presets',
          ),
          trailing: state.isProUnlocked
              ? PremiumBadge(
                  label: state.isLifetimeUnlocked ? 'Lifetime' : 'Active',
                )
              : const PremiumBadge(),
          onTap: () => context.pushNamed(Routes.upgrade),
        ),
      ],
    );
  }
}

void _showChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required T current,
  required List<T> options,
  required String Function(T) label,
  required ValueChanged<T> onSelected,
  String Function(T)? subtitle,
  Widget? explanation,
}) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: RadioGroup<T>(
        groupValue: current,
        onChanged: (value) {
          if (value == null) return;
          onSelected(value);
          Navigator.pop(context);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (explanation != null) ...[
              explanation,
              const SizedBox(height: FluttyTheme.spacingMd),
            ],
            for (final option in options)
              RadioListTile<T>(
                value: option,
                title: Text(label(option)),
                subtitle: subtitle == null ? null : Text(subtitle(option)),
              ),
          ],
        ),
      ),
    ),
  );
}

class _SettingSwitch<N extends Notifier<bool>> extends ConsumerWidget {
  const _SettingSwitch({
    required this.provider,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.setEnabled,
  });

  final NotifierProvider<N, bool> provider;
  final IconData icon;
  final String title;
  final String subtitle;
  final Future<void> Function(N, {required bool enabled}) setEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SwitchListTile(
    secondary: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    value: ref.watch(provider),
    onChanged: (value) =>
        unawaited(setEnabled(ref.read(provider.notifier), enabled: value)),
  );
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeNotifierProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'appearance',
          subtitle: 'App-wide color mode',
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Theme'),
          subtitle: Text(_themeModeLabel(themeMode)),
          onTap: () => _showThemeDialog(context, ref, themeMode),
        ),
        _SettingSwitch(
          provider: terminalThemesApplyToAppNotifierProvider,
          icon: Icons.color_lens_outlined,
          title: 'Use terminal themes for app',
          subtitle:
              'Apply the selected terminal light and dark themes to app colors',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
      ],
    );
  }

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
    ThemeMode.system => 'System default',
  };

  void _showThemeDialog(
    BuildContext context,
    WidgetRef ref,
    ThemeMode current,
  ) => _showChoiceDialog(
    context: context,
    title: 'Theme',
    current: current,
    options: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
    label: _themeModeLabel,
    onSelected: ref.read(themeModeNotifierProvider.notifier).setThemeMode,
  );
}

class _SecuritySection extends ConsumerWidget {
  const _SecuritySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final isAuthKnown = authState != AuthState.unknown;
    final isAuthConfigured =
        authState == AuthState.locked || authState == AuthState.unlocked;
    final autoLockTimeout = ref.watch(autoLockTimeoutNotifierProvider);
    final biometricSettings = ref.watch(_biometricSettingsStateProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'security',
          subtitle: 'PIN, biometrics, and automatic locking',
        ),
        if (isAuthConfigured)
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: const Text('Change PIN'),
            subtitle: const Text('Update your PIN code'),
            onTap: () => _showChangePinDialog(context, ref),
          )
        else
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Set up app lock'),
            subtitle: Text(
              isAuthKnown
                  ? 'Protect the app with a PIN and optional biometrics'
                  : 'Checking security status',
            ),
            onTap: isAuthKnown
                ? () => context.pushNamed(Routes.authSetup)
                : null,
          ),
        biometricSettings.when(
          loading: () => const SwitchListTile(
            secondary: Icon(Icons.fingerprint),
            title: Text('Biometric authentication'),
            subtitle: Text('Checking biometric availability'),
            value: false,
            onChanged: null,
          ),
          error: (_, _) => const SwitchListTile(
            secondary: Icon(Icons.fingerprint),
            title: Text('Biometric authentication'),
            subtitle: Text('Biometric status unavailable'),
            value: false,
            onChanged: null,
          ),
          data: (state) => SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Biometric authentication'),
            subtitle: Text(
              _biometricSubtitle(
                isAuthKnown: isAuthKnown,
                isAuthConfigured: isAuthConfigured,
                state: state,
              ),
            ),
            value: state.isEnabled && state.canAuthenticateWithBiometrics,
            onChanged: state.canAuthenticateWithBiometrics && isAuthConfigured
                ? (value) => _toggleBiometric(ref, value)
                : null,
          ),
        ),
        biometricSettings.maybeWhen(
          data: (state) {
            if (!isAuthConfigured || !state.needsBiometricEnrollment) {
              return const SizedBox.shrink();
            }

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      ref.invalidate(_biometricSettingsStateProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Re-check biometric status'),
                ),
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Auto-lock timeout'),
          subtitle: Text(
            !isAuthKnown
                ? 'Checking security status'
                : isAuthConfigured
                ? autoLockTimeout == 0
                      ? 'Disabled'
                      : '$autoLockTimeout minute${autoLockTimeout == 1 ? '' : 's'}'
                : 'Set up app lock first',
          ),
          enabled: isAuthConfigured,
          onTap: isAuthConfigured
              ? () => _showAutoLockDialog(context, ref, autoLockTimeout)
              : null,
        ),
      ],
    );
  }

  String _biometricSubtitle({
    required bool isAuthKnown,
    required bool isAuthConfigured,
    required _BiometricSettingsState state,
  }) {
    if (!isAuthKnown) {
      return 'Checking security status';
    }
    if (!state.isBiometricHardwareSupported) {
      return state.isDeviceAuthSupported
          ? 'Device lock is available, but no biometric hardware was reported'
          : 'Biometric hardware not supported on this device';
    }
    if (!isAuthConfigured) {
      return state.needsBiometricEnrollment
          ? 'Enroll fingerprint or face in system settings before enabling'
          : 'Set up app lock first';
    }
    if (state.canAuthenticateWithBiometrics) {
      return 'Use fingerprint or face to unlock';
    }
    return 'Enroll fingerprint or face in system settings, then return and re-check';
  }

  void _showChangePinDialog(BuildContext context, WidgetRef ref) {
    final currentPinController = TextEditingController();
    final newPinController = TextEditingController();
    final confirmPinController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var currentPinErrorText = '';
    var isChanging = false;

    String? validateCurrentPin(String? value) {
      if (value?.isEmpty ?? true) return 'Required';
      return null;
    }

    String? validateNewPin(String? value) {
      if (value?.isEmpty ?? true) return 'Required';
      if (value!.length < 6) return 'PIN must be 6-8 digits';
      return null;
    }

    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('Change PIN'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: currentPinController,
                    decoration: const InputDecoration(
                      labelText: 'Current PIN',
                      counterText: '',
                    ),
                    forceErrorText: currentPinErrorText.isEmpty
                        ? null
                        : currentPinErrorText,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: validateCurrentPin,
                    onChanged: (_) {
                      if (currentPinErrorText.isEmpty) return;
                      setState(() => currentPinErrorText = '');
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: newPinController,
                    decoration: const InputDecoration(
                      labelText: 'New PIN',
                      counterText: '',
                    ),
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: validateNewPin,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: confirmPinController,
                    decoration: const InputDecoration(
                      labelText: 'Confirm new PIN',
                      counterText: '',
                    ),
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (v) {
                      final pinValidationError = validateNewPin(v);
                      if (pinValidationError != null) return pinValidationError;
                      if (v != newPinController.text) {
                        return 'PINs do not match';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isChanging ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isChanging
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }

                        setState(() {
                          currentPinErrorText = '';
                          isChanging = true;
                        });

                        bool success;
                        try {
                          success = await ref
                              .read(authServiceProvider)
                              .changePin(
                                currentPinController.text,
                                newPinController.text,
                              );
                        } on Object catch (error, stackTrace) {
                          FlutterError.reportError(
                            FlutterErrorDetails(
                              exception: error,
                              stack: stackTrace,
                              library: 'auth',
                              context: ErrorDescription(
                                'while changing the app PIN from settings',
                              ),
                            ),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not change PIN. Try again.',
                                ),
                              ),
                            );
                          }
                          return;
                        } finally {
                          if (context.mounted) {
                            setState(() => isChanging = false);
                          }
                        }

                        if (!context.mounted) return;

                        if (success) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('PIN changed successfully'),
                            ),
                          );
                          return;
                        }

                        setState(
                          () =>
                              currentPinErrorText = 'Current PIN is incorrect',
                        );
                      },
                child: isChanging
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Change'),
              ),
            ],
          ),
        ),
      ).whenComplete(() {
        currentPinController.clear();
        newPinController.clear();
        confirmPinController.clear();
        currentPinController.dispose();
        newPinController.dispose();
        confirmPinController.dispose();
      }),
    );
  }

  Future<void> _toggleBiometric(WidgetRef ref, bool value) async {
    await ref.read(authServiceProvider).setBiometricEnabled(enabled: value);
    ref.invalidate(_biometricSettingsStateProvider);
  }

  void _showAutoLockDialog(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) => _showChoiceDialog(
    context: context,
    title: 'Auto-lock timeout',
    current: current,
    options: const [0, 1, 2, 5, 10, 15, 30],
    label: (minutes) =>
        minutes == 0 ? 'Disabled' : '$minutes minute${minutes == 1 ? '' : 's'}',
    onSelected: ref.read(autoLockTimeoutNotifierProvider.notifier).setTimeout,
  );
}

class _PrivacySection extends ConsumerWidget {
  const _PrivacySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final telemetryService = ref.watch(telemetryServiceProvider);
    final telemetryCollectionEnabled = ref.watch(
      telemetryCollectionNotifierProvider,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'privacy',
          subtitle: 'Anonymous usage analytics and crash reporting',
        ),
        SwitchListTile(
          secondary: const Icon(Icons.insights_outlined),
          title: const Text('Share analytics and crash reports'),
          subtitle: Text(
            _telemetrySubtitle(
              status: telemetryService.status,
              enabled: telemetryCollectionEnabled,
            ),
          ),
          value: telemetryService.isAvailable && telemetryCollectionEnabled,
          onChanged: telemetryService.isAvailable
              ? (value) {
                  unawaited(
                    ref
                        .read(telemetryCollectionNotifierProvider.notifier)
                        .setEnabled(enabled: value),
                  );
                }
              : null,
        ),
      ],
    );
  }

  String _telemetrySubtitle({
    required TelemetryServiceStatus status,
    required bool enabled,
  }) {
    if (status != TelemetryServiceStatus.ready) {
      return switch (status) {
        TelemetryServiceStatus.disabledByBuild =>
          'Not available in this build.',
        TelemetryServiceStatus.unsupportedPlatform =>
          'Not available on this platform.',
        TelemetryServiceStatus.initializationFailed =>
          'Unavailable because Firebase could not initialize.',
        TelemetryServiceStatus.ready => '',
      };
    }
    if (!enabled) {
      return 'Off. When on, MonkeySSH shares anonymous feature usage and sanitized crash reports.';
    }
    return 'On. Never includes hostnames, usernames, commands, terminal output, paths, clipboard, or credentials.';
  }
}

class _TerminalSection extends ConsumerWidget {
  const _TerminalSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentWindowMode = ref.watch(
      agentWindowModePreferenceNotifierProvider,
    );
    final fontSize = ref.watch(fontSizeNotifierProvider);
    final fontFamily = ref.watch(fontFamilyNotifierProvider);
    final cursorStyle = ref.watch(cursorStyleNotifierProvider);
    final agentAccess =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final canManageAgents = agentAccess.allowsFeature(
      MonetizationFeature.agentManagement,
    );
    final agentUpdateNotifications = ref.watch(
      agentUpdateNotificationsNotifierProvider,
    );
    final terminalPathLinks = ref.watch(terminalPathLinksNotifierProvider);
    final terminalPathLinkUnderlines = ref.watch(
      terminalPathLinkUnderlinesNotifierProvider,
    );
    final sharedClipboard = ref.watch(sharedClipboardNotifierProvider);
    final sharedClipboardLocalRead = ref.watch(
      sharedClipboardLocalReadNotifierProvider,
    );
    final themeSettings = ref.watch(terminalThemeSettingsProvider);
    final availableThemes =
        ref.watch(allTerminalThemesProvider).asData?.value ??
        TerminalThemes.all;

    final lightTheme = TerminalThemes.resolveById(
      brightness: Brightness.light,
      themeId: themeSettings.lightThemeId,
      additionalThemes: availableThemes,
    );
    final darkTheme = TerminalThemes.resolveById(
      brightness: Brightness.dark,
      themeId: themeSettings.darkThemeId,
      additionalThemes: availableThemes,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'terminal',
          subtitle:
              'Themes, fonts, agent windows, links, keyboard, and clipboard behavior',
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Light Mode Theme'),
          subtitle: Text(lightTheme.name),
          onTap: () => _showThemePicker(context, ref, isLight: true),
        ),
        ListTile(
          leading: const Icon(Icons.palette),
          title: const Text('Dark Mode Theme'),
          subtitle: Text(darkTheme.name),
          onTap: () => _showThemePicker(context, ref, isLight: false),
        ),
        ListTile(
          leading: const Icon(Icons.format_size),
          title: const Text('Font size'),
          subtitle: Text('${fontSize.round()} pt'),
          onTap: () => _showFontSizeDialog(context, ref, fontSize),
        ),
        ListTile(
          leading: const Icon(Icons.font_download_outlined),
          title: const Text('Font family'),
          subtitle: Text(fontFamilyLabel(fontFamily)),
          onTap: () => _showFontFamilyDialog(context, ref, fontFamily),
        ),
        ListTile(
          key: const ValueKey('settings-agent-window-mode'),
          leading: const Icon(Icons.view_agenda_outlined),
          title: const Text('Agent window mode'),
          subtitle: Text(
            '${agentWindowMode.label}\n${agentWindowMode.explanation}',
            maxLines: 3,
          ),
          onTap: () =>
              _showAgentWindowModeDialog(context, ref, agentWindowMode),
        ),
        SwitchListTile(
          key: const ValueKey('settings-agent-update-notifications'),
          secondary: const Icon(Icons.system_update_alt_rounded),
          title: Row(
            children: [
              const Expanded(child: Text('Agent update indicators')),
              if (!canManageAgents) const PremiumBadge(),
            ],
          ),
          subtitle: const Text(
            'Show a dot on the terminal menu when agent updates are available',
          ),
          value: canManageAgents && agentUpdateNotifications,
          onChanged: (value) async {
            if (!await requireMonetizationFeatureAccess(
                  context: context,
                  ref: ref,
                  feature: MonetizationFeature.agentManagement,
                ) ||
                !context.mounted) {
              return;
            }
            await ref
                .read(agentUpdateNotificationsNotifierProvider.notifier)
                .setEnabled(enabled: value);
          },
        ),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('Cursor style'),
          subtitle: Text(_cursorStyleLabel(cursorStyle)),
          onTap: () => _showCursorStyleDialog(context, ref, cursorStyle),
        ),
        _SettingSwitch(
          provider: bellSoundNotifierProvider,
          icon: Icons.notifications_outlined,
          title: 'Bell sound',
          subtitle: 'Play sound on terminal bell',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
        _SettingSwitch(
          provider: terminalNotificationsNotifierProvider,
          icon: Icons.notifications_active_outlined,
          title: 'Desktop notifications',
          subtitle: 'Let the remote shell post notifications (OSC 9/777/99)',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
        _SettingSwitch(
          provider: terminalWakeLockNotifierProvider,
          icon: Icons.screen_lock_portrait_outlined,
          title: 'Keep screen awake',
          subtitle: 'Hold a wake lock while a terminal is active',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.folder_open_outlined),
          title: const Text('Clickable file paths'),
          subtitle: const Text('Tap terminal file paths to open them in SFTP'),
          value: terminalPathLinks,
          onChanged: (value) {
            ref
                .read(terminalPathLinksNotifierProvider.notifier)
                .setEnabled(enabled: value);
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.format_underline),
          title: const Text('Path link underlines'),
          subtitle: const Text('Underline clickable terminal file paths'),
          value: terminalPathLinks && terminalPathLinkUnderlines,
          onChanged: terminalPathLinks
              ? (value) {
                  ref
                      .read(terminalPathLinkUnderlinesNotifierProvider.notifier)
                      .setEnabled(enabled: value);
                }
              : null,
        ),
        _SettingSwitch(
          provider: portForwardBrowserLinksNotifierProvider,
          icon: Icons.open_in_browser_outlined,
          title: 'Open forwarded links in app',
          subtitle:
              'Keeps the SSH connection open while you browse forwarded pages; turn off to use the system browser',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
        _SettingSwitch(
          provider: shellCompletionsNotifierProvider,
          icon: Icons.auto_awesome_motion_outlined,
          title: 'Shell completion popups',
          subtitle:
              'Show command and path suggestions while typing at a shell prompt',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
        _SettingSwitch(
          provider: confirmMuxWindowCloseNotifierProvider,
          icon: Icons.warning_amber_rounded,
          title: 'Confirm before closing mux windows',
          subtitle: 'Ask before closing a tmux or MonkeyMux terminal window',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.content_paste_go_outlined),
          title: const Text('Remote can update clipboard'),
          subtitle: const Text(
            'Allow OSC 52 and remote clipboard tools to copy remote text into the local clipboard',
          ),
          value: sharedClipboard,
          onChanged: (value) {
            unawaited(
              ref
                  .read(sharedClipboardNotifierProvider.notifier)
                  .setEnabled(enabled: value),
            );
            ref
                .read(activeSessionsProvider.notifier)
                .updateClipboardSharing(
                  enabled: value,
                  allowLocalClipboardRead: value && sharedClipboardLocalRead,
                );
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.content_paste_search_outlined),
          title: const Text('Remote can read clipboard'),
          subtitle: Text(
            Theme.of(context).platform == TargetPlatform.iOS
                ? 'Allow remote OSC 52 queries to read local clipboard text. '
                      'The clipboard is not polled automatically on iOS.'
                : 'Allow remote OSC 52 queries and clipboard sync to send local clipboard text to the connected host',
          ),
          value: sharedClipboard && sharedClipboardLocalRead,
          onChanged: sharedClipboard
              ? (value) {
                  unawaited(
                    ref
                        .read(sharedClipboardLocalReadNotifierProvider.notifier)
                        .setEnabled(enabled: value),
                  );
                  ref
                      .read(activeSessionsProvider.notifier)
                      .updateClipboardSharing(
                        enabled: sharedClipboard,
                        allowLocalClipboardRead: value,
                      );
                }
              : null,
        ),
        _SettingSwitch(
          provider: tapToShowKeyboardNotifierProvider,
          icon: Icons.keyboard_outlined,
          title: 'Tap to show keyboard',
          subtitle:
              'Show the keyboard when tapping the terminal. '
              'When off, use the toolbar button instead.',
          setEnabled: (notifier, {required enabled}) =>
              notifier.setEnabled(enabled: enabled),
        ),
      ],
    );
  }

  void _showAgentWindowModeDialog(
    BuildContext context,
    WidgetRef ref,
    AgentWindowModePreference current,
  ) => _showChoiceDialog(
    context: context,
    title: 'Agent window mode',
    current: current,
    options: AgentWindowModePreference.values,
    label: (preference) => preference.label,
    subtitle: (preference) => preference.explanation,
    explanation: const Text(
      'Choose the default for agents that support both experiences. '
      'You can still pick a different mode from the window menu.',
    ),
    onSelected: ref
        .read(agentWindowModePreferenceNotifierProvider.notifier)
        .setPreference,
  );

  Future<void> _showThemePicker(
    BuildContext context,
    WidgetRef ref, {
    required bool isLight,
  }) async {
    final settings = ref.read(terminalThemeSettingsProvider);
    final currentId = isLight ? settings.lightThemeId : settings.darkThemeId;

    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );

    if (theme != null) {
      final notifier = ref.read(terminalThemeSettingsProvider.notifier);
      if (isLight) {
        await notifier.setLightTheme(theme.id);
      } else {
        await notifier.setDarkTheme(theme.id);
      }
    }
  }

  String _cursorStyleLabel(String style) => switch (style) {
    'block' => 'Block',
    'underline' => 'Underline',
    'bar' => 'Bar',
    _ => style,
  };

  void _showFontSizeDialog(
    BuildContext context,
    WidgetRef ref,
    double current,
  ) {
    var tempValue = current;
    final currentFont = ref.read(fontFamilyNotifierProvider);
    const previewText = 'AaBbCc 0123 {}[]';

    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Font size'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Live preview with current font
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Text(
                      previewText,
                      style: resolveMonospaceTextStyle(
                        currentFont,
                        fontSize: tempValue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${tempValue.round()} pt',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Slider(
                value: tempValue,
                min: 8,
                max: 24,
                divisions: 16,
                label: '${tempValue.round()} pt',
                onChanged: (value) => setState(() => tempValue = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(fontSizeNotifierProvider.notifier)
                    .setFontSize(tempValue);
                Navigator.pop(context);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showFontFamilyDialog(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final selected = await showFontPickerDialog(
      context: context,
      currentFontFamily: current,
      title: 'Font family',
      previewFontSize: 16,
    );
    if (selected != null && context.mounted) {
      await ref
          .read(fontFamilyNotifierProvider.notifier)
          .setFontFamily(selected);
    }
  }

  void _showCursorStyleDialog(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) => _showChoiceDialog(
    context: context,
    title: 'Cursor style',
    current: current,
    options: const ['block', 'underline', 'bar'],
    label: _cursorStyleLabel,
    onSelected: ref.read(cursorStyleNotifierProvider.notifier).setCursorStyle,
  );
}

class _DiagnosticsSection extends ConsumerStatefulWidget {
  const _DiagnosticsSection();

  @override
  ConsumerState<_DiagnosticsSection> createState() =>
      _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends ConsumerState<_DiagnosticsSection> {
  late final DiagnosticsLogService _diagnosticsLog;

  @override
  void initState() {
    super.initState();
    _diagnosticsLog = ref.read(diagnosticsLogServiceProvider)
      ..addListener(_handleDiagnosticsChanged);
  }

  @override
  void dispose() {
    _diagnosticsLog.removeListener(_handleDiagnosticsChanged);
    super.dispose();
  }

  void _handleDiagnosticsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final appMetadata = ref.watch(appMetadataProvider).asData?.value;
    final entryCount = _diagnosticsLog.entryCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'diagnostics',
          subtitle: 'Preview-only troubleshooting logs',
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Copy diagnostics log'),
          subtitle: Text(
            entryCount == 0
                ? 'No diagnostic events recorded yet'
                : '$entryCount sanitized event${entryCount == 1 ? '' : 's'} ready to copy',
          ),
          onTap: entryCount == 0
              ? null
              : () => _copyDiagnostics(context, appMetadata),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Clear diagnostics log'),
          subtitle: const Text('Remove the in-memory troubleshooting log'),
          enabled: entryCount > 0,
          onTap: entryCount == 0 ? null : () => _clearDiagnostics(context),
        ),
      ],
    );
  }

  Future<void> _copyDiagnostics(
    BuildContext context,
    AppMetadata? appMetadata,
  ) async {
    final text = _diagnosticsLog.exportText(appMetadata: appMetadata);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnostics log copied')));
  }

  void _clearDiagnostics(BuildContext context) {
    _diagnosticsLog.clear();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnostics log cleared')));
  }
}

class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appMetadata = ref.watch(appMetadataProvider);
    final appName = ref.watch(appDisplayNameProvider);
    final previewBuildLabel = appMetadata.asData?.value.pullRequestLabel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'about',
          subtitle: 'Version, source, and licenses',
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('App version'),
          subtitle: Text(
            _versionLabel(appMetadata),
            style: FluttyTheme.monoStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (previewBuildLabel != null)
          ListTile(
            leading: const Icon(Icons.merge_type_outlined),
            title: const Text('Preview build'),
            subtitle: Text(
              previewBuildLabel,
              style: FluttyTheme.monoStyle.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('GitHub'),
          subtitle: const Text('Copy source repository URL'),
          onTap: () => unawaited(_copyGitHubUrl(context)),
        ),
        ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('App Review Demo'),
          subtitle: const Text(
            'Load a pre-populated local workspace for review',
          ),
          onTap: () => context.pushNamed(Routes.appReviewDemo),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Licenses'),
          subtitle: const Text('Open source licenses'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: appName,
            applicationVersion: _versionLabel(appMetadata),
          ),
        ),
        const MessageOfTheDay(),
      ],
    );
  }

  String _versionLabel(AsyncValue<AppMetadata> appMetadata) => appMetadata.when(
    data: (value) => value.versionLabel,
    loading: () => 'Loading...',
    error: (_, _) => 'Unavailable',
  );

  Future<void> _copyGitHubUrl(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: _githubUrl));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('GitHub URL copied')));
  }
}

class _AndroidBackgroundSection extends ConsumerStatefulWidget {
  const _AndroidBackgroundSection();

  @override
  ConsumerState<_AndroidBackgroundSection> createState() =>
      _AndroidBackgroundSectionState();
}

class _AndroidBackgroundSectionState
    extends ConsumerState<_AndroidBackgroundSection>
    with WidgetsBindingObserver {
  late Future<bool?> _batteryOptimizationStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _batteryOptimizationStatus =
        BackgroundSshService.isBatteryOptimizationIgnored();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) {
      return;
    }
    _refreshStatus();
  }

  void _refreshStatus() {
    setState(() {
      _batteryOptimizationStatus =
          BackgroundSshService.isBatteryOptimizationIgnored();
    });
  }

  Future<void> _requestBatteryOptimizationExemption() async {
    final openedSettings =
        await BackgroundSshService.requestDisableBatteryOptimization();
    if (!mounted) {
      return;
    }
    if (!openedSettings) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open Android battery optimization settings'),
        ),
      );
      return;
    }
    _refreshStatus();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool?>(
    future: _batteryOptimizationStatus,
    builder: (context, snapshot) {
      final isLoading = snapshot.connectionState != ConnectionState.done;
      final isUnavailable = !isLoading && snapshot.data == null;
      final hasResolvedStatus = snapshot.data != null && !isLoading;
      final isDisabled = snapshot.data ?? false;
      final leadingIcon = isLoading
          ? Icons.hourglass_top_outlined
          : isUnavailable
          ? Icons.error_outline
          : isDisabled
          ? Icons.battery_saver_outlined
          : Icons.battery_alert_outlined;
      final subtitle = isLoading
          ? 'Checking Android battery optimization status...'
          : isUnavailable
          ? 'Could not determine battery optimization status right now.'
          : isDisabled
          ? 'Disabled for MonkeySSH. Android is less likely to pause background SSH.'
          : 'Still enabled. Foreground notifications alone are not always enough on Android. Tap to allow MonkeySSH to request an exemption.';
      final trailingText = hasResolvedStatus
          ? (isDisabled ? 'Disabled' : 'Enabled')
          : isUnavailable
          ? 'Unavailable'
          : 'Loading...';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'background ssh',
            subtitle: 'Keep sessions alive while MonkeySSH is backgrounded',
          ),
          ListTile(
            leading: Icon(leadingIcon),
            title: const Text('Battery optimization'),
            subtitle: Text(subtitle),
            trailing: Text(
              trailingText,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            onTap: hasResolvedStatus
                ? _requestBatteryOptimizationExemption
                : null,
          ),
        ],
      );
    },
  );
}

class _ImportExportSection extends ConsumerWidget {
  const _ImportExportSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionHeader(
        title: 'import & export',
        subtitle: 'Encrypted migration packages for moving devices',
      ),
      ListTile(
        leading: Icon(useShareSheet ? Icons.share : Icons.save_alt),
        title: const Text('Export app data'),
        subtitle: const Text(
          'Create encrypted .monkeysshx export file (MonkeySSH Pro)',
        ),
        trailing: const PremiumBadge(),
        onTap: () => _exportMigration(context, ref),
      ),
      ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: const Text('Import app data'),
        subtitle: const Text(
          'Open encrypted .monkeysshx export file (MonkeySSH Pro)',
        ),
        trailing: const PremiumBadge(),
        onTap: () => _importMigration(context, ref),
      ),
    ],
  );

  Future<void> _exportMigration(BuildContext context, WidgetRef ref) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.migrationImportExport,
      blockedAction: 'Export encrypted app data',
      blockedOutcome:
          'Unlock Pro to package hosts, keys, snippets, and settings for '
          'another device.',
    );
    if (!hasAccess || !context.mounted) {
      return;
    }
    final isAuthorized = await authorizeSensitiveTransferExport(
      context: context,
      authService: ref.read(authServiceProvider),
      readAuthState: () => ref.read(authStateProvider),
      reason: 'Authenticate to export app data',
    );
    if (!context.mounted) {
      return;
    }
    if (!isAuthorized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication required for export')),
      );
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Export passphrase',
    );
    if (!context.mounted || transferPassphrase == null) {
      return;
    }

    try {
      final payload = await ref
          .read(secureTransferServiceProvider)
          .createFullMigrationPayload(transferPassphrase: transferPassphrase);
      if (!context.mounted) {
        return;
      }
      await saveTransferPayloadToFile(
        context: context,
        payload: payload,
        defaultFileName: 'monkeyssh-migration',
        sharePositionOrigin: shareOriginFromContext(context),
      );
    } on FormatException catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on Exception catch (error) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          library: 'settings',
          context: ErrorDescription('while exporting app data'),
        ),
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export failed. Try again.')),
      );
    }
  }

  Future<void> _importMigration(BuildContext context, WidgetRef ref) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.migrationImportExport,
      blockedAction: 'Import encrypted app data',
      blockedOutcome:
          'Unlock Pro to restore a MonkeySSH migration package on this device.',
    );
    if (!hasAccess || !context.mounted) {
      return;
    }
    final isAuthorized = await authorizeSensitiveTransferExport(
      context: context,
      authService: ref.read(authServiceProvider),
      readAuthState: () => ref.read(authStateProvider),
      reason: 'Authenticate to import app data',
    );
    if (!context.mounted) {
      return;
    }
    if (!isAuthorized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication required for import')),
      );
      return;
    }

    final encodedPayload = await pickTransferPayloadFromFile(context);
    if (!context.mounted || encodedPayload == null) {
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Import passphrase',
    );
    if (!context.mounted || transferPassphrase == null) {
      return;
    }

    try {
      final transferService = ref.read(secureTransferServiceProvider);
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      final payload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: transferPassphrase,
      );
      if (payload.type != TransferPayloadType.fullMigration) {
        throw const FormatException(
          'This transfer payload does not contain app data',
        );
      }

      final preview = transferService.previewMigrationPayload(payload);
      if (!context.mounted) {
        return;
      }
      final mode = await showMigrationImportModeDialog(
        context: context,
        preview: preview,
        title: 'Import app data',
      );
      if (mode == null || !context.mounted) {
        return;
      }

      await transferService.importFullMigrationPayload(
        payload: payload,
        mode: mode,
      );
      if (mode == MigrationImportMode.replace) {
        await sessionsNotifier.disconnectAll();
      }
      invalidateSyncedDataProviders(ref.invalidate);

      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Import completed')));
    } on FormatException catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${error.message}')),
      );
    } on Exception catch (error) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          library: 'settings',
          context: ErrorDescription('while importing app data'),
        ),
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Import failed. Check the file and try again.'),
        ),
      );
    }
  }
}
