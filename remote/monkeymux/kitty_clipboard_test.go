package main

import (
	"bufio"
	"encoding/base64"
	"io"
	"math/rand"
	"strconv"
	"strings"
	"testing"
	"time"
)

const kittyClipboardHintFixture = capabilityHintFixture +
	"\x1e" + "osc5522\x1f\x1b[?5522;2$y"

// "@1" and "@2" in hex, as forwarded request ids carry them ahead of the
// request's sequence number in the window.
const (
	kittyClipboardTagWindow1 = "mmx4031"
	kittyClipboardTagWindow2 = "mmx4032"
)

// oweKittyClipboardReplies makes client owe a reply, as a request forwarded
// to it does.
func oweKittyClipboardReplies(client *attachClient) {
	client.kittyClipboardInput.outstanding.Add(1)
	client.kittyClipboardInput.owedUntil.Store(time.Now().Add(time.Minute).UnixNano())
}

func kittyClipboardRepliesOwed(client *attachClient) bool {
	return client.kittyClipboardInput.repliesOwed(time.Now())
}

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
	for _, tc := range []struct {
		windowID string
		sequence uint64
	}{
		{"@1", 1},
		{"@12", 345},
		{"@3", ^uint64(0)},
	} {
		tag := kittyClipboardWindowTag(tc.windowID, tc.sequence)
		windowID, ok := untagKittyClipboardID(tag)
		if !ok || windowID != tc.windowID {
			t.Fatalf("untag(%q) = %q, %v; want %q", tag, windowID, ok, tc.windowID)
		}
	}
	if got := kittyClipboardWindowTag("@1", 7); got != kittyClipboardTagWindow1+".7" {
		t.Fatalf("tag = %q", got)
	}
	for _, tag := range []string{"", "abc", "mmx", "mmxzz", "mmx.abc", "mmx4031", "mmx4031.", "mmx4031.x", "mmx4031.1.x"} {
		if _, ok := untagKittyClipboardID(tag); ok {
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

	waitForAttachOutput(t, attach, "\x1b]5522;type=read:id="+kittyClipboardTagWindow1+".1;Lg==\x1b\\")
	got := waitForAttachOutput(t, secondary, "ab")
	if strings.Contains(got, "5522") {
		t.Fatalf("secondary client got %q, want the request withheld", got)
	}
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q, want no local answer for a forwarded request", out)
	}
	server.mu.Lock()
	client := server.attachClients[attach]
	server.mu.Unlock()
	if !kittyClipboardRepliesOwed(client) {
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
		"\x1b]5522;type=write:id="+kittyClipboardTagWindow1+".1\x1b\\"+
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
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")

	// Window 2 comes on screen and starts its own write before window 1
	// writes again.
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.handleWindowOutput("@2", []byte("\x1b]5522;type=write:id=two\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow2+".1")

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
	reply := "\x1b]5522;type=read:status=DATA:id=" + kittyClipboardTagWindow2 + ".3:mime=Lg==;dGV4dA==\x1b\\"

	input, replies := client.splitKittyClipboardRepliesLocked([]byte("a"+reply+"b"), time.Now())

	if string(input) != "ab" {
		t.Fatalf("input = %q, want the reply removed", input)
	}
	if len(replies) != 1 || replies[0].windowID != "@2" || !replies[0].kittyClipboardReply {
		t.Fatalf("replies = %+v", replies)
	}
	if got := string(replies[0].data); got != reply {
		t.Fatalf("reply = %q, want it whole for the window to resolve", got)
	}
}

// A reply reaches the program with its own id back, and only while the tag
// it carries names a request the window still holds.
func TestKittyClipboardReplyIsResolvedByItsTag(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte(
		"\x1b]5522;type=read:id=x;Lg==\x1b\\\x1b]5522;type=write\x1b\\"))
	waitForAttachOutput(t, attach, "type=write:id="+kittyClipboardTagWindow1+".2")
	tag := kittyClipboardTagWindow1 + ".1"

	server.mu.Lock()
	client := server.attachClients[attach]
	server.mu.Unlock()
	take := func(reply string) string {
		return string(server.takeKittyClipboardReply(client, "@1", []byte(reply)))
	}
	if got := take("\x1b]5522;type=read:status=DATA:id=" + tag + ":mime=Lg==;dGV4dA==\x1b\\"); got != "\x1b]5522;type=read:status=DATA:mime=Lg==:id=x;dGV4dA==\x1b\\" {
		t.Fatalf("reply = %q, want the program's id restored", got)
	}
	// A tag of another window, operation or sequence is no reply.
	for _, reply := range []string{
		"\x1b]5522;type=write:status=DONE:id=" + tag + "\x1b\\",
		"\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".9\x1b\\",
		"\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow2 + ".1\x1b\\",
	} {
		if got := take(reply); got != "" {
			t.Fatalf("take(%q) = %q, want it dropped", reply, got)
		}
	}
	if got := take("\x1b]5522;type=read:status=DONE:id=" + tag + "\x1b\\"); got != "\x1b]5522;type=read:status=DONE:id=x\x1b\\" {
		t.Fatalf("final reply = %q", got)
	}
	// The request is finished: a second final reply is dropped.
	if got := take("\x1b]5522;type=read:status=DONE:id=" + tag + "\x1b\\"); got != "" {
		t.Fatalf("second final reply = %q, want it dropped", got)
	}
	// Without the program's own id the id record is dropped.
	if got := take("\x1b]5522;type=write:status=DONE:id=" + kittyClipboardTagWindow1 + ".2\x07"); got != "\x1b]5522;type=write:status=DONE\x07" {
		t.Fatalf("write reply = %q", got)
	}
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q", out)
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
		"\x1b[200~\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".1\x1b\\\x1b[201~",
	} {
		input, replies := client.splitKittyClipboardRepliesLocked([]byte(data), time.Now())
		if string(input) != data || len(replies) != 0 {
			t.Fatalf("split(%q) = %q, %+v; want all of it as input", data, input, replies)
		}
	}
}

func TestKittyClipboardSplitHoldsRepliesSplitAcrossReads(t *testing.T) {
	client := newAttachClient(&recordingConn{}, controlMessage{})
	client.inputDispatchMu.Lock()
	defer client.inputDispatchMu.Unlock()
	reply := "\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".1\x1b\\"

	// Not owed: a trailing ESC is the Escape key and passes straight on.
	input, _ := client.splitKittyClipboardRepliesLocked([]byte("x\x1b"), time.Now())
	if string(input) != "x\x1b" {
		t.Fatalf("input = %q, want the Escape key kept", input)
	}

	oweKittyClipboardReplies(client)
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
	client := newAttachClient(&recordingConn{}, controlMessage{})
	oweKittyClipboardReplies(client)
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
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")

	// The user switches windows before the client answers: the answer still
	// goes to the window that asked, never to the one on screen.
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	reply := "\x1b]5522;type=read:status=OK:id=" + kittyClipboardTagWindow1 + ".1\x1b\\" +
		"\x1b]5522;type=read:status=DATA:id=" + kittyClipboardTagWindow1 + ".1:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\" +
		"\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".1\x1b\\"
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
	want := strings.Replace(input, "id=big", "id="+kittyClipboardTagWindow1+".1", 1)

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
	tag := ":id=" + kittyClipboardTagWindow2 + ".1"
	mime := base64.StdEncoding.EncodeToString([]byte("image/png"))
	var tagged strings.Builder
	packet := func(metadata string, payload string) {
		tagged.WriteString("\x1b]5522;type=read:" + metadata + tag + payload + "\x1b\\")
	}
	packet("status=OK", "")
	for offset := 0; offset < len(data); offset += 4096 {
		end := min(offset+4096, len(data))
		packet("status=DATA:mime="+mime, ";"+base64.StdEncoding.EncodeToString(data[offset:end]))
	}
	packet("status=DONE", "")
	input := tagged.String()

	client := newAttachClient(&recordingConn{}, controlMessage{})
	oweKittyClipboardReplies(client)
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
	if routed.String() != input {
		t.Fatalf("routed %d bytes, want %d identical bytes", routed.Len(), len(input))
	}
}

// A window that sends a whole write in one read still replaces the write
// another window has open on the client, which must hear EBUSY: otherwise,
// back on screen, it forwards the rest of its write into nothing and waits
// forever.
func TestKittyClipboardWriteCommittedInOneReadDisplacesOpenWrite(t *testing.T) {
	server, first, second, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=one\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")

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
		waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")

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
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")
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
	reply := "\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".1\x1b\\"
	split := func(input string, at int) (string, []attachInputAction) {
		client := newAttachClient(&recordingConn{}, controlMessage{})
		oweKittyClipboardReplies(client)
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
	waitForAttachOutput(t, attachA, "c\x1b]5522;type=write:id="+kittyClipboardTagWindow1+".1\x1b\\")
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

// startKittyClipboardInputWorker runs the input worker of attach's client,
// as handleAttach does, so its replies reach their windows and its
// departure is noticed once they have.
func startKittyClipboardInputWorker(t *testing.T, server *muxServer, attach *recordingConn) *attachClient {
	t.Helper()
	server.mu.Lock()
	client := server.attachClients[attach]
	server.mu.Unlock()
	go server.runAttachInputActions(client)
	return client
}

func waitForWindowPtyOutput(t *testing.T, window *muxWindow, want string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		got := windowPtyOutput(t, window)
		if got == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("window got %q, want %q", got, want)
		}
		time.Sleep(time.Millisecond)
	}
}

// A request whose client goes away before answering it is answered EBUSY at
// once: on a phone the primary client vanishing mid-request is how a
// session usually ends, and the program would otherwise wait for its own
// timeout.
func TestKittyClipboardRequestsOfADepartedClientAreAnsweredBusy(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	client := startKittyClipboardInputWorker(t, server, attach)
	server.handleWindowOutput("@1", []byte(
		"\x1b]5522;type=read:mime=dGV4dC9wbGFpbg==:id=r1\x1b\\"+
			"\x1b]5522;type=write:id=w\x1b\\\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")

	server.removeAttachClient(client)
	waitForWindowPtyOutput(t, first,
		"\x1b]5522;type=read:status=EBUSY:id=r1\x1b\\"+
			"\x1b]5522;type=write:status=EBUSY:id=w\x1b\\")

	// The rest of the write has nowhere to go, and is not answered again.
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata\x1b\\more"))
	waitForWindowReplies(t, first)
	if got := windowPtyOutput(t, first); strings.Count(got, "type=write") != 1 {
		t.Fatalf("window got %q, want the write answered once", got)
	}
}

// Replies the client sent before it went away still reach the window, ahead
// of the EBUSY for what it left unanswered, and a request it finished is
// not answered again.
func TestKittyClipboardDepartedClientRepliesComeFirst(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	client := startKittyClipboardInputWorker(t, server, attach)
	server.handleWindowOutput("@1", []byte(
		"\x1b]5522;type=read:mime=dGV4dC9wbGFpbg==:id=done\x1b\\"+
			"\x1b]5522;type=read:mime=dGV4dC9wbGFpbg==:id=half\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".2")

	tag := ":id=" + kittyClipboardTagWindow1
	client.inputDispatchMu.Lock()
	_, replies := client.splitKittyClipboardRepliesLocked([]byte(
		"\x1b]5522;type=read:status=OK"+tag+".1\x1b\\"+
			"\x1b]5522;type=read:status=DONE"+tag+".1\x1b\\"+
			"\x1b]5522;type=read:status=OK"+tag+".2\x1b\\"), time.Now())
	client.enqueueInputActions(replies)
	client.inputDispatchMu.Unlock()
	server.removeAttachClient(client)

	waitForWindowPtyOutput(t, first,
		"\x1b]5522;type=read:status=OK:id=done\x1b\\"+
			"\x1b]5522;type=read:status=DONE:id=done\x1b\\"+
			"\x1b]5522;type=read:status=OK:id=half\x1b\\"+
			"\x1b]5522;type=read:status=EBUSY:id=half\x1b\\")
}

// A write the client already refused is not answered again when MonkeyMux
// later drops the rest of it.
func TestKittyClipboardAnsweredWriteIsNotAnsweredAgain(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	client := startKittyClipboardInputWorker(t, server, attach)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")

	client.inputDispatchMu.Lock()
	_, replies := client.splitKittyClipboardRepliesLocked([]byte(
		"\x1b]5522;type=write:status=EPERM:id="+kittyClipboardTagWindow1+".1\x1b\\"), time.Now())
	client.enqueueInputActions(replies)
	client.inputDispatchMu.Unlock()
	want := "\x1b]5522;type=write:status=EPERM:id=w\x1b\\"
	waitForWindowPtyOutput(t, first, want)

	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"))
	server.removeAttachClient(client)
	time.Sleep(20 * time.Millisecond)
	if got := windowPtyOutput(t, first); got != want {
		t.Fatalf("window got %q, want only the client's answer", got)
	}
}

// The Escape key, a lone ESC in a read, is held back only while a reply is
// owed, since only then can it start one. Once the client has finished
// answering, it goes straight to the window, however recent the request.
func TestKittyClipboardEscapeIsNotHeldOnceRepliesAreDone(t *testing.T) {
	restore := stubForegroundResize(t)
	defer restore()
	server := newMuxServer("kitty-clipboard-escape")
	window := &muxWindow{id: "@1", pty: &recordingPty{}, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
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
	waitForEscape := func(prefix string, within time.Duration) {
		t.Helper()
		if _, err := writer.Write([]byte("\x1b")); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(within)
		for window.pty.(*recordingPty).String() != prefix+"\x1b" {
			if time.Now().After(deadline) {
				t.Fatalf("window got %q within %v, want %q",
					window.pty.(*recordingPty).String(), within, prefix+"\x1b")
			}
			time.Sleep(time.Millisecond)
		}
	}

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")
	reply := "\x1b]5522;type=read:status=OK:id=" + kittyClipboardTagWindow1 + ".1\x1b\\" +
		"\x1b]5522;type=read:status=DONE:id=" + kittyClipboardTagWindow1 + ".1\x1b\\"
	if _, err := writer.Write([]byte(reply)); err != nil {
		t.Fatal(err)
	}
	answered := "\x1b]5522;type=read:status=OK:id=r\x1b\\\x1b]5522;type=read:status=DONE:id=r\x1b\\"
	deadline = time.Now().Add(2 * time.Second)
	for window.pty.(*recordingPty).String() != answered {
		if time.Now().After(deadline) {
			t.Fatalf("window got %q, want %q", window.pty.(*recordingPty).String(), answered)
		}
		time.Sleep(time.Millisecond)
	}
	waitForEscape(answered, kittyClipboardAmbiguousCarryTimeout/2)
}

// A client owes replies from a request until its final reply, and a request
// it never answers stops holding the Escape key back after the grace.
func TestKittyClipboardRepliesAreOwedOnlyWhileARequestIsOpen(t *testing.T) {
	server, _, _, attach := newKittyClipboardTestServer(t)
	server.mu.Lock()
	client := server.attachClients[attach]
	server.mu.Unlock()
	finish := func(reply string) {
		t.Helper()
		client.inputDispatchMu.Lock()
		_, replies := client.splitKittyClipboardRepliesLocked([]byte(reply), time.Now())
		client.inputDispatchMu.Unlock()
		for _, action := range replies {
			server.takeKittyClipboardReply(client, action.windowID, action.data)
		}
	}
	tag := ":id=" + kittyClipboardTagWindow1

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))
	if !kittyClipboardRepliesOwed(client) {
		t.Fatal("a forwarded read owes no reply")
	}
	finish("\x1b]5522;type=read:status=OK" + tag + ".1\x1b\\")
	finish("\x1b]5522;type=read:status=DATA" + tag + ".1:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\")
	if !kittyClipboardRepliesOwed(client) {
		t.Fatal("a read stopped owing replies before DONE")
	}
	finish("\x1b]5522;type=read:status=DONE" + tag + ".1\x1b\\")
	if kittyClipboardRepliesOwed(client) {
		t.Fatal("a finished read still owes replies")
	}

	// A write owes its reply from the write packet through the commit.
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\"+
		"\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\x1b]5522;type=wdata\x1b\\"))
	if !kittyClipboardRepliesOwed(client) {
		t.Fatal("a committed write owes no reply")
	}
	finish("\x1b]5522;type=write:status=DONE" + tag + ".2\x1b\\")
	if kittyClipboardRepliesOwed(client) {
		t.Fatal("a finished write still owes replies")
	}

	// A request the client ignores holds a trailing ESC back only for the
	// grace after it went out.
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=lost;!!\x1b\\"))
	client.inputDispatchMu.Lock()
	held, _ := client.splitKittyClipboardRepliesLocked([]byte("x\x1b"), time.Now())
	later, _ := client.splitKittyClipboardRepliesLocked([]byte("y\x1b"),
		time.Now().Add(kittyClipboardRepliesOwedGrace+time.Second))
	client.inputDispatchMu.Unlock()
	if string(held) != "x" || string(later) != "\x1by\x1b" {
		t.Fatalf("input = %q then %q, want the ESC held, then given back with the next", held, later)
	}

	// A window that closes stops counting.
	server.mu.Lock()
	server.retireWindowLocked(server.windowByIDLocked("@1"))
	server.mu.Unlock()
	if got := client.kittyClipboardInput.outstanding.Load(); got != 0 {
		t.Fatalf("outstanding = %d after the window closed", got)
	}
}

// Once a client has begun answering a read, the rest of its answer is held
// back when a read splits it, however long it takes to come: the grace only
// covers a request the client never answers.
func TestKittyClipboardReadBeingAnsweredOwesItsRestPastTheGrace(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.mu.Lock()
	client := server.attachClients[attach]
	server.mu.Unlock()
	split := func(data string, now time.Time) string {
		t.Helper()
		client.inputDispatchMu.Lock()
		input, replies := client.splitKittyClipboardRepliesLocked([]byte(data), now)
		client.inputDispatchMu.Unlock()
		for _, action := range replies {
			server.takeKittyClipboardReply(client, action.windowID, action.data)
		}
		return string(input)
	}

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))
	tag := ":id=" + forwardedKittyClipboardTag(t, server, first, "r")
	split("\x1b]5522;type=read:status=OK"+tag+"\x1b\\", time.Now())

	late := time.Now().Add(kittyClipboardRepliesOwedGrace + time.Second)
	data := "\x1b]5522;type=read:status=DATA" + tag + ":mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"
	for cut := 1; cut < len(kittyClipboardOscIntroducer); cut++ {
		if got := split("x"+data[:cut], late); got != "x" {
			t.Fatalf("cut %d: input = %q, want the start of the DATA packet held", cut, got)
		}
		if got := split(data[cut:]+"y", late); got != "y" {
			t.Fatalf("cut %d: input = %q, want only what follows the DATA packet", cut, got)
		}
	}
	split("\x1b]5522;type=read:status=DONE"+tag+"\x1b\\", late)
	if got := split("x\x1b", late.Add(kittyClipboardRepliesOwedGrace+time.Second)); got != "x\x1b" {
		t.Fatalf("input = %q, want the Escape key kept once the read is done", got)
	}
	if got := client.kittyClipboardInput.replying.Load(); got != 0 {
		t.Fatalf("client is still answering %d reads", got)
	}
}

// forwardedKittyClipboardTag returns the id MonkeyMux gave the request in a
// client's output whose own id was id.
func forwardedKittyClipboardTag(t *testing.T, server *muxServer, window *muxWindow, id string) string {
	t.Helper()
	server.mu.Lock()
	defer server.mu.Unlock()
	for _, request := range window.kittyClipboard.requests {
		if request.id == id {
			return request.tag
		}
	}
	t.Fatalf("window %s holds no request with id %q", window.id, id)
	return ""
}

// sendKittyClipboardReply passes reply through client's input, as its
// attach read loop does, to the input worker.
func sendKittyClipboardReply(client *attachClient, reply string) {
	client.inputDispatchMu.Lock()
	_, replies := client.splitKittyClipboardRepliesLocked([]byte(reply), time.Now())
	client.enqueueInputActions(replies)
	client.inputDispatchMu.Unlock()
}

// failingWriteConn is a client connection whose every write fails.
type failingWriteConn struct {
	recordingConn
}

func (*failingWriteConn) Write([]byte) (int, error) {
	return 0, io.ErrClosedPipe
}

// A request that fails over with the rest of its read to another client
// belongs to that client: the failed one's departure does not answer it,
// and the client that got it owes its reply.
func TestKittyClipboardRequestFailedOverBelongsToTheClientThatGotIt(t *testing.T) {
	server, first, _, attachB := newKittyClipboardTestServer(t)
	clientB := startKittyClipboardInputWorker(t, server, attachB)
	clientA := registerTestAttachClient(t, server, &failingWriteConn{}, "failing", 80, 24)
	clientA.capabilityHint = []byte(kittyClipboardHintFixture)
	departed := make(chan struct{})
	go func() {
		defer close(departed)
		server.runAttachInputActions(clientA)
	}()

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\\x1b[c"))
	got := waitForAttachOutput(t, attachB, "\x1b[c")
	<-departed
	tag := forwardedKittyClipboardTag(t, server, first, "r")
	if !strings.Contains(got, "id="+tag+";") {
		t.Fatalf("failover client got %q, want the request tagged %q", got, tag)
	}
	if got := clientB.kittyClipboardInput.outstanding.Load(); got != 1 {
		t.Fatalf("failover client owes %d replies, want 1", got)
	}
	if got := clientA.kittyClipboardInput.outstanding.Load(); got != 0 {
		t.Fatalf("failed client owes %d replies, want 0", got)
	}

	sendKittyClipboardReply(clientB, "\x1b]5522;type=read:status=EPERM:id="+tag+"\x1b\\")
	waitForWindowPtyOutput(t, first, "\x1b]5522;type=read:status=EPERM:id=r\x1b\\")
	time.Sleep(20 * time.Millisecond)
	if got := windowPtyOutput(t, first); got != "\x1b]5522;type=read:status=EPERM:id=r\x1b\\" {
		t.Fatalf("window got %q, want one answer", got)
	}
}

// A reply to a request MonkeyMux already answered is dropped, even when the
// program has since sent another request with the same id through another
// client: it must not retire that one.
func TestKittyClipboardLateReplyLeavesAnotherClientsRequest(t *testing.T) {
	server, first, _, attachA := newKittyClipboardTestServer(t)
	clientA := startKittyClipboardInputWorker(t, server, attachA)
	attachB := &recordingConn{}
	clientB := registerTestAttachClient(t, server, attachB, "second", 80, 24)
	clientB.capabilityHint = []byte(kittyClipboardHintFixture)
	go server.runAttachInputActions(clientB)
	server.mu.Lock()
	server.attachConn = attachA
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\"))
	tagA := forwardedKittyClipboardTag(t, server, first, "w")
	waitForAttachOutput(t, attachA, "id="+tagA)
	// Focus moves to B, so A's write is refused at its next packet.
	server.focusAttachClient(clientB, 0, 0, false)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\"))
	busy := "\x1b]5522;type=write:status=EBUSY:id=w\x1b\\"
	waitForWindowPtyOutput(t, first, busy)

	// The program retries through B with the same id.
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\"))
	tagB := forwardedKittyClipboardTag(t, server, first, "w")
	waitForAttachOutput(t, attachB, "id="+tagB)
	if tagA == tagB {
		t.Fatalf("both requests were tagged %q", tagA)
	}

	// A's answer to the refused write arrives late.
	sendKittyClipboardReply(clientA, "\x1b]5522;type=write:status=EPERM:id="+tagA+"\x1b\\")
	time.Sleep(20 * time.Millisecond)
	if got := windowPtyOutput(t, first); got != busy {
		t.Fatalf("window got %q, want the late reply dropped", got)
	}
	if got := clientB.kittyClipboardInput.outstanding.Load(); got != 1 {
		t.Fatalf("B owes %d replies, want 1", got)
	}

	// B leaves without answering: its request is answered EBUSY.
	server.removeAttachClient(clientB)
	clientB.close()
	waitForWindowPtyOutput(t, first, busy+busy)
}

// A request forwarded while redraw forwarding is paused reaches the client
// however the pause ends, even when the held redraw is replaced by a frame
// painted from the screen model.
func TestKittyClipboardRequestHeldByARedrawPauseIsDelivered(t *testing.T) {
	for _, name := range []string{"answered cursor", "oversized", "restarted"} {
		t.Run(name, func(t *testing.T) {
			server, first, _, attach := newKittyClipboardTestServer(t)
			server.handleWindowOutput("@1", []byte("hello\r\n"))
			waitForAttachOutput(t, attach, "hello")
			attach.Reset()
			server.mu.Lock()
			first.redrawForwardingPaused = true
			first.redrawForwardingGeneration = 1
			first.redrawForwardingPrimaryConn = attach
			first.redrawForwardingReplay = []byte("\x1b[H\x1b[2J")
			if name == "answered cursor" {
				first.redrawForwardingAnsweredCursor = true
			}
			server.mu.Unlock()

			server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))
			switch name {
			case "oversized":
				server.handleWindowOutput("@1", []byte(strings.Repeat("x", foregroundRedrawBufferLimitBytes+1)))
			case "restarted":
				server.mu.Lock()
				first.foregroundCommand = "codex"
				server.pauseAttachForwardingForRedrawLocked(first, 120, 41)
				first.redrawForwardingAnsweredCursor = true
				server.mu.Unlock()
			}
			server.mu.Lock()
			generation := first.redrawForwardingGeneration
			server.mu.Unlock()
			server.resumePausedAttachForwarding("@1", generation)

			tag := forwardedKittyClipboardTag(t, server, first, "r")
			waitForAttachOutput(t, attach, "\x1b]5522;type=read:id="+tag+";dGV4dC9wbGFpbg==\x1b\\")
			server.mu.Lock()
			client := server.attachClients[attach]
			server.mu.Unlock()
			if got := client.kittyClipboardInput.outstanding.Load(); got != 1 {
				t.Fatalf("client owes %d replies, want 1", got)
			}
			if out := windowPtyOutput(t, first); out != "" {
				t.Fatalf("window got %q", out)
			}
		})
	}
}

