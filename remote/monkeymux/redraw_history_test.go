package main

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

func TestTerminalOutputReplacesScreen(t *testing.T) {
	for _, tt := range []struct {
		name  string
		data  string
		clear bool
	}{
		{"erase display", "\x1b[2J", true},
		{"reset", "\x1bc", true},
		{"home and erase below", "\x1b[H\x1b[J", false},
		{"explicit home", "\x1b[1;1H\x1b[0J", false},
		{"zero home", "\x1b[0;0f\x1b[J", false},
		{"default home", "\x1b[;H\x1b[J", false},
		{"styled home", "\x1b[H\x1b[32m\x1b[J", false},
		{"C1 clear", "\x9b2J", true},
		{"enter alternate screen", "\x1b[?1049h", true},
		{"leave alternate screen", "\x1b[?1049l", true},
		{"enter alternate 1047", "\x1b[?1047h", true},
		{"leave alternate 1047", "\x1b[?1047l", true},
		{"enter alternate 47", "\x1b[?47h", true},
		{"leave alternate 47", "\x1b[?47l", true},
		{"combined private modes", "\x1b[?25;1049;2004h", true},
		{"C1 alternate screen", "\x9b?1047l", true},
		{"save cursor only", "\x1b[?1048h", false},
		{"non-private mode", "\x1b[1049h", false},
		{"alternate mode query", "\x1b[?1049$p", false},
		{"OSC alternate payload", "\x1b]0;\x1b[?1049h\x07", false},
		{"DCS alternate payload", "\x1bP\x1b[?1047l\x1b\\", false},
		{"UTF-8 alternate payload", "\xc2\x9b?1049h", false},
		{"spinner", "\r\x1b[2KWorking 13s", false},
		{"scrollback only", "\x1b[3J", false},
		{"erase below", "\x1b[J", false},
		{"home only", "\x1b[H", false},
		{"moved from home", "\x1b[H\x1b[B\x1b[J", false},
		{"printed from home", "\x1b[Hx\x1b[J", false},
		{"not home", "\x1b[2;1H\x1b[J", false},
		{"truncated", "\x1b[2", false},
		{"cancelled", "\x1b[2\x18J", false},
		{"OSC payload", "\x1b]0;\x1b[2J\x07", false},
		{"DCS payload", "\x1bP\x1bc\x1b\\", false},
		{"APC payload", "\x1b_\x1b[2J\x1b\\", false},
		{"UTF-8 continuation", "\xc2\x9b2J", false},
		{"clear after OSC", "\x1b]0;title\x07\x1b[2J", true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := terminalOutputReplacesScreen([]byte(tt.data), terminalOutputParserSnapshot{}); got != tt.clear {
				t.Fatalf("terminalOutputReplacesScreen(%q) = %v, want %v", tt.data, got, tt.clear)
			}
		})
	}
}

func TestRedrawDoesNotReplayPreviousBufferAcrossAlternateScreenSwitch(t *testing.T) {
	for _, mode := range []string{"47", "1047", "1049", "25;1049;2004"} {
		for _, action := range []string{"h", "l"} {
			t.Run(mode+action, func(t *testing.T) {
				server := newMuxServerWithSize("test", 80, 24)
				window := &muxWindow{
					id:                              "@1",
					redrawForwardingPaused:          true,
					redrawForwardingGeneration:      1,
					redrawForwardingFallbackHistory: []byte("previous buffer content"),
				}
				if action == "l" {
					window.privateModes = map[string]bool{"1049": true}
				}
				server.windows = []*muxWindow{window}
				server.activeID = window.id
				primary, secondary := &recordingConn{}, &recordingConn{}
				registerTestAttachClient(t, server, secondary, "secondary", 80, 24)
				registerTestAttachClient(t, server, primary, "primary", 80, 24)
				window.redrawForwardingPrimaryConn = primary
				const query = "\x1b[>q"
				frame := "\x1b[?" + mode + action + "\x1b[Hnew buffer prompt"
				server.handleWindowOutput(window.id, []byte(frame+query))
				server.resumePausedAttachForwarding(window.id, 1)
				waitForRecordedOutput(t, primary, terminalSynchronizedOutputBegin+frame+query+terminalSynchronizedOutputEnd)
				waitForRecordedOutput(t, secondary, terminalSynchronizedOutputBegin+frame+terminalSynchronizedOutputEnd)
			})
		}
	}
}

