package main

import (
	"bufio"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

type shutdownAuditPty struct {
	muxPty
	write func([]byte) (int, error)
}

func (p shutdownAuditPty) Write(data []byte) (int, error) { return p.write(data) }

func TestWriteWindowInputConcurrentClose(t *testing.T) {
	window := &muxWindow{id: "@1", pty: shutdownAuditPty{write: func(data []byte) (int, error) {
		return len(data), nil
	}}}
	server := &muxServer{windows: []*muxWindow{window}}
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		for i := 0; i < 10000; i++ {
			server.mu.Lock()
			window.closed = i%2 == 0
			server.mu.Unlock()
		}
	}()
	for i := 0; i < 10000; i++ {
		_ = server.writeWindowInput(window.id, []byte("x"), false)
	}
	workers.Wait()

	server.mu.Lock()
	window.closed = true
	server.mu.Unlock()
	if err := server.writeWindow(window.id, []byte("x")); err == nil {
		t.Error("closed window accepted input")
	}
	if err := server.writeWindow("@missing", []byte("x")); err == nil {
		t.Error("missing window accepted input")
	}
}

func TestWriteWindowInputDoesNotHoldServerLockDuringWrite(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	defer close(release)
	window := &muxWindow{id: "@1", pty: shutdownAuditPty{write: func([]byte) (int, error) {
		close(entered)
		<-release
		return 0, io.ErrClosedPipe
	}}}
	server := &muxServer{windows: []*muxWindow{window}}
	writeDone := make(chan error, 1)
	go func() { writeDone <- server.writeWindow(window.id, []byte("x")) }()
	<-entered
	locked := make(chan struct{})
	go func() {
		server.mu.Lock()
		window.closed = true
		server.mu.Unlock()
		close(locked)
	}()
	select {
	case <-locked:
	case <-time.After(time.Second):
		t.Fatal("blocked PTY write prevented window shutdown from taking the server lock")
	}
	// Release the write without closing release twice in the deferred cleanup.
	release <- struct{}{}
	if err := <-writeDone; !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("write error = %v, want closed pipe", err)
	}
}

func TestAcpAttachAfterStopDoesNotRegisterClient(t *testing.T) {
	bridge := newTestAcpBridge()
	server, peer := net.Pipe()
	defer peer.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		bridge.handleConnection(server)
	}()
	// Model a socket accepted before stop whose hello arrives afterward.
	bridge.stop()
	_ = peer.SetDeadline(time.Now().Add(time.Second))
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: acpBridgeProtocolVersion, Type: "hello"}); err != nil {
		t.Fatal(err)
	}
	message, err := readAcpWireFrame(bufio.NewReader(peer))
	if !errors.Is(err, io.EOF) {
		t.Errorf("stopped bridge attach = %+v, %v; want EOF", message, err)
	}
	if count := bridge.snapshot().ClientCount; count != 0 {
		t.Errorf("stopped bridge registered %d clients", count)
	}
	_ = peer.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Error("late attach handler did not exit")
	}
}
