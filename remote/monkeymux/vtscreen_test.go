package main

import (
	"bytes"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

// vtScrollbackText renders a stored scrollback line back to plain text.
func vtScrollbackText(line []byte) string {
	s := newTerminalScreen(400, 1)
	s.Write(line)
	return s.TextRows()[0]
}

func vtText(t *testing.T, s *terminalScreen) string {
	t.Helper()
	return strings.Join(s.TextRows(), "\n")
}

func vtRowsEqual(a, b [][]vtCell) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if len(a[i]) != len(b[i]) {
			return false
		}
		for j := range a[i] {
			x, y := a[i][j], b[i][j]
			if x.width != y.width || x.attrs != y.attrs || string(x.comb) != string(y.comb) {
				return false
			}
			xr, yr := x.r, y.r
			if xr == 0 {
				xr = ' '
			}
			if yr == 0 {
				yr = ' '
			}
			if xr != yr {
				return false
			}
		}
	}
	return true
}

// vtRoundTrip feeds RenderFrame into a fresh screen the way the real replay
// does (after the reset prefix and the window's private modes) and asserts the
// picture, cursor, region and scrollback survive.
func vtRoundTrip(t *testing.T, s *terminalScreen) {
	t.Helper()
	w, h := s.Size()
	replica := newTerminalScreen(w, h)
	preamble := "\x1b[?6l\x1b[r\x1b[0m"
	if s.autowrap {
		preamble += "\x1b[?7h"
	}
	if s.AlternateScreenActive() {
		preamble += "\x1b[?1049h"
	}
	replica.Write([]byte(preamble))
	replica.Write(s.RenderFrame())
	if !vtRowsEqual(s.grid().rows, replica.grid().rows) {
		t.Fatalf("round trip changed the grid:\nwant:\n%s\ngot:\n%s", vtText(t, s), vtText(t, replica))
	}
	r1, c1 := s.CursorPosition()
	r2, c2 := replica.CursorPosition()
	if r1 != r2 || c1 != c2 {
		t.Fatalf("round trip moved the cursor: want (%d,%d) got (%d,%d)", r1, c1, r2, c2)
	}
	if s.top != replica.top || s.bottom != replica.bottom || s.originMode != replica.originMode {
		t.Fatalf("round trip changed region/origin: want %d-%d/%v got %d-%d/%v",
			s.top, s.bottom, s.originMode, replica.top, replica.bottom, replica.originMode)
	}
	if s.attrs != replica.attrs {
		t.Fatalf("round trip changed the current rendition: %+v vs %+v", s.attrs, replica.attrs)
	}
	if s.grid().pendingWrap != replica.grid().pendingWrap {
		t.Fatalf("round trip changed pending wrap: %v vs %v", s.grid().pendingWrap, replica.grid().pendingWrap)
	}
	if s.insertMode != replica.insertMode || s.g0Graphics != replica.g0Graphics ||
		s.g1Graphics != replica.g1Graphics || s.shiftOut != replica.shiftOut {
		t.Fatal("round trip changed insert mode or charsets")
	}
	if strings.Join(boolStrings(s.tabs), "") != strings.Join(boolStrings(replica.tabs), "") {
		t.Fatal("round trip changed tab stops")
	}
	if a, b := *s.saved(), *replica.saved(); a.valid && a != b {
		t.Fatalf("round trip changed the saved cursor: %+v vs %+v", a, b)
	}
	if a, b := s.scoCursor, replica.scoCursor; a.valid && (a.row != b.row || a.col != b.col) {
		t.Fatalf("round trip changed the SCO cursor: %+v vs %+v", a, b)
	}
	if !s.AlternateScreenActive() {
		if len(s.scrollback) != len(replica.scrollback) {
			t.Fatalf("round trip changed scrollback length: want %d got %d", len(s.scrollback), len(replica.scrollback))
		}
		for i := range s.scrollback {
			if !bytes.Equal(s.scrollback[i], replica.scrollback[i]) {
				t.Fatalf("scrollback line %d differs: %q vs %q", i, s.scrollback[i], replica.scrollback[i])
			}
		}
	}
}

func boolStrings(values []bool) []string {
	out := make([]string, len(values))
	for i, v := range values {
		if v {
			out[i] = "1"
		} else {
			out[i] = "0"
		}
	}
	return out
}

func TestVTScreenCursorMovesAndClamp(t *testing.T) {
	s := newTerminalScreen(10, 4)
	s.Write([]byte("\x1b[99;99H"))
	if r, c := s.CursorPosition(); r != 3 || c != 9 {
		t.Fatalf("CUP did not clamp: (%d,%d)", r, c)
	}
	s.Write([]byte("\x1b[H\x1b[2B\x1b[3CX"))
	if got := s.TextRows()[2]; got != "   X" {
		t.Fatalf("relative moves misplaced X: %q", got)
	}
	s.Write([]byte("\x1b[5A\x1b[9DY"))
	if got := s.TextRows()[0]; got != "Y" {
		t.Fatalf("clamped moves misplaced Y: %q", got)
	}
}

func TestVTScreenWrapAndPendingWrap(t *testing.T) {
	s := newTerminalScreen(5, 3)
	s.Write([]byte("abcde"))
	if r, c := s.CursorPosition(); r != 0 || c != 4 {
		t.Fatalf("cursor after filling a row should stay on it: (%d,%d)", r, c)
	}
	s.Write([]byte("\rZ"))
	if got := s.TextRows()[0]; got != "Zbcde" || s.TextRows()[1] != "" {
		t.Fatalf("CR must clear pending wrap: %q", s.TextRows())
	}
	s.Write([]byte("\x1b[1;5Hxy"))
	if got := s.TextRows(); got[0] != "Zbcdx" || got[1] != "y" {
		t.Fatalf("pending wrap should defer the newline: %q", got)
	}
	s.Write([]byte("\x1b[?7l\x1b[1;4Hpqrs"))
	if got := s.TextRows()[0]; got != "Zbcps" {
		t.Fatalf("autowrap off must overwrite the last column: %q", got)
	}
}

