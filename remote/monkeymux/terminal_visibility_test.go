package main

import (
	"strings"
	"testing"
	"time"
)

const (
	visibleReport = "\x1b[?999;1n"
	hiddenReport  = "\x1b[?999;2n"
)

// newVisibilityTestServer has two windows, @1 active, and one attached client
// "phone".
func newVisibilityTestServer(t *testing.T) (*muxServer, [2]*recordingPty, *attachClient, *recordingConn) {
	t.Helper()
	server := newMuxServer("visibility-" + strings.ReplaceAll(t.Name(), "/", "-"))
	var ptys [2]*recordingPty
	for i := range ptys {
		ptys[i] = &recordingPty{}
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: ptys[0], lastActivity: time.Now()},
		{id: "@2", index: 1, pty: ptys[1], lastActivity: time.Now()},
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	client := registerTestAttachClient(t, server, attach, "phone", server.width, server.height)
	return server, ptys, client, attach
}

func setClientVisibility(server *muxServer, clientID string, hidden bool) {
	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:     "client_visibility",
		ClientID: clientID,
		Hidden:   hidden,
	})
}

func windowReplies(t *testing.T, server *muxServer, index int, pty *recordingPty) string {
	t.Helper()
	waitForWindowReplies(t, server.windows[index])
	got := pty.String()
	pty.Reset()
	return got
}

func TestVisibilityReportsAreAnsweredByMonkeyMux(t *testing.T) {
	server, ptys, _, attach := newVisibilityTestServer(t)

	server.handleWindowOutput("@1", []byte("a\x1b[?2033$p\x1b[?2033hb\x1b[?2033$p\x1b[?998nc"))
	if got := windowReplies(t, server, 0, ptys[0]); got != "\x1b[?2033;2$y"+visibleReport+"\x1b[?2033;1$y"+visibleReport {
		t.Fatalf("active window replies = %q", got)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); strings.Contains(got, "2033") || strings.Contains(got, "998") ||
		!strings.Contains(got, "abc") {
		t.Fatalf("attach output = %q, want the text without visibility sequences", got)
	}

	// A background window is not visible.
	server.handleWindowOutput("@2", []byte("\x1b[?2033h"))
	if got := windowReplies(t, server, 1, ptys[1]); got != hiddenReport {
		t.Fatalf("background window replies = %q, want %q", got, hiddenReport)
	}

	// Enabling again reports again; the query answers without enabling.
	server.handleWindowOutput("@1", []byte("\x1b[?2033h\x1b[?2033l\x1b[?998n\x1b[?2033$p"))
	if got := windowReplies(t, server, 0, ptys[0]); got != visibleReport+visibleReport+"\x1b[?2033;2$y" {
		t.Fatalf("replies = %q", got)
	}
}

