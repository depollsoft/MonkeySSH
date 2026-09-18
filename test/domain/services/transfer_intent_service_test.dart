// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const transferChannel = MethodChannel('xyz.depollsoft.monkeyssh/transfer');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transferChannel, null);
  });

  group('TransferIntentService', () {
    test(
      'returns null when the native transfer channel is unavailable',
      () async {
        final service = TransferIntentService();

        final payload = await service.consumeIncomingTransferPayload();

        expect(payload, isNull);
        await service.dispose();
      },
    );

    test(
      'returns the pending payload from the native transfer channel',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(transferChannel, (call) async {
              if (call.method == 'consumeIncomingTransferPayload') {
                return 'encoded-transfer-payload';
              }
              return null;
            });

        final service = TransferIntentService();

        final payload = await service.consumeIncomingTransferPayload();

        expect(payload, 'encoded-transfer-payload');
        await service.dispose();
      },
    );

    test('acknowledges native pending payload after event delivery', () async {
      var consumeCallCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transferChannel, (call) async {
            if (call.method == 'consumeIncomingTransferPayload') {
              consumeCallCount += 1;
            }
            return null;
          });

      final service = TransferIntentService();
      final firstPayload = service.incomingPayloads.first;

      final payloadMessage = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onIncomingTransferPayload', 'event-payload'),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(transferChannel.name, payloadMessage, (_) {});

      expect(await firstPayload, 'event-payload');
      await Future<void>.delayed(Duration.zero);
      expect(consumeCallCount, 1);
      await service.dispose();
    });

    test('ignores a pending payload that was already delivered over the live channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(transferChannel, (call) async {
            if (call.method == 'consumeIncomingTransferPayload') {
              return 'encoded-transfer-payload';
            }
            return null;
          });

      final service = TransferIntentService();
      final livePayloads = <String>[];
      final subscription = service.incomingPayloads.listen(livePayloads.add);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            transferChannel.name,
            transferChannel.codec.encodeMethodCall(
              const MethodCall(
                'onIncomingTransferPayload',
                'encoded-transfer-payload',
              ),
            ),
            null,
          );

      final payload = await service.consumeIncomingTransferPayload();

      expect(livePayloads, ['encoded-transfer-payload']);
      expect(payload, isNull);
      await subscription.cancel();
      await service.dispose();
    });
  });
}
