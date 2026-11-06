//go:build !windows

package main

import (
	"os/exec"
	"testing"
	"time"

	"github.com/creack/pty"
)

func assertPtyPixelSize(
	t *testing.T,
	p muxPty,
	columns int,
	rows int,
	widthPx int,
	heightPx int,
) {
	t.Helper()
	size, err := pty.GetsizeFull(ptyFile(t, p))
	if err != nil {
		t.Fatal(err)
	}
	if int(size.Cols) != columns || int(size.Rows) != rows ||
		int(size.X) != widthPx || int(size.Y) != heightPx {
		t.Fatalf(
			"pty size = %dx%d cells, %dx%d px; want %dx%d cells, %dx%d px",
			size.Cols, size.Rows, size.X, size.Y,
			columns, rows, widthPx, heightPx,
		)
	}
}

func assertPtyPixelSizeEventually(
	t *testing.T,
	p muxPty,
	columns int,
	rows int,
	widthPx int,
	heightPx int,
) {
	t.Helper()
	file := ptyFile(t, p)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		size, err := pty.GetsizeFull(file)
		if err == nil && int(size.Cols) == columns && int(size.Rows) == rows &&
			int(size.X) == widthPx && int(size.Y) == heightPx {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	assertPtyPixelSize(t, p, columns, rows, widthPx, heightPx)
}

func registerTestAttachClientWithCellSize(
	t *testing.T,
	server *muxServer,
	clientID string,
	width int,
	height int,
	cellWidth int,
	cellHeight int,
) *attachClient {
	t.Helper()
	client := registerTestAttachClient(t, server, &recordingConn{}, clientID, width, height)
	server.mu.Lock()
	client.cellWidth, client.cellHeight = cellWidth, cellHeight
	server.mu.Unlock()
	return client
}

func newCellSizeTestServer(t *testing.T) (*muxServer, *muxWindow, muxPty) {
	t.Helper()
	server := newMuxServerWithSize("test", 80, 24)
	windowPty := openTestPty(t)
	setPtySize(t, windowPty, 80, 24)
	window := &muxWindow{
		id:           "@1",
		pty:          windowPty,
		ptyWidth:     80,
		ptyHeight:    24,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	return server, window, windowPty
}

func TestPtyWinsizeOmitsPixelsThatDoNotFit(t *testing.T) {
	size := ptyWinsize(80, 24, 800, 480)
	if size.Cols != 80 || size.Rows != 24 || size.X != 800 || size.Y != 480 {
		t.Fatalf("winsize = %+v, want 80x24 at 800x480", size)
	}
	size = ptyWinsize(500, 300, 500*200, 300*20)
	if size.Cols != 500 || size.Rows != 300 || size.X != 0 || size.Y != 0 {
		t.Fatalf("winsize = %+v, want 500x300 with no pixel size", size)
	}
}

func TestCellPixelSizeOfDividesPixelsByGrid(t *testing.T) {
	for _, test := range []struct {
		name          string
		size          *pty.Winsize
		width, height int
	}{
		{"grid", &pty.Winsize{Cols: 100, Rows: 40, X: 1005, Y: 815}, 10, 20},
		{"no pixels", &pty.Winsize{Cols: 100, Rows: 40}, 0, 0},
		{"no grid", &pty.Winsize{X: 1000, Y: 800}, 0, 0},
		{"too large", &pty.Winsize{Cols: 1, Rows: 1, X: 4000, Y: 20}, 0, 0},
		{"nil", nil, 0, 0},
	} {
		width, height := cellPixelSizeOf(test.size)
		if width != test.width || height != test.height {
			t.Errorf("%s: cell = %dx%d, want %dx%d", test.name, width, height, test.width, test.height)
		}
	}
}

func TestResizeReportsPrimaryClientCellPixelSize(t *testing.T) {
	server, _, windowPty := newCellSizeTestServer(t)
	registerTestAttachClientWithCellSize(t, server, "app", 80, 24, 10, 20)

	server.resizeForClient("app", 100, 30, false)

	assertPtyPixelSize(t, windowPty, 100, 30, 1000, 600)
}

func TestResizeRequestRecordsCellPixelSize(t *testing.T) {
	server, _, windowPty := newCellSizeTestServer(t)
	registerTestAttachClient(t, server, &recordingConn{}, "cli", 80, 24)

	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:       "resize",
		ClientID:   "cli",
		Width:      90,
		Height:     30,
		CellWidth:  9,
		CellHeight: 18,
	})

	assertPtyPixelSize(t, windowPty, 90, 30, 810, 540)
}

func TestCellSizeRequestReportsPixelsAtCurrentGrid(t *testing.T) {
	server, _, windowPty := newCellSizeTestServer(t)
	registerTestAttachClient(t, server, &recordingConn{}, "app", 80, 24)

	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:       "cell_size",
		ClientID:   "app",
		CellWidth:  9,
		CellHeight: 18,
	})

	assertPtyPixelSize(t, windowPty, 80, 24, 720, 432)
}