// A request whose packet reaches no client is answered EBUSY: here the
// window left the screen while a redraw pause held the packet.
func TestKittyClipboardRequestThatReachesNoClientIsAnsweredBusy(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.mu.Lock()
	first.redrawForwardingPaused = true
	first.redrawForwardingGeneration = 1
	first.redrawForwardingPrimaryConn = attach
	client := server.attachClients[attach]
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()

	server.resumePausedAttachForwarding("@1", 1)

	waitForWindowPtyOutput(t, first, "\x1b]5522;type=read:status=EBUSY:id=r\x1b\\")
	if got := attach.String(); strings.Contains(got, "5522") {
		t.Fatalf("attach got %q", got)
	}
	if got := client.kittyClipboardInput.outstanding.Load(); got != 0 {
		t.Fatalf("client owes %d replies, want 0", got)
	}
}

// A replay the client already received covers a window's output, but never
// its clipboard packets, which still reach the client.
func TestKittyClipboardRequestInReplayedOutputIsDelivered(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.mu.Lock()
	server.attachClients[attach].markOutputReplay("@1", ^uint64(0))
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("text\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\"))

	packet := "\x1b]5522;type=read:id=" + kittyClipboardTagWindow1 + ".1;dGV4dC9wbGFpbg==\x1b\\"
	if got := waitForAttachOutput(t, attach, packet); got != packet {
		t.Fatalf("attach got %q, want only the request", got)
	}
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q", out)
	}
}