func TestRedrawPreservesParserStateAcrossPause(t *testing.T) {
	for _, tt := range []struct {
		name, prefix, continuation string
		keepsBase                  bool
	}{
		// An ESC inside an OSC ends the string, so the erase is real there.
		{"OSC", "\x1b]0;", "\x1b[2J\x07", false},
		{"DCS", "\x1bPpayload", "\x1b[2J\x1b\\", true},
		{"APC", "\x1b_payload", "\x1b[?1049h\x1b\\", true},
		{"UTF-8", "\xc2", "\x9b2J", true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			parser := terminalOutputParserSnapshot{}
			parser.observe([]byte(tt.prefix))
			if terminalOutputReplacesScreen([]byte(tt.continuation), parser) {
				t.Fatal("continuation was treated as a screen replacement")
			}
			if !terminalOutputReplacesScreen([]byte(tt.continuation+"\x1b[2J"), parser) {
				t.Fatal("real erase after the continuation was missed")
			}
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@1", privateModes: map[string]bool{"1049": true}}
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			primary, secondary := &recordingConn{}, &recordingConn{}
			registerTestAttachClient(t, server, secondary, "secondary", 80, 24)
			registerTestAttachClient(t, server, primary, "primary", 80, 24)
			server.handleWindowOutput(window.id, []byte("base frame"+tt.prefix))
			waitForTestAttachWrites(t, server)
			primary.Reset()
			secondary.Reset()
			server.mu.Lock()
			server.pauseAttachForwardingForRedrawLocked(window, 80, 24)
			generation := window.redrawForwardingGeneration
			start := window.redrawForwardingStartParser
			server.mu.Unlock()
			if start.isGround() {
				t.Fatal("pause forgot the partial sequence")
			}
			server.handleWindowOutput(window.id, []byte(tt.continuation+"spinner update"))
			server.resumePausedAttachForwarding(window.id, generation)
			waitForTestAttachWrites(t, server)
			for _, conn := range []*recordingConn{primary, secondary} {
				got := conn.String()
				// The frame is painted from the screen model, whose parser
				// carried the open sequence across the pause: the continuation
				// finishes it instead of leaking as text or a stray command.
				screen := newTerminalScreen(80, 24)
				screen.Write([]byte(got))
				rows := strings.Join(screen.TextRows(), "\n")
				if !strings.Contains(rows, "spinner update") {
					t.Fatalf("lost update across partial sequence: %q", rows)
				}
				if strings.Contains(rows, "base frame") != tt.keepsBase {
					t.Fatalf("base frame retention = %v, want %v: %q", !tt.keepsBase, tt.keepsBase, rows)
				}
				if strings.Contains(rows, "payload") || strings.Contains(rows, "[2J") || strings.Contains(rows, "1049") {
					t.Fatalf("sequence payload leaked into the frame: %q", rows)
				}
			}
		})
	}
}

func differentialComposerHistory() []byte {
	// The editor and footer stay at the bottom while transcript-only updates
	// repaint earlier rows. This is the shape emitted by Pi's real renderer.
	history := []byte("\x1b[2J\x1b[Htranscript\x1b[20;1Hcomposer top border\r\ncomposer input\r\ncomposer bottom border\r\nstatus ready\x1b[21;1H")
	for len(history) <= 2*windowReplayLimitBytes {
		history = append(history, []byte("\x1b[3A\r\x1b[2Klatest transcript update\x1b[3B\r")...)
	}
	return history
}

