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
	go func() { result <- relayAttachOutput(dst, src, limit) }()
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
	)
	if !errors.Is(err, readErr) {
		t.Fatalf("relay = %v, want the read error", err)
	}
	if terminal.String() != "last frame" {
		t.Fatalf("terminal got %q before the read error", terminal.String())
	}
}