func TestVTScreenWideAndCombining(t *testing.T) {
	s := newTerminalScreen(6, 2)
	s.Write([]byte("a漢b"))
	if got := s.TextRows()[0]; got != "a漢b" {
		t.Fatalf("wide glyph text: %q", got)
	}
	if s.grid().rows[0][1].width != 2 || s.grid().rows[0][2].width != 0 {
		t.Fatal("wide glyph must occupy a continuation cell")
	}
	if r, c := s.CursorPosition(); r != 0 || c != 4 {
		t.Fatalf("cursor after wide glyph: (%d,%d)", r, c)
	}
	s.Write([]byte("é"))
	if got := string(s.grid().rows[0][4].comb); got != "́" {
		t.Fatalf("combining mark not attached: %q", got)
	}
	// A wide glyph that does not fit in the last column wraps first.
	s.Write([]byte("\x1b[1;6H漢"))
	if got := s.TextRows(); got[1] != "漢" {
		t.Fatalf("wide glyph at last column must wrap: %q", got)
	}
	// Overwriting half of a wide glyph blanks the rest of it.
	s.Write([]byte("\x1b[1;3HQ"))
	if got := s.TextRows()[0]; got != "a Qbe\u0301" {
		t.Fatalf("overwriting a wide half: %q", got)
	}
	vtRoundTrip(t, s)
}

func TestVTScreenEraseInsertDelete(t *testing.T) {
	s := newTerminalScreen(8, 4)
	s.Write([]byte("12345678\r\nabcdefgh\r\nABCDEFGH\r\nwxyz"))
	s.Write([]byte("\x1b[2;3H\x1b[K"))
	if got := s.TextRows()[1]; got != "ab" {
		t.Fatalf("EL 0: %q", got)
	}
	s.Write([]byte("\x1b[3;3H\x1b[1K"))
	if got := s.TextRows()[2]; got != "   DEFGH" {
		t.Fatalf("EL 1: %q", got)
	}
	s.Write([]byte("\x1b[1;2H\x1b[2@"))
	if got := s.TextRows()[0]; got != "1  23456" {
		t.Fatalf("ICH: %q", got)
	}
	s.Write([]byte("\x1b[1;2H\x1b[2P"))
	if got := s.TextRows()[0]; got != "123456" {
		t.Fatalf("DCH: %q", got)
	}
	s.Write([]byte("\x1b[1;1H\x1b[3X"))
	if got := s.TextRows()[0]; got != "   456" {
		t.Fatalf("ECH: %q", got)
	}
	s.Write([]byte("\x1b[2;1H\x1b[L"))
	if got := s.TextRows(); got[1] != "" || got[2] != "ab" || got[3] != "   DEFGH" {
		t.Fatalf("IL: %q", got)
	}
	s.Write([]byte("\x1b[1;1H\x1b[2M"))
	if got := s.TextRows(); got[0] != "ab" || got[1] != "   DEFGH" || got[2] != "" {
		t.Fatalf("DL: %q", got)
	}
	s.Write([]byte("\x1b[2;4H\x1b[J"))
	if got := s.TextRows(); got[1] != "" || got[2] != "" {
		t.Fatalf("ED 0: %q", got)
	}
	s.Write([]byte("\x1b[2J"))
	if s.HasVisibleContent() {
		t.Fatal("ED 2 must clear the screen")
	}
}

func TestVTScreenScrollRegionAndOriginMode(t *testing.T) {
	s := newTerminalScreen(10, 6)
	for i := 1; i <= 6; i++ {
		s.Write([]byte(fmt.Sprintf("\x1b[%d;1Hline%d", i, i)))
	}
	s.Write([]byte("\x1b[2;4r\x1b[?6h\x1b[3;1H\n\n"))
	got := s.TextRows()
	if got[0] != "line1" || got[1] != "line4" || got[2] != "" || got[3] != "" || got[4] != "line5" || got[5] != "line6" {
		t.Fatalf("region scroll: %q", got)
	}
	if len(s.scrollback) != 0 {
		t.Fatal("lines scrolled out of a partial region must not enter scrollback")
	}
	s.Write([]byte("\x1b[1;1HTOP"))
	if got := s.TextRows()[1]; got != "TOPe4" {
		t.Fatalf("DECOM CUP must be relative to the margin: %q", got)
	}
	s.Write([]byte("\x1b[1;1H\x1bM"))
	if got := s.TextRows(); got[1] != "" || got[2] != "TOPe4" {
		t.Fatalf("RI at the top margin scrolls the region down: %q", got)
	}
	vtRoundTrip(t, s)
	s.Write([]byte("\x1b[?6l\x1b[r"))
	if s.top != 0 || s.bottom != 5 {
		t.Fatal("DECSTBM without parameters must reset the region")
	}
}

