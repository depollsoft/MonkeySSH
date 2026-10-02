import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_authentication.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/presentation/widgets/acp_auth_method_sheet.dart';

void main() {
  setUp(() => FluttyTheme.debugUseSystemFonts = true);
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('cancelling an agent sign-in cancels its request', (
    tester,
  ) async {
    final pending = Completer<AcpSessionError?>();
    AcpRequestCancellation? captured;
    final request = AcpAuthenticationRequest(
      hostId: 1,
      providerId: 'copilot',
      providerLabel: 'Copilot CLI',
      methods: const [AcpAuthMethod(id: 'agent-login', name: 'Agent login')],
      authenticate: (_, {cancellation}) {
        captured = cancellation;
        return pending.future;
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: FluttyTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => AcpAuthMethodSheet(request: request),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Agent login'));
    await tester.pump();
    expect(captured, isNotNull);
    expect(captured!.isCancelled, isFalse);

    await tester.tap(find.text('Cancel sign-in'));
    await tester.pumpAndSettle();
    expect(captured!.isCancelled, isTrue);
    expect(find.byType(AcpAuthMethodSheet), findsNothing);

    // A late answer from the abandoned request changes nothing.
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(AcpAuthMethodSheet), findsNothing);
  });
}
