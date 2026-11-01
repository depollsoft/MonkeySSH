package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

type graphemeParityCase struct {
	Name    string     `json:"name"`
	Size    [2]int     `json:"size"`
	Write   string     `json:"write"`
	Rows    [][]string `json:"rows"`
	Cursor  [3]any     `json:"cursor"`
	Wrapped []int      `json:"wrapped"`
}

// graphemeParityState is a screen as testdata/grapheme_cluster_parity.json
// describes it: each viewport row's cells up to the last one that is not
// empty (a glyph's code points, "<" for a wide glyph's second half, "" for an
// empty cell), the cursor, and the rows that soft-wrap from the row above.
type graphemeParityState struct {
	rows    [][]string
	cursor  [3]any
	wrapped []int
}

func dumpGraphemeParity(s *terminalScreen) graphemeParityState {
	g := s.grid()
	state := graphemeParityState{
		rows:    make([][]string, len(g.rows)),
		cursor:  [3]any{float64(g.cursorRow), float64(g.cursorCol), g.pendingWrap},
		wrapped: []int{},
	}
	for r, row := range g.rows {
		cells := []string{}
		for _, cell := range row {
			switch {
			case cell.width == 0:
				cells = append(cells, "<")
			case cell.r == 0:
				cells = append(cells, "")
			default:
				cells = append(cells, string(cell.r)+string(cell.comb))
			}
		}
		for len(cells) > 0 && cells[len(cells)-1] == "" {
			cells = cells[:len(cells)-1]
		}
		state.rows[r] = cells
		if g.wrapped[r] {
			state.wrapped = append(state.wrapped, r)
		}
	}
	return state
}

func (c graphemeParityCase) expected(height int) graphemeParityState {
	state := graphemeParityState{rows: make([][]string, height), cursor: c.Cursor, wrapped: c.Wrapped}
	for r := range state.rows {
		state.rows[r] = []string{}
		if r < len(c.Rows) {
			state.rows[r] = c.Rows[r]
		}
	}
	return state
}

func loadGraphemeParityCases(t *testing.T) []graphemeParityCase {
	t.Helper()
	data, err := os.ReadFile("testdata/grapheme_cluster_parity.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []graphemeParityCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	return cases
}

// TestGraphemeClusterParityWithClient runs the cases the client's
// grapheme_cluster_parity_test.dart runs, and expects the same cells, cursor
// and soft wraps.
func TestGraphemeClusterParityWithClient(t *testing.T) {
	for _, c := range loadGraphemeParityCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			s := newTerminalScreen(c.Size[0], c.Size[1])
			s.Write([]byte(c.Write))
			if got, want := dumpGraphemeParity(s), c.expected(c.Size[1]); !reflect.DeepEqual(got, want) {
				t.Fatalf("model differs from the client\n got: %q %v %v\nwant: %q %v %v",
					got.rows, got.cursor, got.wrapped, want.rows, want.cursor, want.wrapped)
			}
		})
	}
}

// TestGraphemeClusterParityFramesRepaintTheCells paints each case's screen
// from the model's frame onto a fresh model, whichever mode 2027 it was in,
// and onto one that received a whole window replay: every one must end with
// the same cells and cursor, and in the model's mode.
func TestGraphemeClusterParityFramesRepaintTheCells(t *testing.T) {
	for _, c := range loadGraphemeParityCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			s := newTerminalScreen(c.Size[0], c.Size[1])
			s.Write([]byte(c.Write))
			want := dumpGraphemeParity(s)
			frame := s.RenderFrame()
			for _, initial := range []string{"\x1b[?2027h", "\x1b[?2027l"} {
				replica := newTerminalScreen(c.Size[0], c.Size[1])
				replica.Write([]byte(initial))
				replica.Write(frame)
				if got := dumpGraphemeParity(replica); !reflect.DeepEqual(got, want) {
					t.Fatalf("frame %q after %q\n got: %q %v\nwant: %q %v", frame, initial, got.rows, got.cursor, want.rows, want.cursor)
				}
				if replica.graphemeCluster != s.graphemeCluster {
					t.Fatalf("frame after %q leaves mode 2027 %v, want %v", initial, replica.graphemeCluster, s.graphemeCluster)
				}
			}
			replica := replayFrame(s)
			if got := dumpGraphemeParity(replica); !reflect.DeepEqual(got.rows, want.rows) || got.cursor != want.cursor {
				t.Fatalf("replay\n got: %q %v\nwant: %q %v", got.rows, got.cursor, want.rows, want.cursor)
			}
			if replica.graphemeCluster != s.graphemeCluster {
				t.Fatalf("replay leaves mode 2027 %v, want %v", replica.graphemeCluster, s.graphemeCluster)
			}
		})
	}
}

// graphemeRows returns the parity dump of the active grid's rows.
func graphemeRows(s *terminalScreen) [][]string {
	return dumpGraphemeParity(s).rows
}

// TestGraphemeStartWidthDiffersOnlyFromNoWidth pins what print and
// planVTSingleGlyph rely on to look up a code point's width once: a cluster
// starts at the code point's own width unless that is 0.
func TestGraphemeStartWidthDiffersOnlyFromNoWidth(t *testing.T) {
	for r := rune(0); r <= 0x10FFFF; r++ {
		if width := runeWidth(r); width != 0 && graphemeStartWidth(r) != width {
			t.Fatalf("%U starts %d columns wide, not its width %d", r, graphemeStartWidth(r), width)
		}
	}
}

func TestGraphemeClusterModeDefaultsAndResets(t *testing.T) {
	s := newTerminalScreen(10, 2)
	if !s.graphemeCluster {
		t.Fatal("clustering is off on a new screen")
	}
	s.Write([]byte("\x1b[1;1H\x1b[?2027l"))
	if s.graphemeCluster {
		t.Fatal("CSI ? 2027 l left clustering on")
	}
	if _, ok := s.CursorPositionReport(); !ok {
		t.Fatal("mode 2027 lost the known cursor")
	}
	s.Write([]byte("\x1b[!p"))
	if s.graphemeCluster || s.Clone().graphemeCluster {
		t.Fatal("DECSTR or a clone turned clustering back on")
	}
	s.Write([]byte("\x1bc"))
	if !s.graphemeCluster {
		t.Fatal("RIS left clustering off")
	}
	s.Write([]byte("\x1b[?2027l\x1b[?2027h"))
	if !s.graphemeCluster {
		t.Fatal("CSI ? 2027 h left clustering off")
	}
}

// TestWindowTracksGraphemeClusterMode covers the copy of mode 2027 a window
// keeps for its replays and its snapshot: RIS sets it again, DECSTR keeps it,
// and an upgrade restore carries it like the other display modes.
func TestWindowTracksGraphemeClusterMode(t *testing.T) {
	window := &muxWindow{}
	window.observeTerminalModesLocked([]byte("\x1b[?2027l"))
	if enabled, ok := window.privateModes["2027"]; !ok || enabled {
		t.Fatalf("modes after CSI ? 2027 l = %v", window.privateModes)
	}
	window.observeTerminalModesLocked([]byte("\x1b[!p"))
	if window.privateModes["2027"] {
		t.Fatal("DECSTR turned clustering back on")
	}
	if restored := privateModesForRestore(window.privateModes); restored["2027"] || len(restored) != 1 {
		t.Fatalf("restore keeps %v", restored)
	}
	window.observeTerminalModesLocked([]byte("\x1bc"))
	if !window.privateModes["2027"] {
		t.Fatal("RIS left clustering off")
	}
}

