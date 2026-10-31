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
	return selectWindowReplayReads(t, window, stream, redraw, len(stream))
}

// selectWindowReplayReads is selectWindowReplay with the window reading
// stream in reads of readBytes.
func selectWindowReplayReads(t *testing.T, window *muxWindow, stream, redraw string, readBytes int) string {
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
	for read := 0; read < len(stream); read += readBytes {
		server.handleWindowOutput(window.id, []byte(stream[read:min(read+readBytes, len(stream))]))
	}
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
	clear := strings.Index(got, "\x1b_Ga=d,d=i,i=1,q=2\x1b\\")
	rows := strings.Index(got, "5 parent placed again")
	placed := strings.Index(got, kittyDemoPlacement)
	saved := strings.LastIndex(got, "\x1b7")
	switch {
	case frame < 0 || image < 0 || clear < 0 || rows < 0 || placed < 0 || saved < 0:
		t.Fatalf("replay is missing a part (frame %d, image %d, clear %d, rows %d, placement %d, saved cursor %d): %q",
			frame, image, clear, rows, placed, saved, got)
	case !(clear < image && image < frame && frame < rows && rows < placed && placed < saved):
		t.Fatalf("replay parts out of order (clear %d, image %d, frame %d, rows %d, placement %d, saved cursor %d): %q",
			clear, image, frame, rows, placed, saved, got)
	}
	// Only the client's copies of the image placed again are deleted.
	if n := strings.Count(got, "a=d"); n != 1 {
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
	if n := strings.Count(got, "a=p,i=1,"); n != 1 || strings.Contains(got, "a=d") {
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

// TestReplayPrefixKeepsTheClientsPlacements: ED 2 leaves the client's
// physical placements on the main screen, and a window whose program owns
// the screen keeps them; the app deletes its own placements before it
// changes windows itself. A shell window's replay deletes them, and an
// image whose transmission is older than the history tail comes back with
// it.
func TestReplayPrefixKeepsTheClientsPlacements(t *testing.T) {
	if strings.Contains(activeWindowReplayPrefix, "a=d") {
		t.Fatalf("replay prefix %q deletes placements", activeWindowReplayPrefix)
	}
	window := &muxWindow{id: "@2", index: 1, agentTool: "copilot", lastActivity: time.Now()}
	if got := selectWindowReplay(t, window, "\x1b[Hno images here", ""); strings.Contains(got, "a=d") {
		t.Fatalf("a window switch deletes the client's placements: %q", got)
	}

	server := newMuxServerWithSize("test", 80, 24)
	shell := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{shell}
	server.activeID = shell.id
	big := strings.Repeat("A", 4*windowHistoryLimitBytes)
	server.handleWindowOutput(shell.id, []byte("$ icat\r\n\x1b_Ga=T,i=7,C=1,f=100;"+big+"\x1b\\\r\n$ "))
	server.mu.Lock()
	replay, _ := server.activeReplayWithImageFollowUpLocked()
	server.mu.Unlock()
	image := strings.Index(string(replay), "\x1b_Ga=t,i=7,C=1,f=100,q=2;"+big+"\x1b\\")
	placed := strings.Index(string(replay), "\x1b[1G\x1b_Ga=p,i=7,C=1,q=2\x1b\\\r\n$ ")
	deleted := strings.Index(string(replay), kittyVisiblePlacementsDelete)
	if strings.Count(string(replay), "a=d") != 1 || deleted < 0 || image < deleted || placed < image ||
		strings.Count(string(replay), big) != 1 {
		t.Fatalf("attach replay does not place the image again once (image %d, placement %d): %.300q",
			image, placed, replay)
	}
}

// TestForegroundReplayPlacesAgainImagesItCanName: an image placed by number
// (I=) next to one placed by id. The replay can only name the one with an id
// to place it again, and deletes the client's copies of that one alone.
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
	got := string(server.foregroundHistoryFallbackReplayLocked(window, window.screenLocked()))
	server.mu.Unlock()
	deleted := strings.Index(got, "\x1b_Ga=d,d=i,i=4,q=2\x1b\\")
	image := strings.Index(got, "\x1b_Ga=t,i=4,")
	placed := strings.Index(got, "\x1b[3;3H\x1b_Ga=p,i=4,C=1,q=2\x1b\\")
	if !strings.HasPrefix(got, windowReplayTag(window)+activeWindowReplayPrefix) || strings.Count(got, "a=d") != 1 ||
		!(deleted >= 0 && deleted < image && image < placed) {
		t.Fatalf("attach frame (delete %d, image %d, placement %d): %q", deleted, image, placed, got)
	}
}

// TestWindowReplayStartsWithItsWindowTag: every replay names the window it
// paints, so the app keeps its images on a reopen and drops them for another
// window; a captured replay loses the tag along with its prefix.
func TestWindowReplayStartsWithItsWindowTag(t *testing.T) {
	window := &muxWindow{id: "@3", index: 0, lastActivity: time.Now()}
	replay := string(buildWindowReplay(window, nil, []byte("hello"), false))
	want := "\x1b]7502;window=" + monkeyMuxServerInstance + ":@3\x1b\\" + activeWindowReplayPrefix
	if !strings.HasPrefix(replay, want) {
		t.Fatalf("replay = %q, want it to start with %q", replay, want)
	}
	captured := string(normalizeCapturedReplayHistory([]byte(replay)))
	if strings.Contains(captured, "\x1b]7502;") || strings.HasPrefix(captured, activeWindowReplayPrefix) ||
		!strings.Contains(captured, "hello") {
		t.Fatalf("captured history = %q", captured)
	}
	// A ConPTY replay is wrapped in synchronized output, ahead of its tag.
	wrapped := string(wrapSynchronizedTerminalOutput(nil, []byte(replay)))
	captured = string(normalizeCapturedReplayHistory([]byte(wrapped)))
	if strings.Contains(captured, "\x1b]7502;") || !strings.Contains(captured, "hello") {
		t.Fatalf("captured synchronized history = %q", captured)
	}
}

// kittyChunkedTransmission is an image transmission of payloadBytes of
// base64 in 4096-byte chunks, as kitten icat sends one: keys name the image
// and its placement in the first chunk.
func kittyChunkedTransmission(keys string, payloadBytes int) string {
	const chunkBytes = 4096
	var out strings.Builder
	for sent := 0; sent < payloadBytes; sent += chunkBytes {
		n := min(chunkBytes, payloadBytes-sent)
		more := 0
		if sent+n < payloadBytes {
			more = 1
		}
		control := fmt.Sprintf("m=%d", more)
		if sent == 0 {
			control = keys + "," + control
		}
		fmt.Fprintf(&out, "\x1b_G%s;%s\x1b\\", control, strings.Repeat("A", n))
	}
	return out.String()
}

// TestShellReplayPlacesAgainAnImageItsTailCutsOff: a shell window showed an
// image, then a little more output. Its replay carries only the last
// windowReplayLimitBytes of output, which start among the transmission's
// later chunks: the client ignores those, so the image would not come back
// after switching away and back. The replay starts with the command
// instead, at the column it ran at: from the history while the history holds
// it, else made again from the retained image. The image goes on the row it
// had, above the output that followed it, with the cursor moved past it as
// the command moved it.
func TestShellReplayPlacesAgainAnImageItsTailCutsOff(t *testing.T) {
	for _, tc := range []struct {
		name, keys, root, place string
		payload                 int
	}{
		// 47 KB of PNG: the history holds the whole transmission.
		{"from history by id", "a=T,i=7,f=100", "\x1b_Ga=T,i=7,f=100,m=1,", "", 64 * 1024},
		{"from history by number", "a=T,I=9,f=100", "\x1b_Ga=T,I=9,f=100,m=1,", "", 64 * 1024},
		{"from history without an id", "a=T,f=100", "\x1b_Ga=T,f=100,m=1,", "", 64 * 1024},
		// Larger than the history: the retained image is sent again.
		{"retained by id", "a=T,i=7,f=100", "\x1b_Ga=t,i=7,f=100,m=1,q=2;", "\x1b_Ga=p,i=7,q=2\x1b\\", 300 * 1024},
		{"retained by number", "a=T,I=9,f=100,c=20,r=10", "\x1b_Ga=t,I=9,f=100,c=20,r=10,m=1,q=2;", "\x1b_Ga=p,I=9,c=20,r=10,q=2\x1b\\", 300 * 1024},
	} {
		// The window reads the output whole, and in reads that split its
		// sequences anywhere.
		for _, readBytes := range []int{1 << 30, 997} {
			t.Run(fmt.Sprintf("%s in reads of %d", tc.name, readBytes), func(t *testing.T) {
				window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
				stream := "$ icat img.png\r\n  " + kittyChunkedTransmission(tc.keys, tc.payload) +
					"\r\n$ ls\r\nfoo  bar\r\n$ "
				got := selectWindowReplayReads(t, window, stream, "", readBytes)
				tag := strings.LastIndex(got, windowReplayTag(window))
				if tag < 0 {
					t.Fatalf("no replay of the window: %.300q", got)
				}
				got = got[tag:]
				root := strings.Index(got, tc.root)
				text := strings.Index(got, "\r\n$ ls")
				if root < 0 || text < 0 || strings.Count(got, tc.root) != 1 {
					t.Fatalf("replay does not carry the image once before its output (image %d, output %d): %.400q",
						root, text, got)
				}
				// It goes at the column the command ran at.
				column := "\x1b[3G"
				at := strings.Index(got, column)
				if tc.place == "" {
					if !(at >= 0 && at+len(column) == root && root < text) {
						t.Fatalf("command not replayed at its column (column %d, image %d, output %d): %.400q",
							at, root, text, got)
					}
					return
				}
				place := strings.Index(got, column+tc.place)
				if !(root < place && place < text) || strings.Count(got, "a=p") != 1 {
					t.Fatalf("image not placed again at its column before its output (image %d, placement %d, output %d): %.400q",
						root, place, text, got)
				}
			})
		}
	}
}

// TestShellReplayLeavesOutImagesAboveWhatItPaints: the output after an image
// is longer than the replay carries, so the image's row is above the first
// one the replay paints, and the replay does not place it.
func TestShellReplayLeavesOutImagesAboveWhatItPaints(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "$ icat img.png\r\n" + kittyChunkedTransmission("a=T,i=7,f=100", 64*1024) +
		strings.Repeat("a line of output\r\n", 2*windowReplayLimitBytes/18) + "$ "
	got := selectWindowReplay(t, window, stream, "")
	if strings.Contains(got, "i=7") {
		t.Fatalf("replay places an image above what it paints: %.400q", got)
	}
}

// TestShellReplaySendsTheImagesItsDisplayCommandsShow: an image transmitted
// long before a display command in a shell window's replayed output. The
// client keeps image data per id, and another window may since have sent a
// different image with that id, so the replay sends the image first, unless
// the client reports holding these bytes.
func TestShellReplaySendsTheImagesItsDisplayCommandsShow(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "$ show\r\n" + kittyChunkedTransmission("a=t,i=5,f=100", 16*1024) +
		strings.Repeat("a line of output\r\n", 2*windowReplayLimitBytes/18) +
		"\x1b_Ga=p,i=5,c=4,r=2\x1b\\\r\n$ "
	got := selectWindowReplay(t, window, stream, "")
	got = got[strings.LastIndex(got, windowReplayTag(window)):]
	root := strings.Index(got, "\x1b_Ga=t,i=5,f=100,m=1,q=2;")
	place := strings.Index(got, "\x1b_Ga=p,i=5,c=4,r=2")
	if root < 0 || place < 0 || root > place || strings.Count(got, "a=t,i=5,") != 1 {
		t.Fatalf("replay does not send image 5 once before showing it (image %d, display %d): %.300q",
			root, place, got)
	}

	server := newMuxServerWithSize("test", 80, 40)
	server.windows = []*muxWindow{window}
	server.mu.Lock()
	held := map[string]uint32{"5": window.kittyImageToken["5"]}
	replay, followUp := server.replayBytesWithImageFollowUpLocked(window, held)
	server.mu.Unlock()
	if strings.Contains(string(replay)+string(followUp), "a=t,i=5") {
		t.Fatalf("replay sends an image the client holds: %.300q", replay)
	}
}

// TestShellReplayLeavesOutAnImageOverItsBudget: an image cut off by the
// replayed output and gone from the history is made again only if it fits
// in what a replay carries for images.
func TestShellReplayLeavesOutAnImageOverItsBudget(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "$ icat img.png\r\n" +
		kittyChunkedTransmission("a=T,i=7,f=100", maxReplayedKittyImageBytes+4096) + "\r\n$ "
	got := selectWindowReplay(t, window, stream, "")
	got = got[strings.LastIndex(got, windowReplayTag(window)):]
	if strings.Contains(got, "i=7") || !strings.Contains(got, "\r\n$ ") {
		t.Fatalf("replay = %.300q", got)
	}
}

// TestShellReplayReplacesTheClientsPlacements: a client reopened on a shell
// window keeps its placements through the replay prefix (ED 2 leaves them),
// and the replayed output places each image it carries again. One sent by
// number or with no id gets a new id from the client each time, so the
// copy the client kept would stay beside the new one, pushed up into the
// scrollback by the output. The replay deletes the client's placements
// first; it places again every image it reaches.
func TestShellReplayReplacesTheClientsPlacements(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	shell := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{shell}
	server.activeID = shell.id
	server.handleWindowOutput(shell.id, []byte("$ icat a.png b.png\r\n"+
		"\x1b_Ga=T,I=9,"+kittyPixelRoot+"\x1b\\\r\n"+
		"\x1b_Ga=T,"+kittyPixelRoot+"\x1b\\\r\n$ "))
	server.mu.Lock()
	replay, _ := server.activeReplayWithImageFollowUpLocked()
	server.mu.Unlock()
	got := string(replay)
	prefix := strings.Index(got, activeWindowReplayPrefix)
	deleted := strings.Index(got, "\x1b_Ga=d,d=a,q=2\x1b\\")
	first := strings.Index(got, "\x1b_Ga=T,I=9,")
	if prefix < 0 || !(prefix < deleted && deleted < first) || strings.Count(got, "a=d") != 1 {
		t.Fatalf("replay does not delete the client's placements before its own (prefix %d, delete %d, image %d): %q",
			prefix, deleted, first, got)
	}
}

// TestMainScreenReplayLeavesOutCleanlyAnImageOverItsBudget: a main-screen
// image too large for the replay, behind an alternate-screen program. The
// replay paints the main screen with its scrollback, which scrolls the
// client's screen, so the client's own copy of the image would go up the
// screen with the rows, away from its cell. Every placement the client kept
// there goes before the main screen is painted; the image is left out.
func TestMainScreenReplayLeavesOutCleanlyAnImageOverItsBudget(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	big := strings.Repeat("A", maxReplayedKittyImageBytes)
	stream := strings.Repeat("earlier output\r\n", 60) +
		"\x1b_Ga=T,i=8,C=1,f=100;" + big + "\x1b\\\r\n$ vim\r\n" +
		"\x1b[?1049h\x1b[H\x1b[2J\x1b[10;1Halternate"
	server := newMuxServerWithSize("test", 80, 40)
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.mu.Lock()
	window.recordScreenGeometryLocked(80, 40)
	window.screenWidth, window.screenHeight = 80, 40
	server.mu.Unlock()
	server.handleWindowOutput(window.id, []byte(stream))

	server.mu.Lock()
	replay, followUp := server.replayBytesWithImageFollowUpLocked(window, nil)
	server.mu.Unlock()
	got := string(replay)
	deleted := strings.Index(got, kittyVisiblePlacementsDelete)
	frame := strings.Index(got, "earlier output")
	enter := strings.LastIndex(got, "\x1b[?1049h")
	if !(deleted >= 0 && deleted < frame && frame < enter) || strings.Count(got, "a=d") != 1 {
		t.Fatalf("client's main-screen placements not deleted before the main screen is painted (delete %d, frame %d, 1049h %d): %.400q",
			deleted, frame, enter, got)
	}
	if strings.Contains(got, "i=8") || strings.Contains(string(followUp), "i=8") {
		t.Fatalf("replay places an image it does not carry: %.400q", got)
	}
}

// TestShellReplayRebuildsOnlyTheImageItsCutCommandSent: the image a cut
// command sent is gone from the history, and the window has since sent
// another image with its id, on the alternate screen, whose store the
// client keeps apart. Placing that one on the main screen would show the
// wrong image, so the replay leaves the cut command out.
func TestShellReplayRebuildsOnlyTheImageItsCutCommandSent(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	stream := "$ icat img.png\r\n" + kittyChunkedTransmission("a=T,i=7,f=100", 300*1024) +
		"\r\n$ vim\r\n\x1b[?1049h\x1b_Ga=T,i=7,f=100,c=2,r=1;BBBB\x1b\\\x1b[?1049l\r\n$ "
	got := selectWindowReplay(t, window, stream, "")
	got = got[strings.LastIndex(got, windowReplayTag(window)):]
	enter := strings.Index(got, "\x1b[?1049h\x1b_Ga=T,i=7")
	if strings.Contains(got, "a=t,i=7") || strings.Contains(got, "a=p,i=7") ||
		strings.Index(got, "BBBB") < enter {
		t.Fatalf("replay places the alternate screen's image on the main screen: %.600q", got)
	}
}

// TestShellReplayFindsItsCutCommandBehindManyImages: many small images follow
// the one the replay's cut falls on, all within what it carries; the model
// still knows the cut command.
func TestShellReplayFindsItsCutCommandBehindManyImages(t *testing.T) {
	window := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	var thumbnails strings.Builder
	for id := 100; id < 300; id++ {
		fmt.Fprintf(&thumbnails, "\x1b_Ga=T,i=%d,C=1,%s\x1b\\", id, kittyPixelRoot)
	}
	stream := "$ icat img.png\r\n" + kittyChunkedTransmission("a=T,i=7,f=100", 64*1024) +
		"\r\n" + thumbnails.String() + "\r\n$ "
	got := selectWindowReplay(t, window, stream, "")
	got = got[strings.LastIndex(got, windowReplayTag(window)):]
	root := strings.Index(got, "\x1b[1G\x1b_Ga=T,i=7,f=100,m=1,")
	if root < 0 || root > strings.Index(got, "a=T,i=100,") {
		t.Fatalf("replay does not start with the image its cut falls on (image %d): %.300q", root, got)
	}
}

// TestConPtyReplayReplacesTheClientsPlacements: a ConPTY window keeps its
// normal screen and replays its whole retained output, which places its
// images again, so a reopened client's own placements go first there too.
func TestConPtyReplayReplacesTheClientsPlacements(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@1", index: 0, win32InputMode: true, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.handleWindowOutput(window.id, []byte("> show\r\n\x1b_Ga=T,I=9,"+kittyPixelRoot+"\x1b\\\r\n> "))
	server.mu.Lock()
	conPty := window.retainsConPtyNormalScreenLocked()
	replay, _ := server.activeReplayWithImageFollowUpLocked()
	server.mu.Unlock()
	got := string(replay)
	deleted := strings.Index(got, kittyVisiblePlacementsDelete)
	image := strings.Index(got, "\x1b_Ga=T,I=9,")
	if !conPty || deleted < 0 || deleted > image || strings.Count(got, "a=d") != 1 {
		t.Fatalf("ConPTY replay does not delete the client's placements first (delete %d, image %d): %q",
			deleted, image, got)
	}
}

// TestShellReplayShowsNoOtherWindowsImage: window @1 transmitted five images
// long before showing them, and window @2 then sent different images under
// the same ids, or numbers. Switching back to @1 keeps the image data the
// client holds, so a display command in @1's replay would show @2's image
// unless the replay sent @1's first. It sends what fits in its budget and
// deletes the client's data of the rest, so their display commands fail
// instead.
func TestShellReplayShowsNoOtherWindowsImage(t *testing.T) {
	// The display commands run on the main screen, where the client starts
	// the replay: also after a program used the alternate screen in what the
	// replay carries, and before a reset of a mode that was not set.
	visits := map[string][2]string{
		"":                          {"", ""},
		"after an alternate screen": {"\x1b[?1049hTUI\x1b[?1049l", ""},
		"before a redundant reset":  {"", "\x1b[?1049l"},
	}
	for _, key := range []string{"i", "I"} {
		for visitName, visit := range visits {
			t.Run(strings.TrimSpace(key+" "+visitName), func(t *testing.T) {
				server := newMuxServerWithSize("test", 80, 24)
				one := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
				two := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
				server.windows = []*muxWindow{one, two}
				server.activeID = one.id
				attach := &recordingConn{}
				registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

				images := func(payload string) string {
					var out strings.Builder
					for n := 1; n <= 5; n++ {
						fmt.Fprintf(&out, "\x1b_Ga=t,%s=%d,f=100;%s\x1b\\", key, n, payload)
					}
					return out.String()
				}
				var shows strings.Builder
				for n := 1; n <= 5; n++ {
					fmt.Fprintf(&shows, "\x1b_Ga=p,%s=%d,c=2,r=1\x1b\\\r\n", key, n)
				}
				server.handleWindowOutput(one.id, []byte(images("AAAA")+
					strings.Repeat("a line of output\r\n", 2*windowReplayLimitBytes/18)+visit[0]+shows.String()+visit[1]+"$ "))
				if err := server.selectWindow(two.id); err != nil {
					t.Fatal(err)
				}
				server.handleWindowOutput(two.id, []byte(images("BBBB")+"$ "))
				if err := server.selectWindow(one.id); err != nil {
					t.Fatal(err)
				}
				waitForTestAttachWrites(t, server)
				got := attach.String()
				got = got[strings.LastIndex(got, windowReplayTag(one)):]
				for n := 1; n <= 5; n++ {
					show := strings.Index(got, fmt.Sprintf("\x1b_Ga=p,%s=%d,", key, n))
					sent := strings.Index(got, fmt.Sprintf("\x1b_Ga=t,%s=%d,", key, n))
					deleted := strings.Index(got, fmt.Sprintf("\x1b_Ga=d,d=%s,%s=%d,q=2\x1b\\",
						map[string]string{"i": "I", "I": "N"}[key], key, n))
					if show < 0 || !(sent >= 0 && sent < show || deleted >= 0 && deleted < show) {
						t.Fatalf("image %d is shown (%d) without being sent (%d) or deleted (%d) first: %.600q",
							n, show, sent, deleted, got)
					}
				}
			})
		}
	}
}

// TestShellReplaySendsTheImageADirectPlacementShowsBesideAVirtualOne: one
// image shown by a virtual placement and a direct one, in either order. The
// follow-up places the virtual one again, but nothing does the direct one,
// so the replay sends the image before both.
func TestShellReplaySendsTheImageADirectPlacementShowsBesideAVirtualOne(t *testing.T) {
	const (
		virtual = "\x1b_Ga=p,U=1,i=7,p=1,c=1,r=1\x1b\\"
		direct  = "\x1b_Ga=p,i=7,p=2,c=1,r=1\x1b\\"
	)
	for name, shows := range map[string]string{
		"virtual first": virtual + direct,
		"direct first":  direct + virtual,
	} {
		t.Run(name, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			server.handleWindowOutput(window.id, []byte("\x1b_Ga=t,i=7,"+kittyPixelRoot+"\x1b\\"+
				strings.Repeat("a line of output\r\n", 2*windowReplayLimitBytes/18)+shows+"\r\n$ "))
			server.mu.Lock()
			replay, _ := server.replayBytesWithImageFollowUpLocked(window, map[string]uint32{})
			server.mu.Unlock()
			got := string(replay)
			sent := strings.Index(got, "\x1b_Ga=t,i=7,")
			placed := strings.Index(got, "\x1b_Ga=p,i=7,p=2,")
			if sent < 0 || placed < sent || strings.Contains(got, "a=d,d=I") {
				t.Fatalf("image 7 not sent before its direct placement (image %d, placement %d): %.300q",
					sent, placed, got)
			}
		})
	}
}