// A region whose top margin is the first row feeds the scrollback whatever
// its bottom margin, as xterm does: ratatui's inline viewport (the Codex CLI)
// pushes transcript lines out of a "CSI 1 ; N r" region above the viewport and
// they must survive into a rendered frame so the client can scroll back to
// them after a replay.
func TestVTScreenTopAnchoredPartialRegionFeedsScrollback(t *testing.T) {
	s := newTerminalScreen(10, 6)
	s.Write([]byte("\x1b[4;1HV0\r\nV1\r\nV2"))
	s.Write([]byte("\x1b7\x1b[1;3r\x1b[3;1H"))
	for _, line := range []string{"T0", "T1", "T2", "T3", "T4"} {
		s.Write([]byte("\r\n" + line))
	}
	s.Write([]byte("\x1b[r\x1b8"))
	got := s.TextRows()
	want := []string{"T2", "T3", "T4", "V0", "V1", "V2"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("inline viewport rows: %q", got)
		}
	}
	if len(s.scrollback) != 5 {
		t.Fatalf("scrollback: %d lines, want 5", len(s.scrollback))
	}
	for i, want := range []string{"", "", "", "T0", "T1"} {
		if got := vtScrollbackText(s.scrollback[i]); got != want {
			t.Fatalf("scrollback[%d] = %q, want %q", i, got, want)
		}
	}
	if row, col := s.CursorPosition(); row != 5 || col != 2 {
		t.Fatalf("cursor after DECRC: (%d,%d)", row, col)
	}
	vtRoundTrip(t, s)

	// CSI S inside the same region saves lines too; a region that starts
	// below the first row never does.
	s.Write([]byte("\x1b[1;3r\x1b[S\x1b[2;3r\x1b[S\x1b[r"))
	if len(s.scrollback) != 6 || vtScrollbackText(s.scrollback[5]) != "T2" {
		t.Fatalf("scrollback after SU: %d lines", len(s.scrollback))
	}
	if got := s.TextRows(); got[0] != "T3" || got[1] != "" || got[2] != "" || got[3] != "V0" {
		t.Fatalf("rows after SU: %q", got)
	}
}

func TestVTScreenScrollbackAndClear(t *testing.T) {
	s := newTerminalScreen(20, 3)
	for i := 1; i <= 5; i++ {
		s.Write([]byte(fmt.Sprintf("row %d\r\n", i)))
	}
	if len(s.scrollback) != 3 || vtScrollbackText(s.scrollback[0]) != "row 1" || vtScrollbackText(s.scrollback[2]) != "row 3" {
		t.Fatalf("scrollback: %d lines", len(s.scrollback))
	}
	if got := s.TextRows(); got[0] != "row 4" || got[1] != "row 5" || got[2] != "" {
		t.Fatalf("screen after scroll: %q", got)
	}
	vtRoundTrip(t, s)
	s.Write([]byte("\x1b[3J"))
	if len(s.scrollback) != 0 {
		t.Fatal("ED 3 must clear the scrollback")
	}
	s.Write([]byte("\x1b[?1049h\x1b[Halt\r\n\r\n\r\n\r\n"))
	if len(s.scrollback) != 0 {
		t.Fatal("alternate screen must not scroll into the scrollback")
	}
	if got := s.TextRows(); got[0] != "" {
		t.Fatalf("alternate screen scrolled: %q", got)
	}
	s.Write([]byte("\x1b[?1049l"))
	if got := s.TextRows(); got[0] != "row 4" || got[1] != "row 5" {
		t.Fatalf("leaving 1049 must restore the main screen: %q", got)
	}
}

func TestVTScreenScrollbackBounded(t *testing.T) {
	s := newTerminalScreen(10, 2)
	for i := 0; i < vtScrollbackLimit+50; i++ {
		s.Write([]byte(fmt.Sprintf("%d\r\n", i)))
	}
	if len(s.scrollback) != vtScrollbackLimit {
		t.Fatalf("scrollback length %d", len(s.scrollback))
	}
	if vtScrollbackText(s.scrollback[0]) != "49" {
		t.Fatalf("oldest retained line %q", vtScrollbackText(s.scrollback[0]))
	}
}

func TestVTScreenTabs(t *testing.T) {
	s := newTerminalScreen(24, 1)
	s.Write([]byte("\tA\x1b[1;12H\x1bH\x1b[1;1H\t\tB"))
	if got := s.TextRows()[0]; got != "        A  B" {
		t.Fatalf("tab stops: %q", got)
	}
	s.Write([]byte("\x1b[1;20H\x1b[2ZC"))
	if got := s.TextRows()[0]; got != "        A  C" {
		t.Fatalf("CBT: %q", got)
	}
	s.Write([]byte("\x1b[3g\x1b[1;1H\tD"))
	if got := s.TextRows()[0]; got != "        A  C"+strings.Repeat(" ", 11)+"D" {
		t.Fatalf("TBC 3 leaves no stops: %q", got)
	}
}

func TestVTScreenInsertMode(t *testing.T) {
	s := newTerminalScreen(6, 1)
	s.Write([]byte("abcd\x1b[1;2H\x1b[4hXY\x1b[4l"))
	if got := s.TextRows()[0]; got != "aXYbcd" {
		t.Fatalf("IRM: %q", got)
	}
}

func TestVTScreenSGRParsing(t *testing.T) {
	s := newTerminalScreen(10, 1)
	s.Write([]byte("\x1b[1;3;4:3;38;2;10;20;30;48;5;200;58:2::1:2:3mX"))
	cell := s.grid().rows[0][0]
	want := vtAttrs{
		fg:      vtColor{kind: vtColorRGB, r: 10, g: 20, b: 30},
		bg:      vtColor{kind: vtColorIndexed, index: 200},
		ul:      vtColor{kind: vtColorRGB, r: 1, g: 2, b: 3},
		flags:   vtAttrBold | vtAttrItalic,
		ulStyle: 3,
	}
	if cell.attrs != want {
		t.Fatalf("SGR attrs: %+v", cell.attrs)
	}
	s.Write([]byte("\x1b[22;23;24;39;49;59;91;103mY\x1b[0mZ"))
	cell = s.grid().rows[0][1]
	want = vtAttrs{fg: vtColor{kind: vtColorIndexed, index: 9}, bg: vtColor{kind: vtColorIndexed, index: 11}}
	if cell.attrs != want {
		t.Fatalf("SGR bright colours: %+v", cell.attrs)
	}
	if s.grid().rows[0][2].attrs != (vtAttrs{}) {
		t.Fatal("SGR 0 must reset")
	}
	vtRoundTrip(t, s)
}

