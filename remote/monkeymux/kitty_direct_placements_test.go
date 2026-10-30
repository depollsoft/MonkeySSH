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
	// The client shows @1, as its attach replay left it.
	server.shownWindowID = "@1"
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
	clear := strings.Index(got, windowChangeReplayPrefix)
	own := strings.Index(got, "\x1b_Ga=d,d=i,i=1,q=2\x1b\\")
	rows := strings.Index(got, "5 parent placed again")
	placed := strings.Index(got, kittyDemoPlacement)
	saved := strings.LastIndex(got, "\x1b7")
	switch {
	case frame < 0 || image < 0 || clear < 0 || rows < 0 || placed < 0 || saved < 0:
		t.Fatalf("replay is missing a part (frame %d, image %d, clear %d, rows %d, placement %d, saved cursor %d): %q",
			frame, image, clear, rows, placed, saved, got)
	case !(clear == len(terminalSynchronizedOutputBegin) && clear < own && own < image &&
		image < frame && frame < rows && rows < placed && placed < saved):
		t.Fatalf("replay parts out of order (clear %d, image %d, frame %d, rows %d, placement %d, saved cursor %d): %q",
			clear, image, frame, rows, placed, saved, got)
	}
	// The window-change prefix deletes the client's placements, and the
	// image placed again its own copies too.
	if n := strings.Count(got, "a=d"); n != 2 {
		t.Fatalf("replay deletes %d times: %q", n, got)
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
	if n := strings.Count(got, "a=p,i=1,"); n != 1 || strings.Count(got, "a=d") != 1 ||
		!strings.Contains(got, windowChangeReplayPrefix) {
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

	mainDelete := strings.Index(got, "\x1b_Ga=d,d=i,i=5,q=2\x1b\\")
	mainImage := strings.Index(got, "\x1b_Ga=t,i=5,")
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
	// The main screen's image reaches its own store before its frame, after
	// the client's copies of its placements are deleted; entering the
	// alternate screen clears its own.
	if !(mainDelete >= 0 && mainDelete < mainImage && mainImage < mainPlaced) ||
		strings.Count(got, "a=d,d=i") != 1 {
		t.Fatalf("main screen image and delete out of place (delete %d, image %d, placement %d): %q",
			mainDelete, mainImage, mainPlaced, got)
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
	if n := strings.Count(got, "a=p,i=1,"); n != want || strings.Contains(got, "a=d,d=i,i=1,q=2") {
		t.Fatalf("history replay placed image 1 %d times, its history %d: %q", n, want, got)
	}
}

// TestReplayPrefixDeletesPlacementsOnlyOnAWindowChange: ED 2 leaves the
// client's physical placements on the main screen. A client reopened on the
// window it showed keeps them, which is how a shell window's images whose
// transmissions are older than its history tail survive; a client that was
// showing another window has them deleted (keeping the image data), so the
// images of the window shown before do not stay over this one.
func TestReplayPrefixDeletesPlacementsOnlyOnAWindowChange(t *testing.T) {
	const clear = "\x1b_Ga=d,d=a,q=2\x1b\\"
	if strings.Contains(activeWindowReplayPrefix, clear) ||
		!strings.Contains(windowChangeReplayPrefix, "\x1b[H\x1b[2J\x1b[3J"+clear+"\x1b[?1049h") {
		t.Fatalf("prefixes: %q, %q", activeWindowReplayPrefix, windowChangeReplayPrefix)
	}
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot", lastActivity: time.Now()}
	got := selectWindowReplay(t, window, "\x1b[Hno images here", "")
	if strings.Count(got, clear) != 1 || strings.Contains(got, "a=p") {
		t.Fatalf("switching to a window without images: %q", got)
	}

	// A shell window with an image whose transmission is older than the
	// history tail: an attach replay leaves the client's placement alone,
	// and so does selecting the window the client already shows.
	server := newMuxServerWithSize("test", 80, 24)
	shell := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{shell}
	server.activeID = shell.id
	big := strings.Repeat("A", 4*windowHistoryLimitBytes)
	server.handleWindowOutput(shell.id, []byte("$ icat\r\n\x1b_Ga=T,i=7,C=1,f=100;"+big+"\x1b\\\r\n$ "))
	server.mu.Lock()
	attachReplay, _ := server.activeReplayWithImageFollowUpLocked()
	reselect, _ := server.windowChangeReplayWithImageFollowUpLocked(shell, nil)
	server.mu.Unlock()
	for name, replay := range map[string][]byte{"attach": attachReplay, "reselect": reselect} {
		if strings.Contains(string(replay), "a=d") || strings.Contains(string(replay), big) {
			t.Fatalf("%s replay deletes the placement or carries the image: %.300q", name, replay)
		}
	}
}

// TestForegroundReplayPlacesAgainImagesItCanName: an image placed by number
// (I=) next to one placed by id. The prefix deletes both on the client, and
// the replay can only name the one with an id to place it again.
func TestForegroundReplayPlacesAgainImagesItCanName(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot", lastActivity: time.Now()}
	stream := "\x1b[2;2H\x1b_Ga=T,I=9,C=1," + kittyPixelRoot + "\x1b\\" +
		"\x1b[2;20H\x1b_Ga=T,i=42,C=1," + kittyPixelRoot + "\x1b\\\x1b[5;1Hwaiting"
	got := selectWindowReplay(t, window, stream, "")
	if strings.Count(got, "a=p") != 1 || !strings.Contains(got, "\x1b[2;20H\x1b_Ga=p,i=42,C=1,q=2\x1b\\") {
		t.Fatalf("replay does not place image 42 alone again: %q", got)
	}
}

// TestMainScreenReplayKeepsTheAlternateScreensImageData: the client keeps an
// image store per screen, so an id transmitted on the main screen and again
// on the alternate one names two images. The main screen gets no image the
// window last transmitted on the alternate screen, and no placement of it.
func TestMainScreenReplayKeepsTheAlternateScreensImageData(t *testing.T) {
	const red, blue = "f=32,s=1,v=1;/wAA/w==", "f=32,s=1,v=1;AAD//w=="
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "\x1b[2;3H\x1b_Ga=T,i=7,C=1," + red + "\x1b\\" +
		"\x1b[?1049h\x1b_Ga=t,i=7," + blue + "\x1b\\" +
		"\x1b[5;5H\x1b_Ga=p,i=7,p=2,C=1\x1b\\\x1b[10;1Halternate"
	got := selectWindowReplay(t, window, stream, "")
	enter := strings.LastIndex(got, "\x1b[?1049h")
	mainPart, altPart := got[:enter], got[enter:]
	// The main screen gets neither the alternate screen's data nor a placement
	// of id 7, which would show whatever its store holds under that id.
	if strings.Contains(mainPart, "a=t,i=7") || strings.Contains(mainPart, "a=p,i=7") {
		t.Fatalf("main screen replay = %q", mainPart)
	}
	if !strings.Contains(altPart, "AAD//w==") || !strings.Contains(altPart, "\x1b[5;5H\x1b_Ga=p,i=7,p=2,C=1,q=2\x1b\\") {
		t.Fatalf("alternate screen replay = %q", altPart)
	}
}

// TestForegroundReplaySendsMainScreenImagesToTheMainScreen: the client keeps
// an image store per screen, so the images the main screen's placements show
// are sent while it is the screen shown, before the frame places them, and a
// placement whose image the replay cannot carry is left out.
func TestForegroundReplaySendsMainScreenImagesToTheMainScreen(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	big := strings.Repeat("A", maxReplayedKittyImageBytes)
	stream := "\x1b[2;3H\x1b_Ga=T,i=5,C=1," + kittyPixelRoot + "\x1b\\" +
		"\x1b[3;3H\x1b_Ga=T,i=8,C=1,f=100;" + big + "\x1b\\" +
		"\x1b[?1049h\x1b[10;1Halternate"
	server := newMuxServerWithSize("test", 80, 40)
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.mu.Lock()
	window.recordScreenGeometryLocked(80, 40)
	window.screenWidth, window.screenHeight = 80, 40
	server.mu.Unlock()
	server.handleWindowOutput(window.id, []byte(stream))

	server.mu.Lock()
	replay, _ := server.replayBytesWithImageFollowUpLocked(window, nil)
	server.mu.Unlock()
	got := string(replay)
	image := strings.Index(got, "\x1b_Ga=t,i=5,")
	placed := strings.Index(got, "\x1b[2;3H\x1b_Ga=p,i=5,C=1,q=2\x1b\\")
	enter := strings.LastIndex(got, "\x1b[?1049h")
	if !(image >= 0 && image < placed && placed < enter) {
		t.Fatalf("main screen image not sent before its placement on the main screen (image %d, placement %d, 1049h %d): %q",
			image, placed, enter, got)
	}
	// Image 8 does not fit in what the replay carries, so neither its
	// placement nor its delete is sent: the client keeps what it had.
	if strings.Contains(got, "i=8") {
		t.Fatalf("replay places an image it does not carry: %.400q", got)
	}
}

// TestAttachReplayDeletesOnlyTheImagesItPlacesAgain: a client reopened on a
// foreground window keeps what it holds, so the frame deletes the client's
// copies of each image it places again, and nothing else.
func TestAttachReplayDeletesOnlyTheImagesItPlacesAgain(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@1", index: 0, agentTool: "copilot", lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.handleWindowOutput(window.id, []byte("\x1b_Ga=t,i=4,"+kittyPixelRoot+"\x1b\\"+
		"\x1b[3;3H\x1b_Ga=p,i=4,C=1\x1b\\\x1b[3;9H\x1b_Ga=T,I=9,C=1,"+kittyPixelRoot+"\x1b\\"))
	server.mu.Lock()
	got := string(server.foregroundHistoryFallbackReplayLocked(window, window.screenLocked(), false))
	server.mu.Unlock()
	deleted := strings.Index(got, "\x1b_Ga=d,d=i,i=4,q=2\x1b\\")
	image := strings.Index(got, "\x1b_Ga=t,i=4,")
	placed := strings.Index(got, "\x1b[3;3H\x1b_Ga=p,i=4,C=1,q=2\x1b\\")
	if !strings.HasPrefix(got, activeWindowReplayPrefix) || strings.Count(got, "a=d") != 1 ||
		!(deleted >= 0 && deleted < image && image < placed) {
		t.Fatalf("attach frame (delete %d, image %d, placement %d): %q", deleted, image, placed, got)
	}
}
