//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
	"testing"
)

func TestRejectedWindowReapsStartedProcess(t *testing.T) {
	for _, command := range []string{"sleep 30", "exit 0"} {
		t.Run(command, func(t *testing.T) { testRejectedWindowReapsStartedProcess(t, command) })
	}
}

func testRejectedWindowReapsStartedProcess(t *testing.T, command string) {
	server := newMuxServer("rejected-process")
	listener := windowStartListener{closed: make(chan struct{})}
	server.listener = listener
	created := make(chan struct{})
	t.Cleanup(func() {
		awaitWindowStart(t, "create return", created)
		server.close()
	})
	started := newWindowStartGate(t)
	var cmd *exec.Cmd
	var windowPty muxPty
	var startErr, createErr error
	var window *muxWindow
	go func() {
		defer close(created)
		window, createErr = server.createWindowWithStarter(
			createWindowOptions{args: []string{"/bin/sh", "-c", command}},
			func(command *exec.Cmd, cols, rows int) (muxPty, muxProcess, error) {
				cmd = command
				var proc muxProcess
				windowPty, proc, startErr = startWindow(cmd, cols, rows)
				// Hold a real launch before registration, rather than creating
				// on an already-closed server, which must never launch now.
				started.pass()
				return windowPty, proc, startErr
			},
		)
	}()
	awaitWindowStart(t, "real process startup", started.entered)
	if startErr != nil {
		t.Fatal(startErr)
	}
	closed := closeWindowStartServer(server)
	awaitWindowStart(t, "shutdown admission closed", listener.closed)
	assertWindowStartPending(t, "real startup before registration", closed)
	started.open()
	awaitWindowStart(t, "request rejection", created)
	if !errors.Is(createErr, errServerClosed) || window != nil {
		t.Fatalf("createWindow = (%v, %v), want (nil, errServerClosed)", window, createErr)
	}
	awaitWindowStart(t, "shutdown and reap", closed)
	if !errors.Is(cmd.Process.Signal(syscall.Signal(0)), os.ErrProcessDone) {
		t.Error("shutdown returned before the rejected child was reaped")
	}
	if _, err := windowPty.(*unixPty).file.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Errorf("shutdown returned before PTY closure: %v", err)
	}
	if len(server.windows) != 0 {
		t.Fatal("rejected window was published")
	}
}
