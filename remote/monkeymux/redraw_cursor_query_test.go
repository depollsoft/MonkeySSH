package main

import (
	"strings"
	"testing"
	"time"
)

func TestVTScreenCursorPositionReport(t *testing.T) {
	s := newTerminalScreen(80, 24)
	report := func() string {
		t.Helper()
		got, ok := s.CursorPositionReport()
		if !ok {
			return "unanswerable"
		}
		return string(got)
	}
	if got := report(); got != "unanswerable" {
		t.Fatalf("report before any position = %q, want none", got)
	}
	s.Write([]byte("\x1b[7;9H"))
	if got := report(); got != "\x1b[7;9R" {
		t.Fatalf("report = %q, want 1-based row 7 column 9", got)
	}

	// What moves the cursor in neither the model nor the app's terminal keeps
	// it known: the tail of a Codex frame, titles, queries, erases.
	s.Write([]byte("\x1b[0;1m\x1b]0;title\x07\x1b[?25h\x1b[?2026l\x1b[>7u" +
		"\x1b[=0;1u\x1b[2 q\x1b[>q\x1b[c\x1b[?2004h\x1b[?1000;1006h\x1b[K\x1b[J" +
		"\x07\x1b=\x1b(0\x1b(B\x1b_Ga=t,f=32,s=1,v=1;/wAA/w==\x1b\\"))
	if got := report(); got != "\x1b[7;9R" {
		t.Fatalf("report after cursor-neutral output = %q, want 7;9", got)
	}

	// Anything else leaves it unknown until the next absolute position: the
	// two differ on a pending wrap, LNM, margins kept per screen, sequences
	// one of them ignores, and image placements.
	for _, seq := range []string{
		"x", "\b", "\r", "\n", "\t", "\x1bD", "\x1bM", "\x1b7", "\x1b8", "\x1b#8", "\x1bc",
		"\x1b[A", "\x1b[2D", "\x1b[5G", "\x1b[3d", "\x1b[2a", "\x1b[2e", "\x1b[3`", "\x1b[2b",
		"\x1b[s", "\x1b[u", "\x1b[!p", "\x1b[2;10r", "\x1b[20h", "\x1b[4h", "\x1b[@", "\x1b[P",
		"\x1b[X", "\x1b[L", "\x1b[S", "\x1b[?1049h\x1b[?1049l", "\x1b[?47h\x1b[?47l",
		"\x1b[?1048h", "\x1b[?7l\x1b[?7h", "\x1b[?2C", "\x1b[2 A", "\x1b[?J",
		"\x1bXsos\x1b\\", "\x1b^pm\x1b\\", "\x1bP$qm\x1b\\", "\x1b]0;a\x18b",
		"\x1b_Ga=T,f=32,s=1,v=1,r=2,c=2;/wAA/w==\x1b\\",
		"\x1b_Ga=p,i=7,r=2,c=2\x1b\\",
		"\x1b_Ga=T,f=32,s=1,v=1\x9c",
		"\x1b_Gf=32,s=1,v=1" + strings.Repeat(",X=0", 70) + ",a=T;/wAA/w==\x1b\\",
		"\x9b3;4H", "\x9c",
		// The app places iTerm2 inline images like Kitty ones.
		"\x1b]1337;File=inline=1;height=3:AAAA\x07", "\x1b]1337;File=inline=1:AAAA\x1b\\",
		// Parser states the two leave differently.
		"\x1b\x07=", "\x1b(\x07B",
	} {
		s.Write([]byte("\x1b[3;4H" + seq))
		if got := report(); got != "unanswerable" {
			t.Fatalf("report after %q = %q, want none", seq, got)
		}
		// The BEL ends any string the app's output decoder is still in.
		s.Write([]byte("\a\x1b[3;4H"))
		if got := report(); got != "\x1b[3;4R" {
			t.Fatalf("report after %q and CUP = %q, want 3;4", seq, got)
		}
	}

	// Placements that do not move the client's cursor keep it known.
	for _, command := range []string{
		"a=T,f=32,s=1,v=1,C=1", "a=T,f=32,s=1,v=1,U=1", "a=d,d=a", "a=q,i=1",
	} {
		s.Write([]byte("\x1b[3;4H\x1b_G" + command + ";/wAA/w==\x1b\\"))
		if got := report(); got != "\x1b[3;4R" {
			t.Fatalf("report after %s = %q, want 3;4", command, got)
		}
	}

	// In origin mode the app's terminal counts rows from its own margins,
	// which it keeps per screen, so even a CUP leaves the cursor unknown.
	s.Write([]byte("\x1b[5;20r\x1b[?6h\x1b[2;3H"))
	if got := report(); got != "unanswerable" {
		t.Fatalf("origin-mode report = %q, want none", got)
	}
	s.Write([]byte("\x1b[?6l\x1b[r"))

	// After some output even a CUP may land elsewhere in the app's terminal,
	// until a reset or a real resize: origin mode, which it does not restore
	// with DECRC; a CSI too long for the parser to keep; a resize request.
	reset := func() { s.Write([]byte("\x1bc")) }
	resize := func() {
		s.Resize(81, 24)
		s.Resize(80, 24)
	}
	both := func() {
		reset()
		resize()
	}
	for _, tc := range []struct {
		name  string
		seq   string
		clear func()
	}{
		{"origin mode restored by DECRC", "\x1b[5;20r\x1b7\x1b[?6h\x1b8\x1b[r", reset},
		{"truncated mode list", "\x1b[?" + strings.Repeat("25;", 21) + "1;1049h", both},
		{"truncated CUP", "\x1b[" + strings.Repeat("9", 64) + ";9H", both},
		{"ignored mode change", "\x1b[?6?h", both},
		{"abandoned CSI", "\x1b[?6\x18", both},
		{"origin mode with an intermediate", "\x1b[5;20r\x1b[?6 h", reset},
		{"sequence inside an SOS string", "\x1b[5;20r\x1bX\x1b[?6h\x1b\\", both},
		{"tmux passthrough", "\x1bPtmux;\x1b\x1b[?6h\x1b\\", both},
		{"ESC inside an APC", "\x1b_Ga=t\x1bD\x1b\\", both},
		{"resize request", "\x1b[8;10;20t", resize},
		{"host resize request", "\x1b[?8;10;20t", resize},
		{"resize request with an intermediate", "\x1b[8;10;20 t", resize},
	} {
		s.Write([]byte("\x1b[3;4H" + tc.seq))
		if got := report(); got != "unanswerable" {
			t.Fatalf("%s: report = %q, want none", tc.name, got)
		}
		s.Write([]byte("\x1b[3;4H"))
		if got := report(); got != "unanswerable" {
			t.Fatalf("%s: report after a CUP = %q, want none", tc.name, got)
		}
		tc.clear()
		s.Write([]byte("\x1b[3;4H"))
		if got := report(); got != "\x1b[3;4R" {
			t.Fatalf("%s: report once cleared = %q, want 3;4", tc.name, got)
		}
	}
	// The app's terminal keeps a requested size through a reset.
	s.Write([]byte("\x1b[8;10;20t\x1bc\x1b[3;4H"))
	if got := report(); got != "unanswerable" {
		t.Fatalf("report after a resize request and a reset = %q, want none", got)
	}
	resize()

	// An ESC that abandons a sequence can make the app's output decoder
	// misframe the one it starts (in insert mode it injects ICH into the
	// parameters), so that CUP is not trusted; the next one is.
	for _, abandoned := range []string{"\x1b", "\x1b(", "\x1b[2"} {
		s.Write([]byte("\x1b[4h\x1b[r\x1bc\x1b[4h" + abandoned + "\x1b[5;5H"))
		if got := report(); got != "unanswerable" {
			t.Fatalf("report after %q and a CUP = %q, want none", abandoned, got)
		}
		s.Write([]byte("\x1b[5;5H"))
		if abandoned == "\x1b[2" {
			// An abandoned CSI also distrusts every CUP until a reset and
			// a real resize.
			s.Write([]byte("\x1bc"))
			s.Resize(81, 24)
			s.Resize(80, 24)
			s.Write([]byte("\x1b[5;5H"))
		}
		if got := report(); got != "\x1b[5;5R" {
			t.Fatalf("report after %q and two CUPs = %q, want 5;5", abandoned, got)
		}
	}
	s.Write([]byte("\x1b[4l"))

	// The app's output decoder ends a string only at BEL or ESC \\ and holds
	// everything after until then, so a string the model ended any other way
	// leaves even a CUP unanswerable until one of those arrives.
	for _, seq := range []string{
		"\x1b]2;abc\x1b[5;5H", "\x1b]2;abc\x1bm", "\x1b]2;ab\x18", "\x1b]2;ab\x9c",
		"\x1b_Ga=T\x18", "\x1bP\x1a", "\x1b_Ga=t\x9c",
	} {
		for _, end := range []string{"\a", "\x1b\\"} {
			s.Write([]byte(seq + "\x1b[3;4H"))
			if got := report(); got != "unanswerable" {
				t.Fatalf("report after %q and CUP = %q, want none", seq, got)
			}
			s.Write([]byte(end + "\x1b[3;4H"))
			if got := report(); got != "\x1b[3;4R" {
				t.Fatalf("report after %q, %q and CUP = %q, want 3;4", seq, end, got)
			}
		}
	}

	// A chunked transmission places its image when the last chunk arrives,
	// whatever the cursor did in between.
	for _, tc := range []struct {
		first string
		moves bool
	}{
		{"a=T,f=32,s=1,v=1,m=1", true},
		{"a=T,f=32,s=1,v=1,r=2,c=2,q=2,m=1", true},
		{"a=t,f=32,s=1,v=1,m=1", false},
	} {
		s.Write([]byte("\x1b_G" + tc.first + ";AAAA\x1b\\\x1b[2;2H\x1b_Gm=1;AAAA\x1b\\"))
		if got := report(); got != "\x1b[2;2R" {
			t.Fatalf("after %s and a middle chunk report = %q, want 2;2", tc.first, got)
		}
		s.Write([]byte("\x1b_Gm=0;AAAA\x1b\\"))
		if got := report(); (got == "unanswerable") != tc.moves {
			t.Fatalf("after %s and its last chunk report = %q, want unanswerable=%v", tc.first, got, tc.moves)
		}
	}

	// A resize moves the cursor on both sides by rules the model does not
	// follow closely enough.
	s.Write([]byte("\x1b[3;4H"))
	s.Resize(100, 30)
	if got := report(); got != "unanswerable" {
		t.Fatalf("report after a resize = %q, want none", got)
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
	// The program last placed the cursor absolutely, as Codex ends a frame.
	server.mu.Lock()
	window.screenLocked().Write([]byte("\x1b[1;1H"))
	server.mu.Unlock()
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
		[]byte("\x1b[?1049h\x1b[H\x1b[2Jhi\x1b[5;10H\x1b[?25h"+cursorPositionQuery+"\x1b[1;1Hlater"),
	)
	waitForWindowReplies(t, window)

	if got := pty.String(); got != "\x1b[5;10R" {
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

// A query the model cannot answer as the client would goes to the terminal,
// and so does every later one, which would otherwise be answered first.
func TestRedrawPauseLeavesUnanswerableCursorQueriesToTerminal(t *testing.T) {
	for _, tc := range []struct {
		name   string
		chunks []string
		held   string
	}{
		{
			name:   "after a Kitty placement",
			chunks: []string{"\x1b[5;10H\x1b_Ga=T,f=32,s=1,v=1,r=2,c=2,q=2;/wAA/w==\x1b\\" + cursorPositionQuery},
			held:   cursorPositionQuery,
		},
		{
			name:   "after printing",
			chunks: []string{"\x1b[5;10Hhi" + cursorPositionQuery},
			held:   cursorPositionQuery,
		},
		{
			name:   "in origin mode, then outside it",
			chunks: []string{"\x1b[5;20r\x1b[?6h\x1b[2;3H" + cursorPositionQuery + "\x1b[?6l\x1b[r\x1b[1;1H" + cursorPositionQuery},
			held:   cursorPositionQuery + cursorPositionQuery,
		},
		{
			name:   "split across reads",
			chunks: []string{"\x1b[6", "n"},
			held:   cursorPositionQuery,
		},
		{
			name:   "read that starts inside an OSC",
			chunks: []string{"\x1b]2;title", "\x07" + cursorPositionQuery},
			held:   cursorPositionQuery,
		},
		{
			// The scanner sees a query where the model is mid-sequence;
			// removing it would turn the lone ESC into ESC h.
			name:   "after a lone ESC",
			chunks: []string{"\x1b" + cursorPositionQuery + "hello"},
			held:   cursorPositionQuery,
		},
		{
			name:   "inside an SOS string",
			chunks: []string{"\x1bXabc" + cursorPositionQuery + "\x1b\\"},
			held:   cursorPositionQuery,
		},
		{
			// The terminal reads parameters as numbers, so CSI 06 n is a
			// cursor query it answers first.
			name:   "behind a zero-padded query",
			chunks: []string{"\x1b[2;3H\x1b[06n\x1b[7;9H" + cursorPositionQuery},
			held:   "\x1b[06n" + cursorPositionQuery,
		},
		{
			name:   "behind a query with extra parameters",
			chunks: []string{"\x1b[2;3H\x1b[6;0n\x1b[7;9H" + cursorPositionQuery + "x"},
			held:   "\x1b[6;0n" + cursorPositionQuery,
		},
		{
			name:   "behind a query with extra parameters in an earlier read",
			chunks: []string{"\x1b[2;3H\x1b[6:0n", "\x1b[7;9H" + cursorPositionQuery + "x"},
			held:   "\x1b[6:0n" + cursorPositionQuery,
		},
		{
			name:   "C1 and DECXCPR forms",
			chunks: []string{"\x9b6n\x1b[?6n"},
			held:   "\x9b6n\x1b[?6n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server, window, pty, _ := newRedrawCursorQueryTestServer(t)

			for _, chunk := range tc.chunks {
				server.handleWindowOutput("@1", []byte(chunk))
			}
			waitForWindowReplies(t, window)

			if got := pty.String(); got != "" {
				t.Fatalf("window got %q, want the terminal left to answer", got)
			}
			server.mu.Lock()
			queries := string(window.redrawForwardingQueryBuffer)
			server.mu.Unlock()
			if queries != tc.held {
				t.Fatalf("held queries = %q, want %q", queries, tc.held)
			}
		})
	}
}

// Codex asks again after drawing each size, in separate reads; every answer
// reflects the frame drawn before it.
func TestRedrawPauseAnswersEachCursorQueryAtItsOwnPosition(t *testing.T) {
	server, window, pty, _ := newRedrawCursorQueryTestServer(t)

	for _, chunk := range []string{
		cursorPositionQuery,
		"\x1b[1;1H\x1b[Jhello world!\x1b[1;13H",
		cursorPositionQuery,
	} {
		server.handleWindowOutput("@1", []byte(chunk))
	}
	waitForWindowReplies(t, window)

	if got := pty.String(); got != "\x1b[1;1R\x1b[1;13R" {
		t.Fatalf("window got %q, want one report per query", got)
	}
}

// DECXCPR (CSI ? 6 n) is answered the way the app's terminal answers it.
func TestRedrawPauseAnswersExtendedCursorPositionQuery(t *testing.T) {
	server, window, pty, _ := newRedrawCursorQueryTestServer(t)

	server.handleWindowOutput("@1", []byte("\x1b[3;7H"+extendedCursorPositionQuery+cursorPositionQuery))
	waitForWindowReplies(t, window)

	if got := pty.String(); got != "\x1b[?3;7;1R\x1b[3;7R" {
		t.Fatalf("window got %q, want a DECXCPR then a CPR", got)
	}
}

// A redraw that only moves the cursor would normally be replaced by the frame
// from before the pause, but the program has been told the moved position, so
// the client must end up there too.
func TestRedrawPauseResumesAtTheReportedCursor(t *testing.T) {
	for _, tc := range []struct {
		name     string
		before   string
		redraw   string
		report   string
		row, col int
		rows     map[int]string
	}{
		{
			name:   "cursor move",
			before: "\x1b[1;1Hbase",
			redraw: "\x1b[10;20H",
			report: "\x1b[10;20R",
			row:    9, col: 19,
			rows: map[int]string{0: "base"},
		},
		{
			// Erasing the area below a position paints nothing either.
			name:   "erase then ask",
			before: "\x1b[2J\x1b[1;1Hbase\x1b[20;1Hprompt> ",
			redraw: "\x1b[17;1H\x1b[J",
			report: "\x1b[17;1R",
			row:    16, col: 0,
			rows: map[int]string{0: "base", 19: ""},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server, window, pty, attach := newRedrawCursorQueryTestServer(t)
			window.redrawForwardingPaused = false
			server.handleWindowOutput("@1", []byte(tc.before))
			waitForTestAttachWrites(t, server)
			server.mu.Lock()
			window.redrawForwardingPaused = true
			window.redrawForwardingFallbackScreen = window.screenLocked().Clone()
			server.mu.Unlock()

			server.handleWindowOutput("@1", []byte(tc.redraw+cursorPositionQuery))
			waitForWindowReplies(t, window)
			if got := pty.String(); got != tc.report {
				t.Fatalf("window got %q, want %q", got, tc.report)
			}
			server.resumePausedAttachForwarding("@1", 1)
			waitForTestAttachWrites(t, server)

			client := newTerminalScreen(80, 24)
			client.Write([]byte(attach.String()))
			if row, col := client.CursorPosition(); row != tc.row || col != tc.col {
				t.Fatalf("client cursor = (%d,%d), want the reported (%d,%d)", row, col, tc.row, tc.col)
			}
			for row, want := range tc.rows {
				if got := client.TextRows()[row]; got != want {
					t.Fatalf("client row %d = %q, want %q", row, got, want)
				}
			}
		})
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

// A cursor query sent to the terminal before the pause may still be waiting
// for its reply when the next one is held. Answering the held one first would
// pair each position with the wrong query, so the local answer waits until the
// terminal's reply has reached the window.
func TestRedrawPauseWaitsForTerminalReplyOwedFromBeforeIt(t *testing.T) {
	for _, replied := range []bool{false, true} {
		name := "reply outstanding"
		if replied {
			name = "reply delivered"
		}
		t.Run(name, func(t *testing.T) {
			server, window, pty, attach := newRedrawCursorQueryTestServer(t)
			client := server.attachClients[attach]
			go server.runAttachInputActions(client)
			window.redrawForwardingPaused = false
			server.handleWindowOutput("@1", []byte(cursorPositionQuery))
			waitForTestAttachWrites(t, server)

			server.mu.Lock()
			window.redrawForwardingPaused = true
			server.mu.Unlock()
			reply := ""
			if replied {
				reply = "\x1b[1;1R"
				routing := client.routeInput([]byte(reply))
				client.enqueueInputActions(routing.actions)
				waitForTerminalRepliesSettled(t, client, "@1")
			}
			server.handleWindowOutput("@1", []byte("\x1b[5;10H"+cursorPositionQuery))
			waitForWindowReplies(t, window)

			want := reply
			if replied {
				want += "\x1b[5;10R"
			}
			if got := pty.String(); got != want {
				t.Fatalf("window got %q, want %q", got, want)
			}
		})
	}
}

// A client owes a window a reply from the moment a query is queued to it
// until the reply has been written to the window, or the wait for it expires.
func TestAttachClientOwesReplyUntilItReachesTheWindow(t *testing.T) {
	server := newMuxServer("owed-replies")
	pty := &recordingPty{}
	window := &muxWindow{id: "@1", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "primary", 80, 24)
	owes := func() bool { return client.owesTerminalReplies("@1", time.Now()) }

	gate := &attachWriteGate{done: make(chan struct{})}
	client.enqueueWrite([]byte(cursorPositionQuery), false, "@1", 1, gate)
	if !owes() {
		t.Fatal("a query queued to the client must count as owed")
	}
	if client.owesTerminalReplies("@2", time.Now()) {
		t.Fatal("another window must not be owed anything")
	}
	gate.deliver.Store(true)
	close(gate.done)
	waitForRecordedOutput(t, conn, cursorPositionQuery)
	waitForTestAttachWrites(t, server)
	if !owes() {
		t.Fatal("a sent query must count as owed until its reply arrives")
	}
	if client.owesTerminalReplies("@1", time.Now().Add(2*terminalResponseFocusGrace)) {
		t.Fatal("a reply the client stopped waiting for must not count as owed")
	}

	routing := client.routeInput([]byte("\x1b[3;4R"))
	if !owes() {
		t.Fatal("a received reply must count as owed until it reaches the window")
	}
	client.enqueueInputActions(routing.actions)
	go server.runAttachInputActions(client)
	waitForTerminalRepliesSettled(t, client, "@1")
	if got := pty.String(); got != "\x1b[3;4R" {
		t.Fatalf("window got %q, want the reply", got)
	}

	dropped := &attachWriteGate{done: make(chan struct{})}
	client.enqueueWrite([]byte(cursorPositionQuery), false, "@1", 1, dropped)
	close(dropped.done)
	waitForTerminalRepliesSettled(t, client, "@1")
}

// A removed client's input worker can still be writing a reply it received,
// so the reply stays owed until it is written, and the client is forgotten
// once it owes nothing.
func TestRemovedClientOwesRepliesItIsStillDelivering(t *testing.T) {
	server := newMuxServer("removed-client-replies")
	pty := &recordingPty{}
	window := &muxWindow{id: "@1", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "leaving", 80, 24)
	client.enqueueWrite([]byte(cursorPositionQuery), false, "@1", 1, nil)
	waitForRecordedOutput(t, conn, cursorPositionQuery)
	waitForTestAttachWrites(t, server)
	routing := client.routeInput([]byte("\x1b[1;1R"))
	client.enqueueInputActions(routing.actions)

	server.removeAttachClient(client)
	owes := func() bool {
		server.mu.Lock()
		defer server.mu.Unlock()
		return server.terminalOwesRepliesLocked("@1")
	}
	if !owes() {
		t.Fatal("a reply the removed client still holds must count as owed")
	}
	go server.runAttachInputActions(client)
	deadline := time.Now().Add(time.Second)
	for {
		server.mu.Lock()
		remembered := len(server.detachedReplyClients)
		server.mu.Unlock()
		if remembered == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the removed client was not forgotten once its worker stopped")
		}
		time.Sleep(time.Millisecond)
	}
	if got := pty.String(); got != "\x1b[1;1R" {
		t.Fatalf("window got %q, want the reply", got)
	}
	if owes() {
		t.Fatal("the delivered reply still counts as owed")
	}

	// A client removed with nothing to deliver is not kept at all.
	quiet := registerTestAttachClient(t, server, &recordingConn{}, "quiet", 80, 24)
	server.removeAttachClient(quiet)
	server.mu.Lock()
	remembered := len(server.detachedReplyClients)
	server.mu.Unlock()
	if remembered != 0 {
		t.Fatal("a removed client that holds no replies must not be kept")
	}
}

// Replies received just as the client closes cannot be queued for its worker,
// so they stop counting as owed.
func TestRepliesThatCannotBeQueuedAreReleased(t *testing.T) {
	server := newMuxServer("unqueued-replies")
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "closing", 80, 24)
	client.enqueueWrite([]byte(cursorPositionQuery), false, "@1", 1, nil)
	waitForRecordedOutput(t, conn, cursorPositionQuery)
	waitForTestAttachWrites(t, server)
	routing := client.routeInput([]byte("\x1b[1;1R"))
	client.close()

	if client.enqueueInputActions(routing.actions) {
		t.Fatal("a closed client must not queue input")
	}
	if client.holdsReceivedReplies() {
		t.Fatal("replies that could not be queued must be released")
	}
}