// TestWindowReplayRestoresGraphemeClusterMode covers a window whose program
// turned clustering off before the history a replay paints, as an upgrade
// restore leaves it: the model reads that history in that mode, and the
// replay sets it before the history, after its prefix put back the default
// for windows that never changed it.
func TestWindowReplayRestoresGraphemeClusterMode(t *testing.T) {
	server := newMuxServerWithSize("test", 10, 3)
	legacy := &muxWindow{
		id: "@1", index: 0, lastActivity: time.Now(), screenWidth: 10, screenHeight: 3,
		history:                   []byte("\U0001F468\u200d\U0001F469x"),
		historyGraphemeClusterOff: true,
		privateModes:              map[string]bool{"2027": false},
	}
	shell := &muxWindow{id: "@2", index: 1, lastActivity: time.Now(), history: []byte("\U0001F468\u200d\U0001F469x")}
	server.windows = []*muxWindow{legacy, shell}
	server.activeID = legacy.id
	server.mu.Lock()
	model := legacy.screenLocked()
	legacyReplay := string(buildWindowReplay(legacy, nil, legacy.history, false))
	shellReplay := string(buildWindowReplay(shell, nil, shell.history, false))
	server.mu.Unlock()

	want := [][]string{{"\U0001F468\u200d", "<", "\U0001F469", "<", "x"}, {}, {}}
	if got := graphemeRows(model); !reflect.DeepEqual(got, want) || model.graphemeCluster {
		t.Fatalf("model = %q, clustering %v; want %q in legacy mode", got, model.graphemeCluster, want)
	}
	if !strings.Contains(activeWindowReplayPrefix, "\x1b[?2027h") {
		t.Fatalf("replay prefix %q does not reset mode 2027", activeWindowReplayPrefix)
	}
	history := strings.LastIndex(legacyReplay, "\U0001F468")
	if reset := strings.LastIndex(legacyReplay[:history], "\x1b[?2027l"); reset < strings.Index(legacyReplay, activeWindowReplayPrefix) {
		t.Fatalf("replay %q does not reset mode 2027 after its prefix and before the history", legacyReplay)
	}
	client := newTerminalScreen(10, 3)
	client.Write([]byte(legacyReplay))
	if got := graphemeRows(client); !reflect.DeepEqual(got, want) || client.graphemeCluster {
		t.Fatalf("client = %q, clustering %v; want %q in legacy mode", got, client.graphemeCluster, want)
	}
	// Switching to a window that never changed the mode turns it back on.
	client.Write([]byte(shellReplay))
	if got := graphemeRows(client); !client.graphemeCluster || got[0][0] != "\U0001F468\u200d\U0001F469" {
		t.Fatalf("client after the shell's replay = %q, clustering %v", got, client.graphemeCluster)
	}
}

// TestShellReplayStartsInTheModeItsHistoryDid covers a shell window whose
// program switched clustering partway through the output a replay paints:
// the output before the switch is laid out in the mode in force where the
// replay starts, as the model laid it out, whether that is where the output
// began or past a switch the kept history no longer holds, and a model
// rebuilt from a snapshot of the window starts in that mode too.
func TestShellReplayStartsInTheModeItsHistoryDid(t *testing.T) {
	family := "\U0001F468\u200d\U0001F469"
	clustered := []string{family, "<"}
	legacy := []string{"\U0001F468\u200d", "<", "\U0001F469", "<"}
	filler := strings.Repeat("a\r\n", windowHistoryLimitBytes)
	for _, tc := range []struct {
		name, output string
		y            int
		row          []string
		startsOff    bool
	}{
		{
			name:   "from where the output began",
			output: family + "\x1b[?2027lx" + family,
			row:    append(append(append([]string{}, clustered...), "x"), legacy...),
		},
		{
			name:   "before more switches than a short record keeps",
			output: family + "x" + strings.Repeat("\x1b[?2027l\x1b[?2027h", 65) + "\x1b[?2027l" + family,
			row:    append(append(append([]string{}, clustered...), "x"), legacy...),
		},
		{
			name:      "past a switch the history lost",
			output:    "\x1b[?2027l" + filler + family + "\x1b[?2027hx" + family,
			y:         2,
			row:       append(append(append([]string{}, legacy...), "x"), clustered...),
			startsOff: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			window := &muxWindow{
				id: "@1", name: "zsh", command: "zsh", foregroundCommand: "zsh",
				lastActivity: time.Now(), screenWidth: 10, screenHeight: 3,
			}
			server := newMuxServerWithSize("test", 10, 3)
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			server.mu.Lock()
			window.observeTerminalModesLocked([]byte(tc.output))
			window.appendHistoryLocked([]byte(tc.output))
			model := window.screenLocked()
			replay := server.replayBytesLocked(window)
			server.mu.Unlock()

			if got := graphemeRows(model)[tc.y]; !reflect.DeepEqual(got, tc.row) {
				t.Fatalf("model = %q, want %q", got, tc.row)
			}
			client := newTerminalScreen(10, 3)
			client.Write(replay)
			if got, want := graphemeRows(client), graphemeRows(model); !reflect.DeepEqual(got, want) ||
				client.graphemeCluster != model.graphemeCluster {
				t.Fatalf("client = %q (clustering %v), want the model's %q (%v)",
					got, client.graphemeCluster, want, model.graphemeCluster)
			}

			restore := server.restoreSnapshot()
			if len(restore.Windows) != 1 {
				t.Fatalf("snapshot has %d windows", len(restore.Windows))
			}
			state := restore.Windows[0]
			if state.HistoryGraphemeClusterOff != tc.startsOff {
				t.Fatalf("snapshot history starts with clustering off = %v, want %v",
					state.HistoryGraphemeClusterOff, tc.startsOff)
			}
			options := createWindowOptionsForRestore(state, false)
			restored := &muxWindow{
				history:                   options.history,
				historyGraphemeClusterOff: options.historyGraphemeClusterOff,
				privateModes:              options.privateModes,
				screenWidth:               10,
				screenHeight:              3,
			}
			if got := graphemeRows(restored.screenLocked())[tc.y]; !reflect.DeepEqual(got, tc.row) {
				t.Fatalf("restored model = %q, want %q", got, tc.row)
			}
		})
	}
}

// TestGraphemeClusterAtKeepsTheChangesAReplayReaches covers the record of
// mode 2027 changes a replay looks its starting mode up in: each change holds
// from just past its sequence, every change a replay can reach back to is
// kept, however many, and one no replay can start before only sets the mode
// before the next.
func TestGraphemeClusterAtKeepsTheChangesAReplayReaches(t *testing.T) {
	s := newTerminalScreen(10, 2)
	s.Write([]byte("ab\x1b[?2027lcd\x1b[?2027hef"))
	for at, want := range map[int64]bool{0: true, 9: true, 10: false, 19: false, 20: true, 22: true} {
		if got := s.GraphemeClusterAt(at); got != want {
			t.Errorf("mode at %d = %v, want %v", at, got, want)
		}
	}

	s = newTerminalScreen(10, 2)
	s.Write([]byte("\U0001F468\u200d\U0001F469x"))
	start := s.Written()
	switches := strings.Repeat("\x1b[?2027l\x1b[?2027h", 65) + "\x1b[?2027l"
	s.Write([]byte(switches))
	if !s.GraphemeClusterAt(0) || !s.GraphemeClusterAt(start) || s.GraphemeClusterAt(s.Written()) {
		t.Fatal("the record lost the mode before many switches")
	}
	for i, at := 0, start; i < 131; i++ {
		at += int64(len("\x1b[?2027l"))
		if got, want := s.GraphemeClusterAt(at), i%2 == 1; got != want {
			t.Fatalf("mode after switch %d = %v, want %v", i, got, want)
		}
	}

	s.Write([]byte(strings.Repeat("a", vtModeChangeReach) + "\x1b[?2027h"))
	if len(s.graphemeChanges) != 2 {
		t.Fatalf("kept %d changes, want the last 2", len(s.graphemeChanges))
	}
	if s.GraphemeClusterAt(s.Written()-vtModeChangeReach) || !s.GraphemeClusterAt(s.Written()) {
		t.Fatal("pruning lost the mode a replay within reach starts in")
	}
	if c := s.Clone(); !slices.Equal(c.graphemeChanges, s.graphemeChanges) || &c.graphemeChanges[0] == &s.graphemeChanges[0] {
		t.Fatal("a clone shares the record of changes")
	}
}

