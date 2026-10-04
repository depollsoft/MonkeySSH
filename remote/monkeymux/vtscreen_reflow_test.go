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
// The client reflows, so that lands inside the old input area. A model that
// only cut rows to the new width kept that area short, so the same move went
// past it into the transcript, and the frame painted from the model on the
// switch back showed the transcript without its last lines.
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
	vtRoundTrip(t, s)
}

func vtScrollbackTexts(s *terminalScreen) []string {
	out := make([]string, len(s.scrollback))
	for i, line := range s.scrollback {
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
	// into the scrollback; the cursor keeps its row on the screen.
	s.Resize(4, 3)
	if got := s.TextRows(); !slices.Equal(got, []string{"89ab", "cd", "next"}) {
		t.Fatalf("narrow: %q", got)
	}
	if got := vtScrollbackTexts(s); !slices.Equal(got, []string{"0123", "4567"}) {
		t.Fatalf("narrow scrollback: %q", got)
	}
	if row, col := s.CursorPosition(); row != 2 || col != 3 {
		t.Fatalf("narrow cursor (%d,%d)", row, col)
	}
	vtRoundTrip(t, s)

	// Widening joins the parts back, from the scrollback too.
	s.Resize(20, 3)
	if got := s.TextRows(); !slices.Equal(got, []string{"0123456789abcd", "next", ""}) {
		t.Fatalf("widen: %q", got)
	}
	if len(s.scrollback) != 0 || slices.Contains(s.main.wrapped, true) {
		t.Fatalf("widen left %d scrollback lines, wrapped %v", len(s.scrollback), s.main.wrapped)
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
		if !s.main.wrapped[0] || !slices.Contains(s.scrollbackWrapped, true) {
			t.Fatalf("setup: wrapped %v scrollback %v", s.main.wrapped, s.scrollbackWrapped)
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
