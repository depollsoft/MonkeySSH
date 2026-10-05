package main

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// inlineAgentChrome is the input area Hermes's prompt_toolkit UI draws under
// its transcript: a status bar and rules as wide as the screen around the
// prompt, with the cursor left on the prompt.
func inlineAgentChrome(width int) string {
	rule := strings.Repeat("─", width)
	status := " status" + strings.Repeat(" ", width-len(" status")-1) + "!"
	return status + "\r\n" + rule + "\r\n❯ hi\r\n" + rule + "\x1b[A\r\x1b[2C"
}

// TestVTScreenRotationKeepsInlineAgentTranscript is the regression test for
// the last lines of a Hermes answer disappearing when the phone was rotated
// to portrait and the window was switched away and back.
//
// After the width change Hermes erases its input area and draws it again: it
// moves the cursor up over the rows that area takes once a reflowing terminal
// has rewrapped its full-width rules, then erases to the end of the screen.
// The client reflows, so that lands on the old input area. A model that only
// cut rows to the new width kept that area short, so the same move went past
// it into the transcript, and the frame painted from the model on the switch
// back showed the transcript without its last lines. The move starts from the
// cell Hermes left the cursor on, so the cursor has to stay on that cell for
// the erase to take the whole old input area and nothing above it.
func TestVTScreenRotationKeepsInlineAgentTranscript(t *testing.T) {
	const wide, narrow = 30, 13
	s := newTerminalScreen(wide, 8)
	for line := 1; line <= 9; line++ {
		s.Write([]byte(fmt.Sprintf("%d. some answer text\r\n", line)))
	}
	s.Write([]byte("END-OF-ANSWER\r\n" + inlineAgentChrome(wide)))

	s.Resize(narrow, 16)
	// prompt_toolkit's redraw: back to the start of the area, up over the
	// status bar and rule it drew (three rows each at this width), erase.
	s.Write([]byte("\x1b[2D\x1b[6A\x1b[J" + inlineAgentChrome(narrow)))

	text := strings.Join(append(vtScrollbackTexts(s), s.TextRows()...), "\n")
	for _, want := range []string{"9. some answe", "END-OF-ANSWER"} {
		if !strings.Contains(text, want) {
			t.Fatalf("redraw after rotation erased %q:\n%s", want, text)
		}
	}
	row, _ := s.CursorPosition()
	if got := s.TextRows()[row]; got != "❯ hi" {
		t.Fatalf("cursor row %d is %q, want the prompt", row, got)
	}
	if got := strings.Count(text, " status"); got != 1 {
		t.Fatalf("redraw left the old input area behind (%d status bars):\n%s", got, text)
	}
	vtRoundTrip(t, s)
}

func vtScrollbackTexts(s *terminalScreen) []string {
	out := make([]string, s.scrollback.len())
	for i, line := range vtScrollbackLines(s) {
		out[i] = vtScrollbackText(line)
	}
	return out
}

func TestVTScreenReflowKeepsLogicalLines(t *testing.T) {
	s := newTerminalScreen(10, 3)
	s.Write([]byte("0123456789abcd\r\nnext"))
	if got := s.TextRows(); !slices.Equal(got, []string{"0123456789", "abcd", "next"}) ||
		!slices.Equal(s.main.wrapped, []bool{false, true, false}) {
		t.Fatalf("autowrap: %q wrapped %v", got, s.main.wrapped)
	}

	// Narrowing splits the long line again and the split parts push the top
	// into the scrollback; the cursor stays after "next".
	s.Resize(4, 3)
	if got := s.TextRows(); !slices.Equal(got, []string{"89ab", "cd", "next"}) {
		t.Fatalf("narrow: %q", got)
	}
	if got := vtScrollbackTexts(s); !slices.Equal(got, []string{"0123", "4567"}) {
		t.Fatalf("narrow scrollback: %q", got)
	}
	if row, col := s.CursorPosition(); row != 2 || col != 3 || !s.main.pendingWrap {
		t.Fatalf("narrow cursor (%d,%d) pending %v", row, col, s.main.pendingWrap)
	}
	vtRoundTrip(t, s)

	// Widening joins the parts back, from the scrollback too.
	s.Resize(20, 3)
	if got := s.TextRows(); !slices.Equal(got, []string{"0123456789abcd", "next", ""}) {
		t.Fatalf("widen: %q", got)
	}
	if s.scrollback.len() != 0 || slices.Contains(s.main.wrapped, true) {
		t.Fatalf("widen left %d scrollback lines, wrapped %v", s.scrollback.len(), s.main.wrapped)
	}
}

