import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/utils/byte_consumer.dart';

List<int> _drain(ByteConsumer consumer) {
  final out = <int>[];
  while (consumer.isNotEmpty) {
    out.add(consumer.consume());
  }
  return out;
}

void registerByteConsumerTests() {
  group('ByteConsumer.add', () {
    test('ASCII bytes are consumed as their code points', () {
      final consumer = ByteConsumer()..add('hello');
      expect(consumer.length, 5);
      expect(_drain(consumer), 'hello'.runes.toList());
    });

    test('matches String.runes for non-BMP code points (emoji)', () {
      const text = 'a🎉b👨‍👩‍👧c'; // mixes BMP, astral and ZWJ sequences
      final consumer = ByteConsumer()..add(text);
      final expected = text.runes.toList();
      expect(consumer.length, expected.length);
      expect(_drain(consumer), expected);
    });

    test('combines a surrogate pair into a single code point', () {
      const rocket = '🚀'; // U+1F680, one rune, two UTF-16 code units
      final consumer = ByteConsumer()..add(rocket);
      expect(consumer.length, 1);
      expect(_drain(consumer), [0x1F680]);
    });

    test('preserves a lone (unpaired) high surrogate like String.runes', () {
      final lone = String.fromCharCode(0xD83D); // high surrogate, no low
      final consumer = ByteConsumer()..add(lone);
      expect(_drain(consumer), lone.runes.toList());
    });

    test('handles code points split across multiple add() calls', () {
      // The slice pump never splits a surrogate pair, but mixed sequential
      // adds must still decode each block correctly and report a stable length.
      final consumer = ByteConsumer()
        ..add('x')
        ..add('🚀')
        ..add('y');
      expect(consumer.length, 3);
      expect(_drain(consumer), ['x'.runeAt(0), 0x1F680, 'y'.runeAt(0)]);
    });
  });
}

extension on String {
  int runeAt(int index) => runes.elementAt(index);
}
