package main

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// kittyRelativeDemoStream is the output of a program that places images
// directly and relative to each other, step by step, logging each step with
// DECSC/DECRC, and then waits for input without handling SIGWINCH: it
// places image 1 at row 4, column 2, hangs children off it, moves it to row
// 13, column 14, deletes it, and places it at row 4, column 2 again.
func kittyRelativeDemoStream() string {
	var out strings.Builder
	gfx := func(keys string) { fmt.Fprintf(&out, "\x1b_G%s\x1b\\", keys) }
	logRow := 30
	step := func(text string) {
		fmt.Fprintf(&out, "\x1b7\x1b[%d;1H\x1b[2K%s\x1b8", logRow, text)
		logRow++
	}
	out.WriteString("\x1b[?25l\x1b[2J\x1b[Hkitty relative placements (Enter: next)")
	for id := 1; id <= 4; id++ {
		gfx(fmt.Sprintf("a=t,i=%d,q=2,%s", id, kittyPixelRoot))
	}
	const size = "c=8,r=3"
	out.WriteString("\x1b[4;2H")
	gfx("a=p,i=1,p=1," + size + ",C=1,q=2")
	step("1 parent")
	gfx("a=p,i=2,p=1,P=1,Q=1,H=10,V=0," + size + ",C=1,q=2")
	gfx("a=p,i=3,p=1,P=1,Q=1,H=0,V=4," + size + ",C=1,q=2")
	gfx("a=p,i=4,p=1,P=3,Q=1,H=10,V=0," + size + ",C=1,q=2")
	step("2 children")
	out.WriteString("\x1b[13;14H")
	gfx("a=p,i=1,p=1," + size + ",C=1,q=2")
	step("3 parent moved")
	gfx("a=d,d=i,i=1,p=1,q=2")
	step("4 parent deleted")
	out.WriteString("\x1b[4;2H")
	gfx("a=p,i=1,p=1," + size + ",C=1,q=2")
	step("5 parent placed again")
	return out.String()
}

const kittyDemoPlacement = "\x1b[4;2H\x1b_Ga=p,i=1,p=1,c=8,r=3,C=1,q=2\x1b\\"