// Past the requests a window keeps, the oldest is answered EBUSY, and the
// client's late reply to it is dropped.
func TestKittyClipboardOldestRequestPastTheLimitIsAnsweredBusy(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	for index := 0; index <= maxTrackedKittyClipboardRequests; index++ {
		server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r"+strconv.Itoa(index)+";Lg==\x1b\\"))
	}
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+"."+strconv.Itoa(maxTrackedKittyClipboardRequests+1))
	busy := "\x1b]5522;type=read:status=EBUSY:id=r0\x1b\\"
	waitForWindowPtyOutput(t, first, busy)
	server.mu.Lock()
	client := server.attachClients[attach]
	server.mu.Unlock()
	if reply := server.takeKittyClipboardReply(client, "@1", []byte(
		"\x1b]5522;type=read:status=DONE:id="+kittyClipboardTagWindow1+".1\x1b\\")); reply != nil {
		t.Fatalf("late reply = %q, want it dropped", reply)
	}
	if got := client.kittyClipboardInput.outstanding.Load(); got != maxTrackedKittyClipboardRequests {
		t.Fatalf("client owes %d replies, want %d", got, maxTrackedKittyClipboardRequests)
	}
}

// The rest of a write forwarded while a redraw pause holds it belongs to the
// write's client like the write itself: when it reaches no client, here
// because the window left the screen before the pause ended, the write can
// never complete and is answered EBUSY, even though the held packets
// committed it.
func TestKittyClipboardWriteContinuationThatReachesNoClientIsAnsweredBusy(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")
	server.mu.Lock()
	first.redrawForwardingPaused = true
	first.redrawForwardingGeneration = 1
	first.redrawForwardingPrimaryConn = attach
	client := server.attachClients[attach]
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte(
		"\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\x1b\\\x1b]5522;type=wdata\x1b\\"))
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()

	server.resumePausedAttachForwarding("@1", 1)

	waitForWindowPtyOutput(t, first, "\x1b]5522;type=write:status=EBUSY:id=w\x1b\\")
	if got := attach.String(); strings.Contains(got, "wdata") {
		t.Fatalf("attach got %q", got)
	}
	if got := client.kittyClipboardInput.outstanding.Load(); got != 0 {
		t.Fatalf("client owes %d replies, want 0", got)
	}
	server.mu.Lock()
	owner := server.kittyClipboardWriteWindow
	server.mu.Unlock()
	if owner != "" {
		t.Fatalf("write owner = %q, want none", owner)
	}
}

