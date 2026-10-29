package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

// stalledWriter blocks every write until release is closed, like a terminal
// whose SSH channel has stopped draining.
type stalledWriter struct {
	release chan struct{}
	mu      sync.Mutex
	buf     bytes.Buffer
}

func (w *stalledWriter) Write(p []byte) (int, error) {
	<-w.release
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.Write(p)
}

func (w *stalledWriter) bytes() []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]byte(nil), w.buf.Bytes()...)
}

func attachRelayTestOutput(size int) []byte {
	data := make([]byte, size)
	for i := range data {
		data[i] = byte('a' + i%26)
	}
	return data
}

func startAttachRelay(
	t *testing.T,
	dst io.Writer,
	src io.Reader,
	limit int,
	delivered func(uint64),
) <-chan error {
	t.Helper()
	result := make(chan error, 1)
	go func() { result <- relayAttachOutput(dst, src, limit, delivered) }()
	return result
}

func awaitAttachRelay(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(5 * time.Second):
		t.Fatal("relay did not finish")
		return nil
	}
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

// A terminal that stops accepting output for longer than the server's write
// timeout must not get the attach dropped: the server's writes keep landing
// while the relay holds them, and the terminal receives all of it, in order,
// once it drains again.
func TestRelayAttachOutputKeepsSocketDrainingWhileTerminalStalls(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &stalledWriter{release: make(chan struct{})}
	result := startAttachRelay(t, terminal, client, attachOutputBufferLimitBytes, nil)

	output := attachRelayTestOutput(1024 * 1024)
	stall := time.AfterFunc(attachWriteTimeout+500*time.Millisecond, func() {
		close(terminal.release)
	})
	defer stall.Stop()
	if err := writeAttachConnection(server, output); err != nil {
		t.Fatalf("server write while the terminal stalled: %v", err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := awaitAttachRelay(t, result); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if got := terminal.bytes(); !bytes.Equal(got, output) {
		t.Fatalf("terminal got %d bytes, want the %d the server wrote", len(got), len(output))
	}
}

// With a limit of 1, for a server that cannot take delivery reports, the
// relay reads nothing ahead, so a stalled terminal still stalls the server's
// writes as a plain copy would.
func TestRelayAttachOutputWithoutReadAheadCopiesLikeIoCopy(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &stalledWriter{release: make(chan struct{})}
	result := startAttachRelay(t, terminal, client, 1, nil)

	err := writeAttachConnection(server, attachRelayTestOutput(4*attachWriteChunkBytes))
	if !isTimeout(err) {
		t.Fatalf("server write to a stalled plain copy = %v, want a timeout", err)
	}
	close(terminal.release)
	_ = server.Close()
	if err := awaitAttachRelay(t, result); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if got := len(terminal.bytes()); got > 2*attachWriteChunkBytes {
		t.Fatalf("plain copy held %d bytes, want at most one read ahead of the terminal", got)
	}
}

// Past its limit the relay stops reading, so a terminal that never drains
// still reaches the server's write timeout instead of growing the client.
func TestRelayAttachOutputStopsReadingAtItsLimit(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &stalledWriter{release: make(chan struct{})}
	const limit = 64 * 1024
	result := startAttachRelay(t, terminal, client, limit, nil)

	err := writeAttachConnection(server, attachRelayTestOutput(4*limit))
	if !isTimeout(err) {
		t.Fatalf("server write past the relay limit = %v, want a timeout", err)
	}
	close(terminal.release)
	_ = server.Close()
	if err := awaitAttachRelay(t, result); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if got := len(terminal.bytes()); got < limit || got > limit+attachWriteChunkBytes {
		t.Fatalf("relay held %d bytes, want its %d-byte limit plus at most one read", got, limit)
	}
}

// recordingWriter records, for each delivery report, how much the terminal
// had been written when it came.
type recordingWriter struct {
	mu      sync.Mutex
	written int
	reports [][2]uint64
}

func (w *recordingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.written += len(p)
	return len(p), nil
}

func (w *recordingWriter) delivered(offset uint64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.reports = append(w.reports, [2]uint64{offset, uint64(w.written)})
}

// Each report counts only what the terminal has been written, piece by piece,
// so a query near the start of a long backlog is reported as soon as its own
// piece is out.
func TestRelayAttachOutputReportsDeliveryPerPiece(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &recordingWriter{}
	result := startAttachRelay(
		t,
		terminal,
		client,
		attachOutputBufferLimitBytes,
		terminal.delivered,
	)

	output := attachRelayTestOutput(5*attachWriteChunkBytes + 100)
	if err := writeAttachConnection(server, output); err != nil {
		t.Fatal(err)
	}
	_ = server.Close()
	if err := awaitAttachRelay(t, result); err != nil {
		t.Fatalf("relay: %v", err)
	}
	terminal.mu.Lock()
	defer terminal.mu.Unlock()
	if len(terminal.reports) == 0 {
		t.Fatal("no delivery reports")
	}
	previous := uint64(0)
	for _, report := range terminal.reports {
		offset, written := report[0], report[1]
		if offset != written {
			t.Fatalf("report %d came with %d bytes written", offset, written)
		}
		if offset <= previous || offset-previous > attachWriteChunkBytes {
			t.Fatalf("report %d after %d: want pieces of at most %d bytes", offset, previous, attachWriteChunkBytes)
		}
		previous = offset
	}
	if previous != uint64(len(output)) {
		t.Fatalf("last report %d, want %d", previous, len(output))
	}
}

func TestRelayAttachOutputReturnsTheWriteError(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	sink, err := os.Open(os.DevNull) // Read-only: writes fail.
	if err != nil {
		t.Fatal(err)
	}
	defer sink.Close()
	result := startAttachRelay(t, sink, client, attachOutputBufferLimitBytes, nil)

	go func() { _, _ = server.Write([]byte("output")) }()
	if err := awaitAttachRelay(t, result); err == nil {
		t.Fatal("relay ignored a failed terminal write")
	}
}

type failingAttachSource struct {
	data []byte
	err  error
}

func (s *failingAttachSource) Read(p []byte) (int, error) {
	n := copy(p, s.data)
	s.data = s.data[n:]
	if len(s.data) == 0 {
		return n, s.err
	}
	return n, nil
}

func TestRelayAttachOutputWritesWhatItReadBeforeAReadError(t *testing.T) {
	readErr := errors.New("connection reset")
	var terminal bytes.Buffer
	err := relayAttachOutput(
		&terminal,
		&failingAttachSource{data: []byte("last frame"), err: readErr},
		attachOutputBufferLimitBytes,
		nil,
	)
	if !errors.Is(err, readErr) {
		t.Fatalf("relay = %v, want the read error", err)
	}
	if terminal.String() != "last frame" {
		t.Fatalf("terminal got %q before the read error", terminal.String())
	}
}

// A client that reads ahead of its terminal reports delivery, and the replies
// a query is owed must not expire before the terminal has the query.
func TestUndeliveredQueryKeepsItsRepliesExpected(t *testing.T) {
	client := &attachClient{deliveryToken: "token"}
	client.expectTerminalResponsesUntilDelivered("@1", 1, 10)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.trackRepliesLocked(nil)
	client.activityMu.Unlock()

	if !client.owesTerminalReplies("@1", time.Now()) {
		t.Fatal("an undelivered query's reply is not owed")
	}
	routing := client.routeInput([]byte("\x1b[?62;4c"))
	if len(routing.actions) != 1 ||
		routing.actions[0].userInput || routing.actions[0].windowID != "@1" {
		t.Fatalf("late reply to an undelivered query routed as %#v", routing.actions)
	}
}

// Delivery starts the reply grace; once that has run out, input is the
// user's again, as for a client that does not report.
func TestDeliveredQueryRepliesExpireAfterTheirGrace(t *testing.T) {
	client := &attachClient{deliveryToken: "token"}
	client.expectTerminalResponsesUntilDelivered("@1", 1, 10)
	client.expectTerminalResponsesUntilDelivered("@1", 1, 20)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()

	client.markOutputDelivered(15)
	client.activityMu.Lock()
	undelivered := append([]uint64(nil), client.undeliveredQueryEnds...)
	renewed := client.terminalResponseUntil.After(time.Now())
	client.activityMu.Unlock()
	if len(undelivered) != 1 || undelivered[0] != 20 {
		t.Fatalf("undelivered after a report at 15 = %v, want [20]", undelivered)
	}
	if !renewed {
		t.Fatal("delivery did not restart the reply grace")
	}

	client.markOutputDelivered(20)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()
	routing := client.routeInput([]byte("x"))
	if len(routing.actions) != 1 || !routing.actions[0].userInput {
		t.Fatalf("input after the grace routed as %#v", routing.actions)
	}
}

func TestClientWithoutDeliveryReportsExpiresAtTheUsualTime(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponsesUntilDelivered("@1", 1, 10)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()

	routing := client.routeInput([]byte("x"))
	if len(routing.actions) != 1 || !routing.actions[0].userInput {
		t.Fatalf("input after the grace routed as %#v", routing.actions)
	}
}

// The writer records each query at the output offset just past it, counting
// everything written to the client before it.
func TestAttachWriterRecordsWhereEachQueryEnds(t *testing.T) {
	server, peer := net.Pipe()
	defer peer.Close()
	client := newAttachClient(server, controlMessage{AttachToken: "token"})
	defer client.close()
	received := make(chan []byte, 1)
	go func() {
		data, _ := io.ReadAll(peer)
		received <- data
	}()

	if _, ok := client.enqueueWrite([]byte("frame"), false, "", 0, nil); !ok {
		t.Fatal("frame not queued")
	}
	completion, ok := client.enqueueWrite([]byte("\x1b[c"), true, "@1", 1, nil)
	if !ok || !client.waitForWrite(completion) {
		t.Fatal("query not written")
	}
	client.activityMu.Lock()
	ends := append([]uint64(nil), client.undeliveredQueryEnds...)
	client.activityMu.Unlock()
	if len(ends) != 1 || ends[0] != uint64(len("frame\x1b[c")) {
		t.Fatalf("query ends = %v, want [%d]", ends, len("frame\x1b[c"))
	}

	mux := &muxServer{attachClients: map[net.Conn]*attachClient{server: client}}
	mux.handleControlRequest(nil, controlMessage{
		Type:        attachDeliveredRequest,
		AttachToken: "token",
		Delivered:   ends[0],
	})
	client.activityMu.Lock()
	left := len(client.undeliveredQueryEnds)
	client.activityMu.Unlock()
	if left != 0 {
		t.Fatalf("%d queries still undelivered after the report", left)
	}
	client.close()
	<-received
}
