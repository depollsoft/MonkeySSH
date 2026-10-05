# HANDOFF from refactor/sa5-xterm (third_party/xterm)

## Edit already made to a file outside this package

- `pubspec.lock` (root): the `zmodem` transitive entry is gone, because
  `third_party/xterm/pubspec.yaml` no longer depends on `zmodem`. `flutter pub get`
  produced it; nothing else in the lockfile changed.

## Edits other packages still need to make

1. `lib/domain/services/ssh_service.dart` (`_TerminalOutputCursorTracker`, about lines
   600-830). The fork now follows `remote/monkeymux/vtscreen.go`. The decoder's
   cursor tracker does not yet, so the insert-mode column it computes can drift:
   - `_setMargins`: ignore the sequence when `top >= bottom` (it currently swaps
     the values), and home the cursor after a valid region: row `_marginTop` in
     origin mode, otherwise row 0, column 0.
   - `_moveCursorRows` (CUU/CUD/CNL/CPL): when the cursor is inside
     `[_marginTop, _marginBottom]`, clamp a move up at `_marginTop` and a move down
     at `_marginBottom`. A cursor outside the region still clamps to the screen.
   - VPA (`_terminalLinePositionAbsoluteFinalCodeUnit`): in origin mode add
     `_marginTop` and clamp to `[_marginTop, _marginBottom]`, as `_setCursor` does.
   - D10: `_terminalCellWidth`, `_isTerminalZeroWidthRune` and `_isTerminalWideRune`
     re-implement wcwidth with a smaller table. Replace them with
     `unicodeV11.wcwidth(rune)` from `package:xterm/src/utils/unicode_v11.dart`. The
     buffer now drops width-0 code points (D1), so the tracker's column math
     matches the buffer only if both use the same table.

2. `lib/presentation/widgets/monkey_terminal_view.dart`: nothing creates a
   `TerminalHighlight`, so the highlight pass (the `_paintHighlights(canvas,
   _controller.highlights, ...)` call near line 4402 and `_paintHighlights` near
   line 5172) always paints an empty list. Its `highlights` parameter is unused
   too (D16). Once the pass is deleted, the fork can delete
   `TerminalController.highlight()`/`highlights`, `TerminalHighlight`,
   `RenderTerminal._paintHighlights`, `TerminalPainter.paintHighlight` and
   `base/disposable.dart` (codex finding 9). That is not done here because the
   app still reads `_controller.highlights`.

3. `test/widget/monkey_terminal_view_layout_cases.dart` (about line 514, 'style-run
   batching falls back to per-cell for combining marks, ...'): the buffer no
   longer stores U+0301 as its own cell (D1), so the combining-mark part of this
   test no longer reaches the painter. The test still passes. Update its comment,
   or drop `é` from the input.
