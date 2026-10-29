package main

import (
	"bufio"
	"encoding/base64"
	"io"
	"math/rand"
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

// A write sends its data as many packets of up to 4 KiB before base64, each
// larger than the 4 KiB the output scan holds back for a split OSC. Whatever
// the PTY read boundaries, every byte must reach the client in order, with
// only the opening packet's id tagged.
func TestKittyClipboardLargeWriteSurvivesArbitraryReadSplits(t *testing.T) {
	random := rand.New(rand.NewSource(5522))
	data := make([]byte, 1<<20)
	random.Read(data)
	mime := base64.StdEncoding.EncodeToString([]byte("image/png"))
	var stream strings.Builder
	stream.WriteString("\x1b]5522;type=write:id=big\x1b\\")
	for offset := 0; offset < len(data); offset += 4096 {
		end := min(offset+4096, len(data))
		stream.WriteString("\x1b]5522;type=wdata:mime=" + mime + ";")
		stream.WriteString(base64.StdEncoding.EncodeToString(data[offset:end]))
		stream.WriteString("\x1b\\")
	}
	stream.WriteString("\x1b]5522;type=wdata\x1b\\")
	input := stream.String()
	want := strings.Replace(input, "id=big", "id="+kittyClipboardTagWindow1+".big", 1)

	for round := 0; round < 3; round++ {
		server, first, _, attach := newKittyClipboardTestServer(t)
		for offset := 0; offset < len(input); {
			end := min(offset+1+random.Intn(32*1024), len(input))
			server.handleWindowOutput("@1", []byte(input[offset:end]))
			offset = end
		}
		got := waitForAttachOutput(t, attach, "\x1b]5522;type=wdata\x1b\\")
		if got != want {
			t.Fatalf("round %d: client got %d bytes, want %d identical bytes", round, len(got), len(want))
		}
		if out := windowPtyOutput(t, first); out != "" {
			t.Fatalf("round %d: window got %q", round, out)
		}
	}
}

// A large read answer reaches MonkeyMux through a PTY and a socket, so it is
// split at arbitrary points. Every packet must still be routed whole, with
// the user's own keystrokes between reads left alone.
func TestKittyClipboardLargeReplySurvivesArbitraryReadSplits(t *testing.T) {
	random := rand.New(rand.NewSource(2026))
	data := make([]byte, 256<<10)
	random.Read(data)
	tag := ":id=" + kittyClipboardTagWindow2 + ".r"
	mime := base64.StdEncoding.EncodeToString([]byte("image/png"))
	var tagged, restored strings.Builder
	packet := func(metadata string, payload string) {
		tagged.WriteString("\x1b]5522;type=read:" + metadata + tag + payload + "\x1b\\")
		restored.WriteString("\x1b]5522;type=read:" + metadata + ":id=r" + payload + "\x1b\\")
	}
	packet("status=OK", "")
	for offset := 0; offset < len(data); offset += 4096 {
		end := min(offset+4096, len(data))
		packet("status=DATA:mime="+mime, ";"+base64.StdEncoding.EncodeToString(data[offset:end]))
	}
	packet("status=DONE", "")
	input := tagged.String()

	var owed atomic.Int64
	client := newAttachClient(&recordingConn{}, controlMessage{})
	client.kittyClipboardInput.owedUntil = &owed
	owed.Store(time.Now().Add(time.Minute).UnixNano())
	client.inputDispatchMu.Lock()
	defer client.inputDispatchMu.Unlock()
	var routed strings.Builder
	var leftover strings.Builder
	for offset := 0; offset < len(input); {
		end := min(offset+1+random.Intn(8*1024), len(input))
		rest, replies := client.splitKittyClipboardRepliesLocked([]byte(input[offset:end]), time.Now())
		leftover.Write(rest)
		for _, reply := range replies {
			if reply.windowID != "@2" {
				t.Fatalf("reply routed to %q", reply.windowID)
			}
			routed.Write(reply.data)
		}
		offset = end
	}
	if leftover.Len() != 0 {
		t.Fatalf("%d bytes of the answer were left as user input", leftover.Len())
	}
	if routed.String() != restored.String() {
		t.Fatalf("routed %d bytes, want %d identical bytes", routed.Len(), restored.Len())
	}
}

// A window that sends a whole write in one read still replaces the write
// another window has open on the client, which must hear EBUSY: otherwise,
// back on screen, it forwards the rest of its write into nothing and waits
// forever.
func TestKittyClipboardWriteCommittedInOneReadDisplacesOpenWrite(t *testing.T) {
	server, first, second, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=one\x1b\\"))
	waitForAttachOutput(t, attach, ".one")

	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.handleWindowOutput("@2", []byte(
		"\x1b]5522;type=write:id=two\x1b\\"+
			"\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"+
			"\x1b]5522;type=wdata\x1b\\",
	))
	waitForAttachOutput(t, attach, "\x1b]5522;type=wdata\x1b\\")

	if got := windowPtyOutput(t, first); got != "\x1b]5522;type=write:status=EBUSY:id=one\x1b\\" {
		t.Fatalf("displaced writer got %q", got)
	}
	server.mu.Lock()
	owner := server.kittyClipboardWriteWindow
	state := first.kittyClipboard.write
	server.mu.Unlock()
	if owner != "" || state != kittyClipboardWriteRejected {
		t.Fatalf("owner = %q, displaced state = %v; want none and rejected", owner, state)
	}
	if got := windowPtyOutput(t, second); got != "" {
		t.Fatalf("new writer got %q", got)
	}

	// Back on screen, the displaced window's packets go nowhere.
	server.mu.Lock()
	server.activeID = "@1"
	server.mu.Unlock()
	attach.Reset()
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\x1b]5522;type=wdata\x1b\\done"))
	if got := waitForAttachOutput(t, attach, "done"); got != "done" {
		t.Fatalf("attach got %q, want the displaced write's packets dropped", got)
	}
}

