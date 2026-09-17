package main

import (
	"bytes"
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
	for _, tt := range []struct{ name, prefix, continuation string }{
		{"OSC", "\x1b]0;", "\x1b[2J\x07"},
		{"DCS", "\x1bPpayload", "\x1b[2J\x1b\\"},
		{"APC", "\x1b_payload", "\x1b[?1049h\x1b\\"},
		{"UTF-8", "\xc2", "\x9b2J"},
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
				if !strings.Contains(got, "base frame") || !strings.Contains(got, "spinner update") {
					t.Fatalf("lost base or update across partial sequence: %q", got)
				}
				if !strings.Contains(got, tt.prefix+tt.continuation) {
					t.Fatalf("replay split the retained sequence: %q", got)
				}
			}
		})
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

func TestForegroundHistoryFallbackPreservesCursorOperationsAndBound(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{foregroundCommand: "pi"}
	history := differentialComposerHistory()
	window.appendHistoryLocked(history)
	got := server.foregroundHistoryFallbackHistoryLocked(window)
	if !bytes.Equal(got, history) {
		t.Fatalf("fallback truncated differential state: got %d bytes, want %d", len(got), len(history))
	}
	window.appendHistoryLocked(bytes.Repeat([]byte("x"), 2*windowFullReplayHistoryLimitBytes))
	got = server.foregroundHistoryFallbackHistoryLocked(window)
	if len(got) > windowFullReplayHistoryLimitBytes {
		t.Fatalf("fallback exceeded bounded TUI history: %d bytes", len(got))
	}
}

func TestForegroundHistoryFallbackSkipsEvictedControlSequencePrefix(t *testing.T) {
	server := newMuxServer("test")
	for _, prefix := range []string{"\x1b_Ga=t;", "\x1b]2;", "\x1bP"} {
		window := &muxWindow{foregroundCommand: "pi"}
		payload := []byte(prefix + strings.Repeat("x", windowFullReplayHistoryLimitBytes) + "\x1b\\\x1b[Hcomposer")
		window.appendHistoryLocked(payload)
		got := server.foregroundHistoryFallbackHistoryLocked(window)
		if string(got) != "\x1b[Hcomposer" {
			t.Fatalf("fallback retained evicted control payload: %d bytes", len(got))
		}
	}
}