func TestCellSizeRequestRejectsInvalidSize(t *testing.T) {
	server, _, windowPty := newCellSizeTestServer(t)
	registerTestAttachClient(t, server, &recordingConn{}, "app", 80, 24)

	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:       "cell_size",
		ClientID:   "app",
		CellWidth:  maxCellPixelSize + 1,
		CellHeight: 18,
	})

	assertPtyPixelSize(t, windowPty, 80, 24, 0, 0)
}

func TestBackgroundClientCellPixelSizeAppliesWhenFocused(t *testing.T) {
	server, _, windowPty := newCellSizeTestServer(t)
	registerTestAttachClientWithCellSize(t, server, "tablet", 80, 24, 12, 24)
	registerTestAttachClientWithCellSize(t, server, "phone", 80, 24, 10, 20)
	server.resizeForClient("phone", 80, 24, false)
	assertPtyPixelSize(t, windowPty, 80, 24, 800, 480)

	server.updateAttachClientCellSize("tablet", 11, 22)
	assertPtyPixelSize(t, windowPty, 80, 24, 800, 480)

	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:     "focus_client",
		ClientID: "tablet",
		Width:    80,
		Height:   24,
	})

	assertPtyPixelSize(t, windowPty, 80, 24, 880, 528)
}

func TestCellPixelSizeOutlivesPrimaryClient(t *testing.T) {
	server, _, windowPty := newCellSizeTestServer(t)
	client := registerTestAttachClientWithCellSize(t, server, "app", 80, 24, 10, 20)
	server.resizeForClient("app", 80, 24, false)

	server.removeAttachClient(client)
	server.resizeWithRedraw(100, 30, false, false, "")

	assertPtyPixelSize(t, windowPty, 100, 30, 1000, 600)
}

func TestBackgroundWindowReportsCellPixelSizeAtNextResize(t *testing.T) {
	server, _, _ := newCellSizeTestServer(t)
	backgroundPty := openTestPty(t)
	setPtySize(t, backgroundPty, 80, 24)
	background := &muxWindow{
		id:           "@2",
		index:        1,
		pty:          backgroundPty,
		ptyWidth:     80,
		ptyHeight:    24,
		lastActivity: time.Now(),
	}
	server.windows = append(server.windows, background)
	registerTestAttachClientWithCellSize(t, server, "app", 80, 24, 10, 20)
	server.resizeForClient("app", 80, 24, false)
	assertPtyPixelSize(t, backgroundPty, 80, 24, 0, 0)

	server.mu.Lock()
	server.activeID = background.id
	server.resizeActiveLocked(80, 24)
	server.mu.Unlock()

	assertPtyPixelSize(t, backgroundPty, 80, 24, 800, 480)
}

func TestForegroundRedrawKeepsCellPixelSize(t *testing.T) {
	server, window, windowPty := newCellSizeTestServer(t)
	registerTestAttachClientWithCellSize(t, server, "app", 80, 24, 10, 20)
	server.resizeForClient("app", 80, 24, false)

	simulateForegroundResize(window, 80, 24)
	// A cell size arriving mid-dance must not cancel the restore.
	server.updateAttachClientCellSize("app", 9, 18)

	assertPtyPixelSizeEventually(t, windowPty, 80, 24, 720, 432)
}

func TestStartWindowSizedReportsPixelSize(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "exec sleep 120")
	windowPty, _, err := startWindowSized(cmd, 80, 24, 800, 480)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-done
		_ = windowPty.Close()
	})

	assertPtyPixelSize(t, windowPty, 80, 24, 800, 480)
}

func TestServerStartsWindowWithCellPixelSize(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	server.mu.Lock()
	server.cellWidthPx, server.cellHeightPx = 10, 20
	server.mu.Unlock()
	cmd := exec.Command("/bin/sh", "-c", "exec sleep 120")
	windowPty, _, err := server.startWindowWithCellSize(cmd, 90, 30)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-done
		_ = windowPty.Close()
	})

	assertPtyPixelSize(t, windowPty, 90, 30, 900, 600)
}

type flushCountingWriter struct {
	writes  int
	flushes int
}

func (w *flushCountingWriter) Write(data []byte) (int, error) {
	w.writes++
	return len(data), nil
}

func (w *flushCountingWriter) Flush() error {
	w.flushes++
	return nil
}

func TestNotifyFirstWriteClosesOnFirstOutputAndKeepsFlush(t *testing.T) {
	inner := &flushCountingWriter{}
	first := make(chan struct{})
	writer := notifyFirstWrite(inner, first)

	_, _ = writer.Write(nil)
	select {
	case <-first:
		t.Fatal("empty write reported output")
	default:
	}
	_, _ = writer.Write([]byte("\x1b]7502;window=1:@1\x07"))
	_, _ = writer.Write([]byte("more"))
	select {
	case <-first:
	default:
		t.Fatal("first output was not reported")
	}
	flusher, ok := writer.(interface{ Flush() error })
	if !ok {
		t.Fatal("wrapped writer lost Flush")
	}
	_ = flusher.Flush()
	if inner.writes != 3 || inner.flushes != 1 {
		t.Fatalf("inner writes = %d, flushes = %d; want 3 and 1", inner.writes, inner.flushes)
	}
}