func TestVTScreenSplitSequencesAndInvalidUTF8(t *testing.T) {
	s := newTerminalScreen(10, 2)
	s.Write([]byte("\x1b[38;2;10;"))
	s.Write([]byte("20;30mX\xe6\xbc"))
	s.Write([]byte("\xa2\xffY\x1b]0;title"))
	s.Write([]byte(" more\x07Z\x1b[?10"))
	s.Write([]byte("49h\x1b[2J\x1b[HQ"))
	if !s.AlternateScreenActive() {
		t.Fatal("split private mode was not applied")
	}
	if got := s.TextRows()[0]; got != "Q" {
		t.Fatalf("alternate screen content: %q", got)
	}
	s.Write([]byte("\x1b[?1049l"))
	if got := s.TextRows()[0]; got != "X漢�YZ" {
		t.Fatalf("split sequences/UTF-8: %q", got)
	}
	if s.grid().rows[0][0].attrs.fg != (vtColor{kind: vtColorRGB, r: 10, g: 20, b: 30}) {
		t.Fatal("split SGR lost its colour")
	}
	// A Kitty graphics APC is skipped entirely, even across writes.
	s.Write([]byte("\x1b_Ga=T,f=100;AAAA"))
	s.Write([]byte("BBBB\x1b\\!"))
	if got := s.TextRows()[0]; got != "X漢�YZ!" {
		t.Fatalf("APC payload leaked: %q", got)
	}
}

func TestVTScreenDECGraphicsAndCharsets(t *testing.T) {
	s := newTerminalScreen(10, 1)
	s.Write([]byte("\x1b(0lqk\x1b(B|\x1b)0\x0ex\x0f|"))
	if got := s.TextRows()[0]; got != "┌─┐|│|" {
		t.Fatalf("DEC graphics: %q", got)
	}
	vtRoundTrip(t, s)
}

func TestVTScreenSaveRestoreAndAlternate1049(t *testing.T) {
	s := newTerminalScreen(10, 3)
	s.Write([]byte("main\x1b[2;3H\x1b[31m\x1b7\x1b[?1049hALT\x1b[?1049lX"))
	if got := s.TextRows(); got[0] != "main" || got[1] != "  X" {
		t.Fatalf("1049 must restore cursor and screen: %q", got)
	}
	if s.grid().rows[1][2].attrs.fg != (vtColor{kind: vtColorIndexed, index: 1}) {
		t.Fatal("1049 exit must restore the saved rendition")
	}
	s.Write([]byte("\x1b8Y"))
	if got := s.TextRows()[1]; got != "  Y" {
		t.Fatalf("DECRC: %q", got)
	}
	s.Write([]byte("\x1b[?47h\x1b[2J\x1b[Halt2"))
	if got := s.TextRows()[0]; got != "alt2" {
		t.Fatalf("mode 47 switches: %q", got)
	}
	s.Write([]byte("\x1b[?47l"))
	if got := s.TextRows()[0]; got != "main" {
		t.Fatalf("mode 47 exit: %q", got)
	}
}

func TestVTScreenResize(t *testing.T) {
	s := newTerminalScreen(10, 4)
	s.Write([]byte("one\r\ntwo\r\nthree\r\nfour"))
	s.Resize(3, 2)
	if got := s.TextRows(); len(got) != 2 || got[0] != "thr" || got[1] != "fou" {
		t.Fatalf("shrink keeps the cursor row: %q", got)
	}
	if r, c := s.CursorPosition(); r != 1 || c != 2 {
		t.Fatalf("cursor after shrink: (%d,%d)", r, c)
	}
	if len(s.scrollback) != 2 || vtScrollbackText(s.scrollback[1]) != "two" {
		t.Fatalf("rows leaving the top enter the scrollback: %d", len(s.scrollback))
	}
	s.Resize(8, 5)
	if got := s.TextRows(); len(got) != 5 || got[0] != "thr" || got[4] != "" {
		t.Fatalf("grow extends with blanks: %q", got)
	}
	if s.bottom != 4 {
		t.Fatal("resize must reset the scroll region")
	}
	s.Write([]byte("\x1b[?1049h\x1b[HALT"))
	s.Resize(4, 3)
	if got := s.TextRows(); got[0] != "ALT" {
		t.Fatalf("alternate grid resize: %q", got)
	}
	if len(s.scrollback) != 2 {
		t.Fatal("alternate grid rows must not enter the scrollback")
	}
}

func TestVTScreenResetAndClone(t *testing.T) {
	s := newTerminalScreen(10, 2)
	s.Write([]byte("abc\r\nline\r\n\x1b[31m\x1b[2;5r\x1b[?6h"))
	clone := s.Clone()
	s.Write([]byte("\x1bc"))
	if s.HasVisibleContent() || s.attrs != (vtAttrs{}) || s.originMode || s.bottom != 1 {
		t.Fatal("RIS must clear the grid and modes")
	}
	if len(s.scrollback) != 1 {
		t.Fatal("RIS keeps the scrollback")
	}
	if !clone.HasVisibleContent() || clone.attrs.fg.kind != vtColorIndexed || !clone.originMode {
		t.Fatal("clone must be independent of the original")
	}
	clone.Write([]byte("zzz"))
	if s.HasVisibleContent() {
		t.Fatal("writing to the clone must not affect the original")
	}
}

func TestVTScreenHasVisibleContent(t *testing.T) {
	s := newTerminalScreen(5, 2)
	if s.HasVisibleContent() {
		t.Fatal("empty screen is not visible")
	}
	s.Write([]byte("\x1b[44m \x1b[0m"))
	if !s.HasVisibleContent() {
		t.Fatal("a coloured blank is visible")
	}
	s.Write([]byte("\x1b[2J"))
	s.Write([]byte("\x1b[H   "))
	if s.HasVisibleContent() {
		t.Fatal("plain spaces are not visible")
	}
}