// The rest of a write held by a redraw pause that reaches the write's own
// client leaves the write to that client to answer.
func TestKittyClipboardWriteContinuationHeldByARedrawPauseIsLeftToItsClient(t *testing.T) {
	server, first, _, attach := newKittyClipboardTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=write:id=w\x1b\\"))
	waitForAttachOutput(t, attach, "id="+kittyClipboardTagWindow1+".1")
	server.mu.Lock()
	first.redrawForwardingPaused = true
	first.redrawForwardingGeneration = 1
	first.redrawForwardingPrimaryConn = attach
	client := server.attachClients[attach]
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("\x1b]5522;type=wdata\x1b\\"))

	server.resumePausedAttachForwarding("@1", 1)

	waitForAttachOutput(t, attach, "\x1b]5522;type=wdata\x1b\\")
	if got := client.kittyClipboardInput.outstanding.Load(); got != 1 {
		t.Fatalf("client owes %d replies, want 1", got)
	}
	time.Sleep(20 * time.Millisecond)
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q, want the client to answer", out)
	}
}

// stalledWriteConn is a client connection that takes the bytes of its first
// write, then fails it once release is closed, as a connection does that
// hits its write deadline partway through.
type stalledWriteConn struct {
	recordingConn
	release chan struct{}
}

func (c *stalledWriteConn) Write(data []byte) (int, error) {
	_, _ = c.recordingConn.Write(data)
	<-c.release
	return 0, io.ErrClosedPipe
}

