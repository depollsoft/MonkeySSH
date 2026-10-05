package main

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// inlineAgentScreen draws what an inline agent such as Hermes leaves on the
// main screen: a transcript that has scrolled into the scrollback, then an
// input box whose lower border sits below the cursor.
func inlineAgentScreen(width, height int) *terminalScreen {
	s := newTerminalScreen(width, height)
	for line := 1; line <= 12; line++ {
		s.Write([]byte(fmt.Sprintf("line %d\r\n", line)))
	}
	rule := strings.Repeat("─", width)
	s.Write([]byte(rule + "\r\n❯ draft\r\n" + rule + "\x1b[A\r\x1b[7C"))
	return s
}

// TestVTScreenKeyboardCycleKeepsInlineAgentAnchored is the regression test for
// Hermes's input box sitting mid-screen, with blank rows under it, after the
// phone keyboard opened and closed. The client keeps the screen anchored to
// its bottom through every resize step, so the model must too, or the next
// frame painted from it moves the rows the client already shows.
func TestVTScreenKeyboardCycleKeepsInlineAgentAnchored(t *testing.T) {
	s := inlineAgentScreen(30, 10)
	before := s.TextRows()
	beforeRow, beforeCol := s.CursorPosition()
	if before[8] != "❯ draft" || beforeRow != 8 {
		t.Fatalf("setup: %q, cursor row %d", before, beforeRow)
	}

	// The keyboard animation shrinks the window a step at a time.
	for _, height := range []int{9, 7, 6, 5} {
		s.Resize(30, height)
		rows := s.TextRows()
		if rows[height-2] != "❯ draft" || !strings.HasPrefix(rows[height-1], "──") {
			t.Fatalf("shrink to %d lost the input box: %q", height, rows)
		}
		if row, _ := s.CursorPosition(); row != height-2 {
			t.Fatalf("shrink to %d moved the cursor to row %d", height, row)
		}
	}

	// Closing the keyboard brings the scrolled rows back above the content.
	s.Resize(30, 10)
	if got := s.TextRows(); !slices.Equal(got, before) {
		t.Fatalf("keyboard cycle moved the picture:\nwant %q\ngot  %q", before, got)
	}
	if row, col := s.CursorPosition(); row != beforeRow || col != beforeCol {
		t.Fatalf("cursor (%d,%d), want (%d,%d)", row, col, beforeRow, beforeCol)
	}

	// A frame painted from the model reproduces that picture and scrollback.
	client := newTerminalScreen(30, 10)
	client.Write(s.RenderFrame())
	if got := client.TextRows(); !slices.Equal(got, before) {
		t.Fatalf("frame after the cycle:\nwant %q\ngot  %q", before, got)
	}
	if client.scrollback.len() != s.scrollback.len() || vtScrollbackText(client.scrollback.at(0).text) != "line 1" {
		t.Fatalf("frame scrollback: %d lines, want %d", client.scrollback.len(), s.scrollback.len())
	}
}

func TestVTScreenShrinkGivesUpEmptyRowsBelowCursorFirst(t *testing.T) {
	s := newTerminalScreen(20, 8)
	s.Write([]byte("one\r\ntwo\r\nthree"))
	s.Resize(20, 4)
	if got := s.TextRows(); got[0] != "one" || got[2] != "three" || got[3] != "" {
		t.Fatalf("shrink scrolled instead of dropping empty rows: %q", got)
	}
	if s.scrollback.len() != 0 {
		t.Fatalf("empty rows below the cursor reached the scrollback: %d", s.scrollback.len())
	}

	// Written spaces are content, as in the client, so that row is kept and
	// the top row scrolls away instead.
	s = newTerminalScreen(20, 3)
	s.Write([]byte("one\r\ntwo\r\n   \x1b[A"))
	s.Resize(20, 2)
	if got := s.TextRows(); got[0] != "two" {
		t.Fatalf("shrink dropped a row of written spaces: %q", got)
	}
	if s.scrollback.len() != 1 || vtScrollbackText(s.scrollback.at(0).text) != "one" {
		t.Fatalf("scrollback: %d lines", s.scrollback.len())
	}
}

func TestVTScreenGrowRestoresScrollbackRendition(t *testing.T) {
	s := newTerminalScreen(12, 2)
	s.Write([]byte("\x1b[31mred 界\x1b[0m\r\nplain\r\nlast"))
	if s.scrollback.len() != 1 {
		t.Fatalf("setup scrollback: %d", s.scrollback.len())
	}
	s.Resize(12, 3)
	if got := s.TextRows(); got[0] != "red 界" || got[2] != "last" {
		t.Fatalf("restored rows: %q", got)
	}
	if cell := s.main.rows[0][0]; cell.attrs.fg.kind != vtColorIndexed || cell.attrs.fg.index != 1 {
		t.Fatalf("restored row lost its color: %+v", cell.attrs)
	}
	if cell := s.main.rows[0][4]; cell.r != '界' || cell.width != 2 || s.main.rows[0][5].width != 0 {
		t.Fatalf("restored row lost its wide glyph: %+v %+v", cell, s.main.rows[0][5])
	}

	// A line restored into a narrower screen is reflowed like any other.
	s = newTerminalScreen(12, 1)
	s.Write([]byte("abcdefghij\r\nx"))
	s.Resize(4, 2)
	if got := s.TextRows(); got[0] != "ij" || got[1] != "x" {
		t.Fatalf("narrow restore: %q", got)
	}
	if s.scrollback.len() != 2 || vtScrollbackText(s.scrollback.at(1).text) != "efgh" || !s.main.wrapped[0] {
		t.Fatalf("narrow restore scrollback: %d lines, wrapped %v", s.scrollback.len(), s.main.wrapped)
	}
}

// Restoring a scrollback line and painting a frame both go through the
// rendered row, so it must keep which cells were written: a resize reclaims
// only rows nothing was written to, in the model and in the client.
func TestVTScreenRowProvenanceSurvivesScrollbackAndFrames(t *testing.T) {
	s := newTerminalScreen(12, 2)
	s.Write([]byte("ab   \r\n\x1b[44m\x1b[K\x1b[0m\r\nx\r\ny"))
	if s.scrollback.len() != 2 {
		t.Fatalf("setup scrollback: %d", s.scrollback.len())
	}
	vtRoundTrip(t, s)

	s.Resize(12, 4)
	spaces, erased := s.main.rows[0], s.main.rows[1]
	if spaces[2].r != ' ' || spaces[4].r != ' ' || spaces[5].r != 0 {
		t.Fatalf("written spaces came back as %q", []rune{spaces[2].r, spaces[4].r, spaces[5].r})
	}
	if vtRowReclaimable(spaces) {
		t.Fatal("a row of written spaces became reclaimable")
	}
	if !vtRowReclaimable(erased) {
		t.Fatal("a row erased with a background became written")
	}
	if bg := erased[11].attrs.bg; bg.kind != vtColorIndexed || bg.index != 4 {
		t.Fatalf("erased row lost its background: %+v", bg)
	}
	vtRoundTrip(t, s)
}