func TestSwitchFallbackPreservesUnchangedComposerBeyondShellReplayLimit(t *testing.T) {
	for _, tool := range []string{"pi", "copilot", "opencode", ""} {
		name := tool
		if name == "" {
			name = "unrecognized alternate-screen TUI"
		}
		t.Run(name, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@2", index: 1, foregroundCommand: tool}
			if tool == "" {
				window.privateModes = map[string]bool{"1049": true}
			}
			window.appendHistoryLocked(differentialComposerHistory())
			// Capability probes in retained history must not be answered twice.
			window.appendHistoryLocked([]byte("\x1b[6n"))
			server.windows = []*muxWindow{{id: "@1"}, window}
			server.activeID = "@1"
			primary, secondary := &recordingConn{}, &recordingConn{}
			registerTestAttachClient(t, server, secondary, "secondary", 80, 24)
			registerTestAttachClient(t, server, primary, "primary", 80, 24)
			if err := server.selectWindow("@2"); err != nil {
				t.Fatal(err)
			}
			// No resize frame arrives (ConPTY/child can coalesce the short nudge).
			server.mu.Lock()
			generation := window.redrawForwardingGeneration
			server.mu.Unlock()
			server.resumePausedAttachForwarding(window.id, generation)
			waitForTestAttachWrites(t, server)
			for name, conn := range map[string]*recordingConn{"primary": primary, "secondary": secondary} {
				got := conn.String()
				for _, text := range []string{"composer top border", "composer input", "composer bottom border", "status ready", "latest transcript update"} {
					if !strings.Contains(got, text) {
						t.Errorf("%s lost %q from differential frame", name, text)
					}
				}
				if strings.Contains(got, "\x1b[6n") {
					t.Errorf("%s replayed an old cursor query", name)
				}
				if !strings.HasPrefix(got, terminalSynchronizedOutputBegin) || !strings.HasSuffix(got, terminalSynchronizedOutputEnd) {
					t.Errorf("%s fallback was not atomic", name)
				}
			}
		})
	}
}

func TestForegroundHistoryFallbackRendersDifferentialFrame(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{foregroundCommand: "pi"}
	window.appendHistoryLocked(differentialComposerHistory())
	got := server.foregroundHistoryFallbackHistoryLocked(window)
	screen := newTerminalScreen(defaultColumns, defaultRows)
	screen.Write(got)
	rows := screen.TextRows()
	if rows[0] != "transcript" && !strings.Contains(strings.Join(rows, "\n"), "latest transcript update") {
		t.Fatalf("fallback lost the transcript: %q", rows)
	}
	if rows[19] != "composer top border" || rows[20] != "composer input" ||
		rows[21] != "composer bottom border" || rows[22] != "status ready" {
		t.Fatalf("fallback lost the composer rows: %q", rows[19:23])
	}
	if row, col := screen.CursorPosition(); row != 20 || col != 0 {
		t.Fatalf("fallback lost the cursor position: (%d,%d)", row, col)
	}
	// The frame is bounded by the screen, however much output preceded it.
	window.appendHistoryLocked(bytes.Repeat([]byte("x"), 2*windowFullReplayHistoryLimitBytes))
	got = server.foregroundHistoryFallbackHistoryLocked(window)
	if len(got) > windowFullReplayHistoryLimitBytes/2 {
		t.Fatalf("fallback frame is not bounded by the screen: %d bytes", len(got))
	}
}

func TestForegroundHistoryFallbackSkipsEvictedControlSequencePrefix(t *testing.T) {
	server := newMuxServer("test")
	for _, prefix := range []string{"\x1b_Ga=t;", "\x1b]2;", "\x1bP"} {
		window := &muxWindow{foregroundCommand: "pi"}
		payload := []byte(prefix + strings.Repeat("x", windowFullReplayHistoryLimitBytes) + "\x1b\\\x1b[Hcomposer")
		window.appendHistoryLocked(payload)
		got := server.foregroundHistoryFallbackHistoryLocked(window)
		screen := newTerminalScreen(defaultColumns, defaultRows)
		screen.Write(got)
		rows := screen.TextRows()
		if rows[0] != "composer" || strings.Contains(strings.Join(rows, ""), "x") {
			t.Fatalf("fallback retained evicted control payload: %q", rows)
		}
	}
}

// incrementalTUIHistory is the output shape that produced the "blank transcript,
// composer at the bottom" attach bug: one full alternate-screen frame followed
// by more incremental synchronized updates than the byte history retains.
func incrementalTUIHistory(width, height int) []byte {
	var b bytes.Buffer
	b.WriteString("\x1b[?1049h\x1b[2J\x1b[H")
	for row := 1; row <= height-4; row++ {
		fmt.Fprintf(&b, "\x1b[%d;1Htranscript line %d: lorem ipsum dolor sit amet", row, row)
	}
	fmt.Fprintf(&b, "\x1b[%d;1H%s\x1b[%d;1H> \x1b[%d;1H%s", height-2, strings.Repeat("-", width), height-1, height, strings.Repeat("-", width))
	pad := strings.Repeat("\x1b[38;2;1;2;3m·\x1b[0m", 40)
	for tick := 0; b.Len() <= windowFullReplayHistoryLimitBytes+64*1024; tick++ {
		fmt.Fprintf(&b, "\x1b[?2026h\x1b[%d;1H\x1b[2Kspinner %d\x1b[%d;1H\x1b[2Kstatus %s\x1b[%d;3H\x1b[?2026l", height-3, tick, height, pad, height-1)
	}
	return b.Bytes()
}

