package main

import (
	"bufio"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

type attachTransitionPty struct {
	mu     sync.Mutex
	width  int
	height int
}

func (p *attachTransitionPty) Read([]byte) (int, error) { return 0, io.EOF }

func (p *attachTransitionPty) Write(data []byte) (int, error) {
	return len(data), nil
}

func (p *attachTransitionPty) Close() error { return nil }

func (p *attachTransitionPty) Resize(width int, height int) error {
	p.mu.Lock()
	p.width = width
	p.height = height
	p.mu.Unlock()
	return nil
}

func (p *attachTransitionPty) Fd() uintptr { return 0 }

func (p *attachTransitionPty) size() (int, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.width, p.height
}

func TestAttachWaitsForForwardingBeforePublishingRequestedViewport(
	t *testing.T,
) {
	server := newMuxServerWithSize("test", 59, 47)
	windowPty := &attachTransitionPty{width: 59, height: 47}
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		pty:                      windowPty,
		terminalOutputForwarding: true,
		history:                  []byte("restored frame"),
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	attached := make(chan struct{})

	go func() {
		server.handleAttach(
			conn,
			bufio.NewReader(strings.NewReader("")),
			controlMessage{
				ClientID:     "phone",
				Width:        69,
				Height:       55,
				ClipViewport: true,
			},
		)
		close(attached)
	}()

	time.Sleep(20 * time.Millisecond)
	if got := conn.String(); got != "" {
		t.Fatalf("attach published stale output while forwarding: %q", got)
	}
	server.mu.Lock()
	if server.publishedWidth != 59 || server.publishedHeight != 47 {
		publishedWidth, publishedHeight :=
			server.publishedWidth, server.publishedHeight
		server.mu.Unlock()
		t.Fatalf(
			"unsafe attach changed published grid to %dx%d, want 59x47",
			publishedWidth,
			publishedHeight,
		)
	}
	window.terminalOutputForwarding = false
	server.mu.Unlock()

	select {
	case <-attached:
	case <-time.After(time.Second):
		t.Fatal("attach did not finish after forwarding settled")
	}

	got := conn.String()
	resize := string(terminalViewportResizeSequence(69, 55, false))
	server.mu.Lock()
	replay := string(server.replayBytesLocked(window))
	publishedWidth, publishedHeight :=
		server.publishedWidth, server.publishedHeight
	server.mu.Unlock()
	if resizeIndex, replayIndex := strings.Index(got, resize), strings.Index(got, replay); resizeIndex < 0 || replayIndex < 0 || resizeIndex > replayIndex {
		t.Fatalf(
			"attach output order resize=%d replay=%d output=%q",
			resizeIndex,
			replayIndex,
			got,
		)
	}
	if publishedWidth != 69 || publishedHeight != 55 {
		t.Fatalf(
			"published grid = %dx%d, want 69x55",
			publishedWidth,
			publishedHeight,
		)
	}
	deadline := time.Now().Add(time.Second)
	for {
		width, height := windowPty.size()
		if width == 69 && height == 55 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pty grid = %dx%d, want 69x55", width, height)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestAttachBarrierLetsIncompleteOutputReachGroundBeforeReplay(t *testing.T) {
	server := newMuxServerWithSize("test", 59, 47)
	window := &muxWindow{
		id:                  "@1",
		index:               0,
		terminalOutputState: terminalOutputParserCsi,
		history:             []byte("\x1b["),
		lastActivity:        time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	attached := make(chan struct{})

	go func() {
		server.handleAttach(
			conn,
			bufio.NewReader(strings.NewReader("")),
			controlMessage{
				ClientID:     "phone",
				Width:        69,
				Height:       55,
				ClipViewport: true,
			},
		)
		close(attached)
	}()

	time.Sleep(20 * time.Millisecond)
	server.handleWindowOutput(window.id, []byte("0m"))

	select {
	case <-attached:
	case <-time.After(time.Second):
		t.Fatal("attach barrier did not release after parser reached ground")
	}
	got := conn.String()
	resize := string(terminalViewportResizeSequence(69, 55, false))
	if !strings.HasPrefix(got, resize) {
		t.Fatalf("attach did not publish requested grid first: %q", got)
	}
}

func TestAttachBarrierDoesNotHoldResizeLockWhileWaiting(t *testing.T) {
	server := newMuxServerWithSize("test", 59, 47)
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		terminalOutputForwarding: true,
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	attached := make(chan struct{})

	go func() {
		server.handleAttach(
			&recordingConn{},
			bufio.NewReader(strings.NewReader("")),
			controlMessage{Width: 69, Height: 55},
		)
		close(attached)
	}()

	time.Sleep(20 * time.Millisecond)
	resizeLockAcquired := make(chan struct{})
	go func() {
		server.resizeMu.Lock()
		server.resizeMu.Unlock()
		close(resizeLockAcquired)
	}()
	select {
	case <-resizeLockAcquired:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("waiting attach held resizeMu")
	}

	server.mu.Lock()
	window.terminalOutputForwarding = false
	server.mu.Unlock()
	select {
	case <-attached:
	case <-time.After(time.Second):
		t.Fatal("attach did not finish after forwarding settled")
	}
}

func TestResizeRepublishesGridForUnchangedRequest(t *testing.T) {
	// A client whose grid drifted can only ask for a correction by re-sending
	// its viewport. If the server suppresses an unchanged size, that request is
	// silently dropped and the client stays corrupted until the user resizes.
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	client := newAttachClient(conn, controlMessage{
		ClientID:     "phone",
		Width:        80,
		Height:       24,
		ClipViewport: true,
	})
	t.Cleanup(client.close)
	server.mu.Lock()
	server.attachClients[conn] = client
	server.attachConn = conn
	server.mu.Unlock()

	server.resizeForClient("phone", 80, 24, false)

	want := string(terminalViewportResizeSequence(80, 24, false))
	deadline := time.Now().Add(time.Second)
	for {
		if strings.Contains(conn.String(), want) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf(
				"unchanged-size resize did not republish the grid: %q",
				conn.String(),
			)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestAttachBarrierAbortsWhenServerCloses(t *testing.T) {
	server := newMuxServerWithSize("test", 59, 47)
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		terminalOutputForwarding: true,
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	attached := make(chan struct{})

	go func() {
		server.handleAttach(
			&recordingConn{},
			bufio.NewReader(strings.NewReader("")),
			controlMessage{Width: 69, Height: 55},
		)
		close(attached)
	}()

	time.Sleep(20 * time.Millisecond)
	server.mu.Lock()
	server.closed = true
	server.mu.Unlock()
	select {
	case <-attached:
	case <-time.After(time.Second):
		t.Fatal("attach did not abort after server closed")
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.attachViewportTransitionWindowID != "" ||
		server.attachCountLocked() != 0 {
		t.Fatalf(
			"closed server retained attach transition %q with %d clients",
			server.attachViewportTransitionWindowID,
			server.attachCountLocked(),
		)
	}
}

func TestAttachTransitionLockReleasesWhileClientRemainsConnected(t *testing.T) {
	server := newMuxServerWithSize("test", 69, 55)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	firstInput, firstWriter := io.Pipe()
	t.Cleanup(func() {
		_ = firstWriter.Close()
	})
	firstAttached := make(chan struct{})
	go func() {
		close(firstAttached)
		server.handleAttach(
			&recordingConn{},
			bufio.NewReader(firstInput),
			controlMessage{ClientID: "first", Width: 69, Height: 55},
		)
	}()
	<-firstAttached
	deadline := time.Now().Add(time.Second)
	for {
		server.mu.Lock()
		attachCount := server.attachCountLocked()
		server.mu.Unlock()
		if attachCount == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("first attach did not register")
		}
		time.Sleep(time.Millisecond)
	}

	secondAttached := make(chan struct{})
	go func() {
		server.handleAttach(
			&recordingConn{},
			bufio.NewReader(strings.NewReader("")),
			controlMessage{ClientID: "second", Width: 69, Height: 55},
		)
		close(secondAttached)
	}()
	select {
	case <-secondAttached:
	case <-time.After(time.Second):
		t.Fatal("second attach blocked behind connected first client")
	}
}

// TestRedrawFallbackRejectsFrameWithoutVisibleContent pins the fallback against
// painting emptiness.
//
// A pane whose foreground app owns its own pixels is cleared before its new
// content arrives, and the retained frame is what rescues the client when that
// app never repaints. Substituting a frame that draws nothing hands the user
// exactly the blank viewport the fallback exists to prevent, and because the
// grid is already correct nothing else on either side has a reason to speak up.
func TestRedrawFallbackRejectsFrameWithoutVisibleContent(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      []byte("\x1b[H\x1b[2J"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	client := newAttachClient(conn, controlMessage{
		ClientID:     "phone",
		Width:        120,
		Height:       40,
		ClipViewport: true,
	})
	t.Cleanup(client.close)

	originalSimulateForegroundResize := simulateForegroundResize
	t.Cleanup(func() {
		simulateForegroundResize = originalSimulateForegroundResize
	})
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.mu.Lock()
	server.attachClients[conn] = client
	server.attachConn = conn
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	captured := append([]byte(nil), window.redrawForwardingFallbackHistory...)
	server.mu.Unlock()

	if len(captured) != 0 {
		t.Fatalf(
			"pause retained a frame with nothing to paint: %q",
			string(captured),
		)
	}
}

func TestAttachBarrierDeadlineReleasesDisconnectedAndQueuedAttaches(t *testing.T) {
	server := newMuxServerWithSize("test", 59, 47)
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	window.observeTerminalOutputStateLocked([]byte("\x1b]0;unfinished"))
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	firstConn, peer := net.Pipe()
	defer firstConn.Close()
	defer peer.Close()
	firstDone := make(chan struct{})
	go func() {
		server.handleAttach(firstConn, bufio.NewReader(firstConn), controlMessage{Width: 69, Height: 55})
		close(firstDone)
	}()
	deadline := time.Now().Add(time.Second)
	for {
		server.mu.Lock()
		waiting := server.attachViewportTransitionWindowID == window.id
		server.mu.Unlock()
		if waiting {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("first attach did not enter transition")
		}
		time.Sleep(time.Millisecond)
	}
	_ = peer.Close()
	secondConn := &recordingConn{}
	secondDone := make(chan struct{})
	started := time.Now()
	go func() {
		server.handleAttach(secondConn, bufio.NewReader(strings.NewReader("")), controlMessage{Width: 69, Height: 55})
		close(secondDone)
	}()
	for _, done := range []chan struct{}{firstDone, secondDone} {
		select {
		case <-done:
		case <-time.After(time.Until(started.Add(attachTransitionTimeout + time.Second))):
			t.Fatal("incomplete OSC retained an attach beyond its absolute deadline")
		}
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.attachViewportTransitionWindowID != "" || server.attachCountLocked() != 0 {
		t.Fatal("timed-out attach retained transition state")
	}
	if server.publishedWidth != 59 || server.publishedHeight != 47 || secondConn.String() != "" {
		t.Fatal("timed-out attach injected a viewport transition into incomplete output")
	}
	if window.terminalOutputIsGroundLocked() {
		t.Fatal("timeout changed the incomplete parser state")
	}
}
