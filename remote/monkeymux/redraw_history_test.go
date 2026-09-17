package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestTerminalOutputClearsScreen(t *testing.T) {
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
			if got := terminalOutputClearsScreen([]byte(tt.data)); got != tt.clear {
				t.Fatalf("terminalOutputClearsScreen(%q) = %v, want %v", tt.data, got, tt.clear)
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
