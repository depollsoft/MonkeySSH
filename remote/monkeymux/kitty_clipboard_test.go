package main

import (
	"bufio"
	"io"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const kittyClipboardHintFixture = capabilityHintFixture +
	"\x1e" + "osc5522\x1f\x1b[?5522;2$y"

// "@1" and "@2" in hex, as forwarded request ids carry them.
const (
	kittyClipboardTagWindow1 = "mmx4031"
	kittyClipboardTagWindow2 = "mmx4032"
)

func newKittyClipboardTestServer(t *testing.T) (*muxServer, *muxWindow, *muxWindow, *recordingConn) {
	t.Helper()
	server := newMuxServer("kitty-clipboard")
	first := &muxWindow{id: "@1", pty: &recordingPty{}, lastActivity: time.Now()}
	second := &muxWindow{id: "@2", index: 1, pty: &recordingPty{}, lastActivity: time.Now()}
	server.windows = []*muxWindow{first, second}
	server.activeID = "@1"
	attach := &recordingConn{}
	client := registerTestAttachClient(t, server, attach, "primary", 80, 24)
	client.capabilityHint = []byte(kittyClipboardHintFixture)
	return server, first, second, attach
}

func waitForAttachOutput(t *testing.T, attach *recordingConn, want string) string {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		got := attach.String()
		if strings.Contains(got, want) {
			return got
		}
		if time.Now().After(deadline) {
			t.Fatalf("attach output %q never contained %q", got, want)
		}
		time.Sleep(time.Millisecond)
	}
}

func windowPtyOutput(t *testing.T, window *muxWindow) string {
	t.Helper()
	waitForWindowReplies(t, window)
	return window.pty.(*recordingPty).String()
}

func TestKittyClipboardWindowTagRoundTrip(t *testing.T) {
	for _, tc := range []struct{ windowID, id string }{
		{"@1", ""},
		{"@12", "abc"},
		{"@3", "a.b.c"},
	} {
		tag := kittyClipboardWindowTag(tc.windowID, tc.id)
		windowID, id, ok := untagKittyClipboardID(tag)
		if !ok || windowID != tc.windowID || id != tc.id {
			t.Fatalf("untag(%q) = %q, %q, %v; want %q, %q", tag, windowID, id, ok, tc.windowID, tc.id)
		}
	}
	for _, tag := range []string{"", "abc", "mmx", "mmxzz", "mmx.abc"} {
		if _, _, ok := untagKittyClipboardID(tag); ok {
			t.Fatalf("untag(%q) succeeded, want a program's own id left alone", tag)
		}
	}
	if got := sanitizeKittyClipboardID("a b*c-_+.9"); got != "abc-_+.9" {
		t.Fatalf("sanitize = %q", got)
	}
}

func TestKittyClipboardRequestFromOnScreenWindowIsTaggedForPrimaryOnly(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	secondary := &recordingConn{}
	registerTestAttachClient(t, server, secondary, "secondary", 80, 24)
	server.mu.Lock()
	server.attachConn = attach
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("a\x1b]5522;type=read:id=x1;Lg==\x1b\\b"))

	waitForAttachOutput(t, attach, "\x1b]5522;type=read:id="+kittyClipboardTagWindow1+".x1;Lg==\x1b\\")
	got := waitForAttachOutput(t, secondary, "ab")
	if strings.Contains(got, "5522") {
		t.Fatalf("secondary client got %q, want the request withheld", got)
	}
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q, want no local answer for a forwarded request", out)
	}
	if server.kittyClipboardRepliesOwedUntil.Load() <= time.Now().UnixNano() {
		t.Fatal("replies were not marked owed after a forwarded request")
	}
}

func TestKittyClipboardRequestFromBackgroundWindowIsAnsweredBusy(t *testing.T) {
	server, _, second, attach := newKittyClipboardTestServer(t)

	server.handleWindowOutput("@2", []byte("\x1b]5522;type=read:id=q;Lg==\x07"))
	server.handleWindowOutput("@2", []byte("\x1b]5522;type=write\x1b\\\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\x1b]5522;type=wdata\x1b\\"))

	want := "\x1b]5522;type=read:status=EBUSY:id=q\x1b\\" +
		"\x1b]5522;type=write:status=EBUSY\x1b\\"
	if got := windowPtyOutput(t, second); got != want {
		t.Fatalf("background window got %q, want %q", got, want)
	}
	if strings.Contains(attach.String(), "5522") {
		t.Fatalf("attach got %q, want nothing from a background window", attach.String())
	}
}