// maxKittyClipboardDataPacket is a spec-sized data packet: 4096 bytes before
// base64, more than the 4096 bytes held for any other split OSC.
func maxKittyClipboardDataPacket(random *rand.Rand) string {
	data := make([]byte, 4096)
	random.Read(data)
	return "\x1b]5522;type=wdata:mime=" +
		base64.StdEncoding.EncodeToString([]byte("image/png")) + ";" +
		base64.StdEncoding.EncodeToString(data) + "\x1b\\"
}

// A packet split past the generic OSC carry used to leave the scan unchecked,
// so a rejected writer's data reached the write another window has open.
func TestKittyClipboardSplitPacketOfRejectedWriterIsDropped(t *testing.T) {
	random := rand.New(rand.NewSource(14016))
	for round := 0; round < 20; round++ {
		server, first, second, attach := newKittyClipboardTestServer(t)
		server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=one\x1b\\"))
		// Window 2 opens a write while in the background and is refused.
		server.handleWindowOutput("@2", []byte("\x1b]5522;type=write:id=two\x1b\\"))
		if got := windowPtyOutput(t, second); got != "\x1b]5522;type=write:status=EBUSY:id=two\x1b\\" {
			t.Fatalf("round %d: background writer got %q", round, got)
		}
		waitForAttachOutput(t, attach, ".one")

		server.mu.Lock()
		server.activeID = "@2"
		server.mu.Unlock()
		packet := maxKittyClipboardDataPacket(random)
		split := oscBufferLimitBytes + 1 + random.Intn(len(packet)-oscBufferLimitBytes-1)
		server.handleWindowOutput("@2", []byte("a"+packet[:split]))
		server.handleWindowOutput("@2", []byte(packet[split:]+"b"))

		got := waitForAttachOutput(t, attach, "b")
		if strings.Contains(got, "type=wdata") {
			t.Fatalf("round %d (split %d): the rejected writer's data reached the client", round, split)
		}
		if !strings.HasSuffix(got, "ab") {
			t.Fatalf("round %d: attach got %q, want the surrounding output", round, got[len(got)-min(len(got), 40):])
		}
		if out := windowPtyOutput(t, first); out != "" {
			t.Fatalf("round %d: open writer got %q", round, out)
		}
	}
}

