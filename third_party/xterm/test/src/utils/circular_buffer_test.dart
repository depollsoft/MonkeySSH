import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

class IndexedValue<T> with IndexedItem {
  T value;

  IndexedValue(this.value);

  @override
  int get hashCode => value.hashCode;

  @override
  bool operator ==(Object other) {
    if (other is IndexedValue) {
      return other.value == value;
    }
    if (other is T) {
      return other == value;
    }
    return false;
  }

  @override
  String toString() {
    return 'IndexedValue($value), index: ${attached ? index : null}}';
  }
}

extension ToIndexedValue<T> on T {
  IndexedValue<T> get indexed => IndexedValue(this);
}

void main() {
  group("IndexAwareCircularBuffer", () {
    test("normal creation test", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(1000);

      expect(cl, isNotNull);
      expect(cl.maxLength, 1000);
    });

    test("circle works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      expect(cl.maxLength, 10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );

      expect(cl.length, 10);
      expect(cl[0], 0.indexed);
      expect(cl[9], 9.indexed);

      cl.push(IndexedValue(10));

      expect(cl.length, 10);
      expect(cl[0], 1.indexed);
      expect(cl[9], 10.indexed);
    });

    // test("setting the length erases trail", () {
    //   final cl = CircularList<Box<int>>(10);
    //   cl.pushAll(List<int>.generate(10, (index) => index).map(Box.new));

    //   expect(cl.length, 10);
    //   expect(cl[0], 0.box);
    //   expect(cl[9], 9.box);

    //   cl.length = 5;

    //   expect(cl.length, 5);
    //   expect(cl[0], 0.box);
    //   expect(() => cl[5], throwsRangeError);
    // });

    test("foreach works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );

      final collectedItems = List<int>.empty(growable: true);

      cl.forEach((item) {
        collectedItems.add(item.value);
      });

      expect(collectedItems.length, 10);
      expect(collectedItems[0], 0);
      expect(collectedItems[9], 9);
    });

    test("index operator set works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );

      expect(cl.length, 10);
      expect(cl[5], 5.indexed);

      cl[5] = IndexedValue(50);

      expect(cl[5], 50.indexed);
    });

    test("clear works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl[5], 5.indexed);

      cl.clear();

      expect(cl.length, 0);
      expect(() => cl[5], throwsRangeError);
    });

    test("pop works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[9], 9.indexed);

      final val = cl.pop();

      expect(val, 9.indexed);
      expect(cl.length, 9);
      expect(() => cl[9], throwsRangeError);
      expect(cl[8], 8.indexed);
    });

    test("pop on empty throws", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      expect(() => cl.pop(), throwsA(anything));
    });

    test("remove one works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[5], 5.indexed);

      cl.remove(5);

      expect(cl.length, 9);
      expect(cl[5], 6.indexed);
    });

    test("remove multiple works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[5], 5.indexed);

      cl.remove(5, 3);

      expect(cl.length, 7);
      expect(cl[5], 8.indexed);
    });

    test("remove circle works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(15, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[0], 5.indexed);

      cl.remove(0, 9);

      expect(cl.length, 1);
      expect(cl[0], 14.indexed);
    });

    test("remove too much works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[5], 5.indexed);

      cl.remove(5, 10);

      expect(cl.length, 5);
      expect(cl[0], 0.indexed);
    });

    test("insert works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(5, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 5);
      expect(cl[0], 0.indexed);
      cl.insert(0, IndexedValue(100));

      expect(cl.length, 6);
      expect(cl[0], 100.indexed);
      expect(cl[1], 0.indexed);
    });

    test("insert circular works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[0], 0.indexed);
      expect(cl[1], 1.indexed);
      expect(cl[9], 9.indexed);

      cl.insert(1, IndexedValue(100));

      expect(cl.length, 10);
      expect(cl[0], 100.indexed); //circle leads to 100 moving one index down
      expect(cl[1], 1.indexed);
    });

    test("insert circular immediately remove works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[0], 0.indexed);
      expect(cl[1], 1.indexed);
      expect(cl[9], 9.indexed);

      cl.insert(0, IndexedValue(100));

      expect(cl.length, 10);
      expect(cl[0], 100.indexed);
      expect(cl[1], 0.indexed);
      expect(cl[9], 8.indexed);
    });

    test('swap rejects an out-of-range index', () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(2)
        ..push(IndexedValue(1));

      expect(() => cl.swap(-1, IndexedValue(2)), throwsRangeError);
      expect(() => cl.swap(1, IndexedValue(2)), throwsRangeError);
    });

    test("trim start updates item indices and detaches trimmed items", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      final items = List<IndexedValue<int>>.generate(
        10,
        (index) => IndexedValue(index),
      );
      cl.pushAll(items);
      expect(items[7].index, 7);

      cl.trimStart(5);

      // Surviving items report indices relative to the new front (matching
      // eviction via push), and trimmed items are detached.
      expect(items[5].index, 0);
      expect(items[7].index, 2);
      expect(items[9].index, 4);
      expect(items[0].attached, isFalse);
      expect(items[4].attached, isFalse);

      // Further pushes keep counting from the trimmed baseline.
      final next = IndexedValue(10);
      cl.push(next);
      expect(next.index, 5);
    });

    test("trim start works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[0], 0.indexed);
      expect(cl[1], 1.indexed);
      expect(cl[9], 9.indexed);

      cl.trimStart(5);

      expect(cl.length, 5);
      expect(cl[0], 5.indexed);
      expect(cl[1], 6.indexed);
      expect(cl[4], 9.indexed);
    });

    test("trim start with more than length works", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      expect(cl.length, 10);
      expect(cl[0], 0.indexed);
      expect(cl[1], 1.indexed);
      expect(cl[9], 9.indexed);

      cl.trimStart(15);

      expect(cl.length, 0);
    });

    test("replaceWith rebuilds from index zero after trimStart", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(10);
      cl.pushAll(
        List<int>.generate(10, (index) => index).map(IndexedValue.new),
      );
      cl.trimStart(5);

      final replacement = List<int>.generate(
        5,
        (index) => 100 + index,
      ).map(IndexedValue.new).toList();
      cl.replaceWith(replacement);

      expect(cl.length, 5);
      expect(cl[0], 100.indexed);
      expect(cl[4], 104.indexed);
      expect(replacement[0].index, 0);
      expect(replacement[4].index, 4);
    });

    test('can track index of items', () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(3);
      final item0 = IndexedValue(0);
      final item1 = IndexedValue(1);
      final item2 = IndexedValue(2);

      cl.pushAll([item0, item1, item2]);

      expect(item0.index, 0);
      expect(item1.index, 1);
      expect(item2.index, 2);

      final item3 = IndexedValue(3);
      cl.push(item3);

      expect(item0.attached, false);
      expect(item1.index, 0);
      expect(item2.index, 1);
      expect(item3.index, 2);

      final item11 = IndexedValue(4);
      cl.insert(1, item11);

      expect(item0.attached, false);
      expect(item1.attached, false);
      expect(item11.index, 0);
      expect(item2.index, 1);
      expect(item3.index, 2);

      cl.remove(0, 2);

      expect(item11.attached, false);
      expect(item2.attached, false);
      expect(item3.index, 0);
    });

    test("reassignRange keeps reused items attached and re-indexed", () {
      final cl = IndexAwareCircularBuffer<IndexedValue<int>>(4);
      final a = IndexedValue(0);
      final b = IndexedValue(1);
      final c = IndexedValue(2);
      final d = IndexedValue(3);
      cl.pushAll([a, b, c, d]);

      // Scroll the whole region up by one: [a,b,c,d] -> [b,c,d,e]. This mirrors
      // Buffer.scrollUp and used to orphan the shifted items (b,c,d) because the
      // same object was transiently referenced by two slots.
      final e = IndexedValue(4);
      cl.reassignRange(0, [b, c, d, e]);

      expect(cl[0], b);
      expect(cl[1], c);
      expect(cl[2], d);
      expect(cl[3], e);

      // The crucial guarantee: shifted items stay attached so anchors pointing
      // at them remain valid.
      expect(b.attached, isTrue);
      expect(c.attached, isTrue);
      expect(d.attached, isTrue);
      expect(e.attached, isTrue);
      expect(b.index, 0);
      expect(c.index, 1);
      expect(d.index, 2);
      expect(e.index, 3);

      // The item that scrolled out is detached.
      expect(a.attached, isFalse);
    });
  });
}