func renderClientOutput(t *testing.T, conn *recordingConn, width, height int) []string {
	t.Helper()
	screen := newTerminalScreen(width, height)
	screen.Write([]byte(conn.String()))
	return screen.TextRows()
}

// TestRedrawFallbackSurvivesIncrementalHistoryEviction is the regression test
// for the attach that painted only the rows a spinner had touched: the TUI's
// full repaint is long gone from the byte history, the child coalesces the
// synthetic resize, and the client must still receive the whole frame.
func TestRedrawFallbackSurvivesIncrementalHistoryEviction(t *testing.T) {
	for _, answer := range []string{"", "\x1b[?2026h\x1b[21;1H\x1b[2Kspinner tick\x1b[?2026l"} {
		name := "coalesced"
		if answer != "" {
			name = "incremental update"
		}
		t.Run(name, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@2", index: 1, agentTool: "claude"}
			window.appendHistoryLocked(incrementalTUIHistory(80, 24))
			if len(window.history) >= windowFullReplayHistoryLimitBytes && bytes.Contains(window.history, []byte("transcript line 1:")) {
				t.Fatal("test setup: the full repaint must have left the byte history")
			}
			server.windows = []*muxWindow{{id: "@1"}, window}
			server.activeID = "@1"
			primary := &recordingConn{}
			registerTestAttachClient(t, server, primary, "phone", 80, 24)
			if err := server.selectWindow("@2"); err != nil {
				t.Fatal(err)
			}
			if answer != "" {
				server.handleWindowOutput(window.id, []byte(answer))
			}
			server.mu.Lock()
			generation := window.redrawForwardingGeneration
			server.mu.Unlock()
			server.resumePausedAttachForwarding(window.id, generation)
			waitForTestAttachWrites(t, server)
			rows := renderClientOutput(t, primary, 80, 24)
			if rows[0] != "transcript line 1: lorem ipsum dolor sit amet" || rows[19] != "transcript line 20: lorem ipsum dolor sit amet" {
				t.Fatalf("client lost the transcript: %q", rows)
			}
			if rows[21] != strings.Repeat("-", 80) || rows[22] != ">" {
				t.Fatalf("client lost the composer: %q", rows[20:])
			}
			for i, row := range rows {
				if strings.Trim(row, "·") == "" && row != "" {
					t.Fatalf("row %d is a stray padding fragment: %q", i, row)
				}
			}
			if answer != "" && !strings.Contains(rows[20], "spinner tick") {
				t.Fatalf("incremental update was not applied on top of the frame: %q", rows[20])
			}
		})
	}
}

