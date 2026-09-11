// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_attempt_dialog.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockMonetizationService extends Mock implements MonetizationService {}

const _freeMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.unavailable,
  entitlements: MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

/// Stalls until the caller cancels, mirroring an unresponsive SSH endpoint.
class _StalledSshService extends SshService {
  _StalledSshService({this.abortAuthentication = false});

  final bool abortAuthentication;

  final Completer<void> connectStarted = Completer<void>();

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    if (!connectStarted.isCompleted) {
      connectStarted.complete();
    }
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Opening network connection…',
      ),
    );
    await cancellationToken!.cancelled;
    if (abortAuthentication) {
      // dartssh2 errors implement SSHError, not Exception or Error.
      // ignore: only_throw_errors
      throw SSHAuthAbortError('Connection closed before authentication');
    }
    return const SshConnectionResult.userCancelled();
  }
}

class _FailingActiveSessionsNotifier extends ActiveSessionsNotifier {
  final result = Completer<SshConnectionResult>();

  @override
  Map<int, SshConnectionState> build() => {};

  @override
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) => result.future;
}

Host _host() => Host(
  id: 42,
  label: 'stalled box',
  hostname: 'stalled.example.com',
  port: 22,
  username: 'tester',
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

void main() {
  group('connectToHostWithProgressDialog', () {
    for (final failure in <String, Object>{
      'cancelled': const SshConnectionCancelledException(),
      'auth abort': SSHAuthAbortError('Authentication timed out'),
      'auth failure': SSHAuthFailError('Authentication failed'),
      'SSH state': SSHStateError('Transport closed'),
      'SSH socket': SSHSocketError(const SocketException('Disconnected')),
      'socket': const SocketException('Disconnected'),
      'TLS handshake': const HandshakeException('Handshake failed'),
      'TLS': const TlsException('TLS connection failed'),
      'OS': const OSError('Connection refused', 61),
      'unexpected state': StateError('Unexpected connection state'),
    }.entries) {
      testWidgets('${failure.key} uses the connection failure dialog', (
        tester,
      ) async {
        final sessions = _FailingActiveSessionsNotifier();
        SshConnectionResult? result;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeSessionsProvider.overrideWith(() => sessions),
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_freeMonetizationState),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      result = await connectToHostWithProgressDialog(
                        context,
                        ref,
                        _host(),
                      );
                    },
                    child: const Text('Connect'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Connect'));
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget);

        final reports = <FlutterErrorDetails>[];
        final previousOnError = FlutterError.onError;
        FlutterError.onError = reports.add;
        addTearDown(() => FlutterError.onError = previousOnError);
        final stackTrace = StackTrace.current;
        sessions.result.completeError(failure.value, stackTrace);
        await tester.pumpAndSettle();

        FlutterError.onError = previousOnError;
        if (failure.value is StateError) {
          expect(reports, hasLength(1));
          expect(reports.single.exception, same(failure.value));
          expect(reports.single.stack, same(stackTrace));
          expect(reports.single.library, 'connection_attempt_dialog');
        } else {
          expect(reports, isEmpty);
        }
        if (failure.value is SshConnectionCancelledException) {
          expect(find.byType(AlertDialog), findsNothing);
          expect(result?.cancelled, isTrue);
          expect(sessions.getConnectionAttempt(_host().id), isNull);
          return;
        }
        expect(find.text('Connection failed'), findsOneWidget);
        expect(
          find.text(
            'Connection failed. Check the host settings and try again.',
          ),
          findsWidgets,
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(result?.success, isFalse);
        expect(result?.cancelled, isFalse);
        expect(sessions.getConnectionAttempt(_host().id), isNull);
      });
    }

    testWidgets('cancels a stalled connection from the dialog', (tester) async {
      final sshService = _StalledSshService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      final monetizationService = _MockMonetizationService();
      when(
        () => monetizationService.currentState,
      ).thenReturn(_freeMonetizationState);

      SshConnectionResult? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sshServiceProvider.overrideWithValue(sshService),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_freeMonetizationState),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async {
                    result = await connectToHostWithProgressDialog(
                      context,
                      ref,
                      _host(),
                    );
                  },
                  child: const Text('Connect'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Connect'));
      await tester.pump();
      await sshService.connectStarted.future;
      await tester.pump();

      expect(find.text('Connecting to stalled box'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.cancelled, isTrue);
      expect(result!.success, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
      'cancelled authentication closes without reporting a Flutter error',
      (tester) async {
        final sshService = _StalledSshService(abortAuthentication: true);
        final hostRepository = _MockHostRepository();
        when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
        final monetizationService = _MockMonetizationService();
        when(
          () => monetizationService.currentState,
        ).thenReturn(_freeMonetizationState);

        SshConnectionResult? result;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sshServiceProvider.overrideWithValue(sshService),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              monetizationServiceProvider.overrideWithValue(
                monetizationService,
              ),
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_freeMonetizationState),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      result = await connectToHostWithProgressDialog(
                        context,
                        ref,
                        _host(),
                      );
                    },
                    child: const Text('Connect'),
                  ),
                ),
              ),
            ),
          ),
        );

        final reports = <FlutterErrorDetails>[];
        final previousOnError = FlutterError.onError;
        FlutterError.onError = reports.add;
        addTearDown(() => FlutterError.onError = previousOnError);

        await tester.tap(find.text('Connect'));
        await tester.pump();
        await sshService.connectStarted.future;
        await tester.pump();

        expect(find.text('Connecting to stalled box'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        FlutterError.onError = previousOnError;
        expect(reports, isEmpty);
        expect(result, isNotNull);
        expect(result!.cancelled, isTrue);
        expect(result!.success, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('cancels a stalled connection from a back gesture', (
      tester,
    ) async {
      final sshService = _StalledSshService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      final monetizationService = _MockMonetizationService();
      when(
        () => monetizationService.currentState,
      ).thenReturn(_freeMonetizationState);

      SshConnectionResult? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sshServiceProvider.overrideWithValue(sshService),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_freeMonetizationState),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async {
                    result = await connectToHostWithProgressDialog(
                      context,
                      ref,
                      _host(),
                    );
                  },
                  child: const Text('Connect'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Connect'));
      await tester.pump();
      await sshService.connectStarted.future;
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.cancelled, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
