package main

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestWindowTracksKittyKeyboardPerScreen(t *testing.T) {
	window := &muxWindow{}
	observe := func(chunks ...string) {
		t.Helper()
		for _, chunk := range chunks {
			window.observeTerminalModesLocked([]byte(chunk))
		}
	}
	want := func(main, alternate kittyKeyboardModes) {
		t.Helper()
		got := window.kittyKeyboard
		if !reflect.DeepEqual(got[0], main) || !reflect.DeepEqual(got[1], alternate) {
			t.Fatalf("kitty keyboard = %+v, want main %+v alternate %+v", got, main, alternate)
		}
	}

	// A push split across reads still lands once the sequence completes.
	observe("agent\x1b[>", "5u")
	want(kittyKeyboardModes{flags: 5, saved: []int{0}}, kittyKeyboardModes{})
	if !window.keyboardModesUsed {
		t.Fatal("push did not mark keyboard modes used")
	}
	observe("\x1b[?1049h\x1b[>1u")
	want(
		kittyKeyboardModes{flags: 5, saved: []int{0}},
		kittyKeyboardModes{flags: 1, saved: []int{0}},
	)
	observe("\x1b[<u\x1b[?1049l")
	want(kittyKeyboardModes{flags: 5, saved: []int{0}}, kittyKeyboardModes{saved: []int{}})
	observe("\x1b[<9u")
	want(kittyKeyboardModes{saved: []int{}}, kittyKeyboardModes{saved: []int{}})

	observe("\x1b[=1;1u", "\x1b[=4;2u")
	if got := window.kittyKeyboard[0].flags; got != 5 {
		t.Fatalf("flags after set and or = %d, want 5", got)
	}
	observe("\x1b[=1;3u")
	if got := window.kittyKeyboard[0].flags; got != 4 {
		t.Fatalf("flags after and-not = %d, want 4", got)
	}

	observe("\x1b[>4;2m")
	if window.modifyOtherKeys != 2 {
		t.Fatalf("modifyOtherKeys = %d, want 2", window.modifyOtherKeys)
	}
	observe("\x1b[>4m")
	if window.modifyOtherKeys != 0 {
		t.Fatalf("modifyOtherKeys after reset = %d, want 0", window.modifyOtherKeys)
	}

	observe("\x1b[>4;1m\x1b[>3u\x1bc")
	if window.modifyOtherKeys != 0 ||
		!reflect.DeepEqual(window.kittyKeyboard, [2]kittyKeyboardModes{}) {
		t.Fatalf("RIS left keyboard modes %+v, modifyOtherKeys %d", window.kittyKeyboard, window.modifyOtherKeys)
	}
}

func TestKittyKeyboardStackEvictsOldestPush(t *testing.T) {
	var modes kittyKeyboardModes
	for flags := range kittyKeyboardStackLimit + 3 {
		modes.push(flags + 1)
	}
	if len(modes.saved) != kittyKeyboardStackLimit {
		t.Fatalf("saved %d entries, want %d", len(modes.saved), kittyKeyboardStackLimit)
	}
	if modes.saved[0] != 3 || modes.flags != kittyKeyboardStackLimit+3 {
		t.Fatalf("stack = %+v, want oldest pushes evicted", modes)
	}
}

func TestKeyboardModeReplayRebuildsBothScreens(t *testing.T) {
	window := &muxWindow{modifyOtherKeys: 2}
	window.kittyKeyboard[0] = kittyKeyboardModes{flags: 7, saved: []int{1, 5}}
	want := kittyKeyboardResetSequence + "\x1b[=1;1u\x1b[>5u\x1b[>7u" +
		"\x1b[?1049h" + kittyKeyboardResetSequence + "\x1b[?1049l" +
		"\x1b[>4;2m"
	if got := string(window.keyboardModeReplayLocked()); got != want {
		t.Fatalf("replay = %q, want %q", got, want)
	}

	window = &muxWindow{}
	window.kittyKeyboard[1] = kittyKeyboardModes{flags: 1}
	want = kittyKeyboardResetSequence +
		"\x1b[?1049h" + kittyKeyboardResetSequence + "\x1b[=1;1u\x1b[?1049l" +
		"\x1b[>4;0m"
	if got := string(window.keyboardModeReplayLocked()); got != want {
		t.Fatalf("replay = %q, want %q", got, want)
	}
}