// TestOversizedRedrawPaintsScreenModel covers the other byte cut: a repaint
// longer than the redraw buffer budget used to lose its head, which is where
// the top rows are painted.
func TestOversizedRedrawPaintsScreenModel(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@2", index: 1, agentTool: "pi"}
	window.appendHistoryLocked([]byte("\x1b[2J\x1b[Hold frame"))
	server.windows = []*muxWindow{{id: "@1"}, window}
	server.activeID = "@1"
	primary := &recordingConn{}
	registerTestAttachClient(t, server, primary, "phone", 80, 24)
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	var repaint bytes.Buffer
	repaint.WriteString("\x1b[2J\x1b[Hfresh row one\x1b[24;1H")
	for repaint.Len() <= foregroundRedrawBufferLimitBytes+4096 {
		repaint.WriteString("\x1b[2Ktail status ·\r")
	}
	server.handleWindowOutput(window.id, repaint.Bytes())
	server.mu.Lock()
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding(window.id, generation)
	waitForTestAttachWrites(t, server)
	rows := renderClientOutput(t, primary, 80, 24)
	if rows[0] != "fresh row one" || rows[23] != "tail status ·" {
		t.Fatalf("oversized repaint lost its head: %q", rows)
	}
	if len(primary.String()) > foregroundRedrawBufferLimitBytes {
		t.Fatalf("client received %d bytes for a one-screen frame", len(primary.String()))
	}
}
func TestSwitchRedrawPreservesScreenUnderIncrementalUpdates(t *testing.T) {
	for _, tool := range []string{"muse", "copilot", ""} {
		t.Run("tool="+tool, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@2", foregroundCommand: tool}
			if tool == "" {
				window.privateModes = map[string]bool{"1049": true}
			}
			window.appendHistoryLocked([]byte("\x1b[2J\x1b[Htranscript retained\x1b[20;1Hcomposer retained\x1b[18;1H"))
			server.windows = []*muxWindow{{id: "@1"}, window}
			server.activeID = "@1"
			primary, secondary := &recordingConn{}, &recordingConn{}
			registerTestAttachClient(t, server, secondary, "secondary", 80, 24)
			registerTestAttachClient(t, server, primary, "primary", 80, 24)
			if err := server.selectWindow(window.id); err != nil {
				t.Fatal(err)
			}
			// A spinner tick is visible output, but it is not a complete redraw.
			const delta = "\r\x1b[2KWorking 13s\x1b[20;1H"
			const query = "\x1b[>q"
			server.handleWindowOutput(window.id, []byte(delta+query))
			server.mu.Lock()
			generation := window.redrawForwardingGeneration
			server.mu.Unlock()
			server.resumePausedAttachForwarding(window.id, generation)
			waitForTestAttachWrites(t, server)
			for _, conn := range []*recordingConn{primary, secondary} {
				got := conn.String()
				base := strings.Index(got, "composer retained")
				update := strings.Index(got, delta)
				if !strings.Contains(got, "transcript retained") || base < 0 || update <= base {
					t.Fatalf("incremental redraw lost its base frame: %q", got)
				}
				if strings.Count(got, delta) != 1 {
					t.Fatal("incremental update was duplicated")
				}
				wantQueries := 0
				if conn == primary {
					wantQueries = 1
				}
				if strings.Count(got, query) != wantQueries {
					t.Fatal("restoring the base frame changed terminal query routing")
				}
				if !strings.HasPrefix(got, terminalSynchronizedOutputBegin) || !strings.HasSuffix(got, terminalSynchronizedOutputEnd) {
					t.Fatal("base frame and incremental update were not atomic")
				}
			}
		})
	}
}

// TestOversizedRedrawReplaysEveryPlaceholderImage covers the other half of a
// frame painted from the screen model: the model reproduces Kitty unicode
// placeholder cells faithfully, but the parser skips the APC transmissions that
// fill them, so the images have to travel with the frame. The recency-selected
// replay only carries a handful, which left a frame referencing more images
// than that showing blank image areas (Copilot CLI's inline screenshots).
func TestOversizedRedrawReplaysEveryPlaceholderImage(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@2", index: 1, agentTool: "pi"}
	window.appendHistoryLocked([]byte("\x1b[2J\x1b[Hold frame"))
	server.windows = []*muxWindow{{id: "@1"}, window}
	server.activeID = "@1"
	primary := &recordingConn{}
	registerTestAttachClient(t, server, primary, "phone", 80, 24)
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	// More images than the recency replay carries, each big enough that the
	// replay's byte budget is not what excludes them, and small enough that the
	// whole set fits the repair budget.
	const images = maxReplayedKittyImages + 2
	payload := strings.Repeat("QUJD", 4096)
	ids := make([]int, 0, images)
	var repaint bytes.Buffer
	repaint.WriteString("\x1b[2J\x1b[H")
	for i := 0; i < images; i++ {
		id := 0x010000*(i+1) + 0x0203
		ids = append(ids, id)
		fmt.Fprintf(
			&repaint,
			"\x1b_Ga=T,U=1,f=100,c=2,r=1,q=2,i=%d;%s\x1b\\",
			id,
			payload,
		)
		// The placeholder cells carry the image id in the foreground colour.
		fmt.Fprintf(
			&repaint,
			"\x1b[38;2;%d;%d;%dm\U0010EEEE̅̅\U0010EEEE̅̍\x1b[0m\r\n",
			(id>>16)&0xFF,
			(id>>8)&0xFF,
			id&0xFF,
		)
	}
	// Push the redraw past the buffer budget so it is painted from the screen
	// model instead of forwarded as bytes.
	repaint.WriteString("\x1b[24;1H")
	for repaint.Len() <= foregroundRedrawBufferLimitBytes+4096 {
		repaint.WriteString("\x1b[2Ktail status ·\r")
	}
	server.handleWindowOutput(window.id, repaint.Bytes())
	server.mu.Lock()
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding(window.id, generation)
	waitForTestAttachWrites(t, server)

	got := primary.String()
	if len(got) > foregroundRedrawBufferLimitBytes {
		t.Fatalf("client received %d bytes; the redraw was forwarded verbatim", len(got))
	}
	firstPlaceholder := strings.Index(got, "\U0010EEEE")
	if firstPlaceholder < 0 {
		t.Fatal("frame lost its placeholder cells")
	}
	for _, id := range ids {
		marker := fmt.Sprintf("i=%d;", id)
		switch count := strings.Count(got, marker); count {
		case 1:
		case 0:
			t.Fatalf("image %d is referenced by the frame but was not replayed", id)
		default:
			t.Fatalf("image %d was replayed %d times", id, count)
		}
		if strings.Index(got, marker) > firstPlaceholder {
			t.Fatalf("image %d was replayed after the cells that composite it", id)
		}
	}
	if strings.Contains(got, "a=T") {
		t.Fatalf("replayed transmissions were not store-only: %q", got[:256])
	}
}

