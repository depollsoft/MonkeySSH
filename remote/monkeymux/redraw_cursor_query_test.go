package main

import (
	"strings"
	"testing"
	"time"
)

func TestVTScreenCursorPositionReport(t *testing.T) {
	s := newTerminalScreen(80, 24)
	s.Write([]byte("\x1b[7;9H"))
	if got := string(s.CursorPositionReport()); got != "\x1b[7;9R" {
		t.Fatalf("report = %q, want 1-based row 7 column 9", got)
	}
	s.Write([]byte("\x1b[5;20r\x1b[?6h\x1b[2;3H"))
	if got := string(s.CursorPositionReport()); got != "\x1b[2;3R" {
		t.Fatalf("origin-mode report = %q, want the row counted from the margin", got)
	}
	s.Write([]byte("\x1b[?6l\x1b[r\x1b[1;1H" + strings.Repeat("x", 80)))
	if got := string(s.CursorPositionReport()); got != "\x1b[1;80R" {
		t.Fatalf("pending-wrap report = %q, want the last column", got)
	}
	s.Write([]byte("\x1b[?1049h\x1b[3;4H"))
	if got := string(s.CursorPositionReport()); got != "\x1b[3;4R" {
		t.Fatalf("alternate-screen report = %q, want the alternate cursor", got)
	}
}

func newRedrawCursorQueryTestServer(
	t *testing.T,
) (*muxServer, *muxWindow, *recordingPty, *recordingConn) {
	t.Helper()
	server := newMuxServer("redraw-cursor-query")
	pty := &recordingPty{}
	window := &muxWindow{
		id:                         "@1",
		agentTool:                  "codex",
		pty:                        pty,
		screenWidth:                80,
		screenHeight:               24,
		lastActivity:               time.Now(),
		redrawForwardingPaused:     true,
		redrawForwardingGeneration: 1,
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", 80, 24)
	window.redrawForwardingPrimaryConn = attach
	return server, window, pty, attach
}

// Codex asks where the cursor is after every resize and draws nothing until
// it hears back. A redraw pause holds that query with the rest of the output,
// so the temporary-size frame used to escape the pause and paint, followed one
// round trip later by the real frame. MonkeyMux answers it from the screen
// model instead, at the position the query was sent from.
func TestRedrawPauseAnswersCursorPositionQueryFromScreenModel(t *testing.T) {
	server, window, pty, attach := newRedrawCursorQueryTestServer(t)

	server.handleWindowOutput(
		"@1",
		[]byte("\x1b[?1049h\x1b[H\x1b[2J\x1b[5;10Hhi"+cursorPositionQuery+"\x1b[1;1Hlater"),
	)
	waitForWindowReplies(t, window)

	if got := pty.String(); got != "\x1b[5;12R" {
		t.Fatalf("window got %q, want the model's report at the query", got)
	}
	server.mu.Lock()
	queries := string(window.redrawForwardingQueryBuffer)
	held := string(window.redrawForwardingBuffer)
	server.mu.Unlock()
	if queries != "" || strings.Contains(held, cursorPositionQuery) {
		t.Fatalf("held queries %q, held output %q: want the answered query dropped", queries, held)
	}

	server.resumePausedAttachForwarding("@1", 1)
	waitForTestAttachWrites(t, server)
	if got := attach.String(); strings.Contains(got, cursorPositionQuery) ||
		!strings.Contains(got, "later") {
		t.Fatalf("attach output = %q, want the redraw without the answered query", got)
	}
}

// A local answer must not overtake the terminal's answer to a query sent
// before it, so a cursor query behind another query still goes to the
// terminal.
func TestRedrawPauseLeavesCursorQueryBehindAnotherQueryToTerminal(t *testing.T) {
	for _, tc := range []struct {
		name    string
		earlier func(*muxWindow)
		chunk   string
	}{
		{
			name:  "same chunk",
			chunk: "\x1b[c" + cursorPositionQuery,
		},
		{
			name: "held by the pause",
			earlier: func(window *muxWindow) {
				window.redrawForwardingQueryBuffer = []byte("\x1b[>q")
			},
			chunk: cursorPositionQuery,
		},
		{
			name: "replayed on attach",
			earlier: func(window *muxWindow) {
				window.pendingTerminalQueriesInFlight = []byte("\x1b[c")
			},
			chunk: cursorPositionQuery,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server, window, pty, _ := newRedrawCursorQueryTestServer(t)
			if tc.earlier != nil {
				tc.earlier(window)
			}

			server.handleWindowOutput("@1", []byte(tc.chunk))
			waitForWindowReplies(t, window)

			if got := pty.String(); got != "" {
				t.Fatalf("window got %q, want the terminal left to answer", got)
			}
			server.mu.Lock()
			queries := string(window.redrawForwardingQueryBuffer)
			server.mu.Unlock()
			if !strings.HasSuffix(queries, cursorPositionQuery) {
				t.Fatalf("held queries = %q, want the cursor query kept for the terminal", queries)
			}
		})
	}
}

// Outside a redraw pause the terminal sees the output as it is sent, so it
// answers the query itself.
func TestCursorPositionQueryOutsideRedrawPauseReachesTerminal(t *testing.T) {
	server, window, pty, attach := newRedrawCursorQueryTestServer(t)
	window.redrawForwardingPaused = false

	server.handleWindowOutput("@1", []byte("\x1b[5;10H"+cursorPositionQuery))
	waitForWindowReplies(t, window)
	waitForTestAttachWrites(t, server)

	if got := pty.String(); got != "" {
		t.Fatalf("window got %q, want no local answer", got)
	}
	if got := attach.String(); !strings.Contains(got, cursorPositionQuery) {
		t.Fatalf("attach output = %q, want the query forwarded", got)
	}
}