// TestFramesPaintGlyphsThatWouldJoinTheGlyphBefore covers glyphs a frame
// cannot print after the glyph to their left, which the client would join
// them to, but that stand alone: a skin tone swatch written before the emoji
// later put left of it (one after a letter stands alone anyway). The frame
// prints them first, from the right, also at the start of a soft-wrapped row
// and in a line kept in the scrollback.
func TestFramesPaintGlyphsThatWouldJoinTheGlyphBefore(t *testing.T) {
	swatch, thumb := "\U0001F3FD", "\U0001F44D"
	for _, tc := range []struct {
		name, write string
		width       int
		y           int
		row         []string
	}{
		{"after an emoji", "\x1b[1;3H" + swatch + "\x1b[1;1H" + thumb, 8, 0, []string{thumb, "<", swatch, "<"}},
		{"after a letter", "\x1b[1;2H" + swatch + "\x1b[1;1Ha", 8, 0, []string{"a", swatch, "<"}},
		{
			"in a run, with renditions",
			"\x1b[1;5H\x1b[44m" + swatch + "\x1b[1;3H\x1b[0;7m" + swatch + "\x1b[1;1H\x1b[0;31m" + thumb + "\x1b[0;44m\x1b[1;7Hz",
			8, 0, []string{thumb, "<", swatch, "<", swatch, "<", "z"},
		},
		{"at the start of a soft-wrapped row", "\x1b[2;3H" + swatch + "\x1b[1;1Habcd" + thumb, 4, 1, []string{thumb, "<", swatch, "<"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTerminalScreen(tc.width, 3)
			s.Write([]byte(tc.write))
			if got := graphemeRows(s)[tc.y]; !reflect.DeepEqual(got, tc.row) {
				t.Fatalf("model row = %q, want %q", got, tc.row)
			}
			requireGraphemeFrameRoundTrip(t, s, tc.write)

			// Scrolled into the scrollback, the row is kept as the frame
			// paints it.
			want := slices.Clone(s.grid().rows[tc.y])
			s.Write([]byte("\x1b[3;1H\n\n\n"))
			var decoder vtLineDecoder
			line := s.scrollback.at(s.scrollback.len() - 3 + tc.y)
			if got := line.decode(&decoder, s.width); !vtRowsEqual([][]vtCell{want}, [][]vtCell{got}) {
				t.Fatalf("scrollback line %q decodes to another row", line.text)
			}
		})
	}
}

// TestWidenedClusterBlanksTheWideGlyphItCovers pins the attributes the shared
// case "a cluster widened over a wide glyph blanks that glyph's right half"
// leaves: that right half keeps only its background, as in the client.
func TestWidenedClusterBlanksTheWideGlyphItCovers(t *testing.T) {
	s := newTerminalScreen(10, 2)
	s.Write([]byte("\u2665\x1b[7;31;44m\u754c\x1b[2G\x1b[0m\ufe0f"))
	ref := newTerminalScreen(1, 1)
	ref.Write([]byte("\x1b[7;31;44m"))
	if got, want := s.grid().rows[0][2], (vtCell{width: 1, attrs: vtAttrs{bg: ref.attrs.bg}}); !reflect.DeepEqual(got, want) {
		t.Fatalf("right half = %+v, want %+v", got, want)
	}
}

// TestForegroundFrameRestoresGraphemeClusterMode switches to an agent whose
// frame is painted from the model: the frame sets the window's mode 2027 before
// its cells, so the client lays them out as the model did.
func TestForegroundFrameRestoresGraphemeClusterMode(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot", lastActivity: time.Now()}
	got := selectWindowReplay(t, window, "\x1b[?2027l\U0001F468\u200d\U0001F469x\x1b[?2027h\x1b[?2027l", "")
	if !strings.Contains(got, "\x1b[?2027l\x1b[?6l\x1b[r") {
		t.Fatalf("frame does not start in legacy mode: %q", got)
	}
	client := newTerminalScreen(80, 40)
	client.Write([]byte(got))
	want := []string{"\U0001F468\u200d", "<", "\U0001F469", "<", "x"}
	if row := graphemeRows(client)[0]; !reflect.DeepEqual(row, want) || client.graphemeCluster {
		t.Fatalf("client = %q, clustering %v; want %q in legacy mode", row, client.graphemeCluster, want)
	}
}

func TestGraphemeClustersMoveWithTheirCells(t *testing.T) {
	family := "\U0001F468\u200d\U0001F469"
	s := newTerminalScreen(8, 3)
	s.Write([]byte("e\u0301" + family + "\r\x1b[2@"))
	want := []string{"", "", "e\u0301", family, "<"}
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, want) {
		t.Fatalf("after ICH %q, want %q", row, want)
	}
	vtRoundTrip(t, s)
	s.Write([]byte("\x1b[2P"))
	want = []string{"e\u0301", family, "<"}
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, want) {
		t.Fatalf("after DCH %q, want %q", row, want)
	}
	s.Write([]byte("\x1b[L"))
	if rows := graphemeRows(s); len(rows[0]) != 0 || !reflect.DeepEqual(rows[1], want) {
		t.Fatalf("after IL %q", rows)
	}
	s.Write([]byte("\x1b[M"))
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, want) {
		t.Fatalf("after DL %q, want %q", row, want)
	}
	s.Write([]byte("\x1b[T"))
	if row := graphemeRows(s)[1]; !reflect.DeepEqual(row, want) {
		t.Fatalf("after SD %q, want %q", row, want)
	}
	// Insert mode moves them too.
	s.Write([]byte("\x1b[2;1H\x1b[4hx\x1b[4l"))
	if row := graphemeRows(s)[1]; !reflect.DeepEqual(row, append([]string{"x"}, want...)) {
		t.Fatalf("after IRM %q", row)
	}
	vtRoundTrip(t, s)

	// Lines scrolled off keep them, and come back with them.
	s = newTerminalScreen(8, 2)
	s.Write([]byte("e\u0301" + family + "\r\n\r\n\r\nk"))
	if s.scrollback.len() != 2 {
		t.Fatalf("scrollback holds %d lines", s.scrollback.len())
	}
	var decoder vtLineDecoder
	line := s.scrollback.at(0).decode(&decoder, 8)
	if line[0].r != 'e' || string(line[0].comb) != "\u0301" || line[1].r != 0x1F468 || string(line[1].comb) != "\u200d\U0001F469" || line[1].width != 2 {
		t.Fatalf("scrollback line = %+v", line[:3])
	}
	replica := replayFrame(s)
	if got := replica.scrollback.at(0).decode(&decoder, 8); !vtRowsEqual([][]vtCell{got}, [][]vtCell{line}) {
		t.Fatalf("replayed scrollback line = %+v", got[:3])
	}
	s.Resize(8, 4)
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, want) {
		t.Fatalf("restored from the scrollback %q, want %q", row, want)
	}
}