// seedPlaceholderImageWindow fills a window with count retained Kitty images,
// each larger than 16 KiB and each followed by the unicode placeholder cells
// that reference it, so the screen model tracks every id. It returns the ids in
// transmission order (oldest first).
func seedPlaceholderImageWindow(
	t *testing.T,
	server *muxServer,
	window *muxWindow,
	count int,
) []string {
	t.Helper()
	// 20000 base64 bytes per image: comfortably above 16 KiB, and small enough
	// that the whole set fits both the replay and the repair byte budgets, so
	// only the replay's count cap can exclude one.
	payload := strings.Repeat("QUJD", 5000)
	ids := make([]string, 0, count)
	var out bytes.Buffer
	out.WriteString("\x1b[2J\x1b[H")
	for i := 0; i < count; i++ {
		id := 0x010000*(i+1) + 0x0203
		ids = append(ids, fmt.Sprintf("%d", id))
		fmt.Fprintf(
			&out,
			"\x1b_Ga=T,U=1,f=100,c=2,r=1,q=2,i=%d;%s\x1b\\",
			id,
			payload,
		)
		// The placeholder cells carry the image id in the foreground colour.
		fmt.Fprintf(
			&out,
			"\x1b[38;2;%d;%d;%dm\U0010EEEE̅̅\U0010EEEE̅̍\x1b[0m\r\n",
			(id>>16)&0xFF,
			(id>>8)&0xFF,
			id&0xFF,
		)
	}
	server.handleWindowOutput(window.id, out.Bytes())
	server.mu.Lock()
	tracked := len(window.screenLocked().PlaceholderImageIDs())
	retained := len(window.kittyImages)
	server.mu.Unlock()
	if tracked != count || retained != count {
		t.Fatalf(
			"seeded window tracks %d placeholder ids and %d images, want %d",
			tracked,
			retained,
			count,
		)
	}
	return ids
}

