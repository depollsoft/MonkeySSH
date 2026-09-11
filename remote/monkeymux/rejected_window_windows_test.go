//go:build windows

package main

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestRejectedWindowCleanupDrainsConPtyAndClosesHandles(t *testing.T) {
	output, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	defer writer.Close()
	input, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	defer inputWriter.Close()
	// A signaled waitable handle exercises Wait/CloseHandle without needing
	// a child. The real-process case below covers TerminateProcess/ConPTY.
	handle, err := windows.CreateEvent(nil, 1, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	flushed := make(chan int, 1)
	windowPty := &winPty{
		readFile: output, writeFile: inputWriter,
		backend: &conPtyBackend{close: func(windows.Handle) {
			// More than a pipe buffer: close cannot complete without a reader.
			n, _ := writer.Write(bytes.Repeat([]byte("x"), 256*1024))
			_ = writer.Close()
			flushed <- n
		}},
	}
	proc := &winProcess{handle: handle, pty: windowPty}
	done := make(chan struct{})
	go func() {
		cleanupRejectedWindow(windowPty, proc)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		// Unblock the fake close, even if draining regresses.
		_ = output.Close()
		t.Fatal("cleanup blocked on ConPTY output")
	}
	if n := <-flushed; n != 256*1024 {
		t.Errorf("drained %d bytes, want complete final output", n)
	}
	assertRejectedWindowsHandlesClosed(t, proc)
}

func TestRejectedWindowCleanupStopsConPtyProcess(t *testing.T) {
	for _, command := range []string{"exit 0", "for /L %i in (1,0,2) do @echo rejected-output"} {
		t.Run(command, func(t *testing.T) {
			windowPty, process, err := startWindow(exec.Command("cmd.exe", "/c", command), 80, 24)
			if err != nil {
				t.Fatal(err)
			}
			proc := process.(*winProcess)
			// Retain a separate handle to verify process exit after cleanup
			// releases its own handle, without looking the PID up again.
			var observer windows.Handle
			current := windows.CurrentProcess()
			if err := windows.DuplicateHandle(current, proc.handle, current, &observer, 0, false, windows.DUPLICATE_SAME_ACCESS); err != nil {
				cleanupRejectedWindow(windowPty, proc)
				t.Fatal(err)
			}
			defer windows.CloseHandle(observer)
			done := make(chan struct{})
			go func() {
				cleanupRejectedWindow(windowPty, proc)
				close(done)
			}()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				_ = windows.TerminateProcess(observer, 1)
				_ = proc.pty.readFile.Close()
				t.Fatal("ConPTY cleanup did not finish")
			}
			if event, err := windows.WaitForSingleObject(observer, 0); err != nil || event != windows.WAIT_OBJECT_0 {
				t.Errorf("process survived cleanup: event=%v, err=%v", event, err)
			}
			assertRejectedWindowsHandlesClosed(t, proc)
		})
	}
}

func assertRejectedWindowsHandlesClosed(t *testing.T, proc *winProcess) {
	t.Helper()
	if _, err := windows.WaitForSingleObject(proc.handle, 0); !errors.Is(err, windows.ERROR_INVALID_HANDLE) {
		t.Errorf("process handle was not closed: %v", err)
	}
	for _, file := range []*os.File{proc.pty.readFile, proc.pty.writeFile} {
		if _, err := file.Stat(); !errors.Is(err, os.ErrClosed) && !errors.Is(err, windows.ERROR_INVALID_HANDLE) {
			t.Errorf("ConPTY pipe was not closed: %v", err)
		}
	}
	if !proc.pty.closed {
		t.Error("ConPTY was not closed")
	}
}