func TestGraphemeClustersReflow(t *testing.T) {
	family := "\U0001F468\u200d\U0001F469"
	s := newTerminalScreen(8, 3)
	s.Write([]byte("\r\n\r\nab" + family + "cde\u0301"))
	s.Resize(4, 3)
	want := [][]string{{}, {"a", "b", family, "<"}, {"c", "d", "e\u0301"}}
	if rows := graphemeRows(s); !reflect.DeepEqual(rows, want) || !s.main.wrapped[2] {
		t.Fatalf("narrowed %q", rows)
	}
	vtRoundTrip(t, s)
	s.Resize(3, 3)
	// The wide cluster does not fit after "ab" and moves whole.
	want = [][]string{{"a", "b"}, {family, "<", "c"}, {"d", "e\u0301"}}
	if rows := graphemeRows(s); !reflect.DeepEqual(rows, want) {
		t.Fatalf("narrowed again %q", rows)
	}
	vtRoundTrip(t, s)
	s.Resize(8, 3)
	want = [][]string{{}, {}, {"a", "b", family, "<", "c", "d", "e\u0301"}}
	if rows := graphemeRows(s); !reflect.DeepEqual(rows, want) {
		t.Fatalf("widened %q", rows)
	}
	vtRoundTrip(t, s)
}

// TestGraphemeEraseClearsClusters: every erase leaves cells without the code
// points that were joined to them, and a new glyph replaces them.
func TestGraphemeEraseClearsClusters(t *testing.T) {
	cluster := "e\u0301\U0001F468\u200d\U0001F469"
	for _, tc := range []struct {
		name, op string
		want     []string
	}{
		{"EL", "\r\x1b[K", nil},
		{"ED", "\r\x1b[J", nil},
		{"ED 2", "\x1b[2J", nil},
		{"ECH", "\r\x1b[4X", nil},
		{"DCH", "\r\x1b[3P", nil},
		{"ICH", "\r\x1b[3@\x1b[3P", []string{"e\u0301", "\U0001F468\u200d\U0001F469", "<"}},
		{"overwrite", "\rxyz", []string{"x", "y", "z"}},
		{"RIS", "\x1bc", nil},
		{"DECALN", "\x1b#8", []string{"E", "E", "E", "E", "E", "E"}},
		{"scroll", "\x1b[S", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTerminalScreen(6, 2)
			s.Write([]byte(cluster + tc.op))
			want := tc.want
			if want == nil {
				want = []string{}
			}
			if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, want) {
				t.Fatalf("row = %q, want %q", row, want)
			}
		})
	}
}

func TestGraphemeVariationSelectorsInLegacyModeOnlyFollowEmoji(t *testing.T) {
	for _, tc := range []struct {
		write string
		want  []string
	}{
		{"a\ufe0f", []string{"a"}},
		{"1\ufe0f", []string{"1"}},
		{"\u2665\ufe0f", []string{"\u2665\ufe0f"}},
		{"\u231a\ufe0e", []string{"\u231a\ufe0e", "<"}},
		{"a\u0301\ufe0f", []string{"a\u0301"}},
	} {
		s := newTerminalScreen(6, 1)
		s.Write([]byte("\x1b[?2027l" + tc.write))
		if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, tc.want) {
			t.Errorf("%q: row = %q, want %q", tc.write, row, tc.want)
		}
	}
}

// TestGraphemeClusterKeepsFifteenExtras: a cell keeps its base and fifteen
// more code points, in either mode, and drops the rest, even one that would
// widen it.
func TestGraphemeClusterKeepsFifteenExtras(t *testing.T) {
	for _, mode := range []string{"\x1b[?2027h", "\x1b[?2027l"} {
		s := newTerminalScreen(6, 1)
		s.Write([]byte(mode + "e" + strings.Repeat("\u0301", 20) + "x"))
		row := s.grid().rows[0]
		if len(row[0].comb) != 15 || row[1].r != 'x' {
			t.Fatalf("%q: %d extras, then %q", mode, len(row[0].comb), row[1].r)
		}
	}
	s := newTerminalScreen(6, 1)
	s.Write([]byte("\u0915" + strings.Repeat("\u0301", 15) + "\u093fx"))
	row := s.grid().rows[0]
	if row[0].width != 1 || len(row[0].comb) != 15 || row[1].r != 'x' {
		t.Fatalf("a spacing mark past the limit widened the cell: %+v", row[:2])
	}
}

// TestFrameMovesANarrowedClusterIntoTheLastColumnAsInput: a cluster narrowed
// from a wide base, which a frame cannot print in the last column, is printed
// to its left and moved there, as the input it was typed as. Painted as the
// prompt before it, it took no clicks after a replay.
func TestFrameMovesANarrowedClusterIntoTheLastColumnAsInput(t *testing.T) {
	s := newTerminalScreen(5, 2)
	s.Write([]byte(osc133("A") + "$ " + osc133("B") + "\u231a\ufe0e\x1b[3G\x1b[2@"))
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, []string{"$", " ", "", "", "\u231a\ufe0e"}) {
		t.Fatalf("row = %q", row)
	}
	want := dumpSemanticPrompt(s)
	if got := dumpSemanticPrompt(replayFrame(s)); !slices.Equal(got, want) {
		t.Fatalf("replayed\n got: %q\nwant: %q", got, want)
	}
	// A cluster that a code point after its narrow base widened and another
	// narrowed is moved there whole.
	s = newTerminalScreen(5, 2)
	s.Write([]byte("\u2665\u200d\u231a\ufe0e\r\x1b[4@"))
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, []string{"", "", "", "", "\u2665\u200d\u231a\ufe0e"}) {
		t.Fatalf("row = %q", row)
	}
	requireGraphemeFrameRoundTrip(t, s, "")
}

// TestFrameMovesNarrowedClustersBeforeTheLastColumnToo: printing a cluster
// wide on its way to one column writes the column after it, so a frame moves
// every such cluster that ends a row into place together, the cell before
// them painted after.
func TestFrameMovesNarrowedClustersBeforeTheLastColumnToo(t *testing.T) {
	watch := "\u231a\ufe0e"
	for _, tc := range []struct {
		width int
		write string
		want  []string
	}{
		{5, "ab" + watch + watch + "\r\x1b[@", []string{"", "a", "b", watch, watch}},
		{5, "a" + watch + watch + watch + "\r\x1b[@", []string{"", "a", watch, watch, watch}},
		{4, watch + watch + watch + "\r\x1b[@", []string{"", watch, watch, watch}},
		{4, "\x1b[41m" + watch + "\x1b[0m" + watch + watch + "\r\x1b[@", []string{"", watch, watch, watch}},
	} {
		s := newTerminalScreen(tc.width, 3)
		s.Write([]byte(tc.write))
		if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, tc.want) {
			t.Fatalf("%+q: row = %q, want %q", tc.write, row, tc.want)
		}
		requireGraphemeFrameRoundTrip(t, s, tc.write)
	}
	// A row of nothing else, which only a narrower screen makes, has no
	// column to move them in from: the first is left out rather than
	// erasing the second.
	s := newTerminalScreen(6, 2)
	s.Write([]byte(watch + watch + watch))
	s.Resize(3, 2)
	if row := graphemeRows(s)[0]; !reflect.DeepEqual(row, []string{watch, watch, watch}) {
		t.Fatalf("row = %q", row)
	}
	if row := graphemeRows(replayFrame(s))[0]; !reflect.DeepEqual(row, []string{"", watch, watch}) {
		t.Fatalf("replayed row = %q", row)
	}
}

