package main

import (
	"bytes"
	"strings"
	"testing"
)

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