// The owner's split packets still arrive whole and tagged-through unchanged.
func TestKittyClipboardSplitPacketOfOpenWriteIsForwardedWhole(t *testing.T) {
	random := rand.New(rand.NewSource(4096))
	server, _, _, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=one\x1b\\"))
	packet := maxKittyClipboardDataPacket(random)
	split := oscBufferLimitBytes + 1 + random.Intn(len(packet)-oscBufferLimitBytes-1)
	server.handleWindowOutput("@1", []byte(packet[:split]))
	server.handleWindowOutput("@1", []byte(packet[split:]+"\x1b]5522;type=wdata\x1b\\"))

	got := waitForAttachOutput(t, attach, "\x1b]5522;type=wdata\x1b\\")
	if !strings.Contains(got, packet+"\x1b]5522;type=wdata\x1b\\") {
		t.Fatal("the open write's split packet did not reach the client whole")
	}
}

// A packet whose terminator has not come by the time it outgrows the carry
// is dropped, and its write is refused, so the client never commits a write
// with a gap.
func TestKittyClipboardOversizedPacketIsDropped(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=big\x1b\\"))
	waitForAttachOutput(t, attach, ".big")
	attach.Reset()

	huge := "\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;" +
		strings.Repeat("QUFB", kittyClipboardPacketLimitBytes) + "\x1b\\"
	for offset := 0; offset < len(huge); offset += 16 * 1024 {
		server.handleWindowOutput("@1", []byte(huge[offset:min(offset+16*1024, len(huge))]))
	}
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata\x1b\\after"))

	if got := waitForAttachOutput(t, attach, "after"); got != "after" {
		t.Fatalf("attach got %d bytes ending %q, want only the output after the packet", len(got), got[len(got)-min(len(got), 40):])
	}
	if got := windowPtyOutput(t, first); got != "\x1b]5522;type=write:status=EFBIG:id=big\x1b\\" {
		t.Fatalf("writer got %q", got)
	}
}

func TestKittyClipboardDiscardEndsAtTheTerminatorAcrossReads(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.kittyClipboard.discarding = true
	if got := window.skipDiscardedKittyClipboardOscLocked([]byte("QUFB\x1b")); got != nil {
		t.Fatalf("got %q, want the packet's tail dropped", got)
	}
	if got := string(window.skipDiscardedKittyClipboardOscLocked([]byte("\\after"))); got != "after" {
		t.Fatalf("got %q, want the output after ST", got)
	}

	// An ESC that starts another sequence ends the string and is kept.
	window.kittyClipboard.discarding = true
	window.skipDiscardedKittyClipboardOscLocked([]byte("QUFB\x1b"))
	if got := string(window.skipDiscardedKittyClipboardOscLocked([]byte("[1mx"))); got != "\x1b[1mx" {
		t.Fatalf("got %q, want the cancelling sequence kept", got)
	}
	window.kittyClipboard.discarding = true
	if got := string(window.skipDiscardedKittyClipboardOscLocked([]byte("QUFB\ay"))); got != "y" {
		t.Fatalf("got %q, want the output after BEL", got)
	}
	if got := string(window.skipDiscardedKittyClipboardOscLocked([]byte("z"))); got != "z" {
		t.Fatalf("got %q after the discard ended", got)
	}
}

// A read that outgrows the carry can end anywhere around the packet's
// terminator, ESC \ or BEL; the output after it must survive every split.
func TestKittyClipboardOversizedPacketEndsAtSplitTerminator(t *testing.T) {
	body := "\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;" +
		strings.Repeat("QUFB", kittyClipboardPacketLimitBytes/4+16)
	for _, terminator := range []string{"\x1b\\", "\a"} {
		packet := body + terminator
		for _, carried := range []bool{false, true} {
			for split := len(body) - 3; split <= len(packet); split++ {
				server, _, _, attach := newKittyClipboardTestServer(t)
				first := "before" + packet[:split]
				second := packet[split:] + "after\x1b[1mbold"
				if carried {
					// Most of the packet is held first, then the read that
					// outgrows the carry ends at split.
					server.handleWindowOutput("@1", []byte(first[:len(first)-oscBufferLimitBytes]))
					first = first[len(first)-oscBufferLimitBytes:]
				}
				server.handleWindowOutput("@1", []byte(first))
				server.handleWindowOutput("@1", []byte(second))
				server.handleWindowOutput("@1", []byte("tail"))

				got := waitForAttachOutput(t, attach, "tail")
				if got != "beforeafter\x1b[1mboldtail" {
					t.Fatalf("terminator %q, carried %v, split %d: attach got %q",
						terminator, carried, split-len(body), got[max(0, len(got)-60):])
				}
			}
		}
	}
}