// TestFrameWidensAClusterAsTheContentItsSecondHalfWasWrittenAs: the code point
// that widens a cluster writes its second half as the content then current,
// prompt or input, as it does in the rendition then current.
func TestFrameWidensAClusterAsTheContentItsSecondHalfWasWrittenAs(t *testing.T) {
	for _, write := range []string{
		osc133("A") + "\u2665" + osc133("B") + "\ufe0f",
		osc133("A") + "$ " + osc133("B") + "\u2665" + osc133("C") + "\ufe0f\r\n",
		osc133("A") + "\x1b[31m\u0915" + osc133("B") + "\x1b[0m\u093f",
	} {
		s := newTerminalScreen(6, 3)
		s.Write([]byte(write))
		replica := replayFrame(s)
		for col, cell := range s.main.rows[0] {
			if got := replica.main.rows[0][col]; got.sem != cell.sem || got.attrs != cell.attrs {
				t.Fatalf("%+q: column %d replayed as content %d %+v, want %d %+v",
					write, col, got.sem, got.attrs, cell.sem, cell.attrs)
			}
		}
		if got, want := dumpSemanticPrompt(replica), dumpSemanticPrompt(s); !slices.Equal(got, want) {
			t.Fatalf("%+q: replayed\n got: %q\nwant: %q", write, got, want)
		}
	}
}

// TestFrameMovesAClusterInWithoutEndingItsPromptRow: the content a moved
// cluster is printed in is set where the cursor is, at the start of the row
// on a narrow screen, where a C would end the row's prompt mark.
func TestFrameMovesAClusterInWithoutEndingItsPromptRow(t *testing.T) {
	s := newTerminalScreen(2, 2)
	s.Write([]byte("\u231a\ufe0e\r\x1b[@" + osc133("P;k=i") + "$" + osc133("C")))
	want := dumpSemanticPrompt(s)
	if want[0] != "P |$\u231a|po" {
		t.Fatalf("model row = %q", want[0])
	}
	if got := dumpSemanticPrompt(replayFrame(s)); !slices.Equal(got, want) {
		t.Fatalf("replayed\n got: %q\nwant: %q", got, want)
	}
}

// TestFrameKeepsTheCursorsWidenedGlyphOutOfANewCommand: the glyph the cursor
// waits to wrap after, printed again on a row above the running command's,
// keeps the output in force for its second half as for its first, rather
// than leave the app editing for finish to start the command again there.
func TestFrameKeepsTheCursorsWidenedGlyphOutOfANewCommand(t *testing.T) {
	s := newTerminalScreen(4, 3)
	s.Write([]byte(osc133("A") + "$ " + osc133("B") + "\u2665\ufe0f\r\n" + osc133("C") + "x\x1b[1;4H\t"))
	if rows := graphemeCommandMarkRows(replaySequence(s), 4, 3); !slices.Equal(rows, []int{1}) {
		t.Fatalf("the replay marks commands on rows %v, want [1]", rows)
	}
	if status, _ := shellStatusAfter(t, []byte(replaySequence(s)), "prompt", ""); status != "running" {
		t.Fatalf("after the replay the app shows %s", status)
	}
}

// TestFrameWrapsOntoAClusterAsTheContentInForceThen: a row a soft wrap reaches
// is marked as continuing a prompt by the content in force when the wrap
// happens, so the glyph a frame wraps with keeps that content for its second
// half too. A clear afterwards saves as many rows as the model does.
func TestFrameWrapsOntoAClusterAsTheContentInForceThen(t *testing.T) {
	for _, write := range []string{
		osc133("A") + "$" + osc133("B") + "abc" + osc133("C") + "\u2665\ufe0f",
		"abcd" + osc133("B") + "\u2665\ufe0f",
		osc133("A") + "$" + osc133("B") + "abc" + osc133("C") + "\u231a\ufe0e\u0301",
	} {
		s := newTerminalScreen(4, 3)
		s.Write([]byte(write))
		replica := replayFrame(s)
		if got, want := dumpSemanticPrompt(replica), dumpSemanticPrompt(s); !slices.Equal(got, want) {
			t.Fatalf("%+q: replayed\n got: %q\nwant: %q", write, got, want)
		}
		s.Write([]byte("\x1b[2J"))
		replica.Write([]byte("\x1b[2J"))
		if got, want := replica.scrollback.len(), s.scrollback.len(); got != want {
			t.Fatalf("%+q: a clear after the replay saves %d rows, want %d", write, got, want)
		}
	}
}

// graphemeCommandMarkRows paints replay on a client width x height and
// returns the rows it receives OSC 133 C on, in order, each once.
func graphemeCommandMarkRows(replay string, width, height int) []int {
	const mark = "\x1b]133;C\x07"
	client := newTerminalScreen(width, height)
	var rows []int
	parts := strings.Split(replay, mark)
	for i, part := range parts {
		client.Write([]byte(part))
		if i == len(parts)-1 {
			break
		}
		if row := client.grid().cursorRow; !slices.Contains(rows, row) {
			rows = append(rows, row)
		}
		client.Write([]byte(mark))
	}
	return rows
}

// requireGraphemeFrameRoundTrip paints s's frame onto fresh models in either
// mode 2027 and its whole window replay onto another, and requires each to
// end with the model's cells, scrollback, soft wraps, cursor and mode.
func requireGraphemeFrameRoundTrip(t *testing.T, s *terminalScreen, stream string) {
	t.Helper()
	width, height := s.Size()
	check := func(how string, replica *terminalScreen) {
		t.Helper()
		if !vtRowsEqual(s.grid().rows, replica.grid().rows) {
			t.Fatalf("%s of %+q changed the cells\nwant %q\n got %q", how, stream, graphemeRows(s), graphemeRows(replica))
		}
		if !slices.Equal(s.grid().wrapped[1:], replica.grid().wrapped[1:]) {
			t.Fatalf("%s of %+q changed the soft wraps: %v, want %v", how, stream, replica.grid().wrapped, s.grid().wrapped)
		}
		g, r := s.grid(), replica.grid()
		if g.cursorRow != r.cursorRow || g.cursorCol != r.cursorCol || g.pendingWrap != r.pendingWrap {
			t.Fatalf("%s of %+q moved the cursor to %d,%d,%v, want %d,%d,%v", how, stream,
				r.cursorRow, r.cursorCol, r.pendingWrap, g.cursorRow, g.cursorCol, g.pendingWrap)
		}
		if replica.graphemeCluster != s.graphemeCluster || replica.autowrap != s.autowrap {
			t.Fatalf("%s of %+q left mode 2027 %v and autowrap %v", how, stream, replica.graphemeCluster, replica.autowrap)
		}
	}
	frame := s.RenderFrame()
	for _, initial := range []string{"\x1b[?2027h", "\x1b[?2027l"} {
		replica := newTerminalScreen(width, height)
		preamble := initial
		if !s.autowrap {
			preamble += "\x1b[?7l"
		}
		if s.AlternateScreenActive() {
			preamble += "\x1b[?1049h"
		}
		replica.Write([]byte(preamble))
		replica.Write(frame)
		check("frame after "+strings.TrimPrefix(initial, "\x1b"), replica)
	}
	replica := newTerminalScreen(width, height)
	replay := replaySequence(s)
	if !s.autowrap {
		// The window's modes, which the real replay restores before the frame.
		replay = strings.Replace(replay, string(s.RenderFrame()), "\x1b[?7l"+string(s.RenderFrame()), 1)
	}
	replica.Write([]byte(replay))
	check("replay", replica)
	if s.AlternateScreenActive() {
		return
	}
	if replica.scrollback.len() != s.scrollback.len() {
		t.Fatalf("replay of %+q has %d scrollback lines, want %d", stream, replica.scrollback.len(), s.scrollback.len())
	}
	var decoder vtLineDecoder
	for i := range s.scrollback.len() {
		want := s.scrollback.at(i).decode(&decoder, width)
		got := replica.scrollback.at(i).decode(&decoder, width)
		if !vtRowsEqual([][]vtCell{want}, [][]vtCell{got}) {
			t.Fatalf("replay of %+q changed scrollback line %d", stream, i)
		}
	}
}