// inkLikeFrames builds the shapes that agent CLIs emit: a header, a body of
// transcript rows, a composer at the bottom, then incremental synchronized
// updates that touch only the bottom rows.
func inkLikeFrames(width, height int, alternate bool) [][]byte {
	var frames [][]byte
	var b bytes.Buffer
	if alternate {
		b.WriteString("\x1b[?1049h")
	}
	b.WriteString("\x1b[?2026h\x1b[?25l\x1b[2J\x1b[H")
	b.WriteString("\x1b[38;2;215;119;87m ▐▛███▛█\x1b[12G\x1b[39m\x1b[1mClaude Code\x1b[22m v9\r\n")
	for r := 2; r < height-6; r++ {
		fmt.Fprintf(&b, "\x1b[%d;1H\x1b[2m⏺\x1b[22m transcript line %d: lorem ipsum ─ 漢字 é́", r, r)
	}
	fmt.Fprintf(&b, "\x1b[%d;1H\x1b[38;2;136;136;136m%s", height-3, strings.Repeat("─", width))
	fmt.Fprintf(&b, "\x1b[%d;1H\x1b[39m❯ ", height-2)
	fmt.Fprintf(&b, "\x1b[%d;1H\x1b[38;2;136;136;136m%s\x1b[0m", height-1, strings.Repeat("─", width))
	fmt.Fprintf(&b, "\x1b[%d;3H\x1b[?25h\x1b[?2026l", height-2)
	frames = append(frames, append([]byte(nil), b.Bytes()...))
	for tick := 0; tick < 5; tick++ {
		b.Reset()
		fmt.Fprintf(&b, "\x1b[?2026h\x1b[?25l\x1b[%d;1H\x1b[2K\x1b[38;2;255;193;7m✻ Working… (%d)\x1b[0m", height-5, tick)
		fmt.Fprintf(&b, "\x1b[%d;1H\x1b[2K\x1b[48;2;20;20;20m  status %d %s\x1b[0m", height, tick, strings.Repeat("·", 30))
		fmt.Fprintf(&b, "\x1b[%d;3H\x1b[?25h\x1b[?2026l", height-2)
		frames = append(frames, append([]byte(nil), b.Bytes()...))
	}
	return frames
}

func TestVTScreenRenderRoundTrip(t *testing.T) {
	cases := []struct {
		name  string
		build func() *terminalScreen
	}{
		{"ink alternate", func() *terminalScreen {
			s := newTerminalScreen(69, 55)
			for _, frame := range inkLikeFrames(69, 55, true) {
				s.Write(frame)
			}
			return s
		}},
		{"ink main with scrollback", func() *terminalScreen {
			s := newTerminalScreen(69, 30)
			for i := 0; i < 80; i++ {
				s.writeFormatted("\x1b[3%dmstatic transcript line %d\x1b[0m\r\n", i%8, i)
			}
			for _, frame := range inkLikeFrames(69, 30, false) {
				s.Write(frame)
			}
			return s
		}},
		{"region, origin mode, rendition, charset", func() *terminalScreen {
			s := newTerminalScreen(40, 12)
			s.Write([]byte("top line\x1b[3;10r\x1b[?6h\x1b[1;1Hinside\x1b[7;5H\x1b[1;31;44mcoloured tail\x1b[4:3m\x1b(0lq\x0e"))
			return s
		}},
		{"full rows with wide glyph at the edge", func() *terminalScreen {
			s := newTerminalScreen(7, 3)
			s.Write([]byte("abcdefg漢字漢字\x1b[3;1H\x1b[42m       \x1b[0m"))
			return s
		}},
		{"pending wrap, saved cursor, tabs, insert mode", func() *terminalScreen {
			s := newTerminalScreen(12, 4)
			s.Write([]byte("\x1b[3g\x1b[1;5H\x1bH\x1b[2;3H\x1b[33m\x1b7\x1b[0m\x1b[4h\x1b[1;1Habcdefghijkl"))
			return s
		}},
		{"saved cursor with origin mode and charsets", func() *terminalScreen {
			s := newTerminalScreen(20, 8)
			s.Write([]byte("\x1b[3;6r\x1b[?6h\x1b[2;4H\x1b[1;35m\x1b(0\x1b)0\x0e\x1b7\x1b[0m\x0f\x1b(B\x1b[1;1Hqq\x1b[5;2H\x1b[s"))
			return s
		}},
		{"pending wrap after a wide glyph", func() *terminalScreen {
			s := newTerminalScreen(6, 2)
			s.Write([]byte("abcd漢"))
			return s
		}},
		{"blank rows with background", func() *terminalScreen {
			s := newTerminalScreen(10, 4)
			s.Write([]byte("\x1b[48;5;17m\x1b[2J\x1b[2;2Hx\x1b[0m"))
			return s
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			vtRoundTrip(t, tc.build())
		})
	}
}

// Write implements io.Writer for test convenience.
func (s *terminalScreen) WriteString(text string) (int, error) {
	s.Write([]byte(text))
	return len(text), nil
}

func (s *terminalScreen) writeFormatted(format string, args ...any) {
	s.Write([]byte(fmt.Sprintf(format, args...)))
}

func TestVTScreenRenderFrameIsSelfContained(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte("hello\r\nworld\x1b[2;3H"))
	frame := s.RenderFrame()
	// Applying the frame on top of unrelated content must give the same picture.
	dirty := newTerminalScreen(20, 4)
	dirty.Write([]byte("\x1b[41mGARBAGE GARBAGE GARB\r\nGARBAGE GARBAGE GARB\r\nGARBAGE GARBAGE GARB\r\nGARBAGE GARBAGE GARB\x1b[3;8r\x1b[?6h"))
	dirty.Write([]byte("\x1b[?6l\x1b[r\x1b[0m"))
	dirty.Write(frame)
	if !vtRowsEqual(s.grid().rows, dirty.grid().rows) {
		t.Fatalf("frame depended on previous content:\n%s", vtText(t, dirty))
	}
	if r, c := dirty.CursorPosition(); r != 1 || c != 2 {
		t.Fatalf("cursor after frame: (%d,%d)", r, c)
	}
	if bytes.Contains(frame, []byte("\x1b[?25")) || bytes.Contains(frame, []byte("\x1b[?1049")) {
		t.Fatal("frame must not toggle cursor visibility or the alternate screen")
	}
}

