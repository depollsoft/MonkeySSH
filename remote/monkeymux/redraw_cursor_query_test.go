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
	s.Write([]byte("\x1b[7;9H"))
	if got := report(); got != "\x1b[7;9R" {
		t.Fatalf("report = %q, want 1-based row 7 column 9", got)
	}
	s.Write([]byte("\x1b[1;1H" + strings.Repeat("x", 80)))
	if got := report(); got != "\x1b[1;80R" {
		t.Fatalf("pending-wrap report = %q, want the last column", got)
	}
	s.Write([]byte("\x1b[?1049h\x1b[3;4H"))
	if got := report(); got != "\x1b[3;4R" {
		t.Fatalf("alternate-screen report = %q, want the alternate cursor", got)
	}

	// The app's terminal reports the absolute row in origin mode, where xterm
	// counts from the margin, so the model leaves that query to the client.
	s.Write([]byte("\x1b[5;20r\x1b[?6h\x1b[2;3H"))
	if got := report(); got != "unanswerable" {
		t.Fatalf("origin-mode report = %q, want none", got)
	}
	s.Write([]byte("\x1b[?6l\x1b[r"))

	// A Kitty placement moves the client's cursor past the image by an amount
	// the model does not compute, until the next absolute position.
	for _, tc := range []struct {
		command string
		moves   bool
	}{
		{"a=T,f=32,s=1,v=1,r=2,c=2,q=2", true},
		{"a=p,i=7,r=2,c=2", true},
		{"a=T,f=32,s=1,v=1,C=1", false},
		{"a=T,f=32,s=1,v=1,U=1", false},
		{"a=t,f=32,s=1,v=1", false},
		{"a=d,d=a", false},
	} {
		s.Write([]byte("\x1b[5;10H\x1b_G" + tc.command + ";/wAA/w==\x1b\\"))
		if got := report(); (got == "unanswerable") != tc.moves {
			t.Fatalf("after %s report = %q, want unanswerable=%v", tc.command, got, tc.moves)
		}
		s.Write([]byte("\x1b[6;2H"))
		if got := report(); got != "\x1b[6;2R" {
			t.Fatalf("after %s and CUP report = %q, want 6;2", tc.command, got)
		}
	}
	s.Write([]byte("\x1b_Ga=T,f=32,s=1,v=1\x9c"))
	if got := report(); got != "unanswerable" {
		t.Fatalf("C1-terminated placement report = %q, want none", got)
	}
	s.Write([]byte("\x1bc"))
	if got := report(); got != "\x1b[1;1R" {
		t.Fatalf("report after RIS = %q, want home", got)
	}

	// A chunked transmission places its image when the last chunk arrives.
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
		s.Write([]byte("\x1b[1;1H"))
	}

	// A cancelled placement runs nothing, and leaves nothing for a later
	// string's end to act on.
	s.Write([]byte("\x1b_Ga=T,f=32,s=1,v=1\x18\x90q\x9c"))
	if got := report(); got != "\x1b[1;1R" {
		t.Fatalf("after a cancelled placement report = %q, want 1;1", got)
	}

	// A header too long to read in full is taken for a placement.
	long := "f=32,s=1,v=1" + strings.Repeat(",X=0", 70) + ",a=T"
	s.Write([]byte("\x1b_G" + long + ";/wAA/w==\x1b\\"))
	if got := report(); got != "unanswerable" {
		t.Fatalf("after a long placement header report = %q, want none", got)
	}
	s.Write([]byte("\x1b[1;1H"))

	// The uncertainty travels with the cursor it describes.
	placement := "\x1b[5;10H\x1b_Ga=T,f=32,s=1,v=1,r=2,c=2;/wAA/w==\x1b\\"
	for _, tc := range []struct {
		name, seq, want string
	}{
		{"DECSC and DECRC", placement + "\x1b7\x1b[1;1H\x1b8", "unanswerable"},
		{"SCO save and restore", placement + "\x1b[s\x1b[1;1H\x1b[u", "unanswerable"},
		{"alternate screen entered", placement + "\x1b[?1049h", "unanswerable"},
		{"alternate screen positioned", "\x1b[3;3H", "\x1b[3;3R"},
		{"alternate screen left", "\x1b[?1049l", "unanswerable"},
		{"saved before the image", "\x1b[1;1H\x1b7" + placement + "\x1b8", "\x1b[1;1R"},
	} {
		s.Write([]byte(tc.seq))
		if got := report(); got != tc.want {
			t.Fatalf("%s: report = %q, want %q", tc.name, got, tc.want)
		}
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
			name:   "in origin mode, then outside it",
			chunks: []string{"\x1b[5;20r\x1b[?6h" + cursorPositionQuery + "\x1b[?6l\x1b[r" + cursorPositionQuery},
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
		"\x1b[1;1H\x1b[Jhello world!",
		cursorPositionQuery,
	} {
		server.handleWindowOutput("@1", []byte(chunk))
	}
	waitForWindowReplies(t, window)

	if got := pty.String(); got != "\x1b[1;1R\x1b[1;13R" {
		t.Fatalf("window got %q, want one report per query", got)
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
			// prompt_toolkit erases its area and asks where it now starts.
			name:   "erase then ask",
			before: "\x1b[2J\x1b[1;1Hbase\x1b[20;1Hprompt> ",
			redraw: "\x1b[3A\r\x1b[J",
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
	for owes() {
		if time.Now().After(deadline) {
			t.Fatal("the delivered reply still counts as owed")
		}
		time.Sleep(time.Millisecond)
	}
	if got := pty.String(); got != "\x1b[1;1R" {
		t.Fatalf("window got %q, want the reply", got)
	}
	server.mu.Lock()
	remembered := len(server.detachedReplyClients)
	server.mu.Unlock()
	if remembered != 0 {
		t.Fatal("a removed client that owes nothing must be forgotten")
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