// TestFramesRepaintClustersWrittenUnderEitherMode covers cells the client
// would not rebuild by printing them under the mode the window is in now:
// written under the other mode, or before the glyph left of them.
func TestFramesRepaintClustersWrittenUnderEitherMode(t *testing.T) {
	for _, stream := range []string{
		// Written without clustering, painted with it.
		"\x1b[?2027l\u0915\u093f a\U0001F3FD \U0001F468\u200d\U0001F469 \u2665\ufe0f\x1b[?2027h",
		"\x1b[?2027l\U0001F1FA\U0001F1F8 \u0915\u094d\u0937 \u231a\ufe0e\x1b[?2027h",
		// Written with it, painted without.
		"\u0915\u093f \U0001F468\u200d\U0001F469 \u2665\ufe0f \u231a\ufe0e\U0001F3FD\x1b[?2027l",
		// A glyph that would join the one left of it, printed first.
		"\x1b[1;2H\u093f\x1b[1;1H\u0915",
		"\x1b[1;2H\U0001F1F8\x1b[1;1H\U0001F1FA",
		// A continuation row starting with a glyph that would join the end
		// of the row above.
		"\x1b[?2027labcd\u093f\x1b[?2027h",
		"\x1b[?2027labc\u2665\ufe0f\x1b[?2027h",
		// A legacy emoji at the last column, with the cursor waiting to wrap
		// after it and autowrap off.
		"\x1b[?2027labc\u2665\ufe0f\x1b[?2027h\x1b[?7l",
		// The same in the scrollback.
		"\x1b[?2027labcd\u093f\r\n\u2665\ufe0f\U0001F468\u200d\U0001F469\r\n\r\n\r\n\r\n\x1b[?2027h",
		"\U0001F468\u200d\U0001F469\u0915\u093f\r\n\r\n\r\n\r\n\x1b[?2027lx\u2665\ufe0f",
	} {
		s := newTerminalScreen(4, 3)
		s.Write([]byte(stream))
		requireGraphemeFrameRoundTrip(t, s, stream)
	}
}

// TestFramesRepaintRandomClusters paints random output, mixing clustering,
// cursor moves, resizes and both modes, from frames: the client must end
// with the model's cells. Cases with a picture no frame paints are skipped
// (graphemeFrameCannotPaint).
func TestFramesRepaintRandomClusters(t *testing.T) {
	tokens := []string{
		"a", "e", " ", "1", "\u0301", "\u0308", "\u200d", "\ufe0f", "\ufe0e",
		"\U0001F468", "\U0001F469", "\U0001F44D", "\U0001F3FD", "\u2665", "\u231a",
		"\U0001F1FA", "\U0001F1F8", "\u0915", "\u093f", "\u094d", "\u0937",
		"\u1100", "\u1161", "\u11a8", "\u754c", "\u20e3",
		"\U0001F1FA\U0001F1F8", "\u231a\ufe0e", "\U0001F44D\ufe0e", "\u2665\ufe0f",
		"\U0001F468\u200d\U0001F469\u200d\U0001F467", "\u00a9", "\u00ae", "\U0001F468\u200d\u00a9",
		// Marks after a glyph printed in the last column, with autowrap off
		// as often as on.
		"\x1b[1;99He\u0301", "\x1b[2;99H\u2665\ufe0f", "\x1b[?7l\x1b[1;99Hx\u0301\u0308", "\x1b[1;99H\u0915\u093f",
		"\x1b[?2027l", "\x1b[?2027h", "\x1b[?7l", "\x1b[?7h", "\r\n", "\r", "\t", "\x1b[D", "\x1b[2D",
		"\x1b[1;1H", "\x1b[2;3H", "\x1b[1;3H", "\x1b[1;5H", "\x1b[@", "\x1b[P", "\x1b[K", "\x1b[X",
		"\x1b[L", "\x1b[M", "\x1b[S", "\x1b[2J", "\x1b[4h", "\x1b[4l", "\x1b[2;3r", "\x1b[r",
		"\x1b7", "\x1b8", "\x1b[?1049h", "\x1b[?1049l", "\x1bc", "\x1b[!p",
		"\x1b[31m", "\x1b[41m", "\x1b[44m", "\x1b[7m", "\x1b[0m",
	}
	rng := rand.New(rand.NewSource(2027))
	skipped := 0
	const runs = 3000
	for range runs {
		width, height := 2+rng.Intn(6), 2+rng.Intn(3)
		s := newTerminalScreen(width, height)
		var stream strings.Builder
		fmt.Fprintf(&stream, "<%dx%d>", width, height)
		tainted := false
		for range 10 + rng.Intn(60) {
			if rng.Intn(20) == 0 {
				width, height = 2+rng.Intn(6), 2+rng.Intn(3)
				s.Resize(width, height)
				fmt.Fprintf(&stream, "<resize %dx%d>", width, height)
			} else {
				token := tokens[rng.Intn(len(tokens))]
				stream.WriteString(token)
				s.Write([]byte(token))
			}
			// Scrolling such a picture into the scrollback hides it.
			tainted = tainted || graphemeFrameCannotPaint(s)
		}
		if tainted {
			skipped++
			continue
		}
		requireGraphemeFrameRoundTrip(t, s, stream.String())
	}
	if skipped > runs/10 {
		t.Fatalf("%d of %d cases skipped", skipped, runs)
	}
}

// TestFramesRepaintPromptMarksAroundRandomClusters paints random prompts,
// input and output, their marks inside clusters too, and the soft wraps
// between them, from frames: the client must end with the model's cells,
// row marks and cell contents, and a clear must then save as many rows. The
// glyph the cursor waits to wrap after is printed again as the output in
// force (cursorContent), so its content is left out.
func TestFramesRepaintPromptMarksAroundRandomClusters(t *testing.T) {
	a, b, c := osc133("A"), osc133("B"), osc133("C")
	tokens := []string{
		"a", "b", "$ ", "abc", a, b, c, osc133("D;0"), osc133("P;k=s"), "\r\n", "\r", "\x1b[K",
		"\u2665\ufe0f", "\u2665" + c + "\ufe0f", "\u2665" + b + "\ufe0f", "\u231a\ufe0e", "\u231a" + c + "\ufe0e",
		"\u0915\u093f", "\u0915" + b + "\u093f", "e\u0301", "e" + c + "\u0301",
		"\U0001F468\u200d\U0001F469", "\U0001F468" + b + "\u200d\U0001F469", "\U0001F1FA\U0001F1F8",
		"1\ufe0f\u20e3", "\U0001F44D\U0001F3FD", "\u754c", "\U0001F468\u200d\u00a9",
		"\x1b[?2027l", "\x1b[?2027h", "\x1b[41m", "\x1b[0m",
	}
	rng := rand.New(rand.NewSource(133))
	for range 3000 {
		width, height := 3+rng.Intn(5), 2+rng.Intn(3)
		s := newTerminalScreen(width, height)
		var stream strings.Builder
		for range 5 + rng.Intn(40) {
			token := tokens[rng.Intn(len(tokens))]
			stream.WriteString(token)
			s.Write([]byte(token))
		}
		requirePromptFrameRoundTrip(t, s, stream.String())
	}
}