func TestVisibilityReportsFollowTheActiveWindowAndClients(t *testing.T) {
	server, ptys, client, _ := newVisibilityTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b[?2033h"))
	server.handleWindowOutput("@2", []byte("\x1b[?2033h"))
	_ = windowReplies(t, server, 0, ptys[0])
	_ = windowReplies(t, server, 1, ptys[1])

	if err := server.selectWindowWithoutReplay("@2"); err != nil {
		t.Fatal(err)
	}
	if got := windowReplies(t, server, 0, ptys[0]); got != hiddenReport {
		t.Fatalf("@1 after switching away = %q", got)
	}
	if got := windowReplies(t, server, 1, ptys[1]); got != visibleReport {
		t.Fatalf("@2 after switching to it = %q", got)
	}

	// A hidden client hides the active window, once.
	setClientVisibility(server, "phone", true)
	setClientVisibility(server, "phone", true)
	if got := windowReplies(t, server, 1, ptys[1]); got != hiddenReport {
		t.Fatalf("@2 with its client hidden = %q", got)
	}
	// Another attached client that never reported counts as visible.
	other := registerTestAttachClient(t, server, &recordingConn{}, "laptop", server.width, server.height)
	server.mu.Lock()
	server.refreshWindowVisibilityLocked()
	server.mu.Unlock()
	if got := windowReplies(t, server, 1, ptys[1]); got != visibleReport {
		t.Fatalf("@2 with a second client = %q", got)
	}
	server.removeAttachClient(other)
	if got := windowReplies(t, server, 1, ptys[1]); got != hiddenReport {
		t.Fatalf("@2 after the visible client left = %q", got)
	}
	setClientVisibility(server, "phone", false)
	if got := windowReplies(t, server, 1, ptys[1]); got != visibleReport {
		t.Fatalf("@2 with its client visible again = %q", got)
	}
	if got := windowReplies(t, server, 0, ptys[0]); got != "" {
		t.Fatalf("@1 in the background got %q, want nothing", got)
	}

	// Detaching the last client hides the window and forgets the client.
	setClientVisibility(server, "phone", true)
	_ = windowReplies(t, server, 1, ptys[1])
	server.removeAttachClient(client)
	server.mu.Lock()
	_, remembered := server.hiddenClientIDs["phone"]
	server.mu.Unlock()
	if remembered {
		t.Fatal("hidden flag outlived the client")
	}
	if got := windowReplies(t, server, 1, ptys[1]); got != "" {
		t.Fatalf("@2 got %q after detaching while already hidden", got)
	}
}

func TestVisibilityModeIsStrippedFromForwardedOutput(t *testing.T) {
	server, ptys, _, attach := newVisibilityTestServer(t)

	// One sequence that also names another mode keeps that mode, and a
	// sequence split across reads is still recognised.
	server.handleWindowOutput("@1", []byte("x\x1b[?25;2033l\x1b[?20"))
	server.handleWindowOutput("@1", []byte("33hy\x1b[?2033:1;1h\x1b["))
	server.handleWindowOutput("@1", []byte("?99"))
	server.handleWindowOutput("@1", []byte("8nz\x1b[?2026$p"))
	if got := windowReplies(t, server, 0, ptys[0]); got != visibleReport+visibleReport+visibleReport {
		t.Fatalf("replies = %q", got)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); !strings.Contains(got, "x\x1b[?25ly\x1b[?1hz\x1b[?2026$p") {
		t.Fatalf("attach output = %q", got)
	}
}

// The 8-bit CSI the server's parsers accept sets and queries the mode as the
// 7-bit form does, and is stripped the same way, including when it is split
// across reads. A 0x9b that continues a character is text.
func TestC1VisibilitySequencesAreAnsweredAndStripped(t *testing.T) {
	server, ptys, _, attach := newVisibilityTestServer(t)

	server.handleWindowOutput("@1", []byte("a\x9b?2033h\x1b[?2033$p\x9b?2033$pb"))
	if got := windowReplies(t, server, 0, ptys[0]); got != visibleReport+"\x1b[?2033;1$y\x1b[?2033;1$y" {
		t.Fatalf("replies = %q", got)
	}
	setClientVisibility(server, "phone", true)
	if got := windowReplies(t, server, 0, ptys[0]); got != hiddenReport {
		t.Fatalf("replies after hiding = %q, want %q", got, hiddenReport)
	}
	setClientVisibility(server, "phone", false)
	_ = windowReplies(t, server, 0, ptys[0])

	for _, chunk := range []string{"c\x9b", "?25;2033", "ld\x9b?99", "8ne\x9b", "?2033l"} {
		server.handleWindowOutput("@1", []byte(chunk))
	}
	if got := windowReplies(t, server, 0, ptys[0]); got != visibleReport {
		t.Fatalf("split replies = %q, want %q", got, visibleReport)
	}
	server.mu.Lock()
	enabled := server.windows[0].visibility.enabled
	server.mu.Unlock()
	if enabled {
		t.Fatal("a split 8-bit reset left the mode enabled")
	}

	// U+201B ends in 0x9b; split after its lead bytes, that byte starts the
	// next read and is not held back or read as CSI.
	server.handleWindowOutput("@1", []byte("f\xe2\x80"))
	server.handleWindowOutput("@1", []byte("\x9b"))
	server.handleWindowOutput("@1", []byte("g\xe2\x80"))
	server.handleWindowOutput("@1", []byte("\x9b?2033h"))
	if got := windowReplies(t, server, 0, ptys[0]); got != "" {
		t.Fatalf("replies to text = %q, want none", got)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); !strings.Contains(got, "ab") ||
		!strings.Contains(got, "c\x9b?25lde") ||
		!strings.HasSuffix(got, "f\xe2\x80\x9bg\xe2\x80\x9b?2033h") {
		t.Fatalf("attach output = %q", got)
	}
}

// The 8-bit CSI changes the visibility mode, which MonkeyMux owns, and no
// mode of the attached terminal, which does not read it as CSI.
func TestC1CsiChangesOnlyTheVisibilityMode(t *testing.T) {
	window := &muxWindow{id: "@1", lastActivity: time.Now()}
	window.observeTerminalModesLocked([]byte("\x9b?5;20"))
	window.observeTerminalModesLocked([]byte("33h\x9b4h"))
	if !window.visibility.enabled {
		t.Fatal("a split 8-bit set left visibility reports off")
	}
	if window.privateModes["5"] || window.insertModeEnabled {
		t.Fatalf("modes = %v, insert %v; want the terminal's modes untouched",
			window.privateModes, window.insertModeEnabled)
	}
	// A continuation byte is text, even at the start of a read.
	window.terminalOutputUtf8Remaining = 1
	window.observeTerminalModesLocked([]byte("\x9b?2033l"))
	window.terminalOutputUtf8Remaining = 0
	window.observeTerminalModesLocked([]byte("\xe2\x80\x9b?2033l"))
	if !window.visibility.enabled {
		t.Fatal("a 0x9b continuing a character reset visibility reports")
	}
	window.observeTerminalModesLocked([]byte("\x9b?2033l"))
	if window.visibility.enabled {
		t.Fatal("an 8-bit reset left visibility reports on")
	}
}

func TestVisibilityModeIsStrippedFromReplays(t *testing.T) {
	history := []byte("a\x1b[?2033hb\x1b[?1049;2033hc\x9b?998nd\x1b[?2033$pe\x1b[?2031h")
	got := string(stripTerminalQueriesFromReplay(history))
	if want := "ab\x1b[?1049hcde\x1b[?2031h"; got != want {
		t.Fatalf("replay = %q, want %q", got, want)
	}
}

func TestVisibilityModeResetsOnFullReset(t *testing.T) {
	server, ptys, _, _ := newVisibilityTestServer(t)
	server.handleWindowOutput("@1", []byte("\x1b[?2033h\x1bc"))
	_ = windowReplies(t, server, 0, ptys[0])
	setClientVisibility(server, "phone", true)
	if got := windowReplies(t, server, 0, ptys[0]); got != "" {
		t.Fatalf("replies after RIS = %q, want none", got)
	}
}

func TestClientVisibilityIsACapability(t *testing.T) {
	if !containsString(capabilities, "client-visibility") {
		t.Fatal("capabilities do not advertise client-visibility")
	}
}

// A window's display modes are replayed for it and reset for the next one,
// so they do not leak into another window and its DECRQM answers.
func TestReverseVideoAndCursorBlinkAreTrackedPerWindow(t *testing.T) {
	window := &muxWindow{id: "@1", lastActivity: time.Now()}
	window.observeTerminalModesLocked([]byte("\x1b[?5h\x1b[?12h"))
	if got := string(terminalModePostReplaySequence(window)); !strings.Contains(got, "\x1b[?5h") ||
		!strings.Contains(got, "\x1b[?12h") {
		t.Fatalf("post replay = %q, want reverse video and blink restored", got)
	}
	for _, reset := range []string{"\x1b[?5l", "\x1b[?12l"} {
		if !strings.Contains(activeWindowReplayPrefix, reset) {
			t.Fatalf("the replay prefix does not contain %q", reset)
		}
	}
	window.observeTerminalModesLocked([]byte("\x1bc"))
	if window.privateModes["5"] || window.privateModes["12"] {
		t.Fatal("RIS kept reverse video or blink")
	}
}

func TestBackarrowKeyModeIsTrackedAndReplayed(t *testing.T) {
	window := &muxWindow{id: "@1", lastActivity: time.Now()}
	window.observeTerminalModesLocked([]byte("\x1b[?67h"))
	if !window.privateModes["67"] {
		t.Fatal("DECBKM was not tracked")
	}
	if got := string(terminalModePostReplaySequence(window)); !strings.Contains(got, "\x1b[?67h") {
		t.Fatalf("post replay = %q, want DECBKM restored", got)
	}
	if !strings.Contains(activeWindowReplayPrefix, "\x1b[?67l") {
		t.Fatal("the replay prefix does not reset DECBKM")
	}
	if _, kept := privateModesForRestore(window.privateModes)["67"]; kept {
		t.Fatal("a restore kept the old process's DECBKM")
	}
	window.observeTerminalModesLocked([]byte("\x1b[!p"))
	if !window.privateModes["67"] {
		t.Fatal("DECSTR reset DECBKM")
	}
	window.observeTerminalModesLocked([]byte("\x1bc"))
	if window.privateModes["67"] {
		t.Fatal("RIS kept DECBKM")
	}

	var output strings.Builder
	tracker := newAttachModeTracker(&output)
	if _, err := tracker.Write([]byte("\x1b[?67h")); err != nil {
		t.Fatal(err)
	}
	if got := string(tracker.resetSequence()); got != "\x1b[?67l" {
		t.Fatalf("attach end reset = %q, want DECBKM off", got)
	}
}