// The client keeps waiting for a reply while a bracketed paste is in
// progress, however long it takes, so the reply stays owed.
func TestReplyStaysOwedThroughABracketedPaste(t *testing.T) {
	server := newMuxServer("paste-held-replies")
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "primary", 80, 24)
	client.enqueueWrite([]byte(cursorPositionQuery), false, "@1", 1, nil)
	waitForRecordedOutput(t, conn, cursorPositionQuery)
	waitForTestAttachWrites(t, server)
	later := func() time.Time { return time.Now().Add(2 * terminalResponseFocusGrace) }

	client.routeInput([]byte("\x1b[200~pasted"))
	if !client.owesTerminalReplies("@1", later()) {
		t.Fatal("a reply must stay owed while a paste is in progress")
	}
	client.routeInput([]byte(" text\x1b[201~"))
	if client.owesTerminalReplies("@1", later()) {
		t.Fatal("once the paste ends the usual wait applies")
	}
}

// A pause restarted after a local answer drops held bytes the answer
// depended on, so the client must still end up at the reported cursor.
func TestRestartedRedrawPauseResumesAtTheReportedCursor(t *testing.T) {
	server, window, pty, attach := newRedrawCursorQueryTestServer(t)
	window.redrawForwardingPaused = false
	server.handleWindowOutput("@1", []byte("\x1b[1;1Hbase"))
	waitForTestAttachWrites(t, server)
	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 80, 24)
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("\x1b[2J\x1b[10;20H"+cursorPositionQuery))
	waitForWindowReplies(t, window)
	if got := pty.String(); got != "\x1b[10;20R" {
		t.Fatalf("window got %q, want the reported position", got)
	}
	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 80, 24)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("x"))
	server.resumePausedAttachForwarding("@1", generation)
	waitForTestAttachWrites(t, server)

	client := newTerminalScreen(80, 24)
	client.Write([]byte(attach.String()))
	rows := client.TextRows()
	if rows[0] != "" || rows[9] != strings.Repeat(" ", 19)+"x" {
		t.Fatalf("client rows 0 and 9 = %q, %q, want x at 10;20 on a cleared screen", rows[0], rows[9])
	}
	if row, col := client.CursorPosition(); row != 9 || col != 20 {
		t.Fatalf("client cursor = (%d,%d), want (9,20)", row, col)
	}
}