// An erased row no longer continues the one above it, so widening must not
// join it, or bring back the text that was on it.
func TestVTScreenEraseEndsSoftWrap(t *testing.T) {
	for _, erase := range []string{"\x1b[2K", "\x1b[J", "\x1b[1J"} {
		s := newTerminalScreen(4, 3)
		s.Write([]byte("abcdefgh\x1b[2;1H" + erase))
		if s.main.wrapped[1] {
			t.Fatalf("%q kept the soft wrap", erase)
		}
		s.Resize(8, 3)
		if got := strings.Join(s.TextRows(), "|"); strings.Contains(got, "efgh") || strings.Contains(got, "dfgh") {
			t.Fatalf("%q: widening joined an erased row: %q", erase, got)
		}
	}
}

// A wide glyph that does not fit in the one cell left on a line moves to the
// next line whole, as in the client's reflow.
func TestVTScreenReflowMovesWideGlyphWhole(t *testing.T) {
	s := newTerminalScreen(3, 3)
	s.Write([]byte("abc界"))
	s.Resize(4, 3)
	if got := s.TextRows(); !slices.Equal(got, []string{"abc", "界", ""}) || !s.main.wrapped[1] {
		t.Fatalf("reflow split the wide glyph: %q wrapped %v", got, s.main.wrapped)
	}
	if cell := s.main.rows[1][0]; cell.r != '界' || cell.width != 2 || s.main.rows[1][1].width != 0 {
		t.Fatalf("moved glyph: %+v %+v", cell, s.main.rows[1][1])
	}
	vtRoundTrip(t, s)
}

// A frame reproduces which lines soft-wrap, in the scrollback and on the
// screen, including a cell at either side of a wrap that was never written,
// so a client painted from it reflows exactly as the model on the next width
// change.
func TestVTScreenFrameReproducesSoftWraps(t *testing.T) {
	build := func(autowrap bool) *terminalScreen {
		s := newTerminalScreen(8, 4)
		s.Write([]byte("one\r\n0123456789abcdefghij\r\nab界cd\r\n"))
		// A gap of never-written cells that the narrowing below splits.
		s.Write([]byte("\x1b[44mx\x1b[0m\x1b[6Cyz\r\nfirst-row-continues-the-scrollback"))
		s.Resize(5, 4)
		if !autowrap {
			s.Write([]byte("\x1b[?7l"))
		}
		return s
	}
	for _, autowrap := range []bool{true, false} {
		s := build(autowrap)
		if !s.main.wrapped[0] || !slices.Contains(vtScrollbackWrapped(s), true) {
			t.Fatalf("setup: wrapped %v scrollback %v", s.main.wrapped, vtScrollbackWrapped(s))
		}
		replica := vtRoundTrip(t, s)
		for _, width := range []int{11, 3, 8} {
			s.Resize(width, 4)
			replica.Resize(width, 4)
			if got, want := replica.TextRows(), s.TextRows(); !slices.Equal(got, want) {
				t.Fatalf("autowrap %v, width %d: client reflowed to %q, model to %q", autowrap, width, got, want)
			}
			if got, want := vtScrollbackTexts(replica), vtScrollbackTexts(s); !slices.Equal(got, want) {
				t.Fatalf("autowrap %v, width %d: client scrollback %q, model %q", autowrap, width, got, want)
			}
		}
	}
}

// On a one-row screen the row a frame wraps from has already scrolled into
// the history, out of reach of anything that would erase a stand-in glyph
// there. A wide glyph that did not fit is reproduced the way it arose; any
// other wrap from a never-written cell is dropped rather than leave a space
// the client would keep.
func TestVTScreenFrameSoftWrapsOnOneRow(t *testing.T) {
	s := newTerminalScreen(4, 1)
	s.Write([]byte("abc界"))
	replica := vtRoundTrip(t, s)
	s.Resize(8, 1)
	replica.Resize(8, 1)
	if got := replica.TextRows(); !slices.Equal(got, []string{"abc界"}) || !slices.Equal(got, s.TextRows()) {
		t.Fatalf("widened replica %q, model %q", got, s.TextRows())
	}

	s = newTerminalScreen(8, 1)
	s.Write([]byte("abc\x1b[3Cde"))
	s.Resize(4, 1)
	if !s.main.wrapped[0] || s.main.rows[0][0].r != 0 {
		t.Fatalf("setup: wrapped %v, row %q", s.main.wrapped, s.TextRows())
	}
	replica = newTerminalScreen(4, 1)
	replica.Write([]byte("\x1b[?7h"))
	replica.Write(s.RenderFrame())
	if got := vtScrollbackLines(replica); len(got) != 1 || string(got[0]) != "abc" {
		t.Fatalf("frame left a stand-in in the history: %q", got)
	}
	if replica.main.wrapped[0] {
		t.Fatal("frame kept a wrap it could not reproduce faithfully")
	}
}

