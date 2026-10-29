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

func startAttachRelay(t *testing.T, dst io.Writer, src io.Reader, limit int) <-chan error {
	t.Helper()
	result := make(chan error, 1)
	go func() { result <- relayAttachOutput(dst, src, limit, attachOutputQueryWait) }()
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

// A terminal that stops accepting output for longer than the server's write
// timeout must not get the attach dropped: the server's writes keep landing
// while the relay holds them, and the terminal receives all of it, in order,
// once it drains again.
func TestRelayAttachOutputKeepsSocketDrainingWhileTerminalStalls(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &stalledWriter{release: make(chan struct{})}
	result := startAttachRelay(t, terminal, client, attachOutputBufferLimitBytes)

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

// Past its limit the relay stops reading, so a terminal that never drains
// still reaches the server's write timeout instead of growing the client.
func TestRelayAttachOutputStopsReadingAtItsLimit(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &stalledWriter{release: make(chan struct{})}
	const limit = 64 * 1024
	result := startAttachRelay(t, terminal, client, limit)

	err := writeAttachConnection(server, attachRelayTestOutput(4*limit))
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
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

// A query the terminal has not seen for queryWait would be answered after the
// server stopped waiting for it, and the server would type the reply into the
// pane. The relay stops reading ahead instead, so the server's write timeout
// ends the attach as it did before the relay.
func TestRelayAttachOutputStopsReadingAheadOfAnOverdueQuery(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	terminal := &stalledWriter{release: make(chan struct{})}
	const queryWait = 100 * time.Millisecond
	result := make(chan error, 1)
	go func() {
		result <- relayAttachOutput(
			terminal,
			client,
			attachOutputBufferLimitBytes,
			queryWait,
		)
	}()

	if err := writeAttachConnection(server, []byte("frame\x1b[c")); err != nil {
		t.Fatalf("server write of the query: %v", err)
	}
	time.Sleep(queryWait + 50*time.Millisecond)
	err := writeAttachConnection(server, attachRelayTestOutput(256*1024))
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("server write behind an overdue query = %v, want a timeout", err)
	}
	close(terminal.release)
	_ = server.Close()
	if err := awaitAttachRelay(t, result); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if got := terminal.bytes(); !bytes.HasPrefix(got, []byte("frame\x1b[c")) {
		t.Fatalf("terminal got %q first, want the query frame", got[:min(len(got), 16)])
	}
}

func TestAttachQueryScannerFindsQueriesSplitAcrossReads(t *testing.T) {
	for _, test := range []struct {
		name   string
		pieces []string
		want   []bool
	}{
		{"plain output", []string{"agent output", "\x1b[1mbold\x1b[0m"}, []bool{false, false}},
		{"whole query", []string{"\x1b[c"}, []bool{true}},
		{"CSI split", []string{"text\x1b[", "6n"}, []bool{false, true}},
		{"OSC split", []string{"\x1b]11;", "?\x1b\\"}, []bool{false, true}},
		{"title is not a query", []string{"\x1b]0;ti", "tle\x07"}, []bool{false, false}},
		{"trailing ESC", []string{"text\x1b", "[c"}, []bool{false, true}},
	} {
		t.Run(test.name, func(t *testing.T) {
			var scanner attachQueryScanner
			for i, piece := range test.pieces {
				if got := scanner.scan([]byte(piece)); got != test.want[i] {
					t.Fatalf("piece %d %q: query = %v, want %v", i, piece, got, test.want[i])
				}
			}
		})
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
	result := startAttachRelay(t, sink, client, attachOutputBufferLimitBytes)

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
		attachOutputQueryWait,
	)
	if !errors.Is(err, readErr) {
		t.Fatalf("relay = %v, want the read error", err)
	}
	if terminal.String() != "last frame" {
		t.Fatalf("terminal got %q before the read error", terminal.String())
	}
}
