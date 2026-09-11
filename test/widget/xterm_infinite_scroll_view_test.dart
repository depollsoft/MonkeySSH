import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/infinite_scroll_view.dart';

void main() {
  testWidgets('scroll callbacks survive viewport position replacement', (
    tester,
  ) async {
    final offsets = <double>[];
    final key = GlobalKey();

    Future<void> build(ScrollPhysics physics) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(physics: physics),
          child: InfiniteScrollView(
            key: key,
            onScroll: offsets.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    await build(const ClampingScrollPhysics());
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final firstPosition = scrollable.position..jumpTo(12);
    expect(offsets.last, 12);

    await build(const BouncingScrollPhysics());
    final secondPosition = scrollable.position;
    expect(secondPosition, isNot(same(firstPosition)));
    offsets.clear();
    secondPosition.jumpTo(24);
    expect(offsets, [24]);

    await build(const ClampingScrollPhysics());
    final thirdPosition = scrollable.position;
    expect(thirdPosition, isNot(same(secondPosition)));
    offsets.clear();
    thirdPosition.jumpTo(-12);
    expect(offsets, [-12]);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