// A soft wrap in the scrollback scrolls its row in while the wrapping glyph's
// rendition is set, which fills the row with that background on a terminal
// that erases with it, as the model does. The default cells the stored line
// leaves out must not come back coloured.
func TestVTScreenFrameKeepsDefaultPaddingAfterWrappedScrollback(t *testing.T) {
	s := newTerminalScreen(3, 2)
	s.Write([]byte("\x1b[44mabcdefghij\r\nx\r\nx"))
	s.Resize(4, 2)
	if !slices.Contains(vtScrollbackWrapped(s), true) {
		t.Fatalf("setup: scrollback wrapped %v", vtScrollbackWrapped(s))
	}
	vtRoundTrip(t, s)

	// The same for default cells inside a line, and for the first row on the
	// screen when it continues the scrollback.
	s = newTerminalScreen(4, 2)
	s.Write([]byte("\x1b[44mabcd\x1b[0me\x1b[2C\x1b[44mf\x1b[0m"))
	if !s.main.wrapped[1] {
		t.Fatalf("setup: wrapped %v", s.main.wrapped)
	}
	s.Write([]byte("\r\n"))
	vtRoundTrip(t, s)
}

// The replay restores insert mode before the frame. Painting under it would
// shift the glyph a soft wrap prints instead of painting over it.
func TestVTScreenFrameSoftWrapsUnderInsertMode(t *testing.T) {
	s := newTerminalScreen(6, 3)
	s.Write([]byte("abcdefg\x1b[2Ci\x1b[4h"))
	if !s.main.wrapped[1] || !s.insertMode {
		t.Fatalf("setup: wrapped %v insert %v", s.main.wrapped, s.insertMode)
	}
	vtRoundTrip(t, s)
}

// The cursor stays on the cell it was on, wherever the reflow moves it, as in
// the client: after the text on its line, or past the last column with the
// wrap still pending when that text filled the line.
func TestVTScreenReflowKeepsCursorOnItsCell(t *testing.T) {
	s := newTerminalScreen(20, 5)
	s.Write([]byte("0123456789abcdef\r\nxy"))
	s.Resize(8, 5)
	if row, col := s.CursorPosition(); s.TextRows()[row] != "xy" || col != 2 {
		t.Fatalf("cursor (%d,%d) on %q", row, col, s.TextRows()[row])
	}

	s = newTerminalScreen(8, 5)
	s.Write([]byte("abcdefgh"))
	s.Resize(4, 5)
	if row, col := s.CursorPosition(); s.TextRows()[row] != "efgh" || col != 3 || !s.main.pendingWrap {
		t.Fatalf("cursor (%d,%d) pending %v on %q", row, col, s.main.pendingWrap, s.TextRows()[row])
	}
	s.Write([]byte("i"))
	if got := s.TextRows(); !slices.Equal(got[:2], []string{"efgh", "i"}) || !s.main.wrapped[1] {
		t.Fatalf("pending wrap lost: %q wrapped %v", got, s.main.wrapped)
	}

	// A cursor past the new edge on a line its text does not fill sits on
	// the last column; no wrap is pending there.
	s = newTerminalScreen(8, 3)
	s.Write([]byte("\x1b[1;8H"))
	s.Resize(4, 3)
	s.Write([]byte("X"))
	if got := s.TextRows(); got[0] != "   X" || s.main.wrapped[1] {
		t.Fatalf("narrowing made a wrap pending: %q wrapped %v", got, s.main.wrapped)
	}

	// Nor with autowrap off: the next glyph replaces the last one.
	s = newTerminalScreen(8, 3)
	s.Write([]byte("\x1b[?7labcd"))
	s.Resize(4, 3)
	s.Write([]byte("X"))
	if got := s.TextRows(); got[0] != "abcX" || got[1] != "" {
		t.Fatalf("narrowing without autowrap: %q", got)
	}
}

