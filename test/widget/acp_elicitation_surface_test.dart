import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/presentation/widgets/acp_elicitation_surface.dart';

AcpSessionElicitation _item(String key, Map<String, Object?> params) =>
    AcpSessionElicitation(
      requestKey: key,
      requestedAt: DateTime(2026),
      request: AcpElicitationRequest.parse(
        params,
        formSupported: true,
        urlSupported: true,
      ),
    );

AcpSessionElicitation _form({String key = 's:form'}) => _item(key, {
  'sessionId': 's',
  'mode': 'form',
  'message': 'How should I refactor?',
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'strategy': {
        'type': 'string',
        'title': 'Strategy',
        'enum': ['safe', 'fast'],
      },
      'branch': {
        'type': 'string',
        'title': 'Branch',
        'default': 'refactor/payments',
      },
      'retries': {'type': 'integer', 'title': 'Retries', 'maximum': 3},
      'dryRun': {'type': 'boolean', 'title': 'Dry run', 'default': true},
    },
    'required': ['strategy'],
  },
});

AcpSessionElicitation _url(String url, {String key = 's:url'}) => _item(key, {
  'sessionId': 's',
  'mode': 'url',
  'elicitationId': 'oauth-1',
  'url': url,
  'message': 'Connect your account',
});

final class _Calls {
  final log = <String>[];
  final accepted = <(String, Map<String, Object?>?)>[];
  final opened = <Uri>[];
}