// A packet cancelled by another escape sequence ends there: the output after
// the cancelling ESC is never discarded with it.
func TestKittyClipboardOversizedCancelledPacketKeepsFollowingOutput(t *testing.T) {
	server, _, _, attach := newKittyClipboardTestServer(t)
	cancelled := "\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;QUFB\x1b[1m" +
		strings.Repeat("x", kittyClipboardPacketLimitBytes)
	server.handleWindowOutput("@1", []byte(cancelled))
	server.handleWindowOutput("@1", []byte("tail"))

	got := waitForAttachOutput(t, attach, "tail")
	if !strings.HasSuffix(got, strings.Repeat("x", 64)+"tail") {
		t.Fatalf("attach lost the output after the cancelling ESC: %q", got[max(0, len(got)-60):])
	}
}

// A paste marker can be split across reads like anything else. A reply
// after a split end marker still goes to its window, and a reply-shaped
// sequence after a split start marker is still pasted text.
func TestKittyClipboardSplitHonoursPasteMarkersSplitAcrossReads(t *testing.T) {
	reply := "\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + "\x1b\\"
	split := func(input string, at int) (string, []attachInputAction) {
		var owed atomic.Int64
		owed.Store(time.Now().Add(time.Minute).UnixNano())
		client := newAttachClient(&recordingConn{}, controlMessage{})
		client.kittyClipboardInput.owedUntil = &owed
		client.inputDispatchMu.Lock()
		defer client.inputDispatchMu.Unlock()
		// As the attach read loop does: each read is split, then routed.
		first, firstReplies := client.splitKittyClipboardRepliesLocked([]byte(input[:at]), time.Now())
		client.routeInput(first)
		second, secondReplies := client.splitKittyClipboardRepliesLocked([]byte(input[at:]), time.Now())
		client.routeInput(second)
		return string(first) + string(second), append(firstReplies, secondReplies...)
	}
	for _, markers := range []struct{ name, start, end string }{
		{"7-bit", "\x1b[200~", "\x1b[201~"},
		{"C1", "\x9b200~", "\x9b201~"},
	} {
		closed := markers.start + "text" + markers.end
		for offset := 1; offset < len(markers.end); offset++ {
			at := len(markers.start) + len("text") + offset
			input, replies := split(closed+reply+"x", at)
			if input != closed+"x" || len(replies) != 1 || replies[0].windowID != "@1" {
				t.Fatalf("%s end marker split at %d: input %q, replies %+v; want the reply routed",
					markers.name, offset, input, replies)
			}
		}
		pasted := markers.start + reply + markers.end
		for offset := 1; offset < len(markers.start); offset++ {
			input, replies := split(pasted, offset)
			if input != pasted || len(replies) != 0 {
				t.Fatalf("%s start marker split at %d: input %q, replies %+v; want it all pasted",
					markers.name, offset, input, replies)
			}
		}
	}
}

