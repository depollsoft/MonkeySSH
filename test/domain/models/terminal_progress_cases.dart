import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_progress.dart';

/// Registers tests from terminal_progress_test.dart.
void registerDomainModelsTerminalProgressTests() {
  group('terminal_progress', () {
    group('OSC 9;4 terminal progress', () {
      test(
        'applies normal, error, indeterminate, and paused/warning states',
        () {
          final normal = applyTerminalProgressOsc(const [
            '4',
            '1',
            '42',
          ], previousProgress: null);
          expect(
            normal,
            const TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 42,
            ),
          );
          expect(normal?.fraction, 0.42);

          expect(
            applyTerminalProgressOsc(const [
              '4',
              '2',
              '81',
            ], previousProgress: normal),
            const TerminalProgress(
              state: TerminalProgressState.error,
              percentage: 81,
            ),
          );
          expect(
            applyTerminalProgressOsc(const [
              '4',
              '3',
            ], previousProgress: normal),
            const TerminalProgress(state: TerminalProgressState.indeterminate),
          );
          expect(
            applyTerminalProgressOsc(const [
              '4',
              '4',
              '24',
            ], previousProgress: normal),
            const TerminalProgress(
              state: TerminalProgressState.pausedOrWarning,
              percentage: 24,
            ),
          );
        },
      );

      test('preserves percentage when error or paused/warning omits it', () {
        const previous = TerminalProgress(
          state: TerminalProgressState.normal,
          percentage: 63,
        );

        expect(
          applyTerminalProgressOsc(const [
            '4',
            '2',
          ], previousProgress: previous),
          const TerminalProgress(
            state: TerminalProgressState.error,
            percentage: 63,
          ),
        );
        expect(
          applyTerminalProgressOsc(const [
            '4',
            '4',
            '',
          ], previousProgress: previous),
          const TerminalProgress(
            state: TerminalProgressState.pausedOrWarning,
            percentage: 63,
          ),
        );
      });

      test('accepts status-only error and paused/warning updates', () {
        expect(
          applyTerminalProgressOsc(const ['4', '2'], previousProgress: null),
          const TerminalProgress(state: TerminalProgressState.error),
        );
        expect(
          applyTerminalProgressOsc(const ['4', '4'], previousProgress: null),
          const TerminalProgress(state: TerminalProgressState.pausedOrWarning),
        );
      });

      test('clears progress for state zero', () {
        expect(
          applyTerminalProgressOsc(
            const ['4', '0'],
            previousProgress: const TerminalProgress(
              state: TerminalProgressState.normal,
              percentage: 100,
            ),
          ),
          isNull,
        );
      });

      test('ignores malformed, out-of-range, and unrelated updates', () {
        const previous = TerminalProgress(
          state: TerminalProgressState.normal,
          percentage: 20,
        );

        for (final args in <List<String>>[
          const [],
          const ['3', '1', '50'],
          const ['4'],
          const ['4', '1'],
          const ['4', '1', '-1'],
          const ['4', '1', '101'],
          const ['4', '1', 'nope'],
          const ['4', '2', '101'],
          const ['4', '4', 'nope'],
          const ['4', '8', '50'],
        ]) {
          expect(
            applyTerminalProgressOsc(args, previousProgress: previous),
            previous,
            reason: '$args should be ignored',
          );
        }
      });
    });
  });
}