Widget _host(
  _Calls calls, {
  required List<AcpSessionElicitation> items,
  List<AcpAwaitingElicitation> awaiting = const [],
}) => MaterialApp(
  theme: FluttyTheme.dark,
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: SingleChildScrollView(
        child: AcpElicitationSurface(
          agentLabel: 'Claude Code',
          elicitations: items,
          awaiting: awaiting,
          onAccept: (key, content) async {
            calls.log.add('accept:$key');
            calls.accepted.add((key, content));
          },
          onDecline: (key) async => calls.log.add('decline:$key'),
          onCancel: (key) async => calls.log.add('cancel:$key'),
          onOpenUrl: (url) async {
            calls.log.add('open');
            calls.opened.add(url);
            return true;
          },
          onDismissAwaiting: (id) => calls.log.add('stop:$id'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('cards name the agent and answer decline or dismiss', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(calls, items: [_form(), _url('https://auth.example.com/x')]),
    );
    expect(find.text('Claude Code needs your input'), findsOneWidget);
    expect(find.text('Claude Code wants you to open a page'), findsOneWidget);
    expect(find.text('auth.example.com'), findsOneWidget);

    await tester.tap(find.text('Decline').first);
    await tester.pump();
    await tester.tap(find.text('Dismiss').last);
    await tester.pump();
    expect(calls.log, ['decline:s:form', 'cancel:s:url']);
  });

  testWidgets('form sheet validates, pre-fills, and submits content', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host(calls, items: [_form()]));
    await tester.tap(find.text('Respond'));
    await tester.pumpAndSettle();

    expect(find.text('refactor/payments'), findsOneWidget);
    expect(find.bySemanticsLabel('Strategy, required'), findsOneWidget);

    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(calls.log, isEmpty);

    await tester.tap(find.text('safe'));
    await tester.enterText(find.byType(TextFormField).at(1), '9');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(find.text('Use 3 or less'), findsOneWidget);
    expect(calls.log, isEmpty);

    await tester.enterText(find.byType(TextFormField).at(1), '2');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(calls.accepted.single.$1, 's:form');
    expect(calls.accepted.single.$2, {
      'strategy': 'safe',
      'branch': 'refactor/payments',
      'retries': 2,
      'dryRun': true,
    });
  });

  testWidgets('dismissing the form sheet cancels and declining declines', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(
        calls,
        items: [
          _form(),
          _form(key: 's:other'),
        ],
      ),
    );
    await tester.tap(find.text('Respond').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss without answering'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Respond').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline').last);
    await tester.pumpAndSettle();
    expect(calls.log, ['cancel:s:form', 'decline:s:other']);
  });

  testWidgets('URL consent shows warnings and opens only after accepting', (
    tester,
  ) async {
    final calls = _Calls();
    const url = 'http://login.xn--pple-43d.com/oauth?state=1';
    await tester.pumpWidget(_host(calls, items: [_url(url)]));
    await tester.tap(find.text('Review link'));
    await tester.pumpAndSettle();

    expect(find.text('Open a page for Claude Code?'), findsOneWidget);
    expect(find.text(url, findRichText: true), findsOneWidget);
    expect(find.textContaining('Not encrypted'), findsOneWidget);
    expect(find.textContaining('Punycode'), findsOneWidget);
    final open = find.widgetWithText(FilledButton, 'Open in browser');
    expect(tester.widget<FilledButton>(open).onPressed, isNull);

    await tester.tap(find.text('I checked the address and want to open it'));
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(calls.log, ['accept:s:url', 'open']);
    expect(calls.accepted.single.$2, isNull);
    expect(calls.opened.single, Uri.parse(url));
  });

  testWidgets('non-web URLs can only be declined', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_host(calls, items: [_url('javascript:alert(1)')]));
    await tester.tap(find.text('Review link'));
    await tester.pumpAndSettle();
    expect(find.textContaining('only opens web links'), findsOneWidget);
    final open = find.widgetWithText(FilledButton, 'Open in browser');
    expect(tester.widget<FilledButton>(open).onPressed, isNull);
    await tester.tap(find.text('Decline').last);
    await tester.pumpAndSettle();
    expect(calls.log, ['decline:s:url']);
  });

  testWidgets('an agent-withdrawn request closes its sheet unanswered', (
    tester,
  ) async {
    final calls = _Calls();
    await tester.pumpWidget(_host(calls, items: [_form()]));
    await tester.tap(find.text('Respond'));
    await tester.pumpAndSettle();
    expect(find.text('Submit'), findsOneWidget);

    await tester.pumpWidget(_host(calls, items: const []));
    await tester.pumpAndSettle();
    expect(find.text('Submit'), findsNothing);
    expect(calls.log, isEmpty);
  });

  testWidgets('submit checks patterns off the UI isolate', (tester) async {
    final calls = _Calls();
    final slug = _item('s:slug', {
      'sessionId': 's',
      'mode': 'form',
      'message': 'Name the branch',
      'requestedSchema': {
        'type': 'object',
        'properties': {
          'slug': {'type': 'string', 'title': 'Slug', 'pattern': r'^[a-z-]+$'},
        },
        'required': ['slug'],
      },
    });
    await tester.pumpWidget(_host(calls, items: [slug]));
    await tester.tap(find.text('Respond'));
    await tester.pumpAndSettle();

    Future<void> submit(String value) async {
      await tester.enterText(find.byType(TextFormField), value);
      await tester.tap(find.text('Submit'));
      // The pattern runs in a worker isolate, which needs real time.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
    }

    await submit('Not A Slug');
    expect(find.text('Does not match the expected format'), findsOneWidget);
    expect(calls.log, isEmpty);

    await submit('fix-payments');
    expect(calls.log, ['accept:s:slug']);
    expect(calls.accepted.single.$2, {'slug': 'fix-payments'});
  });

  testWidgets('withdrawal closes the sheet even with a date picker open', (
    tester,
  ) async {
    final calls = _Calls();
    final dated = _item('s:dated', {
      'sessionId': 's',
      'mode': 'form',
      'message': 'When should it run?',
      'requestedSchema': {
        'type': 'object',
        'properties': {
          'day': {'type': 'string', 'title': 'Day', 'format': 'date'},
        },
      },
    });
    await tester.pumpWidget(_host(calls, items: [dated]));
    await tester.tap(find.text('Respond'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pick a date'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    await tester.pumpWidget(_host(calls, items: const []));
    await tester.pumpAndSettle();
    // The picker on top of the sheet must not absorb the withdrawal.
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Submit'), findsNothing);
    expect(calls.log, isEmpty);
  });

  testWidgets('edge-case schemas open without breaking field preconditions', (
    tester,
  ) async {
    final calls = _Calls();
    final edgy = _item('s:edgy', {
      'sessionId': 's',
      'mode': 'form',
      'message': 'Edge cases',
      'requestedSchema': {
        'type': 'object',
        'properties': {
          'day': {
            'type': 'string',
            'title': 'Day',
            'format': 'date',
            'default': '1800-01-01',
          },
          'blank': {'type': 'string', 'title': 'Blank', 'maxLength': 0},
        },
      },
    });
    await tester.pumpWidget(_host(calls, items: [edgy]));
    await tester.tap(find.text('Respond'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // A field limited to zero characters accepts no input.
    final blank = find.byType(TextFormField).last;
    await tester.ensureVisible(blank);
    await tester.enterText(blank, 'x');
    await tester.pump();
    expect(tester.widget<TextFormField>(blank).controller!.text, isEmpty);

    // A default before the calendar's range opens at its first date and
    // leaves the entered value alone.
    await tester.tap(find.byTooltip('Pick a date'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(
      tester
          .widget<DatePickerDialog>(find.byType(DatePickerDialog))
          .initialDate,
      DateTime(1900),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('1800-01-01'), findsOneWidget);
  });

  testWidgets('an awaiting URL can be reopened or dismissed', (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(
      _host(
        calls,
        items: const [],
        awaiting: [
          AcpAwaitingElicitation(
            elicitationId: 'oauth-1',
            url: 'https://auth.example.com/x',
            acceptedAt: DateTime(2026),
          ),
        ],
      ),
    );
    expect(find.text('Continue in browser'), findsOneWidget);
    expect(find.text('auth.example.com'), findsOneWidget);
    await tester.tap(find.text('Reopen'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop waiting'));
    await tester.pump();
    expect(calls.log, ['open', 'stop:oauth-1']);
    expect(calls.opened.single, Uri.parse('https://auth.example.com/x'));
  });
}