// TestFramesRepaintPromptMarksAroundRandomEdits paints random prompts, input
// and output from frames after edits, cursor moves, scroll regions, origin
// mode, saved cursors, both screens, resets and resizes have moved them
// around: the client must end as requirePromptFrameRoundTrip says. Cases
// with a picture no frame paints are skipped (graphemeFrameCannotPaint).
func TestFramesRepaintPromptMarksAroundRandomEdits(t *testing.T) {
	a, b, c := osc133("A"), osc133("B"), osc133("C")
	tokens := []string{
		"a", "b", "$ ", "abc", a, b, c, osc133("D;0"), osc133("P;k=s"), "\r\n", "\r", "\t",
		"\u754c", "\u2665" + c + "\ufe0f", "\u0915" + b + "\u093f", "\U0001F468" + b + "\u200d\U0001F469", "\U0001F1FA\U0001F1F8",
		"\x1b[D", "\x1b[2D", "\x1b[C", "\x1b[A", "\x1b[B", "\x1b[1;1H", "\x1b[2;3H", "\x1b[1;99Hx", "\x1b[3G",
		"\x1b[@", "\x1b[P", "\x1b[X", "\x1b[L", "\x1b[M", "\x1b[J", "\x1b[1J", "\x1b[2J", "\x1b[K", "\x1b[1K",
		"\x1b[S", "\x1b[T", "\x1b[2;3r", "\x1b[r", "\x1bD", "\x1bM", "\x1b[3J", "\x1b[?6h", "\x1b[?6l", "\x1b7", "\x1b8",
		"\x1b[?1049h", "\x1b[?1049l", "\x1b[?47h", "\x1b[?47l", "\x1b[?1047h", "\x1b[?1047l", "\x1bc", "\x1b[!p",
		"\x1b[?7l", "\x1b[?7h", "\x1b[4h", "\x1b[4l", "\x1b[?2027l", "\x1b[?2027h", "\x1b[41m", "\x1b[44m", "\x1b[0m",
		"\x1b(0", "\x1b(B", "\x1b)0", "\x0e", "\x0f",
	}
	rng := rand.New(rand.NewSource(1336))
	skipped := 0
	const runs = 5000
	for range runs {
		width, height := 3+rng.Intn(5), 2+rng.Intn(3)
		s := newTerminalScreen(width, height)
		var stream strings.Builder
		fmt.Fprintf(&stream, "<%dx%d>", width, height)
		tainted := false
		for range 5 + rng.Intn(40) {
			if rng.Intn(12) == 0 {
				width, height = 3+rng.Intn(5), 2+rng.Intn(3)
				s.Resize(width, height)
				fmt.Fprintf(&stream, "<resize %dx%d>", width, height)
				continue
			}
			token := tokens[rng.Intn(len(tokens))]
			stream.WriteString(token)
			s.Write([]byte(token))
			tainted = tainted || graphemeFrameCannotPaint(s)
		}
		if tainted {
			skipped++
			continue
		}
		requirePromptFrameRoundTrip(t, s, stream.String())
	}
	if skipped > runs/10 {
		t.Fatalf("%d of %d cases skipped", skipped, runs)
	}
}

// TestFramesPutTheCursorOutsideTheRegionInOriginMode covers a cursor DECRC
// left above or below the scroll region in origin mode, where CUP cannot put
// it, and a saved cursor there.
func TestFramesPutTheCursorOutsideTheRegionInOriginMode(t *testing.T) {
	for _, stream := range []string{
		// Restored above the region, by DECRC and by leaving the alternate
		// screen.
		"\x1b[?6h\x1b7\x1b[2;3r\x1b8",
		"\x1b[?6h\x1b7\x1b[2;3r\x1b[?1049l",
		// Waiting to wrap there, after a glyph whose reprint must not land
		// on the region's top row, nor take the saved charsets and rendition.
		"\x1b[?6h\u754c\u0915\x1b[?1049h\x1b[2;3r\x1b[?1049l",
		"\x1b[?6h\x1b)0\x0e\x1b[41m\x1b7\x1b[2;4r\x1b8\x0f\x1b[0mabcde",
		// Moved along and up from where it was restored, which a later
		// DECRC still goes back to.
		"\x1b[?6h\x1b[2;1H\x1b7\x1b[4;5r\x1b8\x1b[Aab",
		// Below the region.
		"\x1b[?6h\x1b[5;2H\x1b7\x1b[1;2r\x1b8xy",
		// Saved above the region, with the cursor inside it.
		"\x1b[?6h\x1b7\x1b[2;3rab",
	} {
		s := newTerminalScreen(5, 5)
		s.Write([]byte(stream))
		requirePromptFrameRoundTrip(t, s, stream)
		requireGraphemeFrameRoundTrip(t, s, stream)
	}
	// Carried onto the other screen, whose saved cursor never went there:
	// the frame saves the cursor to restore it, so a DECRC now goes back to
	// it rather than home.
	s := newTerminalScreen(5, 5)
	s.Write([]byte("\x1b[?6h\x1b[2;2H\x1b7\x1b[4;5r\x1b8\x1b[?1047h"))
	replica := replayFrame(s)
	if g, r := s.grid(), replica.grid(); r.cursorRow != g.cursorRow || r.cursorCol != g.cursorCol || !replica.originMode {
		t.Fatalf("the cursor carried above the region replays at %d,%d origin %v, want %d,%d", r.cursorRow, r.cursorCol, replica.originMode, g.cursorRow, g.cursorCol)
	}
	if saved := replica.savedAlt; saved.row != 1 || saved.col != 1 || !saved.originMode {
		t.Fatalf("saved cursor %+v, want the cursor", saved)
	}
}

// TestBlankingHalfAWideGlyphUsesTheCurrentBackground covers the other half of
// a wide glyph that an erase, a glyph printed over one half, or a wide glyph
// that does not fit in the last column blanks: it takes the current
// background, as in the client (grapheme_cluster_test.dart) and xterm.
func TestBlankingHalfAWideGlyphUsesTheCurrentBackground(t *testing.T) {
	blue := vtColor{kind: vtColorIndexed, index: 4}
	for _, c := range []struct {
		stream string
		width  int
		blanks []int
	}{
		{"\x1b[41m\x1b[1;3H\u754c\x1b[44m\x1b[1;4H\u754c", 4, []int{2, 3}},
		{"\x1b[41m\u754c\x1b[44m\x1b[2G\x1b[X", 4, []int{0, 1}},
		{"\x1b[41m\u754c\x1b[44m\x1b[1;1H\x1b[X", 4, []int{0, 1}},
		{"\x1b[41m\u754c\x1b[44m\x1b[2Gx", 4, []int{0}},
	} {
		s := newTerminalScreen(c.width, 3)
		s.Write([]byte(c.stream))
		for _, col := range c.blanks {
			if cell := s.grid().rows[0][col]; cell.r != 0 || cell.width != 1 || cell.attrs.bg != blue {
				t.Fatalf("%+q left column %d as %+v, want a blank in the current background", c.stream, col, cell)
			}
		}
		requirePromptFrameRoundTrip(t, s, c.stream)
	}
}