func waitForTerminalRepliesSettled(t *testing.T, client *attachClient, windowID string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for client.owesTerminalReplies(windowID, time.Now()) {
		if time.Now().After(deadline) {
			t.Fatal("the client still owes the window a reply")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestCsiQueryParametersAreReadAsNumbers(t *testing.T) {
	for params, want := range map[string]string{
		"06": "6", "?006": "?6", "00": "0", "0": "0", "100": "100", "05;007": "5;7", ">0": ">0",
	} {
		if got := normalizedCsiQueryParams(params); got != want {
			t.Fatalf("normalizedCsiQueryParams(%q) = %q, want %q", params, got, want)
		}
	}
	// The terminal answers by the prefix and the first parameter alone.
	for _, query := range []string{
		"\x1b[06n", "\x1b[?006n", "\x1b[00c", "\x1b[014t", "\x1b[6;0n", "\x1b[6:0n",
		"\x1b[6 n", "\x1b[?5n", "\x1b[>6n", "\x1b[5c", "\x1b[0;1c",
	} {
		if !isReplayUnsafeCsiQuery([]byte(query)) {
			t.Fatalf("%q must count as a query", query)
		}
	}
	for _, other := range []string{"\x1b[100n", "\x1b[n", "\x1b[7n", "\x1b[<0c"} {
		if isReplayUnsafeCsiQuery([]byte(other)) {
			t.Fatalf("%q is not a query", other)
		}
	}
}