// A read whose first client began answering before its write failed stays
// with that client: the program gets the answer it started, ended EBUSY when
// the client goes, and nothing of the client the output failed over to.
func TestKittyClipboardReadStaysWithTheClientAnsweringIt(t *testing.T) {
	server, first, _, attachB := newKittyClipboardTestServer(t)
	clientB := startKittyClipboardInputWorker(t, server, attachB)
	attachA := &stalledWriteConn{release: make(chan struct{})}
	clientA := registerTestAttachClient(t, server, attachA, "stalled", 80, 24)
	clientA.capabilityHint = []byte(kittyClipboardHintFixture)
	workerA := make(chan struct{})
	go func() {
		defer close(workerA)
		server.runAttachInputActions(clientA)
	}()

	delivered := make(chan struct{})
	go func() {
		defer close(delivered)
		server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\\x1b[c"))
	}()
	waitForAttachOutput(t, &attachA.recordingConn, "\x1b[c")
	tag := forwardedKittyClipboardTag(t, server, first, "r")
	started := "\x1b]5522;type=read:status=OK:id=r\x1b\\" +
		"\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==:id=r;QQ==\x1b\\"
	sendKittyClipboardReply(clientA,
		"\x1b]5522;type=read:status=OK:id="+tag+"\x1b\\"+
			"\x1b]5522;type=read:status=DATA:id="+tag+":mime=dGV4dC9wbGFpbg==;QQ==\x1b\\")
	waitForWindowPtyOutput(t, first, started)
	close(attachA.release)
	<-delivered
	waitForAttachOutput(t, attachB, "id="+tag+";")
	sendKittyClipboardReply(clientB,
		"\x1b]5522;type=read:status=OK:id="+tag+"\x1b\\"+
			"\x1b]5522;type=read:status=DATA:id="+tag+":mime=dGV4dC9wbGFpbg==;Qg==\x1b\\"+
			"\x1b]5522;type=read:status=DONE:id="+tag+"\x1b\\")
	<-workerA
	waitForWindowPtyOutput(t, first, started+"\x1b]5522;type=read:status=EBUSY:id=r\x1b\\")
}

// A client that gets a read another client has begun answering owes a reply
// MonkeyMux will drop, counted while the read is open so a reply it splits
// across its reads is still recognised rather than typed into the program.
func TestKittyClipboardBystanderOwesTheReadWhileItIsOpen(t *testing.T) {
	server, first, _, attachB := newKittyClipboardTestServer(t)
	clientA := registerTestAttachClient(t, server, &recordingConn{}, "answering", 80, 24)
	server.mu.Lock()
	clientB := server.attachClients[attachB]
	clientA.kittyClipboardInput.outstanding.Add(1)
	clientA.kittyClipboardInput.replying.Add(1)
	first.kittyClipboard.requests = append(first.kittyClipboard.requests, kittyClipboardRequest{
		tag: "mmx1.1", op: "read", id: "r", client: clientA, delivering: true, replied: true,
	})
	server.mu.Unlock()

	server.handKittyClipboardRequests("@1", []string{"mmx1.1", "mmx1.1"}, clientB)
	server.handKittyClipboardRequests("@1", []string{"mmx1.1"}, clientA)
	server.mu.Lock()
	request := first.kittyClipboard.requests[0]
	server.mu.Unlock()
	if request.client != clientA || len(request.bystanders) != 1 || request.bystanders[0] != clientB {
		t.Fatalf("request after the hand-offs: client %p, bystanders %v", request.client, request.bystanders)
	}
	if got := clientB.kittyClipboardInput.outstanding.Load(); got != 1 {
		t.Fatalf("bystander owes %d replies, want 1", got)
	}
	clientB.inputDispatchMu.Lock()
	input, _ := clientB.splitKittyClipboardRepliesLocked([]byte("\x1b]55"), time.Now())
	clientB.inputDispatchMu.Unlock()
	if len(input) != 0 {
		t.Fatalf("the start of the bystander's reply went to the program: %q", input)
	}

	server.mu.Lock()
	first.removeKittyClipboardRequestLocked(0)
	server.mu.Unlock()
	if a, b := clientA.kittyClipboardInput.outstanding.Load(), clientB.kittyClipboardInput.outstanding.Load(); a != 0 || b != 0 {
		t.Fatalf("after the read ends the clients owe %d and %d replies, want 0", a, b)
	}
	if got := clientA.kittyClipboardInput.replying.Load(); got != 0 {
		t.Fatalf("after the read ends client A is answering %d reads, want 0", got)
	}
}

// A request whose write to one client failed after the client had read it
// belongs to the client it failed over to. Replies the first client sent
// before it went are not the program's: they must not reach it, interleave
// with the new client's, or finish the request.
func TestKittyClipboardReplyFromAClientTheRequestLeftIsDropped(t *testing.T) {
	server, first, _, attachB := newKittyClipboardTestServer(t)
	startKittyClipboardInputWorker(t, server, attachB)
	attachA := &stalledWriteConn{release: make(chan struct{})}
	clientA := registerTestAttachClient(t, server, attachA, "stalled", 80, 24)
	clientA.capabilityHint = []byte(kittyClipboardHintFixture)

	delivered := make(chan struct{})
	go func() {
		defer close(delivered)
		server.handleWindowOutput("@1", []byte("\x1b]5522;type=read:id=r;dGV4dC9wbGFpbg==\x1b\\\x1b[c"))
	}()
	waitForAttachOutput(t, &attachA.recordingConn, "\x1b[c")
	tag := forwardedKittyClipboardTag(t, server, first, "r")
	sendKittyClipboardReply(clientA,
		"\x1b]5522;type=read:status=OK:id="+tag+"\x1b\\"+
			"\x1b]5522;type=read:status=DATA:id="+tag+":mime=dGV4dC9wbGFpbg==;QQ==\x1b\\"+
			"\x1b]5522;type=read:status=DONE:id="+tag+"\x1b\\")
	close(attachA.release)
	<-delivered
	waitForAttachOutput(t, attachB, "id="+tag+";")

	departed := make(chan struct{})
	go func() {
		defer close(departed)
		server.runAttachInputActions(clientA)
	}()
	<-departed
	if out := windowPtyOutput(t, first); out != "" {
		t.Fatalf("window got %q from the client the request left", out)
	}

	server.mu.Lock()
	clientB := server.attachClients[attachB]
	server.mu.Unlock()
	sendKittyClipboardReply(clientB, "\x1b]5522;type=read:status=EPERM:id="+tag+"\x1b\\")
	waitForWindowPtyOutput(t, first, "\x1b]5522;type=read:status=EPERM:id=r\x1b\\")
}
