package main

import (
	"errors"
	"io"
	"net"
	"os/exec"
	"sync"
	"testing"
	"time"
)

// Gates hold the actual startup/cleanup operation, not a scheduling delay.
// Cleanup opens every gate even when an assertion fails.
type windowStartGate struct {
	entered  chan struct{}
	release  chan struct{}
	returned chan struct{}
	once     sync.Once
}

func newWindowStartGate(t *testing.T) *windowStartGate {
	t.Helper()
	g := &windowStartGate{entered: make(chan struct{}), release: make(chan struct{}), returned: make(chan struct{})}
	t.Cleanup(g.open)
	return g
}

func (g *windowStartGate) open() { g.once.Do(func() { close(g.release) }) }
func (g *windowStartGate) pass() {
	close(g.entered)
	<-g.release
	close(g.returned)
}

func awaitWindowStart(t *testing.T, description string, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func assertWindowStartPending(t *testing.T, description string, callers ...<-chan struct{}) {
	t.Helper()
	// Give incorrectly unblocked callers time to return. The operation itself
	// remains held by its gate throughout this observation interval.
	<-time.After(25 * time.Millisecond)
	for i, done := range callers {
		select {
		case <-done:
			t.Errorf("%s: close caller/barrier %d returned before ownership was released", description, i)
		default:
		}
	}
}

type windowStartListener struct {
	net.Listener
	closed chan struct{}
}

func (l windowStartListener) Close() error { close(l.closed); return nil }

func closeWindowStartServer(s *muxServer) <-chan struct{} {
	done := make(chan struct{})
	go func() { s.close(); close(done) }()
	return done
}

type windowStartProcess struct {
	muxProcess
	kill, wait *windowStartGate
	hungup     chan struct{}
}

func (p windowStartProcess) Pid() int    { return 0 }
func (p windowStartProcess) Kill()       { p.kill.pass() }
func (p windowStartProcess) Wait() error { p.wait.pass(); return nil }
func (p windowStartProcess) Hangup()     { close(p.hungup) }

type windowStartPty struct {
	muxPty
	close, read *windowStartGate
}

func (p windowStartPty) Close() error             { p.close.pass(); return nil }
func (p windowStartPty) Read([]byte) (int, error) { p.read.pass(); return 0, io.EOF }
func (p windowStartPty) Fd() uintptr              { return ^uintptr(0) }

func TestPendingWindowStartShutdownOwnership(t *testing.T) {
	for _, failStart := range []bool{false, true} {
		name := "rejected-cleanup"
		if failStart {
			name = "failed-start"
		}
		t.Run(name, func(t *testing.T) {
			server := newMuxServer(name)
			listener := windowStartListener{closed: make(chan struct{})}
			server.listener = listener
			created := make(chan struct{})
			var window *muxWindow
			var createErr error
			var callers []<-chan struct{}
			t.Cleanup(func() {
				awaitWindowStart(t, "create return", created)
				for _, done := range callers {
					awaitWindowStart(t, "close return", done)
				}
			})
			start := newWindowStartGate(t)
			kill := newWindowStartGate(t)
			ptyClose := newWindowStartGate(t)
			wait := newWindowStartGate(t)
			startErr := errors.New("injected start failure")
			go func() {
				defer close(created)
				window, createErr = server.createWindowWithStarter(createWindowOptions{}, func(*exec.Cmd, int, int) (muxPty, muxProcess, error) {
					start.pass()
					if failStart {
						return nil, nil, startErr
					}
					return windowStartPty{close: ptyClose}, windowStartProcess{kill: kill, wait: wait}, nil
				})
			}()
			awaitWindowStart(t, "startup entry", start.entered)
			callers = append(callers, closeWindowStartServer(server))
			awaitWindowStart(t, "shutdown admission closed", listener.closed)
			for i := 0; i < 3; i++ {
				callers = append(callers, closeWindowStartServer(server))
			}
			server.mu.Lock()
			callers = append(callers, server.closeDone)
			server.mu.Unlock()
			assertWindowStartPending(t, "startup in flight", callers...)

			start.open()
			awaitWindowStart(t, "asynchronous rejection", created)
			wantErr := errServerClosed
			if failStart {
				wantErr = startErr
			}
			if window != nil || !errors.Is(createErr, wantErr) {
				t.Errorf("createWindow = (%v, %v), want (nil, %v)", window, createErr, wantErr)
			}
			if !failStart {
				for _, stage := range []struct {
					name string
					gate *windowStartGate
				}{
					{"Kill", kill}, {"Close", ptyClose}, {"Wait", wait},
				} {
					awaitWindowStart(t, stage.name+" entry", stage.gate.entered)
					assertWindowStartPending(t, "cleanup blocked on "+stage.name, callers...)
					stage.gate.open()
				}
				awaitWindowStart(t, "reap return", wait.returned)
			}
			for _, done := range callers {
				awaitWindowStart(t, "shutdown completion", done)
			}
			server.mu.Lock()
			defer server.mu.Unlock()
			if len(server.windows) != 0 || server.nextID != 0 {
				t.Error("unpublished start changed the window registry")
			}
		})
	}
}

func TestPendingWindowStartAlreadyClosedNeverLaunches(t *testing.T) {
	server := newMuxServer("closed")
	server.close()
	launched := false
	window, err := server.createWindowWithStarter(createWindowOptions{}, func(*exec.Cmd, int, int) (muxPty, muxProcess, error) {
		launched = true
		return nil, nil, errors.New("must not launch")
	})
	if launched || window != nil || !errors.Is(err, errServerClosed) {
		t.Fatalf("closed createWindow = (%v, %v), launched=%v", window, err, launched)
	}
	if len(server.windows) != 0 || server.nextID != 0 {
		t.Fatal("closed server changed the window registry")
	}
	watchersDone := make(chan struct{})
	go func() { server.windowWatchers.Wait(); close(watchersDone) }()
	awaitWindowStart(t, "watcher balance", watchersDone)
}

func TestPendingWindowStartWatcherHandoff(t *testing.T) {
	server := newMuxServer("handoff")
	var callers []<-chan struct{}
	t.Cleanup(func() {
		for _, done := range callers {
			awaitWindowStart(t, "shutdown completion", done)
		}
	})
	read := newWindowStartGate(t)
	wait := newWindowStartGate(t)
	ptyClose := newWindowStartGate(t)
	hungup := make(chan struct{})
	window, err := server.createWindowWithStarter(createWindowOptions{}, func(*exec.Cmd, int, int) (muxPty, muxProcess, error) {
		return windowStartPty{close: ptyClose, read: read}, windowStartProcess{wait: wait, hungup: hungup}, nil
	})
	if err != nil || window == nil {
		t.Fatalf("createWindow = (%v, %v)", window, err)
	}
	awaitWindowStart(t, "reader entry", read.entered)
	awaitWindowStart(t, "watcher entry", wait.entered)
	callers = append(callers, closeWindowStartServer(server))
	awaitWindowStart(t, "normal hangup", hungup)
	awaitWindowStart(t, "normal PTY close", ptyClose.entered)
	callers = append(callers, closeWindowStartServer(server))
	ptyClose.open()
	assertWindowStartPending(t, "registered watchers", callers...)
	read.open()
	awaitWindowStart(t, "reader return", read.returned)
	assertWindowStartPending(t, "process watcher", callers...)
	wait.open()
	for _, done := range callers {
		awaitWindowStart(t, "shutdown completion", done)
	}
	// An unbalanced watcher group must not hide behind the bounded wait.
	watchersDone := make(chan struct{})
	go func() { server.windowWatchers.Wait(); close(watchersDone) }()
	awaitWindowStart(t, "watcher balance", watchersDone)
}