// CAN and SUB cancel an OSC wherever they come, as in the screen model: the
// output after them is ordinary output, whether the packet was being
// discarded for its size or was still short enough to hold.
func TestKittyClipboardPacketCancelledByCanOrSubKeepsFollowingOutput(t *testing.T) {
	for _, cancel := range []string{"\x18", "\x1a"} {
		// Oversized: the discard must stop at the cancel.
		server, first, _, attach := newKittyClipboardTestServer(t)
		server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;"+
			strings.Repeat("QUFB", kittyClipboardPacketLimitBytes/4+16)))
		server.handleWindowOutput("@1", []byte("QUFB"+cancel+"VISIBLE\r\n"))
		server.handleWindowOutput("@1", []byte("tail"))
		if got := waitForAttachOutput(t, attach, "tail"); got != "VISIBLE\r\ntail" {
			t.Fatalf("cancel %q: attach got %q", cancel, got[max(0, len(got)-60):])
		}
		if out := windowPtyOutput(t, first); out != "" {
			t.Fatalf("cancel %q: window got %q", cancel, out)
		}

		// Short, and terminated later: the cancelled request is no request.
		server, first, _, attach = newKittyClipboardTestServer(t)
		server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg=="+cancel+"VISIBLE\x1b\\tail"))
		if got := waitForAttachOutput(t, attach, "tail"); got != "VISIBLE\x1b\\tail" {
			t.Fatalf("cancel %q: attach got %q", cancel, got)
		}
		if out := windowPtyOutput(t, first); out != "" {
			t.Fatalf("cancel %q: window got %q", cancel, out)
		}

		// Split across reads, from a window whose requests are refused.
		server, _, second, attach := newKittyClipboardTestServer(t)
		server.mu.Lock()
		server.activeID = "@2"
		server.attachClients[attach].capabilityHint = nil
		server.mu.Unlock()
		server.handleWindowOutput("@2", []byte("\x1b]5522;type=write:id=w"))
		server.handleWindowOutput("@2", []byte(cancel+"VISIBLE\x1b\\tail"))
		if got := waitForAttachOutput(t, attach, "tail"); got != "VISIBLE\x1b\\tail" {
			t.Fatalf("cancel %q: attach got %q", cancel, got)
		}
		if out := windowPtyOutput(t, second); out != "" {
			t.Fatalf("cancel %q: refused window got %q", cancel, out)
		}
	}
}

func TestKittyClipboardDiscardEndsAtCanOrSub(t *testing.T) {
	for _, cancel := range []byte{0x18, 0x1a} {
		window := &muxWindow{id: "@1"}
		window.kittyClipboard.discarding = true
		if got := string(window.skipDiscardedKittyClipboardOscLocked([]byte("QUFB" + string(cancel) + "x\x1b\\y"))); got != "x\x1b\\y" {
			t.Fatalf("cancel %q: got %q, want the output after it", cancel, got)
		}
		if window.kittyClipboard.discarding {
			t.Fatalf("cancel %q: still discarding", cancel)
		}
	}
}

// A read can still go to the client that received the start of a query
// after focus moved on. A write opened in it belongs to that client: the
// rest of the write must not go to the new primary, which has no open write
// and would drop it.
func TestKittyClipboardWriteStaysWithTheClientItWentTo(t *testing.T) {
	server, first, _, attachA := newKittyClipboardTestServer(t)
	attachB := &recordingConn{}
	clientB := registerTestAttachClient(t, server, attachB, "second", 80, 24)
	clientB.capabilityHint = []byte(kittyClipboardHintFixture)
	server.mu.Lock()
	server.attachConn = attachA
	server.mu.Unlock()

	// A receives the start of a query, then B takes focus.
	server.handleWindowOutput("@1", []byte("\x1b[>"))
	waitForAttachOutput(t, attachA, "\x1b[>")
	server.focusAttachClient(clientB, 0, 0, false)

	server.handleWindowOutput("@1", []byte("c\x1b]5522;type=write:id=w\x1b\\"))
	waitForAttachOutput(t, attachA, "c\x1b]5522;type=write:id="+kittyClipboardTagWindow1+".w\x1b\\")
	server.handleWindowOutput("@1", []byte(
		"\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\x1b]5522;type=wdata\x1b\\done"))
	waitForAttachOutput(t, attachB, "done")

	for name, attach := range map[string]*recordingConn{"A": attachA, "B": attachB} {
		if got := attach.String(); strings.Contains(got, "wdata") {
			t.Fatalf("client %s got the rest of a write it may not hold: %q", name, got)
		}
	}
	if got := windowPtyOutput(t, first); got != "\x1b]5522;type=write:status=EBUSY:id=w\x1b\\" {
		t.Fatalf("window got %q, want the split write refused", got)
	}
}