// TestVTScreenDumpFile is a diagnostic helper: MONKEYMUX_VT_DUMP=<file>
// MONKEYMUX_VT_SIZE=<cols>x<rows> prints the screen a captured byte stream
// produces, for differential checks against other emulators.
func TestVTScreenDumpFile(t *testing.T) {
	path := os.Getenv("MONKEYMUX_VT_DUMP")
	if path == "" {
		t.Skip("MONKEYMUX_VT_DUMP not set")
	}
	cols, rows := 80, 24
	if size := os.Getenv("MONKEYMUX_VT_SIZE"); size != "" {
		if _, err := fmt.Sscanf(size, "%dx%d", &cols, &rows); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := newTerminalScreen(cols, rows)
	s.Write(data)
	r, c := s.CursorPosition()
	fmt.Printf("size=%dx%d bytes=%d cursor=(%d,%d) alt=%v scrollback=%d\n", cols, rows, len(data), r, c, s.AlternateScreenActive(), len(s.scrollback))
	for i, row := range s.TextRows() {
		fmt.Printf("%3d|%s\n", i, row)
	}
	if os.Getenv("MONKEYMUX_VT_ROUNDTRIP") != "" {
		vtRoundTrip(t, s)
	}
}

func TestVTScreenPendingWrapSurvivesFrame(t *testing.T) {
	s := newTerminalScreen(5, 3)
	s.Write([]byte("abcde"))
	replica := newTerminalScreen(5, 3)
	replica.Write([]byte("\x1b[?6l\x1b[r\x1b[0m\x1b[?7h"))
	replica.Write(s.RenderFrame())
	s.Write([]byte("X"))
	replica.Write([]byte("X"))
	if got := replica.TextRows(); got[0] != "abcde" || got[1] != "X" {
		t.Fatalf("client did not defer the wrap like the model: %q", got)
	}
}

func TestVTScreenSavedCursorSurvivesFrame(t *testing.T) {
	s := newTerminalScreen(10, 4)
	s.Write([]byte("\x1b[3;5H\x1b7\x1b[1;1Hhi"))
	replica := newTerminalScreen(10, 4)
	replica.Write([]byte("\x1b[?6l\x1b[r\x1b[0m"))
	replica.Write(s.RenderFrame())
	replica.Write([]byte("\x1b8Z"))
	if got := replica.TextRows(); got[2] != "    Z" || got[0] != "hi" {
		t.Fatalf("DECRC after the frame landed elsewhere: %q", got)
	}
}

func TestVTScreenRepeatSoftResetAndAlignment(t *testing.T) {
	s := newTerminalScreen(10, 3)
	s.Write([]byte("\x1b(0q\x1b[4b\x1b(B"))
	if got := s.TextRows()[0]; got != "─────" {
		t.Fatalf("REP: %q", got)
	}
	s.Write([]byte("\x1b[2;3r\x1b[?6h\x1b[4h\x1b[31m\x1b[!p"))
	if s.top != 0 || s.bottom != 2 || s.originMode || s.insertMode || s.attrs != (vtAttrs{}) {
		t.Fatal("DECSTR did not reset region, modes and rendition")
	}
	s.Write([]byte("\x1b#8"))
	if got := s.TextRows(); got[0] != "EEEEEEEEEE" || got[2] != "EEEEEEEEEE" {
		t.Fatalf("DECALN: %q", got)
	}
}

func TestVTScreenRawC1AndMode47(t *testing.T) {
	s := newTerminalScreen(10, 2)
	s.Write([]byte("abc\x9b2Jd"))
	if got := s.TextRows()[0]; got != "   d" {
		t.Fatalf("raw 8-bit CSI must act as CSI: %q", got)
	}
	s.Write([]byte("\x1b[?47h\x1b[HALT\x1b[?47l\x1b[?47h"))
	if got := s.TextRows()[0]; got != "ALT" {
		t.Fatalf("mode 47 must keep the alternate screen: %q", got)
	}
}

func TestVTScreenInsertCharsSplitsWideGlyphSafely(t *testing.T) {
	s := newTerminalScreen(8, 1)
	s.Write([]byte("a漢bcde\x1b[1;3H\x1b[2@"))
	for i, cell := range s.grid().rows[0] {
		if cell.width == 2 && (i+1 >= 8 || s.grid().rows[0][i+1].width != 0) {
			t.Fatalf("wide glyph at %d lost its continuation cell", i)
		}
	}
	vtRoundTrip(t, s)
}

func TestVTScreenASCIIFastPathMatchesSlowPath(t *testing.T) {
	inputs := []string{
		"hello world, this is a plain run of text that wraps around the row end",
		"\x1b[4hinsert\x1b[4l mode",
		"\x1b(0lqqk\x1b(B plain",
		"a漢b" + strings.Repeat("x", 30) + "\x1b[2;3Htail",
	}
	for _, input := range inputs {
		fast := newTerminalScreen(20, 4)
		fast.Write([]byte(input))
		slow := newTerminalScreen(20, 4)
		for _, b := range []byte(input) {
			slow.step(b)
		}
		if !vtRowsEqual(fast.grid().rows, slow.grid().rows) {
			t.Fatalf("fast path diverged for %q:\n%s\nvs\n%s", input, vtText(t, fast), vtText(t, slow))
		}
		fr, fc := fast.CursorPosition()
		sr, sc := slow.CursorPosition()
		if fr != sr || fc != sc || fast.grid().pendingWrap != slow.grid().pendingWrap {
			t.Fatalf("fast path cursor diverged for %q", input)
		}
	}
}

func TestVTScreenScrollbackRowsAreTrimmed(t *testing.T) {
	s := newTerminalScreen(200, 2)
	s.Write([]byte("hi\r\n\x1b[31mred\x1b[0m\r\n\r\n"))
	if got := string(s.scrollback[0]); got != "hi" {
		t.Fatalf("scrollback line retained %q, want the used prefix", got)
	}
	if got := string(s.scrollback[1]); got != "\x1b[0;31mred" {
		t.Fatalf("scrollback line lost its rendition: %q", got)
	}
	vtRoundTrip(t, s)
}

func TestVTScreenBounds(t *testing.T) {
	s := newTerminalScreen(1<<20, 1<<20)
	if w, h := s.Size(); w*h > vtMaxCells || w > vtMaxColumns || h > vtMaxRows {
		t.Fatalf("size not clamped: %dx%d", w, h)
	}
	s.Resize(100000, 3)
	if w, _ := s.Size(); w != vtMaxColumns {
		t.Fatalf("resize not clamped: %d", w)
	}
	s = newTerminalScreen(10, 2)
	// The final byte that ends an over-long sequence is consumed with it.
	s.Write([]byte("\x1b" + strings.Repeat(" ", 1000) + "8xY"))
	if len(s.parser.intermediates) > vtIntermediateLimit {
		t.Fatal("intermediates unbounded")
	}
	if got := s.TextRows()[0]; got != "Y" {
		t.Fatalf("oversized sequence was not ignored cleanly: %q", got)
	}
	s.Write([]byte("\x1b[" + strings.Repeat("!", 1000) + "p"))
	s.Write([]byte("e" + strings.Repeat("\u0301", 100)))
	if got := len(s.grid().rows[0][1].comb); got != vtCombiningLimit {
		t.Fatalf("combining marks unbounded: %d", got)
	}
}

func TestVTScreenC1TerminatorInsideStrings(t *testing.T) {
	s := newTerminalScreen(20, 2)
	// ✳ is E2 9C B3: the 9C inside it must not end the title.
	s.Write([]byte("\x9d0;\xe2\x9c\xb3 Claude\x9cok\x1b]2;title\x9c!\x1bPdata\x9c?"))
	if got := s.TextRows()[0]; got != "ok!?" {
		t.Fatalf("C1 ST handling: %q", got)
	}
}

func TestVTScreenInsertModeKeepsWidePairs(t *testing.T) {
	s := newTerminalScreen(6, 1)
	s.Write([]byte("ab漢cd\x1b[1;1H\x1b[4hX"))
	row := s.grid().rows[0]
	for i, cell := range row {
		if cell.width == 2 && (i+1 >= len(row) || row[i+1].width != 0) {
			t.Fatalf("wide lead at %d lost its continuation: %q", i, s.TextRows()[0])
		}
		if cell.width == 0 && (i == 0 || row[i-1].width != 2) {
			t.Fatalf("orphan continuation at %d: %q", i, s.TextRows()[0])
		}
	}
	if got := s.TextRows()[0]; got != "Xab漢c" {
		t.Fatalf("insert shifted wrongly: %q", got)
	}
	s.Write([]byte("\x1b[4l\x1b[1;4HY"))
	if got := s.TextRows()[0]; got != "XabY c" {
		t.Fatalf("splitting a shifted pair: %q", got)
	}
	vtRoundTrip(t, s)
}

func TestVTScreenFrameRebuildsDefaultTabStops(t *testing.T) {
	client := newTerminalScreen(20, 1)
	client.Write([]byte("\x1b[3g\x1b[1;3H\x1bH"))
	client.Write(newTerminalScreen(20, 1).RenderFrame())
	client.Write([]byte("\x1b[1;1H\tX"))
	if got := client.TextRows()[0]; got != "        X" {
		t.Fatalf("frame left the client's custom tab stops: %q", got)
	}
}

// TestKittyPlaceholderDiacriticsMatchClient keeps the model's zero-width
// placeholder marks identical to the vendored client's list, so a placeholder
// grid lays out the same on both sides.
func TestKittyPlaceholderDiacriticsMatchClient(t *testing.T) {
	source, err := os.ReadFile("../../third_party/xterm/lib/src/terminal.dart")
	if err != nil {
		t.Skipf("client source unavailable: %v", err)
	}
	text := string(source)
	start := strings.Index(text, "const _kittyPlaceholderDiacritics = <int>[")
	if start < 0 {
		t.Fatal("client diacritic list not found")
	}
	body := text[start:]
	body = body[:strings.Index(body, "];")]
	want := map[rune]bool{}
	for _, field := range strings.Fields(strings.ReplaceAll(body, ",", " ")) {
		if strings.HasPrefix(field, "0x") {
			var value int
			if _, err := fmt.Sscanf(field, "0x%x", &value); err == nil {
				want[rune(value)] = true
			}
		}
	}
	if len(want) == 0 {
		t.Fatal("client diacritic list is empty")
	}
	got := map[rune]bool{}
	for i, r := range kittyPlaceholderDiacritics {
		got[r] = true
		if i > 0 && kittyPlaceholderDiacritics[i-1] >= r {
			t.Fatalf("diacritic list is not sorted at %#x", r)
		}
		if runeWidth(r) != 0 {
			t.Fatalf("placeholder diacritic %#x is not zero width", r)
		}
		if !want[r] {
			t.Fatalf("model lists %#x, client does not", r)
		}
	}
	for r := range want {
		if !got[r] {
			t.Fatalf("client lists %#x, model does not", r)
		}
	}
	// A placeholder row: the base glyph carries row/column marks the client
	// swallows, so the next placeholder lands in the adjacent cell.
	s := newTerminalScreen(6, 1)
	s.Write([]byte("\U0010EEEE\u07EB\u0305\U0010EEEE\u07EB\u030DX"))
	if r, c := s.CursorPosition(); r != 0 || c != 3 {
		t.Fatalf("placeholder marks advanced the cursor: col %d", c)
	}
}

func TestVTScreenScrollbackByteBudget(t *testing.T) {
	s := newTerminalScreen(4000, 2)
	// Each scrolled line alternates truecolor renditions per cell, so a single
	// line renders to well over 50 KB.
	var line strings.Builder
	for i := 0; i < 4000; i++ {
		fmt.Fprintf(&line, "\x1b[38;2;%d;%d;%dmx", i%256, (i*7)%256, (i*13)%256)
	}
	for i := 0; i < 60; i++ {
		s.Write([]byte(line.String() + "\x1b[0m\r\n"))
	}
	if s.scrollbackBytes > vtScrollbackByteLimit || len(s.scrollback) == 0 {
		t.Fatalf("scrollback holds %d bytes in %d lines", s.scrollbackBytes, len(s.scrollback))
	}
	total := 0
	for _, kept := range s.scrollback {
		total += len(kept)
	}
	if total != s.scrollbackBytes {
		t.Fatalf("byte accounting drifted: %d vs %d", total, s.scrollbackBytes)
	}
	s.Write([]byte("\x1b[3J"))
	if s.scrollbackBytes != 0 {
		t.Fatal("ED 3 must reset the byte accounting")
	}
}

// TestVTScreenTracksKittyPlaceholderImageIDs covers the gap a rendered frame
// leaves: the parser skips APC strings, so RenderFrame reproduces the unicode
// placeholder cells but not the image transmissions that fill them. The model
// therefore has to report which images the frame still needs.
func TestVTScreenTracksKittyPlaceholderImageIDs(t *testing.T) {
	s := newTerminalScreen(20, 3)
	const transmit = "\x1b_Ga=T,f=100,c=2,r=1,q=2,i=4822;PAYLOADBYTES\x1b\\"
	// An RGB foreground carries the low 24 bits of the image id:
	// 0<<16 | 18<<8 | 214 == 4822.
	s.Write([]byte(transmit + "\x1b[38;2;0;18;214m" +
		"\U0010EEEE̅̅\U0010EEEE̅̍"))
	if got := s.PlaceholderImageIDs(); len(got) != 1 || got[0] != "4822" {
		t.Fatalf("RGB placeholder ids = %v, want [4822]", got)
	}
	frame := string(s.RenderFrame())
	if !strings.Contains(frame, "\U0010EEEE") {
		t.Fatal("frame lost the placeholder cells")
	}
	if strings.Contains(frame, "PAYLOADBYTES") {
		t.Fatal("frame now carries the transmission; the id set is unnecessary")
	}

	// An indexed foreground carries only the low 8 bits.
	s.Write([]byte("\r\n\x1b[38;5;42m\U0010EEEE̅̅"))
	// A third diacritic supplies bits 24-31: index 1 in the diacritic table.
	s.Write([]byte("\r\n\x1b[38;2;1;0;0m\U0010EEEE̅̅̍"))
	want := []string{"4822", "42", "16842752"}
	if got := s.PlaceholderImageIDs(); !reflect.DeepEqual(got, want) {
		t.Fatalf("placeholder ids = %v, want %v", got, want)
	}

	// A following cell with the same colours belongs to the same image, so it
	// inherits the high byte rather than resolving to the low id alone.
	s.Write([]byte("\U0010EEEE̅̒ tail text"))
	if got := s.PlaceholderImageIDs(); !reflect.DeepEqual(got, want) {
		t.Fatalf("continuation cell changed the id set: %v", got)
	}

	clone := s.Clone()
	clone.Write([]byte("\r\n\x1b[38;5;9m\U0010EEEE̅̅"))
	if got := clone.PlaceholderImageIDs(); !reflect.DeepEqual(got, append(append([]string(nil), want...), "9")) {
		t.Fatalf("clone placeholder ids = %v", got)
	}
	if got := s.PlaceholderImageIDs(); !reflect.DeepEqual(got, want) {
		t.Fatalf("writing to the clone changed the original: %v", got)
	}

	// An erased screen, and even RIS, still reproduce the main-screen
	// scrollback, so the ids stay with it.
	s.Write([]byte("\x1b[2J\x1b[?1049h\x1b[?1049l"))
	if got := s.PlaceholderImageIDs(); !reflect.DeepEqual(got, want) {
		t.Fatalf("clearing the screen dropped the placeholder ids: %v", got)
	}
	s.Write([]byte("\x1bc"))
	if got := s.PlaceholderImageIDs(); !reflect.DeepEqual(got, want) {
		t.Fatalf("RIS dropped the placeholder ids: %v", got)
	}
}

func TestVTScreenPlaceholderImageIDsAreBounded(t *testing.T) {
	s := newTerminalScreen(20, 2)
	for i := 1; i <= vtKittyPlaceholderIDLimit+16; i++ {
		s.Write([]byte(fmt.Sprintf("\x1b[38;2;%d;%d;%dm\U0010EEEE̅̅",
			(i>>16)&0xFF, (i>>8)&0xFF, i&0xFF)))
	}
	got := s.PlaceholderImageIDs()
	if len(got) != vtKittyPlaceholderIDLimit {
		t.Fatalf("retained %d placeholder ids, want %d", len(got), vtKittyPlaceholderIDLimit)
	}
	if got[0] != "17" || got[len(got)-1] != fmt.Sprint(vtKittyPlaceholderIDLimit+16) {
		t.Fatalf("oldest ids were not evicted first: %q..%q", got[0], got[len(got)-1])
	}
}
