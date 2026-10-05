// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

const _absolutePath = '/var/log/app.log';
const _tildePath = '~/.ssh/config';
const _relativePath = 'lib/presentation/terminal_screen.dart';
const _branchLikePath = 'feature/sftp-browser';

class _TerminalPathLinkHarness extends StatefulWidget {
  const _TerminalPathLinkHarness({
    required this.touchScrollToTerminal,
    super.key,
  });

  final bool touchScrollToTerminal;

  @override
  State<_TerminalPathLinkHarness> createState() =>
      _TerminalPathLinkHarnessState();
}

class _TerminalPathLinkHarnessState extends State<_TerminalPathLinkHarness> {
  final _terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
  final _openedLinks = ValueNotifier<List<String>>(<String>[]);
  final _verifiedRelativePaths = <String>{_relativePath};
  late final Terminal _terminal;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 200)
      ..write('Absolute $_absolutePath\r\n')
      ..write('Tilde $_tildePath\r\n')
      ..write('Relative $_relativePath\r\n')
      ..write('Ignore $_branchLikePath\r\n');
  }

  @override
  void dispose() {
    _openedLinks.dispose();
    super.dispose();
  }

  Offset? tapOffsetFor(String needle) {
    for (var row = 0; row < 4; row++) {
      final lineText = trimTerminalLinePadding(
        _terminal.buffer.lines[row].getText(0, _terminal.buffer.viewWidth),
      );
      final startColumn = lineText.indexOf(needle);
      if (startColumn == -1) {
        continue;
      }

      final terminalViewState = _terminalViewKey.currentState;
      if (terminalViewState == null) {
        return null;
      }
      final renderTerminal = terminalViewState.renderTerminal;
      final tapColumn = _firstResolvableColumn(
        row: row,
        startColumn: startColumn,
        length: needle.length,
      );
      if (tapColumn == null) {
        return null;
      }
      final cellOffset = CellOffset(tapColumn, row);
      final localOffset =
          renderTerminal.getOffset(cellOffset) +
          renderTerminal.cellSize.center(Offset.zero);
      return renderTerminal.localToGlobal(localOffset);
    }
    return null;
  }

  String? _resolveLinkTap(CellOffset offset) {
    for (final candidateOffset in resolveForgivingTerminalTapOffsets(offset)) {
      final nearbyHit = _resolveLinkTapAtCell(candidateOffset);
      if (nearbyHit != null) {
        return nearbyHit;
      }
    }

    final rowFallback = _resolveSingleLinkTapOnRow(offset.y);
    if (rowFallback != null) {
      return rowFallback;
    }

    return null;
  }

  String? _resolveLinkTapAtCell(CellOffset offset) {
    final row = offset.y.clamp(0, _terminal.buffer.height - 1);
    final lineText = trimTerminalLinePadding(
      _terminal.buffer.lines[row].getText(0, _terminal.buffer.viewWidth),
    );
    if (lineText.isEmpty) {
      return null;
    }

    final textOffset = offset.x.clamp(0, lineText.length);
    final path =
        detectTerminalFilePathMatches(
              normalizeTerminalFilePathDetectionText(lineText),
            )
            .where(
              (match) =>
                  textOffset >= match.start && textOffset < match.hitTestEnd,
            )
            .firstOrNull
            ?.path;
    if (path == null) {
      return null;
    }

    return shouldActivateTerminalFilePath(
          path,
          hasVerifiedPath: _verifiedRelativePaths.contains(path),
        )
        ? path
        : null;
  }

  int? _firstResolvableColumn({
    required int row,
    required int startColumn,
    required int length,
  }) {
    final endColumn = startColumn + length;
    for (var column = startColumn; column < endColumn; column++) {
      if (_resolveLinkTapAtCell(CellOffset(column, row)) != null) {
        return column;
      }
    }
    return null;
  }

  String? _resolveSingleLinkTapOnRow(int row) {
    final clampedRow = row.clamp(0, _terminal.buffer.height - 1);
    String? matchedPath;
    for (var column = 0; column < _terminal.buffer.viewWidth; column++) {
      final path = _resolveLinkTapAtCell(CellOffset(column, clampedRow));
      if (path == null) {
        continue;
      }
      if (matchedPath == null || matchedPath == path) {
        matchedPath = path;
        continue;
      }
      return null;
    }
    return matchedPath;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 430,
          height: 280,
          child: MonkeyTerminalView(
            key: _terminalViewKey,
            _terminal,
            hardwareKeyboardOnly: true,
            touchScrollToTerminal: widget.touchScrollToTerminal,
            resolveLinkTap: (offset) =>
                shouldResolveTerminalTapLinks(
                  showsNativeSelectionOverlay: false,
                )
                ? _resolveLinkTap(offset)
                : null,
            onLinkTap: (link) {
              _openedLinks.value = [..._openedLinks.value, link];
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpHarness(
  WidgetTester tester,
  GlobalKey<_TerminalPathLinkHarnessState> harnessKey, {
  required bool touchScrollToTerminal,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _TerminalPathLinkHarness(
      key: harnessKey,
      touchScrollToTerminal: touchScrollToTerminal,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final touchScrollToTerminal in <bool>[false, true]) {
    group(
      'terminal path links (touchScrollToTerminal=$touchScrollToTerminal)',
      () {
        testWidgets('opens explicit and conservative relative paths on tap', (
          tester,
        ) async {
          final harnessKey = GlobalKey<_TerminalPathLinkHarnessState>();
          await _pumpHarness(
            tester,
            harnessKey,
            touchScrollToTerminal: touchScrollToTerminal,
          );

          for (final path in <String>[
            _absolutePath,
            _tildePath,
            _relativePath,
          ]) {
            final tapOffset = harnessKey.currentState!.tapOffsetFor(path);
            expect(
              tapOffset,
              isNotNull,
              reason: 'Missing tap offset for $path',
            );

            await tester.tapAt(tapOffset!);
            await tester.pumpAndSettle();
          }

          expect(harnessKey.currentState!._openedLinks.value, <String>[
            _absolutePath,
            _tildePath,
            _relativePath,
          ]);
        });

        testWidgets('ignores branch-like slash tokens', (tester) async {
          final harnessKey = GlobalKey<_TerminalPathLinkHarnessState>();
          await _pumpHarness(
            tester,
            harnessKey,
            touchScrollToTerminal: touchScrollToTerminal,
          );

          final tapOffset = harnessKey.currentState!.tapOffsetFor(
            _branchLikePath,
          );
          expect(tapOffset, isNull);
          expect(harnessKey.currentState!._openedLinks.value, isEmpty);
        });

        testWidgets('opens paths from nearby touch targets', (tester) async {
          final harnessKey = GlobalKey<_TerminalPathLinkHarnessState>();
          await _pumpHarness(
            tester,
            harnessKey,
            touchScrollToTerminal: touchScrollToTerminal,
          );

          final tapOffset = harnessKey.currentState!.tapOffsetFor(
            _absolutePath,
          );
          expect(tapOffset, isNotNull);
          final cellWidth = harnessKey
              .currentState!
              ._terminalViewKey
              .currentState!
              .renderTerminal
              .cellSize
              .width;

          await tester.tapAt(tapOffset! + Offset(cellWidth * 2.5, 0));
          await tester.pumpAndSettle();

          expect(harnessKey.currentState!._openedLinks.value, <String>[
            _absolutePath,
          ]);
        });

        testWidgets('opens a single-path row even from a loose same-row tap', (
          tester,
        ) async {
          final harnessKey = GlobalKey<_TerminalPathLinkHarnessState>();
          await _pumpHarness(
            tester,
            harnessKey,
            touchScrollToTerminal: touchScrollToTerminal,
          );

          final tapOffset = harnessKey.currentState!.tapOffsetFor(
            _absolutePath,
          );
          expect(tapOffset, isNotNull);
          final terminalTopLeft = tester.getTopLeft(
            find.byType(MonkeyTerminalView),
          );

          await tester.tapAt(Offset(terminalTopLeft.dx + 18, tapOffset!.dy));
          await tester.pumpAndSettle();

          expect(harnessKey.currentState!._openedLinks.value, <String>[
            _absolutePath,
          ]);
        });
      },
    );
  }
}