// selectWindowReplay switches an attached client from window @1 to window,
// which first printed stream while in the background, lets the foreground
// redraw pause end with redraw as all the program wrote, and returns what
// the client received.
func selectWindowReplay(t *testing.T, window *muxWindow, stream, redraw string) string {
	t.Helper()
	server := newMuxServerWithSize("test", 80, 40)
	attach := &recordingConn{}
	server.windows = []*muxWindow{{id: "@1", index: 0, lastActivity: time.Now()}, window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	originalSignal, originalSimulate := signalForegroundResize, simulateForegroundResize
	t.Cleanup(func() {
		signalForegroundResize, simulateForegroundResize = originalSignal, originalSimulate
	})
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.mu.Lock()
	window.recordScreenGeometryLocked(80, 40)
	window.screenWidth, window.screenHeight = 80, 40
	server.mu.Unlock()
	server.handleWindowOutput(window.id, []byte(stream))
	if err := server.selectWindow(window.id); err != nil {
		t.Fatal(err)
	}
	if redraw != "" {
		server.handleWindowOutput(window.id, []byte(redraw))
	}
	server.mu.Lock()
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding(window.id, generation)
	waitForTestAttachWrites(t, server)
	return attach.String()
}

// TestForegroundReplayPlacesDirectKittyImagesAgain covers a program that
// placed an image at a cell and never redraws: the frame painted from the
// screen model places it again on that cell, after its image and the rows,
// and before the cursor and modes are restored.
func TestForegroundReplayPlacesDirectKittyImagesAgain(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot", lastActivity: time.Now()}
	got := selectWindowReplay(t, window, kittyRelativeDemoStream(), "")

	frame := strings.Index(got, "\x1b[?6l\x1b[r\x1b[0m\x1b[4l\x1b[3g")
	image := strings.Index(got, "\x1b_Ga=t,i=1,")
	clear := strings.Index(got, kittyPlacementClear)
	rows := strings.Index(got, "5 parent placed again")
	placed := strings.Index(got, kittyDemoPlacement)
	saved := strings.LastIndex(got, "\x1b7")
	switch {
	case frame < 0 || image < 0 || clear < 0 || rows < 0 || placed < 0 || saved < 0:
		t.Fatalf("replay is missing a part (frame %d, image %d, clear %d, rows %d, placement %d, saved cursor %d): %q",
			frame, image, clear, rows, placed, saved, got)
	case !(image < clear && clear < frame && frame < rows && rows < placed && placed < saved):
		t.Fatalf("replay parts out of order (image %d, clear %d, frame %d, rows %d, placement %d, saved cursor %d): %q",
			image, clear, frame, rows, placed, saved, got)
	}
	if n := strings.Count(got, "a=p,i=1,"); n != 1 {
		t.Fatalf("image 1 placed %d times: %q", n, got)
	}
	// The children went with the parent the program deleted.
	for _, child := range []string{"a=p,i=2", "a=p,i=3", "a=p,i=4"} {
		if strings.Contains(got, child) {
			t.Fatalf("replay placed a deleted child (%s): %q", child, got)
		}
	}
	// The frame leaves the cursor where the program left it.
	if tail := got[saved:]; !strings.Contains(tail, "\x1b[4;2H") {
		t.Fatalf("frame does not restore the cursor to 4;2: %q", tail)
	}
}

// TestForegroundReplayLeavesARedrawnScreenToTheProgram covers a program that
// repaints after the resize nudge: the replay paints no frame of the screen
// it shows, so the program's own output places its images.
func TestForegroundReplayLeavesARedrawnScreenToTheProgram(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot", lastActivity: time.Now()}
	redraw := "\x1b[H\x1b[2Jredrawn" + kittyDemoPlacement
	got := selectWindowReplay(t, window, kittyRelativeDemoStream(), redraw)
	if !strings.Contains(got, "redrawn") {
		t.Fatalf("the redraw was not forwarded: %q", got)
	}
	if n := strings.Count(got, "a=p,i=1,"); n != 1 || strings.Contains(got, kittyPlacementClear) {
		t.Fatalf("replay placed image 1 besides the program (%d placements): %q", n, got)
	}
}

// TestForegroundReplayPlacesImagesOnBothScreens covers an alternate-screen
// program: the main screen behind it gets its placement back with its own
// frame, and the alternate screen with the frame that paints it.
func TestForegroundReplayPlacesImagesOnBothScreens(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "\x1b[2;3H\x1b_Ga=T,i=5,C=1," + kittyPixelRoot + "\x1b\\" +
		"\x1b[?1049h\x1b_Ga=t,i=6," + kittyPixelRoot + "\x1b\\" +
		"\x1b[7;9H\x1b_Ga=p,i=6,p=2,C=1\x1b\\\x1b[10;1Halternate"
	got := selectWindowReplay(t, window, stream, "")

	mainPlaced := strings.Index(got, "\x1b[2;3H\x1b_Ga=p,i=5,C=1,q=2\x1b\\")
	enter := strings.LastIndex(got, "\x1b[?1049h")
	altImage := strings.LastIndex(got, "\x1b_Ga=t,i=6,")
	altRows := strings.Index(got, "alternate")
	altPlaced := strings.Index(got, "\x1b[7;9H\x1b_Ga=p,i=6,p=2,C=1,q=2\x1b\\")
	if mainPlaced < 0 || altPlaced < 0 ||
		!(mainPlaced < enter && enter < altImage && altImage < altRows && altRows < altPlaced) {
		t.Fatalf("placements out of place (main %d, 1049h %d, alt image %d, alt rows %d, alt %d): %q",
			mainPlaced, enter, altImage, altRows, altPlaced, got)
	}
	if strings.Count(got, "a=p,i=5,") != 1 || strings.Count(got, "a=p,i=6,") != 1 {
		t.Fatalf("an image was placed more than once: %q", got)
	}
	// Only the main screen keeps the client's placements through the
	// replay prefix, so only its frame clears them.
	if strings.Count(got, kittyPlacementClear) != 1 || strings.Index(got, kittyPlacementClear) > mainPlaced {
		t.Fatalf("main screen placements not cleared once before its frame: %q", got)
	}
}

// TestHistoryReplayPlacesNoImagesAgain covers a shell window, which replays
// the raw tail of its output: that tail already carries the placements, so
// the replay adds none.
func TestHistoryReplayPlacesNoImagesAgain(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "$ icat\r\n" + kittyRelativeDemoStream() + "\r\n$ "
	got := selectWindowReplay(t, window, stream, "")

	if placed := window.screenLocked().kittyDirect; len(placed) != 1 {
		t.Fatalf("the model follows %d placements, want 1", len(placed))
	}
	if !strings.Contains(got, "$ icat") {
		t.Fatalf("not a history replay: %q", got)
	}
	want := strings.Count(stream, "a=p,i=1,")
	if n := strings.Count(got, "a=p,i=1,"); n != want || strings.Contains(got, kittyPlacementClear) {
		t.Fatalf("history replay placed image 1 %d times, its history %d: %q", n, want, got)
	}
}
