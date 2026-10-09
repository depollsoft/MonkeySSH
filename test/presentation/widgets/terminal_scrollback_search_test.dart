import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_scrollback_search.dart';
import 'package:xterm/xterm.dart';

TerminalScrollbackSearchController _search(
  Terminal terminal, {
  int? Function()? anchorRow,
  int maxMatches = 5000,
}) => TerminalScrollbackSearchController(
  terminal: terminal,
  anchorRow: anchorRow,
  typingDebounce: Duration.zero,
  refreshDelay: const Duration(milliseconds: 10),
  maxMatches: maxMatches,
);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the search');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> _settle(TerminalScrollbackSearchController search) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await _until(() => search.status != TerminalSearchStatus.searching);
}

void main() {
  group('TerminalScrollbackSearchController', () {
    test('highlights a match on every soft-wrapped row it covers', () async {
      final terminal = Terminal()
        ..resize(10, 4)
        ..write('1234567hello world');
      final search = _search(terminal)..setQuery('hello');
      addTearDown(search.dispose);
      await _settle(search);

      expect(search.matchCount, 1);
      expect(search.currentIndex, 0);
      final rows = terminal.buffer.lines;
      expect(search.hitsForRow(rows[0]), [
        (startColumn: 7, endColumn: 10, isCurrent: true),
      ]);
      expect(search.hitsForRow(rows[1]), [
        (startColumn: 0, endColumn: 2, isCurrent: true),
      ]);
      expect(search.hitsForRow(rows[2]), isEmpty);
    });

    test('maps hits onto wide glyphs and skipped cells', () async {
      final terminal = Terminal()
        ..resize(20, 2)
        ..write('漢字\x1b[2Cneedle');
      final search = _search(terminal)..setQuery('字  ne');
      addTearDown(search.dispose);
      await _settle(search);

      expect(search.hitsForRow(terminal.buffer.lines[0]), [
        (startColumn: 2, endColumn: 8, isCurrent: true),
      ]);
    });

    test('case toggle and stepping with wrap-around', () async {
      final terminal = Terminal()
        ..resize(20, 6)
        ..write('Alpha\r\nalpha\r\nbeta\r\nALPHA');
      final search = _search(terminal)..setQuery('alpha');
      addTearDown(search.dispose);
      await _settle(search);

      expect(search.matchCount, 3);
      // Without a viewport anchor the search starts from the newest match.
      expect(search.currentIndex, 2);
      expect(search.currentMatchRow, 3);
      final reveal = search.revealRequest;

      search.showNext();
      expect(search.currentIndex, 0);
      search.showPrevious();
      expect(search.currentIndex, 2);
      search.showPrevious();
      expect(search.currentIndex, 1);
      expect(search.currentMatchRow, 1);
      expect(search.revealRequest, reveal + 3);

      search.setCaseSensitive(value: true);
      await _settle(search);
      expect(search.matchCount, 1);
      expect(search.currentMatchRow, 1);
    });

    test('starts from the last match at or above the viewport', () async {
      final terminal = Terminal()..resize(20, 4);
      for (var row = 0; row < 30; row++) {
        terminal.write(row.isEven ? 'match $row\r\n' : 'other $row\r\n');
      }
      final search = _search(terminal, anchorRow: () => 13)..setQuery('match');
      addTearDown(search.dispose);
      await _settle(search);

      expect(search.currentMatchRow, 12);
    });

    test('evicted rows stop painting and leave the results', () async {
      final terminal = Terminal(maxLines: 32)
        ..resize(20, 4)
        ..write('needle first\r\n');
      for (var row = 0; row < 25; row++) {
        terminal.write('filler $row\r\n');
      }
      terminal.write('needle second\r\n');
      final search = _search(terminal)..setQuery('needle');
      addTearDown(search.dispose);
      await _settle(search);
      expect(search.matchCount, 2);
      final firstRow = search.matches.first.startRow;
      expect(search.hitsForRow(firstRow), hasLength(1));

      for (var row = 0; row < 10; row++) {
        terminal.write('more $row\r\n');
      }
      expect(firstRow.attached, isFalse);
      // Stepping skips the evicted match even before the refresh lands.
      search
        ..showNext()
        ..showNext();
      expect(search.matches[search.currentIndex!].startRow.attached, isTrue);

      await _until(() => search.matchCount == 1);
      expect(search.currentMatchRow, isNotNull);
    });

    test(
      'new output refreshes the count and keeps the current match',
      () async {
        final terminal = Terminal()
          ..resize(30, 6)
          ..write('error one\r\nerror two\r\n');
        final search = _search(terminal)..setQuery('error');
        addTearDown(search.dispose);
        await _settle(search);
        search.showPrevious();
        expect(search.currentIndex, 0);
        final reveal = search.revealRequest;

        terminal.write('error three\r\n');
        await _until(() => search.matchCount == 3);

        expect(search.currentIndex, 0);
        expect(search.revealRequest, reveal);
      },
    );

    test('a row that changed after the search paints nothing', () async {
      final terminal = Terminal()
        ..resize(20, 3)
        ..write('find me');
      final search = _search(terminal)..setQuery('find');
      addTearDown(search.dispose);
      await _settle(search);
      final row = terminal.buffer.lines[0];
      expect(search.hitsForRow(row), hasLength(1));

      terminal.write('\r\x1b[2Kreplaced');
      expect(search.hitsForRow(row), isEmpty);
    });

    test('the alternate screen searches only the screen', () async {
      final terminal = Terminal()
        ..resize(20, 3)
        ..write('needle in history\r\nmore\r\nmore\r\nmore\r\n');
      final search = _search(terminal)..setQuery('needle');
      addTearDown(search.dispose);
      await _settle(search);
      expect(search.matchCount, 1);
      expect(search.searchesAlternateScreen, isFalse);

      terminal.write('\x1b[?1049h\x1b[Hno match on screen');
      await _until(() => search.searchesAlternateScreen);
      await _settle(search);
      expect(search.matchCount, 0);

      terminal.write('\x1b[?1049l');
      await _until(() => !search.searchesAlternateScreen);
      await _settle(search);
      expect(search.matchCount, 1);
    });

    test('reports invalid and capped searches', () async {
      final terminal = Terminal()
        ..resize(20, 3)
        ..write('aaaaaa');
      final search = _search(terminal, maxMatches: 3)
        ..setRegex(value: true)
        ..setQuery('a(');
      addTearDown(search.dispose);
      await _settle(search);
      expect(search.status, TerminalSearchStatus.invalidPattern);
      expect(search.matchCount, 0);

      search.setQuery('a');
      await _settle(search);
      expect(search.status, TerminalSearchStatus.ready);
      expect(search.matchCount, 3);
      expect(search.isCapped, isTrue);

      search.setQuery('');
      await _settle(search);
      expect(search.status, TerminalSearchStatus.idle);
      expect(search.currentIndex, isNull);
    });
  });

  group('resolveTerminalSearchRevealOffset', () {
    test('leaves a visible row alone', () {
      expect(
        resolveTerminalSearchRevealOffset(
          row: 12,
          lineHeight: 10,
          viewportExtent: 200,
          currentOffset: 100,
          minScrollExtent: 0,
          maxScrollExtent: 1000,
          obscuredBottom: 50,
        ),
        isNull,
      );
    });

    test('brings a hidden row to a third of the way down', () {
      // Row 25 (250-260) sits under the search bar, which covers 250-300.
      expect(
        resolveTerminalSearchRevealOffset(
          row: 25,
          lineHeight: 10,
          viewportExtent: 200,
          currentOffset: 100,
          minScrollExtent: 0,
          maxScrollExtent: 1000,
          obscuredBottom: 50,
        ),
        200,
      );
      expect(
        resolveTerminalSearchRevealOffset(
          row: 2,
          lineHeight: 10,
          viewportExtent: 200,
          currentOffset: 100,
          minScrollExtent: 0,
          maxScrollExtent: 1000,
        ),
        0,
      );
    });
  });
}