func TestKittyClipboardRequestIsAnsweredBusyWithoutCapableClient(t *testing.T) {
	server := newMuxServer("kitty-clipboard-detached")
	window := &muxWindow{id: "@1", pty: &recordingPty{}, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read;Lg==\x1b\\"))
	if got := windowPtyOutput(t, window); got != "\x1b]5522;type=read:status=EBUSY\x1b\\" {
		t.Fatalf("detached window got %q", got)
	}

	// An attached client that never said it speaks the protocol is not sent
	// the request either.
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "plain", 80, 24)
	window.pty.(*recordingPty).Reset()
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=z;Lg==\x1b\\x"))
	waitForAttachOutput(t, attach, "x")
	if got := windowPtyOutput(t, window); got != "\x1b]5522;type=read:status=EBUSY:id=z\x1b\\" {
		t.Fatalf("window with a plain client got %q", got)
	}
	if strings.Contains(attach.String(), "5522") {
		t.Fatalf("plain client got %q", attach.String())
	}
}

func TestKittyClipboardWriteForwardsWholeTransaction(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	write := "\x1b]5522;type=write:id=w\x1b\\" +
		"\x1b]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVA==\x1b\\" +
		"\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"
	commit := "\x1b]5522;type=wdata\x1b\\"

	server.handleWindowOutput("@1", []byte(write))
	server.mu.Lock()
	owner := server.kittyClipboardWriteWindow
	server.mu.Unlock()
	if owner != "@1" {
		t.Fatalf("write owner = %q, want @1", owner)
	}
	server.handleWindowOutput("@1", []byte(commit))

	waitForAttachOutput(t, attach,
		"\x1b]5522;type=write:id="+kittyClipboardTagWindow1+".w\x1b\\"+
			"\x1b]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVA==\x1b\\"+
			"\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"+
			commit)
	server.mu.Lock()
	owner = server.kittyClipboardWriteWindow
	server.mu.Unlock()
	if owner != "" {
		t.Fatalf("write owner after commit = %q, want none", owner)
	}
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q, want the client to answer", out)
	}
}

func TestKittyClipboardWriteInterruptedBySwitchIsAnsweredBusy(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"))
	waitForAttachOutput(t, attach, "aGk=")

	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	// Output without any clipboard packet is enough: a large data packet
	// could have passed the scan unseen.
	server.handleWindowOutput("@1", []byte("plain"))
	if got := windowPtyOutput(t, first); got != "\x1b]5522;type=write:status=EBUSY:id=w\x1b\\" {
		t.Fatalf("interrupted window got %q", got)
	}

	// The rest of the write is dropped even once the window is back.
	server.mu.Lock()
	server.activeID = "@1"
	server.mu.Unlock()
	attach.Reset()
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\x1b]5522;type=wdata\x1b\\done"))
	if got := waitForAttachOutput(t, attach, "done"); got != "done" {
		t.Fatalf("attach got %q, want the rejected write's packets dropped", got)
	}
	server.mu.Lock()
	state := first.kittyClipboard.write
	server.mu.Unlock()
	if state != kittyClipboardWriteNone {
		t.Fatalf("write state = %v, want none after the commit packet", state)
	}
}