// requirePromptFrameRoundTrip replays s, written by stream, onto a fresh
// model: it must end with the same cells, row marks and cell contents, but
// for the glyph the cursor waits to wrap after (cursorContent), the same
// scrollback, cursor and saved cursor, and a clear must then save as many
// rows. A cursor outside the scroll region in origin mode that the saved
// cursor cannot restore to is saved first (appendVTCursorOutsideRegion), so
// the saved cursor is not compared then.
func requirePromptFrameRoundTrip(t *testing.T, s *terminalScreen, stream string) {
	t.Helper()
	marks := func(s *terminalScreen) []string {
		var rows []string
		for _, line := range dumpSemanticPrompt(s) {
			if !strings.HasPrefix(line, "cursor") {
				rows = append(rows, line[:2])
			}
		}
		return rows
	}
	replica := replayFrame(s)
	if !vtRowsEqual(s.grid().rows, replica.grid().rows) {
		t.Fatalf("replay of %+q changed the cells\nwant %q\n got %q", stream, graphemeRows(s), graphemeRows(replica))
	}
	if got, want := marks(replica), marks(s); !slices.Equal(got, want) {
		t.Fatalf("replay of %+q changed the row marks to %q, want %q", stream, got, want)
	}
	g := s.grid()
	for r, row := range g.rows {
		for col, cell := range row {
			if g.pendingWrap && r == g.cursorRow && col >= len(row)-2 {
				continue
			}
			if got := replica.grid().rows[r][col].sem; got != cell.sem {
				t.Fatalf("replay of %+q changed the content of %d,%d to %d, want %d", stream, r, col, got, cell.sem)
			}
		}
	}
	if !s.altActive {
		if got, want := replica.scrollback.len(), s.scrollback.len(); got != want {
			t.Fatalf("replay of %+q has %d scrollback lines, want %d", stream, got, want)
		}
		var decoder vtLineDecoder
		for i := range s.scrollback.len() {
			want, got := s.scrollback.at(i).decode(&decoder, s.width), replica.scrollback.at(i).decode(&decoder, s.width)
			if !vtRowsEqual([][]vtCell{want}, [][]vtCell{got}) || !slices.EqualFunc(want, got, func(w, g vtCell) bool { return w.sem == g.sem }) {
				t.Fatalf("replay of %+q changed scrollback line %d", stream, i)
			}
		}
	}
	r := replica.grid()
	if r.cursorRow != g.cursorRow || r.cursorCol != g.cursorCol || r.pendingWrap != g.pendingWrap {
		t.Fatalf("replay of %+q moved the cursor to %d,%d,%v, want %d,%d,%v", stream,
			r.cursorRow, r.cursorCol, r.pendingWrap, g.cursorRow, g.cursorCol, g.pendingWrap)
	}
	if replica.originMode != s.originMode || replica.top != s.top || replica.bottom != s.bottom || replica.insertMode != s.insertMode ||
		replica.attrs != s.attrs || replica.g0Graphics != s.g0Graphics || replica.g1Graphics != s.g1Graphics || replica.shiftOut != s.shiftOut {
		t.Fatalf("replay of %+q left origin mode %v, region %d-%d, insert mode %v, rendition %+v, charsets %v %v %v", stream,
			replica.originMode, replica.top, replica.bottom, replica.insertMode, replica.attrs, replica.g0Graphics, replica.g1Graphics, replica.shiftOut)
	}
	outside := func(row int) bool { return row < s.top || row > s.bottom }
	want, got := *s.saved(), *replica.saved()
	if !s.originMode || !outside(g.cursorRow) || want.originMode && outside(clampInt(want.row, 0, s.height-1)) {
		// Whether DECSC ran, and the Kitty column the client cannot know,
		// change nothing a DECRC restores here.
		want.valid, got.valid = false, false
		want.kittyColumnLost, got.kittyColumnLost = false, false
		if got != want {
			t.Fatalf("replay of %+q changed the saved cursor to %+v, want %+v", stream, got, want)
		}
	}
	s.Write([]byte("\x1b[2J"))
	replica.Write([]byte("\x1b[2J"))
	if got, want := replica.scrollback.len(), s.scrollback.len(); got != want {
		t.Fatalf("after the replay of %+q a clear saves %d rows, want %d", stream, got, want)
	}
}

// TestFramesPaintJoiningGlyphsWithTheirOwnContent covers glyphs a frame
// prints before the one to their left (vtStandaloneRun) written as other
// content than it: each keeps its own, and the app sees the marks a painting
// from the left puts there, a running command's C included.
func TestFramesPaintJoiningGlyphsWithTheirOwnContent(t *testing.T) {
	a, b, c := osc133("A"), osc133("B"), osc133("C")
	swatch, thumb := "\U0001F3FD", "\U0001F44D"
	for _, stream := range []string{
		"\x1b[3G" + swatch + "\x1b[1G" + b + thumb,
		a + "$ " + b + "\x1b[5G" + swatch + "\x1b[3G" + thumb + c,
		a + "$ " + b + c + "\x1b[5G" + swatch + "\x1b[3G" + b + thumb,
		a + "$ " + b + "\x1b[5G" + swatch + c + "\x1b[3G" + thumb,
		a + "$ " + b + "\x1b[7G" + swatch + c + "\x1b[5G" + swatch + "\x1b[3G" + b + thumb,
	} {
		s := newTerminalScreen(10, 3)
		s.Write([]byte(stream))
		requirePromptFrameRoundTrip(t, s, stream)
	}
}

// graphemeFrameCannotPaint reports a picture no frame paints:
//   - a glyph only clustering starts (an emoji modifier on its own) right of
//     one it would join, which only printing the right one first makes;
//   - a cluster narrowed from a wide base in the last column, which a frame
//     moves there from the column before it, right of another glyph that
//     was wide on its way to one column, whose second half would erase it;
//   - half a wide glyph: a wide glyph printed in the last column erases the
//     second half of one there, as the client does, and leaves the first.
func graphemeFrameCannotPaint(s *terminalScreen) bool {
	rows := slices.Clone(s.grid().rows)
	if !s.altActive {
		var decoder vtLineDecoder
		for i := range s.scrollback.len() {
			rows = append(rows, s.scrollback.at(i).decode(&decoder, s.width))
		}
	}
	for _, row := range rows {
		// Glyphs the frame prints before the one to their left
		// (vtStandaloneRun) are painted alone.
		alone := 0
		edge := func(col int) bool { return col == len(row)-1 }
		for col, cell := range row {
			if cell.width == 2 && (col+1 == len(row) || row[col+1].width != 0) ||
				cell.width == 0 && (col == 0 || row[col-1].width != 2) {
				return true
			}
			if cell.width == 0 || cell.r == 0 {
				continue
			}
			if col < alone {
				continue
			}
			alone = vtStandaloneRun(row, col, len(row), vtGlyphBefore(row, col), true, edge)
			plan := planVTGlyph(cell, vtGlyphBefore(row, col), true, col == len(row)-1)
			if plan.whole(cell) {
				continue
			}
			if col != len(row)-1 {
				return true
			}
			// The frame moves clusters it cannot print at the end of the row
			// in from the column before them (vtMovedRun), and paints the
			// glyph before them so it does not widen over them.
			moved := vtMovedRun(row, true)
			if moved == len(row) {
				return true
			}
			for i := moved; i < len(row); i++ {
				if !planVTGlyph(row[i], vtGlyphBefore(row, i-1), true, false).whole(row[i]) {
					return true
				}
			}
			if first := row[moved-1]; first.width == 1 && first.r != 0 &&
				!planVTGlyph(first, vtGlyphBefore(row, moved-1), true, true).whole(first) {
				return true
			}
		}
	}
	return false
}