// TestAttachReplayFollowsUpWithPlaceholderImages covers the images a reattach or
// window switch leaves blank. The synchronous replay carries only the newest few
// roots so a phone can parse it before its readiness deadlines; everything else
// the repainting app still references used to stay blank until the client's
// missing-image request round trip. A separate write behind the replay now
// carries exactly those images.
func TestAttachReplayFollowsUpWithPlaceholderImages(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@1", agentTool: "copilot"}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	ids := seedPlaceholderImageWindow(t, server, window, maxReplayedKittyImages+2)
	replayedIDs := ids[len(ids)-maxReplayedKittyImages:]
	followUpIDs := ids[:len(ids)-maxReplayedKittyImages]

	server.mu.Lock()
	replay, followUp := server.replayBytesWithImageFollowUpLocked(window, nil)
	held := map[string]uint32{
		followUpIDs[0]: window.kittyImageToken[followUpIDs[0]],
	}
	_, heldFollowUp := server.replayBytesWithImageFollowUpLocked(window, held)
	server.mu.Unlock()

	marker := func(id string) string { return "i=" + id + ";" }
	for _, id := range replayedIDs {
		if got := strings.Count(string(replay), marker(id)); got != 1 {
			t.Fatalf("image %s appears %d times in the replay, want 1", id, got)
		}
		if strings.Contains(string(followUp), marker(id)) {
			t.Fatalf("image %s was sent twice: replay and follow-up", id)
		}
	}
	for _, id := range followUpIDs {
		if strings.Contains(string(replay), marker(id)) {
			t.Fatalf("image %s must not grow the synchronous replay", id)
		}
		if got := strings.Count(string(followUp), marker(id)); got != 1 {
			t.Fatalf("image %s appears %d times in the follow-up, want 1", id, got)
		}
	}
	if strings.Contains(string(followUp), "a=T") {
		t.Fatal("follow-up transmissions were not store-only")
	}
	if len(replay)+len(followUp) > maxKittyImageRepairBytes {
		t.Fatalf(
			"replay plus follow-up = %d bytes, over the repair budget",
			len(replay)+len(followUp),
		)
	}
	if strings.Contains(string(heldFollowUp), marker(followUpIDs[0])) {
		t.Fatalf(
			"image %s was re-sent although the client reported holding it",
			followUpIDs[0],
		)
	}
	if !strings.Contains(string(heldFollowUp), marker(followUpIDs[1])) {
		t.Fatalf(
			"image %s is still missing on the client and must be sent",
			followUpIDs[1],
		)
	}

	// The follow-up must actually reach the attach client, behind the replay.
	primary := &recordingConn{}
	client := registerTestAttachClient(t, server, primary, "phone", 80, 24)
	server.replayActiveWindowToClient(client)
	waitForTestAttachWrites(t, server)
	got := primary.String()
	if !strings.HasPrefix(got, string(replay)) {
		t.Fatal("client did not receive the replay first")
	}
	for _, id := range ids {
		if count := strings.Count(got, marker(id)); count != 1 {
			t.Fatalf("client received image %s %d times, want once", id, count)
		}
	}
	for _, id := range followUpIDs {
		if strings.Index(got, marker(id)) < len(replay) {
			t.Fatalf("image %s was folded into the replay write", id)
		}
	}
}

// TestPlaceholderImageFollowUpKeepsReplayBudget pins the synchronous replay to
// exactly the bytes it carried before the follow-up existed: it is what the
// client must parse before SSH and terminal readiness deadlines, so the repair
// may only ever ride behind it.
func TestPlaceholderImageFollowUpKeepsReplayBudget(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@1", agentTool: "copilot"}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	seedPlaceholderImageWindow(t, server, window, maxReplayedKittyImages+2)

	server.mu.Lock()
	// The pre-change foreground-redraw replay: the recency-selected images and
	// nothing else.
	want := buildWindowReplay(window, window.kittyImageReplayLocked(nil))
	replay, followUp := server.replayBytesWithImageFollowUpLocked(window, nil)
	active := server.activeReplayLocked()
	server.mu.Unlock()

	if !bytes.Equal(replay, want) {
		t.Fatalf(
			"replay grew from %d to %d bytes; readiness budget changed",
			len(want),
			len(replay),
		)
	}
	if !bytes.Equal(active, want) {
		t.Fatal("activeReplayLocked no longer matches the attach-safe replay")
	}
	if len(replay) > maxReplayedKittyImageBytes+4096 {
		t.Fatalf("replay is %d bytes, well past the attach-safe budget", len(replay))
	}
	if len(followUp) == 0 {
		t.Fatal("images the frame references were left for the repair round trip")
	}
}

// TestWindowSelectDeliversPlaceholderImageFollowUp covers the switch path a
// foreground-redraw pane actually takes: the replay is withheld until the
// repaint it belongs with, so the image follow-up has to travel with it instead
// of racing ahead of the clear.
func TestWindowSelectDeliversPlaceholderImageFollowUp(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot"}
	server.windows = []*muxWindow{{id: "@1"}, window}
	server.activeID = "@1"
	ids := seedPlaceholderImageWindow(t, server, window, maxReplayedKittyImages+2)

	primary := &recordingConn{}
	registerTestAttachClient(t, server, primary, "phone", 80, 24)
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	server.handleWindowOutput(window.id, []byte("\x1b[2J\x1b[Hrepainted"))
	server.mu.Lock()
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding(window.id, generation)
	waitForTestAttachWrites(t, server)

	got := primary.String()
	for _, id := range ids {
		if count := strings.Count(got, "i="+id+";"); count != 1 {
			t.Fatalf("image %s was delivered %d times, want once", id, count)
		}
	}
	if !strings.Contains(got, "repainted") {
		t.Fatal("the repaint the replay belongs with was lost")
	}
}
