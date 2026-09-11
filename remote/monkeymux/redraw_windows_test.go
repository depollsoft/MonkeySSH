//go:build windows

package main

import (
	"bytes"
	"io"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type recordedTerminalSize struct {
	width  int
	height int
}

type resizeRecordingPty struct {
	mu    sync.Mutex
	sizes []recordedTerminalSize
}

func (p *resizeRecordingPty) Read([]byte) (int, error) { return 0, io.EOF }

func (p *resizeRecordingPty) Write(data []byte) (int, error) {
	return len(data), nil
}

func (p *resizeRecordingPty) Close() error { return nil }

func (p *resizeRecordingPty) Resize(width int, height int) error {
	p.mu.Lock()
	p.sizes = append(
		p.sizes,
		recordedTerminalSize{width: width, height: height},
	)
	p.mu.Unlock()
	return nil
}

func (p *resizeRecordingPty) Fd() uintptr { return 0 }

func (p *resizeRecordingPty) snapshot() []recordedTerminalSize {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]recordedTerminalSize(nil), p.sizes...)
}

func TestForegroundRedrawTemporarySizePrefersHeightOnWindows(t *testing.T) {
	width, height, ok := foregroundRedrawTemporarySize(120, 40)

	if width != 120 || height != 39 || !ok {
		t.Fatalf(
			"temporary Windows redraw size = %dx%d, %t; want 120x39, true",
			width,
			height,
			ok,
		)
	}
}

func TestSingleCellRedrawUsesTemporaryWindowsExpansion(t *testing.T) {
	server := newMuxServerWithSize("test", 1, 1)
	pty := &resizeRecordingPty{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		pty:               pty,
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	registerTestAttachClient(t, server, &recordingConn{}, "primary", server.width, server.height)

	server.resizeWithRedraw(1, 1, true, false, "")

	deadline := time.Now().Add(time.Second)
	for len(pty.snapshot()) < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	want := []recordedTerminalSize{
		{width: 1, height: 1},
		{width: 2, height: 1},
		{width: 1, height: 1},
	}
	if got := pty.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("single-cell redraw sizes = %#v, want %#v", got, want)
	}
}

func TestSelectWindowDeliversTargetGeometryWithoutIntermediateSize(t *testing.T) {
	// Manufacturing a temporary size on top of a real geometry change makes the
	// foreground app lay out and emit an entire frame for a geometry that never
	// existed. The client paints that frame before the real one replaces it,
	// which is the "wrong size, then it resizes" flash, and on a long agent
	// transcript it doubles the bytes crossing the wire.
	server := newMuxServerWithSize("test", 80, 24)
	pty := &resizeRecordingPty{}
	target := &muxWindow{
		id:                "@2",
		index:             1,
		foregroundCommand: "codex",
		pty:               pty,
		ptyWidth:          59,
		ptyHeight:         47,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		target,
	}
	server.activeID = "@1"
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

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	time.Sleep(4 * foregroundRedrawResizeDelay)
	want := []recordedTerminalSize{{width: 80, height: 24}}
	if got := pty.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("switch resizes = %#v, want %#v", got, want)
	}
}

func TestForegroundRedrawKeepsSyntheticSizeWhenGeometryIsUnchanged(t *testing.T) {
	// With no real size change to deliver there is nothing for the app to
	// notice, so the temporary size is the only way to ask for a repaint.
	pty := &resizeRecordingPty{}
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "codex",
		pty:               pty,
		ptyWidth:          80,
		ptyHeight:         24,
	}

	deliverForegroundGeometry(window, 80, 24)

	deadline := time.Now().Add(time.Second)
	for len(pty.snapshot()) < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	want := []recordedTerminalSize{
		{width: 80, height: 23},
		{width: 80, height: 24},
	}
	if got := pty.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("same-size redraw sizes = %#v, want %#v", got, want)
	}
}

func TestRedrawWindowsFallback(t *testing.T) {
	for _, test := range []struct {
		name          string
		width, height int
		deferred      bool
		want          []string
	}{
		{"same size", 120, 40, false, []string{"@1"}},
		{"deferred same size", 120, 40, true, []string{"@1"}},
		{"changed size", 100, 30, false, nil},
		{"deferred changed size", 100, 30, true, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := newMuxServerWithSize("test", 120, 40)
			window := &muxWindow{id: "@1", foregroundCommand: "codex", terminalOutputForwarding: test.deferred}
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			client := registerTestAttachClient(t, server, &recordingConn{}, "primary", 120, 40)
			client.clipViewport = test.deferred
			original := simulateForegroundResize
			t.Cleanup(func() { simulateForegroundResize = original })
			var simulated []string
			simulateForegroundResize = func(candidate *muxWindow, _, _ int) { simulated = append(simulated, candidate.id) }
			server.resizeWithRedraw(test.width, test.height, true, false, "")
			if test.deferred {
				if len(simulated) != 0 {
					t.Fatalf("deferred redraw ran before forwarding settled: %#v", simulated)
				}
				server.mu.Lock()
				window.terminalOutputForwarding = false
				server.mu.Unlock()
				server.refreshPendingViewportResize()
			}
			if !reflect.DeepEqual(simulated, test.want) {
				t.Fatalf("redraw fallback = %#v, want %#v", simulated, test.want)
			}
		})
	}
}