func TestKittyClipboardSecondWriterTakesTheClientSlot(t *testing.T) {
	server, first, second, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=one\x1b\\"))
	waitForAttachOutput(t, attach, ".one")

	// Window 2 comes on screen and starts its own write before window 1
	// writes again.
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.handleWindowOutput("@2", []byte("\x1b]5522;type=write:id=two\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow2+".two")

	if got := windowPtyOutput(t, first); got != "\x1b]5522;type=write:status=EBUSY:id=one\x1b\\" {
		t.Fatalf("displaced writer got %q", got)
	}
	if got := windowPtyOutput(t, second); got != "" {
		t.Fatalf("new writer got %q", got)
	}
	server.mu.Lock()
	owner := server.kittyClipboardWriteWindow
	server.mu.Unlock()
	if owner != "@2" {
		t.Fatalf("write owner = %q, want @2", owner)
	}
}

func TestKittyClipboardSplitRoutesTaggedRepliesToTheirWindow(t *testing.T) {
	client := newAttachClient(&recordingConn{}, controlMessage{})
	client.inputDispatchMu.Lock()
	defer client.inputDispatchMu.Unlock()
	reply := "\x1b]5522;type=read:status=DATA:id=" + kittyClipboardTagWindow2 + ".x:mime=Lg==;dGV4dA==\x1b\\"

	input, replies := client.splitKittyClipboardRepliesLocked([]byte("a"+reply+"b"), time.Now())

	if string(input) != "ab" {
		t.Fatalf("input = %q, want the reply removed", input)
	}
	if len(replies) != 1 || replies[0].windowID != "@2" || !replies[0].kittyClipboardReply {
		t.Fatalf("replies = %+v", replies)
	}
	if got := string(replies[0].data); got != "\x1b]5522;type=read:status=DATA:mime=Lg==:id=x;dGV4dA==\x1b\\" {
		t.Fatalf("reply = %q, want the program's id restored", got)
	}

	// Without the program's own id the id record is dropped.
	_, replies = client.splitKittyClipboardRepliesLocked(
		[]byte("\x1b]5522;type=write:status=DONE:id="+kittyClipboardTagWindow1+"\x07"),
		time.Now(),
	)
	if len(replies) != 1 || string(replies[0].data) != "\x1b]5522;type=write:status=DONE\x07" {
		t.Fatalf("replies = %+v", replies)
	}
}

func TestKittyClipboardSplitLeavesPasteEventsAndPastedTextAsInput(t *testing.T) {
	client := newAttachClient(&recordingConn{}, controlMessage{})
	client.inputDispatchMu.Lock()
	defer client.inputDispatchMu.Unlock()
	for _, data := range []string{
		// A paste event has no id; it goes to the window on screen.
		"\x1b]5522;type=read:status=OK:pw=YWJj\x1b\\\x1b]5522;type=read:status=DONE:pw=YWJj\x1b\\",
		// Pasted text is never taken as a reply.
		"\x1b[200~\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + "\x1b\\\x1b[201~",
	} {
		input, replies := client.splitKittyClipboardRepliesLocked([]byte(data), time.Now())
		if string(input) != data || len(replies) != 0 {
			t.Fatalf("split(%q) = %q, %+v; want all of it as input", data, input, replies)
		}
	}
}

func TestKittyClipboardSplitHoldsRepliesSplitAcrossReads(t *testing.T) {
	var owed atomic.Int64
	client := newAttachClient(&recordingConn{}, controlMessage{})
	client.kittyClipboardInput.owedUntil = &owed
	client.inputDispatchMu.Lock()
	defer client.inputDispatchMu.Unlock()
	reply := "\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + "\x1b\\"

	// Not owed: a trailing ESC is the Escape key and passes straight on.
	input, _ := client.splitKittyClipboardRepliesLocked([]byte("x\x1b"), time.Now())
	if string(input) != "x\x1b" {
		t.Fatalf("input = %q, want the Escape key kept", input)
	}

	owed.Store(time.Now().Add(time.Minute).UnixNano())
	for split := 1; split < len(reply); split++ {
		first, replies := client.splitKittyClipboardRepliesLocked([]byte("x"+reply[:split]), time.Now())
		if string(first) != "x" || len(replies) != 0 {
			t.Fatalf("split %d: first read = %q, %+v; want the partial reply held", split, first, replies)
		}
		second, replies := client.splitKittyClipboardRepliesLocked([]byte(reply[split:]+"y"), time.Now())
		if string(second) != "y" || len(replies) != 1 || replies[0].windowID != "@1" {
			t.Fatalf("split %d: second read = %q, %+v", split, second, replies)
		}
	}

	// A held prefix that is not continued as a reply is given back in order.
	first, _ := client.splitKittyClipboardRepliesLocked([]byte("x\x1b]"), time.Now())
	second, _ := client.splitKittyClipboardRepliesLocked([]byte("8;;\x07"), time.Now())
	if string(first)+string(second) != "x\x1b]8;;\x07" {
		t.Fatalf("input = %q + %q, want the hyperlink back in order", first, second)
	}
}

func TestKittyClipboardAmbiguousCarryIsReleasedAfterTimeout(t *testing.T) {
	var owed atomic.Int64
	owed.Store(time.Now().Add(time.Minute).UnixNano())
	client := newAttachClient(&recordingConn{}, controlMessage{})
	client.kittyClipboardInput.owedUntil = &owed
	// As handleAttach wires it: input the routing holds and later releases.
	client.inputPassthrough = func(data []byte) {
		client.enqueueInputActions([]attachInputAction{{
			userInput: true,
			data:      append([]byte(nil), data...),
		}})
	}
	client.inputDispatchMu.Lock()
	input, _ := client.splitKittyClipboardRepliesLocked([]byte("\x1b"), time.Now())
	client.inputDispatchMu.Unlock()
	if len(input) != 0 {
		t.Fatalf("input = %q, want the lone ESC held while replies are owed", input)
	}

	deadline := time.Now().Add(kittyClipboardAmbiguousCarryTimeout + 2*time.Second)
	for {
		action, ok := nextQueuedInputAction(client)
		if ok {
			if !action.userInput || string(action.data) != "\x1b" {
				t.Fatalf("released action = %+v, want the ESC as user input", action)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("held ESC was never released")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func nextQueuedInputAction(client *attachClient) (attachInputAction, bool) {
	client.inputQueueMu.Lock()
	defer client.inputQueueMu.Unlock()
	if len(client.inputQueue) == 0 {
		return attachInputAction{}, false
	}
	action := client.inputQueue[0]
	client.inputQueue = client.inputQueue[1:]
	return action, true
}

func TestKittyClipboardRepliesRouteBackThroughAttach(t *testing.T) {
	restore := stubForegroundResize(t)
	defer restore()
	server := newMuxServer("kitty-clipboard-attach")
	first := &muxWindow{id: "@1", pty: &recordingPty{}, lastActivity: time.Now()}
	second := &muxWindow{id: "@2", index: 1, pty: &recordingPty{}, lastActivity: time.Now()}
	server.windows = []*muxWindow{first, second}
	server.activeID = "@1"

	input, writer := io.Pipe()
	attach := &recordingConn{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleAttach(attach, bufio.NewReader(input), controlMessage{
			Width:          80,
			Height:         24,
			CapabilityHint: kittyClipboardHintFixture,
		})
	}()
	defer func() {
		_ = writer.Close()
		_ = input.Close()
		<-done
	}()
	deadline := time.Now().Add(2 * time.Second)
	for {
		server.mu.Lock()
		attached := server.attachConn != nil
		server.mu.Unlock()
		if attached {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("attach never became primary")
		}
		time.Sleep(time.Millisecond)
	}

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".r")

	// The user switches windows before the client answers: the answer still
	// goes to the window that asked, never to the one on screen.
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	reply := "\x1b]5522;type=read:status=OK:id=" + kittyClipboardTagWindow1 + ".r\x1b\\" +
		"\x1b]5522;type=read:status=DATA:id=" + kittyClipboardTagWindow1 + ".r:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\" +
		"\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".r\x1b\\"
	if _, err := writer.Write([]byte(reply)); err != nil {
		t.Fatal(err)
	}

	want := "\x1b]5522;type=read:status=OK:id=r\x1b\\" +
		"\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==:id=r;aGk=\x1b\\" +
		"\x1b]5522;type=read:status=DONE:id=r\x1b\\"
	deadline = time.Now().Add(2 * time.Second)
	for first.pty.(*recordingPty).String() != want {
		if time.Now().After(deadline) {
			t.Fatalf("asking window got %q, want %q", first.pty.(*recordingPty).String(), want)
		}
		time.Sleep(time.Millisecond)
	}
	if got := second.pty.(*recordingPty).String(); strings.Contains(got, "5522") {
		t.Fatalf("window on screen got %q, want none of the reply", got)
	}
}

func TestKittyClipboardRequestsAreLeftOutOfReplays(t *testing.T) {
	history := "a\x1b]5522;type=write\x1b\\b\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x07c\x9d5522;type=wdata\x1b\\d"
	if got := string(stripTerminalQueriesFromReplay([]byte(history))); got != "abcd" {
		t.Fatalf("replay = %q, want the clipboard packets stripped", got)
	}
}

func TestKittyPasteEventsModeIsTrackedAndReplayed(t *testing.T) {
	window := &muxWindow{id: "@1", privateModes: map[string]bool{}}
	window.observeTerminalModesLocked([]byte("\x1b[?5522h"))
	if !window.privateModes[kittyPasteEventsMode] {
		t.Fatalf("private modes = %v, want 5522 set", window.privateModes)
	}
	if replay := string(terminalModePostReplaySequence(window)); !strings.Contains(replay, "\x1b[?5522h") {
		t.Fatalf("post replay = %q, want 5522 restored", replay)
	}
	if !strings.Contains(activeWindowReplayPrefix, "\x1b[?5522l") {
		t.Fatal("replay prefix does not turn paste events off for windows without them")
	}
	if _, kept := privateModesForRestore(window.privateModes)[kittyPasteEventsMode]; kept {
		t.Fatal("5522 survives an upgrade restore, but the new process has not asked for it")
	}

	// DECSTR leaves it, as in kitty and Ghostty; RIS clears it.
	window.observeTerminalModesLocked([]byte("\x1b[!p"))
	if !window.privateModes[kittyPasteEventsMode] {
		t.Fatal("DECSTR cleared 5522")
	}
	window.observeTerminalModesLocked([]byte("\x1bc"))
	if window.privateModes[kittyPasteEventsMode] {
		t.Fatal("RIS kept 5522")
	}
}
