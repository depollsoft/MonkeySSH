// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/app_link.dart';
import 'package:monkeyssh/domain/services/app_link_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/app_links_service');
  late RecordingDiagnosticsLogger diagnostics;
  late AppLinkService service;
  late List<String?> platformLinks;
  late int consumeCalls;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> sendFromPlatform(String method) async {
    await messenger().handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  setUp(() {
    diagnostics = RecordingDiagnosticsLogger();
    service = AppLinkService(channel: channel, diagnostics: diagnostics);
    platformLinks = [];
    consumeCalls = 0;
    messenger().setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'consumePendingLink') return null;
      consumeCalls++;
      return platformLinks.isEmpty ? null : platformLinks.removeAt(0);
    });
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(channel, null);
    service.dispose();
  });

  test('receive queues the newest link and notifies listeners', () {
    var notifications = 0;
    service
      ..addListener(() => notifications++)
      ..receive(Uri.parse('monkeyssh://open?host=1'))
      ..receive(Uri.parse('monkeyssh://open?host=2'));

    expect(notifications, 2);
    expect(service.takePending(), const OpenHostAppLink(hostId: 2));
    expect(service.takePending(), isNull);
    expect(service.hasPending, isFalse);
  });

  test('attaching pulls the link that launched the app', () async {
    platformLinks.add('monkeyssh://chat?host=4&session=abc');

    service.attachPlatformChannel();
    await pumpEventQueue();

    expect(consumeCalls, 1);
    expect(
      service.takePending(),
      const OpenChatAppLink(hostId: 4, sessionId: 'abc'),
    );
  });

  test('linkAvailable pulls a link delivered while running', () async {
    service.attachPlatformChannel();
    await pumpEventQueue();
    expect(service.hasPending, isFalse);

    platformLinks.add('ssh://deploy@example.com');
    await sendFromPlatform('linkAvailable');
    await pumpEventQueue();

    expect(
      service.takePending(),
      const SshHostAppLink(hostname: 'example.com', username: 'deploy'),
    );
  });

  test('a link is delivered once however pulls interleave', () async {
    platformLinks.add('monkeyssh://open?host=5');
    var notifications = 0;
    service
      ..addListener(() => notifications++)
      ..attachPlatformChannel();
    await sendFromPlatform('linkAvailable');
    await pumpEventQueue();

    expect(consumeCalls, 2);
    expect(notifications, 1);
  });

  test('attaching twice registers once', () async {
    service
      ..attachPlatformChannel()
      ..attachPlatformChannel();
    await pumpEventQueue();

    expect(consumeCalls, 1);
  });

  test('a missing platform implementation is ignored', () async {
    final unhandled = AppLinkService(
      channel: const MethodChannel('test/app_links_unhandled'),
      diagnostics: diagnostics,
    );
    addTearDown(unhandled.dispose);

    unhandled.attachPlatformChannel();
    await pumpEventQueue();

    expect(unhandled.hasPending, isFalse);
  });

  test('over-long platform links are rejected without parsing', () {
    service.receiveString(
      'monkeyssh://open?host=1&pad=${'x' * maxAppLinkLength}',
    );

    expect(
      service.takePending(),
      const RejectedAppLink(AppLinkRejection.tooLong),
    );
  });

  test('diagnostics never include link content', () {
    service
      ..receive(Uri.parse('ssh://alice@private.example.com'))
      ..receive(Uri.parse('ssh://alice:hunter2@private.example.com'))
      ..receive(Uri.parse('monkeyssh://chat?host=1&session=secret-session'));

    expect(diagnostics.events, hasLength(3));
    for (final event in diagnostics.events) {
      final text = event.searchableText;
      expect(text, isNot(contains('alice')));
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('private.example.com')));
      expect(text, isNot(contains('secret-session')));
    }
    expect(diagnostics.events[1].fields['reason'], 'embeddedCredentials');
  });
}