func TestConPtyNormalScreenReturnsWithoutSyntheticResize(t *testing.T) {
	for _, command := range []string{"codex", "copilot", "powershell"} {
		t.Run(command, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			pty := &resizeRecordingPty{}
			window := &muxWindow{id: "@2", index: 1, foregroundCommand: command,
				win32InputMode: true, pty: pty, ptyWidth: 80, ptyHeight: 24}
			server.windows = []*muxWindow{{id: "@1", index: 0, win32InputMode: true}, window}
			server.activeID = "@1"
			window.appendHistoryLocked([]byte("COMPOSER_SAVED\r\n" + strings.Repeat("transcript\r\n", 20000) + "\x1b]11;?\x07"))
			conn := &recordingConn{}
			client := registerTestAttachClient(t, server, conn, "primary", 80, 24)
			for i := 0; i < 2; i++ {
				if err := server.selectWindow(window.id); err != nil {
					t.Fatal(err)
				}
				if err := server.selectWindow("@1"); err != nil {
					t.Fatal(err)
				}
			}
			if err := server.selectWindow(window.id); err != nil {
				t.Fatal(err)
			}
			if !server.replayFocusedWindowToClient(client, 80, 24) {
				t.Fatal("focus replay failed")
			}
			waitForTestAttachWrites(t, server)
			if sizes := pty.snapshot(); len(sizes) != 0 {
				t.Fatalf("return resized PTY: %#v", sizes)
			}
			if window.redrawForwardingPaused {
				t.Fatal("return paused for a synthetic redraw")
			}
			replay := []byte(conn.String())
			if !bytes.Contains(replay, []byte("COMPOSER_SAVED")) || !bytes.Contains(replay, []byte("transcript")) {
				t.Fatal("return discarded retained screen content")
			}
			if bytes.Contains(replay, []byte("\x1b]11;?\x07")) {
				t.Fatal("return replayed a terminal query")
			}
			if !bytes.Contains(replay, []byte(terminalSynchronizedOutputBegin)) || !bytes.Contains(replay, []byte(terminalSynchronizedOutputEnd)) {
				t.Fatal("return was not an atomic screen replay")
			}
			server.width, server.height = 100, 30
			if err := server.selectWindow(window.id); err != nil {
				t.Fatal(err)
			}
			if sizes := pty.snapshot(); !reflect.DeepEqual(sizes, []recordedTerminalSize{{100, 30}}) {
				t.Fatalf("real geometry change = %#v", sizes)
			}
		})
	}
}

func TestConPtyAlternateScreenStillUsesForegroundRedraw(t *testing.T) {
	window := &muxWindow{win32InputMode: true, privateModes: map[string]bool{"1049": true}}
	if !window.usesForegroundRedrawReplayLocked() {
		t.Fatal("alternate screen lost its foreground redraw")
	}
}

func TestConPtyNormalScreenExplicitThemeRedraw(t *testing.T) {
	for _, command := range []string{"codex", "copilot", "powershell"} {
		t.Run(command, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@1", foregroundCommand: command, win32InputMode: true,
				pty: &resizeRecordingPty{}, ptyWidth: 80, ptyHeight: 24}
			window.appendHistoryLocked([]byte("saved frame"))
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			registerTestAttachClient(t, server, &recordingConn{}, "primary", 80, 24)
			original := simulateForegroundResize
			t.Cleanup(func() { simulateForegroundResize = original })
			redrew := false
			simulateForegroundResize = func(candidate *muxWindow, width, height int) {
				redrew = true
				if candidate != window || width != 80 || height != 24 || !window.redrawForwardingPaused {
					t.Fatal("explicit redraw lost its target, dimensions, or synchronized forwarding pause")
				}
				if !bytes.Contains(server.foregroundHistoryFallbackHistoryLocked(window), []byte("saved frame")) {
					t.Fatal("explicit redraw lost its fallback frame")
				}
			}
			server.forceForegroundThemeRedraw(window.id)
			if redrew != (command != "powershell") {
				t.Fatalf("theme redraw = %t for %s", redrew, command)
			}
		})
	}
}
