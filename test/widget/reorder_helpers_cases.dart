// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/presentation/widgets/reorder_helpers.dart';

/// Registers tests from reorder_helpers_test.dart.
void registerWidgetReorderHelpersTests() {
  group('reorder_helpers', () {
    group('reorderVisibleIdsInFullOrder', () {
      test('keeps hidden ids in place while reordering visible items', () {
        final reordered = reorderVisibleIdsInFullOrder(
          allIds: const [1, 2, 3, 4, 5],
          visibleIds: const [1, 3, 5],
          oldIndex: 0,
          newIndex: 2,
        );

        expect(reordered, [3, 2, 5, 4, 1]);
      });

      test('supports moving an item to the end of the visible list', () {
        final reordered = reorderVisibleIdsInFullOrder(
          allIds: const [10, 11, 12],
          visibleIds: const [10, 11, 12],
          oldIndex: 0,
          newIndex: 2,
        );

        expect(reordered, [11, 12, 10]);
      });

      test(
        'returns the original order when fewer than two visible ids exist',
        () {
          expect(
            reorderVisibleIdsInFullOrder(
              allIds: const [1, 2, 3],
              visibleIds: const [],
              oldIndex: 0,
              newIndex: 0,
            ),
            [1, 2, 3],
          );
          expect(
            reorderVisibleIdsInFullOrder(
              allIds: const [1, 2, 3],
              visibleIds: const [2],
              oldIndex: 0,
              newIndex: 1,
            ),
            [1, 2, 3],
          );
        },
      );

      test(
        'supports moving a visible item earlier with hidden ids between',
        () {
          final reordered = reorderVisibleIdsInFullOrder(
            allIds: const [1, 2, 3, 4, 5, 6],
            visibleIds: const [2, 4, 6],
            oldIndex: 2,
            newIndex: 0,
          );

          expect(reordered, [1, 6, 3, 2, 5, 4]);
        },
      );
    });
  });
}
