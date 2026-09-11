import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/auth_setup_screen.dart';

class _BiometricAvailableAuthService extends AuthService {
  @override
  Future<bool> isDeviceAuthSupported() async => true;

  @override
  Future<bool> isBiometricHardwareSupported() async => true;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [
    BiometricType.fingerprint,
  ];

  @override
  Future<BiometricAvailability> getBiometricAvailability() async =>
      const BiometricAvailability(
        isDeviceAuthSupported: true,
        isBiometricHardwareSupported: true,
        enrolledBiometrics: [BiometricType.fingerprint],
      );
}

class _BiometricSupportedAuthService extends AuthService {
  @override
  Future<bool> isDeviceAuthSupported() async => true;

  @override
  Future<bool> isBiometricHardwareSupported() async => true;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [];

  @override
  Future<BiometricAvailability> getBiometricAvailability() async =>
      const BiometricAvailability(
        isDeviceAuthSupported: true,
        isBiometricHardwareSupported: true,
        enrolledBiometrics: [],
      );
}

void main() {
  for (final keyboard in [false, true]) {
    testWidgets(
      'requires six digits to advance via ${keyboard ? 'keyboard' : 'Next'}',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authServiceProvider.overrideWithValue(
                _BiometricAvailableAuthService(),
              ),
            ],
            child: const MaterialApp(home: AuthSetupScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('PIN Code'));
        await tester.pumpAndSettle();
        final nextButton = find.widgetWithText(ElevatedButton, 'Next');
        expect(tester.widget<ElevatedButton>(nextButton).onPressed, isNull);
        for (final pin in ['1234', '12345']) {
          await tester.enterText(find.byType(TextField), pin);
          await tester.pump();
          expect(tester.widget<ElevatedButton>(nextButton).onPressed, isNull);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(find.text('Create PIN'), findsOneWidget);
        }
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        expect(tester.widget<ElevatedButton>(nextButton).onPressed, isNotNull);
        if (keyboard) {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        } else {
          await tester.tap(nextButton);
        }
        await tester.pumpAndSettle();
        expect(find.text('Enter your PIN again to confirm.'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.enterText(find.byType(TextField), '654321');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.text('PINs do not match'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
      },
    );
  }

  testWidgets('explains when biometrics are supported but not enrolled', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(
            _BiometricSupportedAuthService(),
          ),
        ],
        child: const MaterialApp(home: AuthSetupScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Biometrics not ready'), findsOneWidget);
    expect(
      find.text(
        'Enroll fingerprint or face in system settings, then return and re-check',
      ),
      findsOneWidget,
    );
    expect(find.text('Re-check biometric status'), findsOneWidget);

    await tester.tap(find.text('PIN Code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Next'));
    await tester.pumpAndSettle();

    expect(find.text('Enable biometrics'), findsOneWidget);
    final biometricSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Enable biometrics'),
    );
    expect(biometricSwitch.onChanged, isNull);
    expect(
      find.text(
        'Enroll fingerprint or face in system settings, then return and re-check',
      ),
      findsOneWidget,
    );
  });
}