// A row that a scroll, a line insertion or a deletion moves next to a
// different row starts a line of its own, as in the client, so a later width
// change does not join it to its new neighbour.
func TestVTScreenRowMovesEndSoftWraps(t *testing.T) {
	for name, seq := range map[string]string{
		"region scroll up":   "\x1b[2;4r\x1b[S\x1b[r",
		"delete line":        "\x1b[2;1H\x1b[M",
		"region scroll down": "\x1b[3;4r\x1b[T\x1b[r",
		"insert line":        "\x1b[3;1H\x1b[L",
	} {
		s := newTerminalScreen(4, 4)
		s.Write([]byte("HEAD\r\nabcdefgh"))
		if !s.main.wrapped[2] {
			t.Fatalf("%s: setup wrapped %v", name, s.main.wrapped)
		}
		s.Write([]byte(seq))
		for r, row := range s.TextRows() {
			if row == "efgh" && s.main.wrapped[r] {
				t.Fatalf("%s: efgh still continues row %d: %q", name, r-1, s.TextRows())
			}
		}
		s.Resize(8, 4)
		if got := strings.Join(s.TextRows(), "|"); strings.Contains(got, "HEADefgh") || strings.Contains(got, "|efgh") == false {
			t.Fatalf("%s: widening joined moved rows: %q", name, got)
		}
	}
}

// An erased row that still continues the text above it (ECH keeps the wrap)
// stays after that text when a reflow joins them.
func TestVTScreenReflowKeepsErasedContinuationAfterItsText(t *testing.T) {
	s := newTerminalScreen(4, 3)
	s.Write([]byte("abcde\x1b[2;1H\x1b[4X"))
	if !s.main.wrapped[1] {
		t.Fatalf("setup: wrapped %v", s.main.wrapped)
	}
	s.Resize(8, 3)
	if got := s.TextRows(); got[0] != "abcd" || s.main.wrapped[0] {
		t.Fatalf("reflow put the erased row first: %q wrapped %v", got, s.main.wrapped)
	}
}

// A tab with no stop left leaves the client's cursor past the edge with a
// wrap pending, so the next glyph starts the next line, with or without a
// resize in between.
func TestVTScreenExhaustedTabPendsLikeClient(t *testing.T) {
	for _, tab := range []string{"\t", "\x1b[I"} {
		for _, resize := range []bool{false, true} {
			s := newTerminalScreen(8, 3)
			s.Write([]byte(tab))
			if resize {
				s.Resize(4, 3)
			}
			s.Write([]byte("X"))
			if got := s.TextRows(); got[0] != "" || got[1] != "X" {
				t.Fatalf("%q resize %v: %q", tab, resize, got)
			}
		}
	}
}

// A one-column screen splits a wide glyph across rows; the halves are blanked
// so a later widening does not read past a row's end.
func TestVTScreenOneColumnReflowLeavesNoSplitGlyph(t *testing.T) {
	// Printing a wide glyph on one column, plain or in insert mode, has no
	// room for its second half; it must not write past the row.
	for _, seq := range []string{"界a", "\x1b[4h界a"} {
		s := newTerminalScreen(1, 3)
		s.Write([]byte(seq))
		s.Resize(3, 3)
		if got := strings.Join(s.TextRows(), "|"); !strings.Contains(got, "a") {
			t.Fatalf("%q: %q", seq, got)
		}
	}

	s := newTerminalScreen(4, 3)
	s.Write([]byte("\x1b[3;1H界x"))
	s.Resize(1, 3)
	s.Resize(2, 3)
	s.Resize(4, 3)
	for r, row := range s.main.rows {
		if row[len(row)-1].width == 2 || row[0].width == 0 {
			t.Fatalf("row %d keeps a split glyph: %+v", r, row)
		}
	}
	vtRoundTrip(t, s)
}

// A wrap a tab left pending over an empty last column is restored by a tab,
// not by printing a space there, so a client painted from the frame lays the
// line out the same on the next resize.
func TestVTScreenFrameRestoresTabPendingWrap(t *testing.T) {
	for _, tab := range []string{"\t", "\x1b[I"} {
		s := newTerminalScreen(8, 3)
		s.Write([]byte("hi" + tab))
		if !s.main.pendingWrap {
			t.Fatalf("%q: setup did not leave a wrap pending", tab)
		}
		replica := vtRoundTrip(t, s)
		s.Resize(4, 3)
		replica.Resize(4, 3)
		if got, want := replica.TextRows(), s.TextRows(); !slices.Equal(got, want) || replica.scrollback.len() != s.scrollback.len() {
			t.Fatalf("%q: replica %q (%d history), model %q (%d history)", tab, got, replica.scrollback.len(), want, s.scrollback.len())
		}
	}
}
