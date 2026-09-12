//go:build !windows

package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestServerShutdownSurvivesPendingWindowList(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	clientFile := os.NewFile(uintptr(fds[0]), "shutdown-client")
	serverFile := os.NewFile(uintptr(fds[1]), "shutdown-server")
	defer clientFile.Close()
	defer serverFile.Close()
	// Force the greeting to remain in flight after hello is read, as can also
	// happen with a slow metadata refresh between hello and window_list.
	if err := unix.SetsockoptInt(fds[1], unix.SOL_SOCKET, unix.SO_SNDBUF, 1024); err != nil {
		t.Fatal(err)
	}
	clientConn, err := net.FileConn(clientFile)
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()
	serverConn, err := net.FileConn(serverFile)
	if err != nil {
		t.Fatal(err)
	}
	defer serverConn.Close()
	// FileConn duplicates the descriptors; retaining the originals would keep
	// the peer alive after requestServerShutdown's deferred Close.
	_ = clientFile.Close()
	_ = serverFile.Close()

	server := newMuxServer("upgrade")
	defer server.close()
	for i := 0; i < 3; i++ {
		server.windows = append(server.windows, &muxWindow{
			id: fmt.Sprintf("@%d", i+1), name: strings.Repeat("x", 32*1024),
		})
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleConnection(serverConn)
	}()
	if err := sendServerShutdown(clientConn, "upgrade"); err != nil {
		t.Fatal(err)
	}
	_ = clientConn.Close()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown control connection did not finish")
	}
	// handleControlRequest schedules close asynchronously. An unprocessed
	// shutdown leaves this false forever even though the control client exited.
	deadline := time.Now().Add(time.Second)
	for !server.isClosed() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !server.isClosed() {
		t.Fatal("shutdown was lost while sending window_list; old server is still alive")
	}
}
