import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/terminal_hyperlink_tracker.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalHyperlinkTracker', () {
    late Terminal terminal;
    late TerminalHyperlinkTracker tracker;

    setUp(() {
      terminal = Terminal(maxLines: 200);
      tracker = TerminalHyperlinkTracker()..attach(terminal);
      terminal.onPrivateOSC = tracker.handlePrivateOsc;
    });

    test('resolves OSC 8 links whose visible label is not a URL', () {
      terminal.write(
        [
          '\u001b]8;;https://github.com/orgs/community/discussions/1\u0007',
          'Community CLI docs',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'https://github.com/orgs/community/discussions/1',
      );
      expect(tracker.resolveLinkAt(const CellOffset(40, 0)), isNull);
    });

    test('reassembles OSC 8 destinations containing semicolons', () {
      terminal.write(
        [
          '\u001b]8;;https://example.com/docs;topic=tmux\u0007',
          'tmux docs',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(1, 0)),
        'https://example.com/docs;topic=tmux',
      );
    });

    test('renders a link whose introducer is preceded by a stray ESC', () {
      // A MonkeyMux replay could deliver the ESC that opens an OSC 8 sequence
      // and then have the live stream forward it a second time. The duplicated
      // ESC must not make the terminal print the introducer as text
      // (`]8;id=md-...;https://...`) instead of following the hyperlink.
      const url = 'https://github.com/depollsoft/MonkeySSH/releases/tag/x';
      terminal.write(
        [
          'Seeded release: ',
          '\u001b\u001b]8;id=md-7nao1v;$url\u001b\\',
          url,
          '\u001b]8;;\u001b\\',
        ].join(),
      );

      final firstLine = terminal.buffer.lines[0].toString();
      expect(firstLine, startsWith('Seeded release: $url'));
      expect(firstLine, isNot(contains(']8;')));
      expect(tracker.resolveLinkAt(const CellOffset(20, 0)), url);
    });

    test('resolves OSC 8 links terminated with ST (ESC backslash)', () {
      terminal.write(
        [
          '\u001b]8;;https://example.com/st\u001b\\',
          'ST link',
          '\u001b]8;;\u001b\\',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'https://example.com/st',
      );
    });

    test('resolves OSC 8 links carrying an id= parameter', () {
      terminal.write(
        [
          '\u001b]8;id=42;https://example.com/with-id\u0007',
          'labeled',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'https://example.com/with-id',
      );
    });

    test('resolves OSC 8 file: links to the host path', () {
      terminal.write(
        [
          '\u001b]8;;file:///var/log/system.log\u0007',
          'system.log',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'file:///var/log/system.log',
      );
    });

    test('resolves an OSC 8 link whose label wraps across rows', () {
      terminal
        ..resize(10, terminal.viewHeight)
        ..write(
          [
            '\u001b]8;;https://example.com/wrapped\u0007',
            'abcdefghijklmno',
            '\u001b]8;;\u0007',
          ].join(),
        );

      expect(
        tracker.resolveLinkAt(const CellOffset(3, 0)),
        'https://example.com/wrapped',
      );
      expect(
        tracker.resolveLinkAt(const CellOffset(2, 1)),
        'https://example.com/wrapped',
      );
    });

    test('retains a TUI link when trailing cells are erased', () {
      const url = 'https://github.com';
      terminal.write(
        '\u001b[4;2H'
        '\u001b[4m'
        '\u001b]8;id=md-link;$url\u0007'
        'LINKTARGET'
        '\u001b[0m'
        '\u001b]8;;\u0007'
        '\u001b[K',
      );

      expect(tracker.trackedHyperlinkCount, 1);
      expect(tracker.resolveLinkAt(const CellOffset(1, 3)), url);
      expect(tracker.resolveLinkAt(const CellOffset(10, 3)), url);
      expect(tracker.resolveLinkAt(const CellOffset(11, 3)), isNull);
    });

    test('drops a TUI link when its rendered cells are erased', () {
      terminal
        ..write(
          '\u001b]8;;https://example.com/erased\u0007'
          'link'
          '\u001b]8;;\u0007',
        )
        ..write('\r\u001b[K');

      expect(tracker.resolveLinkAt(const CellOffset(0, 0)), isNull);
      expect(tracker.trackedHyperlinkCount, 0);
    });

    test('tracks an OSC 8 link delivered across separate writes', () {
      terminal
        ..write('\u001b]8;;https://example.com/chunked\u0007')
        ..write('chunked label')
        ..write('\u001b]8;;\u0007');

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'https://example.com/chunked',
      );
    });

    test('tracks an OSC 8 open whose sequence is split mid-write', () {
      terminal
        ..write('\u001b]8;;https://exa')
        ..write('mple.com/split\u0007')
        ..write('label')
        ..write('\u001b]8;;\u0007');

      expect(
        tracker.resolveLinkAt(const CellOffset(2, 0)),
        'https://example.com/split',
      );
    });

    test('keeps hyperlink anchors valid after terminal reflow', () {
      terminal
        ..write(
          [
            '\u001b]8;;https://example.com/reflow\u0007',
            'abcdefghijkl',
            '\u001b]8;;\u0007',
          ].join(),
        )
        ..resize(6, terminal.viewHeight);

      expect(
        tracker.resolveLinkAt(const CellOffset(1, 1)),
        'https://example.com/reflow',
      );
      expect(
        tracker.resolveLinkAt(const CellOffset(5, 1)),
        'https://example.com/reflow',
      );
      expect(tracker.resolveLinkAt(const CellOffset(0, 2)), isNull);
    });

    test('prunes detached hyperlinks while processing later OSC 8 output', () {
      terminal = Terminal(maxLines: 200);
      tracker = TerminalHyperlinkTracker()..attach(terminal);
      terminal
        ..onPrivateOSC = tracker.handlePrivateOsc
        ..write(
          [
            '\u001b]8;;https://example.com/one\u0007',
            'one',
            '\u001b]8;;\u0007\n',
            for (var i = 0; i < 220; i++) 'filler $i\n',
          ].join(),
        );

      expect(tracker.trackedHyperlinkCount, 1);

      terminal.write(
        [
          '\u001b]8;;https://example.com/two\u0007',
          'two',
          '\u001b]8;;\u0007',
        ].join(),
      );

      expect(tracker.trackedHyperlinkCount, 1);
      String? resolvedLink;
      for (var y = 0; y <= terminal.buffer.absoluteCursorY; y++) {
        for (var x = 0; x < terminal.buffer.viewWidth; x++) {
          resolvedLink ??= tracker.resolveLinkAt(CellOffset(x, y));
        }
      }
      expect(resolvedLink, 'https://example.com/two');
    });

    test('keeps closed links scoped to their terminal buffer', () {
      terminal
        ..write('\x1b]8;;https://example.com/main\x07main\x1b]8;;\x07')
        ..write('\x1b[?1049halternate');

      expect(tracker.resolveLinkAt(const CellOffset(1, 0)), isNull);
      expect(tracker.resolveLinkOnRow(0), isNull);
      expect(tracker.hasLinkInRowRange(0, 0, 10), isFalse);

      terminal.write('\r\x1b]8;;https://example.com/alt\x07alt\x1b]8;;\x07');
      expect(
        tracker.resolveLinkAt(const CellOffset(1, 0)),
        'https://example.com/alt',
      );
      terminal.write('\x1b[?1049l');
      expect(
        tracker.resolveLinkAt(const CellOffset(1, 0)),
        'https://example.com/main',
      );
      expect(tracker.resolveLinkOnRow(0), 'https://example.com/main');
    });

    test('does not resolve pending links in a different buffer', () {
      terminal
        ..write('\x1b]8;;https://example.com/main\x07main')
        ..write('\x1b[?1049halternate');

      expect(tracker.resolveLinkAt(const CellOffset(1, 0)), isNull);
      expect(tracker.resolveLinkOnRow(0), isNull);
      expect(tracker.hasLinkInRowRange(0, 0, 10), isFalse);

      terminal.write('\x1b]8;;\x07\x1b[?1049l');
      expect(
        tracker.resolveLinkAt(const CellOffset(1, 0)),
        'https://example.com/main',
      );
      expect(tracker.resolveLinkAt(const CellOffset(5, 0)), isNull);
    });

    test('does not resolve an open link before any label is written', () {
      terminal.write('prefix\x1b]8;;https://example.com/empty\x07');

      expect(tracker.resolveLinkAt(const CellOffset(6, 0)), isNull);
      expect(tracker.resolveLinkOnRow(0), isNull);
      expect(tracker.hasLinkInRowRange(0, 0, 20), isFalse);
    });

    test('pending row fallback excludes the cursor-only next row', () {
      terminal.write('\x1b]8;;https://example.com/main\x07main\r\n');

      expect(tracker.resolveLinkOnRow(0), 'https://example.com/main');
      expect(tracker.resolveLinkOnRow(1), isNull);
      expect(tracker.hasLinkInRowRange(1, 0, 10), isFalse);
    });

    group('resolveLinkOnRow', () {
      test('resolves a row carrying a single hyperlink from any column', () {
        terminal.write(
          [
            'See PR ',
            '\u001b]8;;https://github.com/o/r/pull/587\u0007',
            '#587',
            '\u001b]8;;\u0007',
            ' for details',
          ].join(),
        );

        // A precise tap off the label does not resolve...
        expect(tracker.resolveLinkAt(const CellOffset(20, 0)), isNull);
        // ...but the row-level fallback opens the row's only hyperlink.
        expect(tracker.resolveLinkOnRow(0), 'https://github.com/o/r/pull/587');
      });

      test('resolves repeated links with the same destination', () {
        terminal.write(
          '\x1b]8;;https://example.com/a\x07A\x1b]8;;\x07 '
          '\x1b]8;;https://example.com/a\x07A again\x1b]8;;\x07',
        );

        expect(tracker.resolveLinkOnRow(0), 'https://example.com/a');
      });

      test('stays ambiguous when a row carries multiple destinations', () {
        terminal.write(
          [
            '\u001b]8;;https://example.com/a\u0007',
            'A',
            '\u001b]8;;\u0007',
            ' and ',
            '\u001b]8;;https://example.com/b\u0007',
            'B',
            '\u001b]8;;\u0007',
          ].join(),
        );

        expect(tracker.resolveLinkOnRow(0), isNull);
      });

      test('returns null for rows without any hyperlink', () {
        terminal.write(
          [
            '\u001b]8;;https://example.com/a\u0007',
            'A',
            '\u001b]8;;\u0007',
          ].join(),
        );

        expect(tracker.resolveLinkOnRow(5), isNull);
      });
    });

    group('hasLinkInRowRange', () {
      setUp(() {
        // `#587` occupies columns 7-10 ("See PR " is 7 characters).
        terminal.write(
          [
            'See PR ',
            '\u001b]8;;https://github.com/o/r/pull/587\u0007',
            '#587',
            '\u001b]8;;\u0007',
            ' done',
          ].join(),
        );
      });

      test('reports overlap with the hyperlink columns', () {
        expect(tracker.hasLinkInRowRange(0, 7, 10), isTrue);
        expect(tracker.hasLinkInRowRange(0, 5, 8), isTrue);
        expect(tracker.hasLinkInRowRange(0, 10, 14), isTrue);
      });

      test('reports no overlap before or after the hyperlink', () {
        expect(tracker.hasLinkInRowRange(0, 0, 6), isFalse);
        expect(tracker.hasLinkInRowRange(0, 11, 20), isFalse);
      });

      test('does not match a different row', () {
        expect(tracker.hasLinkInRowRange(1, 7, 10), isFalse);
      });
    });

    group('retained-link cap / LRU eviction', () {
      test('caps retained hyperlinks at maxRetainedLinks', () {
        const cap = 3;
        final cappedTracker = TerminalHyperlinkTracker(maxRetainedLinks: cap)
          ..attach(terminal);
        terminal.onPrivateOSC = cappedTracker.handlePrivateOsc;

        for (var i = 0; i < cap + 2; i++) {
          terminal.write(
            '\u001b]8;;https://example.com/$i\u0007'
            'L$i'
            '\u001b]8;;\u0007\n',
          );
        }

        expect(cappedTracker.trackedHyperlinkCount, cap);
      });

      test('oldest links are evicted; newest remain resolvable', () {
        const cap = 2;
        final cappedTracker = TerminalHyperlinkTracker(maxRetainedLinks: cap)
          ..attach(terminal);
        terminal
          ..onPrivateOSC = cappedTracker.handlePrivateOsc
          // Write 3 single-character links on rows 0, 1, 2.
          // Use \r\n (CR+LF) so each link starts at column 0.
          ..write(
            '\u001b]8;;https://a.example.com\u0007A\u001b]8;;\u0007\r\n'
            '\u001b]8;;https://b.example.com\u0007B\u001b]8;;\u0007\r\n'
            '\u001b]8;;https://c.example.com\u0007C\u001b]8;;\u0007\r\n',
          );

        expect(cappedTracker.trackedHyperlinkCount, cap);

        // Link A (oldest) must have been evicted.
        expect(cappedTracker.resolveLinkAt(const CellOffset(0, 0)), isNull);

        // Links B and C (the two most-recent) must still resolve.
        expect(
          cappedTracker.resolveLinkAt(const CellOffset(0, 1)),
          'https://b.example.com',
        );
        expect(
          cappedTracker.resolveLinkAt(const CellOffset(0, 2)),
          'https://c.example.com',
        );
      });

      test('eviction at cap=0 stores no links', () {
        final zeroTracker = TerminalHyperlinkTracker(maxRetainedLinks: 0)
          ..attach(terminal);
        terminal
          ..onPrivateOSC = zeroTracker.handlePrivateOsc
          ..write('\u001b]8;;https://example.com\u0007link\u001b]8;;\u0007');

        expect(zeroTracker.trackedHyperlinkCount, 0);
        expect(zeroTracker.resolveLinkAt(const CellOffset(0, 0)), isNull);
      });
    });

    group('attach / reattach semantics', () {
      test('reattaching to the same terminal preserves tracked hyperlinks', () {
        terminal.write(
          '\u001b]8;;https://example.com/reattach\u0007link\u001b]8;;\u0007\n',
        );

        expect(tracker.trackedHyperlinkCount, 1);
        tracker.attach(terminal); // reattach same terminal
        expect(tracker.trackedHyperlinkCount, 1);

        expect(
          tracker.resolveLinkAt(const CellOffset(0, 0)),
          'https://example.com/reattach',
        );
      });

      test('attaching to a different terminal clears tracked hyperlinks', () {
        terminal.write(
          '\u001b]8;;https://example.com/clear\u0007link\u001b]8;;\u0007\n',
        );

        expect(tracker.trackedHyperlinkCount, 1);

        final newTerminal = Terminal(maxLines: 200);
        tracker.attach(newTerminal);

        expect(tracker.trackedHyperlinkCount, 0);
        // The link from the old terminal must not resolve on the new terminal.
        expect(tracker.resolveLinkAt(const CellOffset(0, 0)), isNull);
      });

      test(
        'reattaching to same terminal preserves pending hyperlink in progress',
        () {
          // Open an OSC 8 but do not close it yet.
          terminal.write('\u001b]8;;https://example.com/pending\u0007partial');

          tracker.attach(terminal); // same terminal – should be a no-op
          // Closing the link after reattach must still work.
          terminal.write('\u001b]8;;\u0007');

          expect(tracker.trackedHyperlinkCount, 1);
          expect(
            tracker.resolveLinkAt(const CellOffset(0, 0)),
            'https://example.com/pending',
          );
        },
      );
    });
  });
}