func TestReplayStripsKeyboardModeSequences(t *testing.T) {
	history := "a\x1b[>5ub\x1b[<uc\x1b[=1;1ud\x1b[>4;2me\x1b[>4mf" +
		"\x1b[?u\x1b[>1;2mg\x1b[4mh\x1b[su\x1b[u"
	want := "abcdef\x1b[>1;2mg\x1b[4mh\x1b[su\x1b[u"
	if got := string(stripTerminalQueriesFromReplay([]byte(history))); got != want {
		t.Fatalf("replay = %q, want %q", got, want)
	}
}

func TestReplayKeepsKeyboardModeSequencesAfterLastReset(t *testing.T) {
	// A full reset in the history erases the restore written before it, so
	// the changes after the last reset have to replay to rebuild the state.
	history := "a\x1b[>1u\x1bcb\x1b[>2u\x1bcc\x1b[>5u\x1b[>4;2md"
	want := "a\x1bcb\x1bcc\x1b[>5u\x1b[>4;2md"
	if got := string(stripTerminalQueriesFromReplay([]byte(history))); got != want {
		t.Fatalf("replay = %q, want %q", got, want)
	}
}

func TestReplayLeavesUntrackedEightBitKeyboardSequences(t *testing.T) {
	history := "a\x9b>5ub"
	if got := string(stripTerminalQueriesFromReplay([]byte(history))); got != history {
		t.Fatalf("replay = %q, want %q", got, history)
	}
}

func TestWindowSwitchRestoresEachWindowsKeyboardModes(t *testing.T) {
	server := newMuxServer("test")
	agent := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	shell := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{agent, shell}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@1", []byte("\x1b[>5u\x1b[>4;2magent"))
	waitForTestAttachWrites(t, server)
	attach.Reset()

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	waitForTestAttachWrites(t, server)
	shellRestore := kittyKeyboardResetSequence +
		"\x1b[?1049h" + kittyKeyboardResetSequence + "\x1b[?1049l\x1b[>4;0m"
	if got := attach.String(); !strings.Contains(got, activeWindowReplayPrefix+shellRestore) {
		t.Fatalf("shell replay = %q, want keyboard reset %q after the prefix", got, shellRestore)
	}
	attach.Reset()

	if err := server.selectWindow("@1"); err != nil {
		t.Fatal(err)
	}
	waitForTestAttachWrites(t, server)
	agentRestore := kittyKeyboardResetSequence + "\x1b[>5u" +
		"\x1b[?1049h" + kittyKeyboardResetSequence + "\x1b[?1049l\x1b[>4;2m"
	got := attach.String()
	if !strings.Contains(got, activeWindowReplayPrefix+agentRestore) {
		t.Fatalf("agent replay = %q, want keyboard restore %q after the prefix", got, agentRestore)
	}
	// The retained history's own push must not stack a second level.
	if count := strings.Count(got, "\x1b[>5u"); count != 1 {
		t.Fatalf("agent replay pushes kitty flags %d times, want once: %q", count, got)
	}
	if !strings.Contains(got, "agent") {
		t.Fatalf("agent replay = %q, want retained history", got)
	}
}

func TestReplayLeavesKeyboardModesAloneUntilAWindowUsesThem(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@1", []byte("\x1b[<u\x1b[>4;0mshell"))
	waitForTestAttachWrites(t, server)
	attach.Reset()
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); strings.Contains(got, kittyKeyboardResetSequence) ||
		strings.Contains(got, "\x1b[>4;") {
		t.Fatalf("replay = %q, want no keyboard mode sequences", got)
	}
}
