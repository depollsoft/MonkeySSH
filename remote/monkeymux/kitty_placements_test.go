package main

import (
	"fmt"
	"strings"
	"testing"
)

// kittyReplayFollowUp returns the write a replay of window sends after its
// synchronous part: the remaining images, then the kept placements.
func kittyReplayFollowUp(t *testing.T, window *muxWindow) string {
	t.Helper()
	server := newMuxServerWithSize("test", 80, 24)
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.mu.Lock()
	defer server.mu.Unlock()
	_, followUp := server.replayBytesWithImageFollowUpLocked(window, nil)
	return string(followUp)
}

func kittyPlacementKeys(window *muxWindow) []string {
	var keys []string
	for _, p := range window.kittyPlacements {
		keys = append(keys, p.key())
	}
	return keys
}

const kittyPixelRoot = "f=32,s=1,v=1;/wAA/w=="

func TestKittyRelativePlacementsReplayAfterTheirImages(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1,c=4,r=2\x1b\\" +
			"\x1b_Ga=p,i=2,p=3,P=1,H=1,V=-1,c=1,r=1\x1b\\"))

	if got := kittyPlacementKeys(window); fmt.Sprint(got) != "[1/virtual 2/3]" {
		t.Fatalf("kept placements = %v", got)
	}
	followUp := kittyReplayFollowUp(t, window)
	virtual := strings.Index(followUp, "\x1b_Ga=p,U=1,i=1,c=4,r=2,q=2\x1b\\")
	child := strings.Index(followUp, "\x1b_Ga=p,i=2,p=3,P=1,H=1,V=-1,c=1,r=1,q=2\x1b\\")
	if virtual < 0 || child < virtual {
		t.Fatalf("placements missing or out of order in follow-up: %q", followUp)
	}
	// The child's image comes back, and before the placement that shows it.
	if image := strings.Index(followUp, "i=2,f=32"); image < 0 || image > child {
		t.Fatalf("child image not replayed before its placement: %q", followUp)
	}
}

func TestKittyRelativePlacementsNeedAVirtualRootAndAPlacementID(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			// A physical parent never comes back, so neither does its child.
			"\x1b_Ga=p,i=1,p=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1,Q=1\x1b\\" +
			// Without p= every replay would add a copy.
			"\x1b_Ga=p,U=1,i=1,p=2\x1b\\" +
			"\x1b_Ga=p,i=2,P=1,Q=2\x1b\\" +
			// A virtual relative placement is rejected by the client.
			"\x1b_Ga=p,U=1,i=2,P=1\x1b\\"))

	if got := kittyPlacementKeys(window); fmt.Sprint(got) != "[1/virtual]" {
		t.Fatalf("kept placements = %v", got)
	}
}

func TestKittyRelativePlacementsFollowTheClientChecks(t *testing.T) {
	window := &muxWindow{id: "@1"}
	var stream strings.Builder
	for id := 1; id <= 11; id++ {
		fmt.Fprintf(&stream, "\x1b_Ga=t,i=%d,%s\x1b\\", id, kittyPixelRoot)
	}
	stream.WriteString("\x1b_Ga=p,U=1,i=1\x1b\\")
	// Eight links: images 2..9 each hang off the one before.
	for id := 2; id <= 9; id++ {
		fmt.Fprintf(&stream, "\x1b_Ga=p,i=%d,p=1,P=%d\x1b\\", id, id-1)
	}
	// A ninth link is too deep; a self parent and a cycle are rejected.
	stream.WriteString("\x1b_Ga=p,i=10,p=1,P=9,Q=1\x1b\\")
	stream.WriteString("\x1b_Ga=p,i=2,p=1,P=2,Q=1\x1b\\")
	stream.WriteString("\x1b_Ga=p,i=2,p=1,P=5,Q=1\x1b\\")
	window.observeKittyGraphicsLocked([]byte(stream.String()))

	keys := kittyPlacementKeys(window)
	if len(keys) != 9 || keys[len(keys)-1] != "9/1" {
		t.Fatalf("kept placements = %v", keys)
	}
	for _, p := range window.kittyPlacements {
		if p.imageID == "2" && p.parent != "1/virtual" {
			t.Fatalf("a rejected command replaced placement 2/1: parent %q", p.parent)
		}
	}
}

func TestKittyPlacementsGoWithTheirParents(t *testing.T) {
	setup := func() *muxWindow {
		window := &muxWindow{id: "@1"}
		window.observeKittyGraphicsLocked([]byte(
			"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
				"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
				"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
				"\x1b_Ga=p,U=1,i=1\x1b\\" +
				"\x1b_Ga=p,i=2,p=1,P=1\x1b\\" +
				"\x1b_Ga=p,i=3,p=1,P=2,Q=1\x1b\\"))
		return window
	}
	for name, command := range map[string]string{
		"delete by id":      "\x1b_Ga=d,d=i,i=1\x1b\\",
		"delete by range":   "\x1b_Ga=d,d=r,x=1,y=1\x1b\\",
		"retransmit":        "\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\",
		"physical re-place": "\x1b_Ga=p,i=2,p=1\x1b\\\x1b_Ga=p,i=1,p=9\x1b\\",
		"free the image":    "\x1b_Ga=d,d=I,i=1\x1b\\",
		"free a range":      "\x1b_Ga=d,d=R,x=1,y=2\x1b\\",
	} {
		t.Run(name, func(t *testing.T) {
			window := setup()
			window.observeKittyGraphicsLocked([]byte(command))
			for _, p := range window.kittyPlacements {
				if !p.virtual() {
					t.Fatalf("relative placement %s outlived its parent", p.key())
				}
			}
		})
	}

	// Deleting only the middle placement keeps the virtual root.
	window := setup()
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=i,i=2,p=1\x1b\\"))
	if got := kittyPlacementKeys(window); fmt.Sprint(got) != "[1/virtual]" {
		t.Fatalf("kept placements = %v", got)
	}
}

func TestKittyRelativePlacementFromATransmitAndDisplayRoot(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,U=1,i=1,c=2,r=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=T,i=2,p=4,P=1,H=2,c=1,r=1," + kittyPixelRoot + "\x1b\\"))

	if got := kittyPlacementKeys(window); fmt.Sprint(got) != "[2/4]" {
		t.Fatalf("kept placements = %v", got)
	}
	if got := window.kittyPlacements[0].parent; got != kittyRootPlacementKey("1") {
		t.Fatalf("parent = %q, want the root's own virtual placement", got)
	}
	followUp := kittyReplayFollowUp(t, window)
	if !strings.Contains(followUp, "\x1b_Ga=p,i=2,p=4,P=1,H=2,c=1,r=1,q=2\x1b\\") {
		t.Fatalf("relative a=T not replayed as a=p: %q", followUp)
	}
}

func TestKittyPlacementsOnARootVirtualPlacementGoWithIt(t *testing.T) {
	for name, command := range map[string]string{
		"retransmit":      "\x1b_Ga=T,U=1,i=1,p=5," + kittyPixelRoot + "\x1b\\",
		"delete by id":    "\x1b_Ga=d,d=i,i=1\x1b\\",
		"delete its p":    "\x1b_Ga=d,d=i,i=1,p=5\x1b\\",
		"delete by range": "\x1b_Ga=d,d=r,x=1,y=1\x1b\\",
	} {
		t.Run(name, func(t *testing.T) {
			window := &muxWindow{id: "@1"}
			window.observeKittyGraphicsLocked([]byte(
				"\x1b_Ga=T,U=1,i=1,p=5," + kittyPixelRoot + "\x1b\\" +
					"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
					"\x1b_Ga=p,i=2,p=1,P=1\x1b\\"))
			if len(window.kittyPlacements) != 1 {
				t.Fatalf("kept placements = %v", kittyPlacementKeys(window))
			}
			window.observeKittyGraphicsLocked([]byte(command))
			if len(window.kittyPlacements) != 0 {
				t.Fatalf("kept placements = %v", kittyPlacementKeys(window))
			}
		})
	}

	// A delete naming another placement id leaves the virtual one.
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,U=1,i=1,p=5," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1\x1b\\" +
			"\x1b_Ga=d,d=i,i=1,p=6\x1b\\"))
	if len(window.kittyPlacements) != 1 {
		t.Fatalf("kept placements = %v", kittyPlacementKeys(window))
	}
}

func TestKittyAlternateScreenPlacementsFollowTheClientClears(t *testing.T) {
	window := &muxWindow{id: "@1", privateModes: map[string]bool{"1049": true}}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b[?1049h" +
			"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1\x1b\\"))
	if got := len(window.kittyPlacements); got != 2 {
		t.Fatalf("kept %d placements on the alternate screen", got)
	}

	// Main-screen output replays none of them.
	window.privateModes["1049"] = false
	if followUp := kittyReplayFollowUp(t, window); strings.Contains(followUp, "a=p") {
		t.Fatalf("alternate-screen placements replayed on the main screen: %q", followUp)
	}
	// Leaving the alternate screen clears its relative placements on the
	// client; its virtual placements survive.
	window.observeKittyGraphicsLocked([]byte("\x1b[?1049l"))
	if got := kittyPlacementKeys(window); fmt.Sprint(got) != "[1/virtual]" {
		t.Fatalf("kept placements = %v", got)
	}
}

func TestKittyDeleteKeepsAnImageWhoseNamedPlacementIsMissing(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=5," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=6," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=7," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=d,d=I,i=5,p=9\x1b\\" +
			"\x1b_Ga=d,d=R,x=6,y=6\x1b\\" +
			"\x1b_Ga=d,d=R,x=9,y=7\x1b\\"))

	if _, ok := window.kittyImages["5"]; !ok {
		t.Fatal("d=I with a placement id freed the retained image")
	}
	if _, ok := window.kittyImages["6"]; ok {
		t.Fatal("d=R did not free the image in its range")
	}
	if _, ok := window.kittyImages["7"]; !ok {
		t.Fatal("an empty d=R range freed an image")
	}
}

func TestKittyTransientImagesAreEvictedFirst(t *testing.T) {
	window := &muxWindow{id: "@1"}
	var stream strings.Builder
	stream.WriteString("\x1b_Ga=t,i=1,N=1," + kittyPixelRoot + "\x1b\\")
	for id := 2; id <= maxRetainedKittyImages; id++ {
		fmt.Fprintf(&stream, "\x1b_Ga=t,i=%d,%s\x1b\\", id, kittyPixelRoot)
	}
	// The transient image is the most recently touched, but goes first.
	stream.WriteString("\x1b_Ga=a,i=1,s=3\x1b\\")
	window.observeKittyGraphicsLocked([]byte(stream.String()))
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=999," + kittyPixelRoot + "\x1b\\"))

	if _, ok := window.kittyImages["1"]; ok {
		t.Fatal("transient image survived eviction")
	}
	if _, ok := window.kittyImages["2"]; !ok {
		t.Fatal("an older non-transient image was evicted before the transient one")
	}
}

func TestKittyErrorRepliesAreTerminalResponses(t *testing.T) {
	for payload, want := range map[string]bool{
		"Gi=1;OK":                         true,
		"Gi=1;ENOTSUP: graphics disabled": true,
		"Gi=2,p=3;ENOPARENT: parent image not found": true,
		"Gi=2;EINVAL":    true,
		"Gi=2;ERROR":     true,
		"Gi=2;Elsewhere": false,
		"Ga=t,i=2;AAAA":  false,
	} {
		if got := isTerminalResponseKitty([]byte(payload)); got != want {
			t.Fatalf("isTerminalResponseKitty(%q) = %v, want %v", payload, got, want)
		}
	}
}

// kittyPlacementWindow is a window whose screen model shows image 1 through
// Unicode placeholder cells from row 3, column 5 (0-based 2, 4), with a
// virtual placement and image 2 placed relative to it.
func kittyPlacementWindow(t *testing.T, child string) *muxWindow {
	t.Helper()
	window := &muxWindow{id: "@1", screen: newTerminalScreen(80, 24)}
	window.screen.Write([]byte(
		"\x1b[38;5;1m\x1b[3;5H\U0010EEEE\U0010EEEE\x1b[4;5H\U0010EEEE\x1b[m",
	))
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1," + child + "\x1b\\"))
	if len(window.kittyPlacements) != 2 {
		t.Fatalf("kept placements = %v", kittyPlacementKeys(window))
	}
	return window
}

func TestKittyDeletesMatchKeptPlacementsAsTheClientDoes(t *testing.T) {
	// The child sits one column right and one row down of the placeholder
	// origin (2, 4): 0-based row 3, columns 5 and 6, so 1-based y=4, x=6..7.
	for _, tc := range []struct {
		name    string
		command string
		removed bool
	}{
		{"another z-index", "d=z,z=9", false},
		{"its z-index", "d=z,z=3", true},
		{"a cell it covers", "d=p,x=7,y=4", true},
		{"a cell beside it", "d=p,x=8,y=4", false},
		{"a cell and the wrong z", "d=q,x=6,y=4,z=0", false},
		{"a cell and its z", "d=q,x=6,y=4,z=3", true},
		{"its column", "d=x,x=6", true},
		{"another row", "d=y,y=3", false},
		{"everything visible", "d=a", true},
		{"everything visible, freeing", "d=A", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			window := kittyPlacementWindow(t, "H=1,V=1,c=2,r=1,z=3")
			window.observeKittyGraphicsLocked([]byte(
				"\x1b_Ga=d," + tc.command + "\x1b\\"))
			kept := len(window.kittyPlacements) == 2
			if kept == tc.removed {
				t.Fatalf("after %s kept placements = %v", tc.command,
					kittyPlacementKeys(window))
			}
		})
	}

	// The cursor cell, and a child whose root shows no placeholder cell.
	window := kittyPlacementWindow(t, "H=1,V=1")
	window.screen.Write([]byte("\x1b[4;6H"))
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=c\x1b\\"))
	if len(window.kittyPlacements) != 1 {
		t.Fatalf("d=c at the child kept %v", kittyPlacementKeys(window))
	}
	// A root that never showed a placeholder cell leaves its child unplaced
	// on the client, so no position matches it.
	window = kittyPlacementWindow(t, "H=1,V=1")
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=3\x1b\\" +
			"\x1b_Ga=p,i=2,p=5,P=3,c=1,r=1\x1b\\" +
			"\x1b_Ga=d\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual 3/virtual 2/5]" {
		t.Fatalf("d=a kept %s", got)
	}
	// One whose cells may only be in the scrollback could be anywhere:
	// MonkeyMux cannot tell, so it drops the child.
	window = kittyPlacementWindow(t, "H=1,V=1,c=1,r=1")
	window.screen.Write([]byte("\x1b[2J"))
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d\x1b\\"))
	if len(window.kittyPlacements) != 1 {
		t.Fatalf("d=a kept a child it could not place: %v", kittyPlacementKeys(window))
	}
}

// observeKittyChunk feeds chunk through the screen model and the graphics
// tracking in the order handleWindowOutput does.
func observeKittyChunk(window *muxWindow, chunk string) {
	window.snapshotKittyScreenLocked([]byte(chunk))
	window.screen.Write([]byte(chunk))
	window.observeKittyGraphicsLocked([]byte(chunk))
	window.releaseKittyScreenSnapshotLocked()
}

func TestKittyPositionalDeletesSeeTheScreenAtTheCommand(t *testing.T) {
	// The child is at 0-based row 3, column 5: 1-based 4;6.
	window := kittyPlacementWindow(t, "H=1,V=1,c=1,r=1")
	observeKittyChunk(window, "\x1b[H\x1b_Ga=d,d=c\x1b\\\x1b[4;6H")
	if len(window.kittyPlacements) != 2 {
		t.Fatalf("d=c at the home cell removed the child: %v",
			kittyPlacementKeys(window))
	}
	observeKittyChunk(window, "\x1b[4;6H\x1b_Ga=d,d=c\x1b\\\x1b[10;10H")
	if len(window.kittyPlacements) != 1 {
		t.Fatalf("d=c at the child kept it: %v", kittyPlacementKeys(window))
	}

	// Without the screen at the command, MonkeyMux drops what may match.
	window = kittyPlacementWindow(t, "H=1,V=1,c=1,r=1")
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=c\x1b\\x"))
	if len(window.kittyPlacements) != 1 {
		t.Fatalf("an unresolved d=c kept the child: %v", kittyPlacementKeys(window))
	}
}

func TestKittyNaturallySizedPlacementsAreDroppedWhenADeleteMayReachThem(t *testing.T) {
	// Sized by its own pixels the child may span cells to the right of and
	// below its first one: 1-based x=8 on its row could be one of them.
	window := kittyPlacementWindow(t, "H=1,V=1")
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=p,x=8,y=4\x1b\\"))
	if len(window.kittyPlacements) != 1 {
		t.Fatalf("a delete that may reach the child kept it: %v",
			kittyPlacementKeys(window))
	}
	// Left of it can never be part of it.
	window = kittyPlacementWindow(t, "H=1,V=1")
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=p,x=5,y=4\x1b\\"))
	if len(window.kittyPlacements) != 2 {
		t.Fatalf("a delete left of the child removed it: %v",
			kittyPlacementKeys(window))
	}
}

func TestKittyScreenSwitchSplitAcrossChunks(t *testing.T) {
	window := &muxWindow{id: "@1", privateModes: map[string]bool{}}
	window.observeKittyGraphicsLocked([]byte("prompt\x1b[?1049"))
	window.privateModes["1049"] = true
	window.observeKittyGraphicsLocked([]byte(
		"h\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1\x1b\\"))
	if len(window.kittyPlacements) != 2 {
		t.Fatalf("kept placements = %v", kittyPlacementKeys(window))
	}
	for _, p := range window.kittyPlacements {
		if !p.alt {
			t.Fatalf("placement %s kept for the main screen", p.key())
		}
	}
}

func TestKittyMissingParentPlacementIsARejection(t *testing.T) {
	window := kittyPlacementWindow(t, "H=1")
	window.observeKittyGraphicsLocked([]byte(
		// Image 3 is stored but has no placement: ENOPARENT.
		"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=3\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual 2/1]" {
		t.Fatalf("kept placements = %s", got)
	}
	// Placed physically, image 3 is a parent the client accepts; no replay
	// restores that, so the placement it replaced goes.
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=p,i=3,p=7\x1b\\\x1b_Ga=p,i=2,p=1,P=3,Q=7\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual]" {
		t.Fatalf("kept placements = %s", got)
	}
	// Once that physical placement is deleted by id it is a parent no more.
	window = kittyPlacementWindow(t, "H=1")
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,i=3,p=7\x1b\\\x1b_Ga=d,d=i,i=3\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=3\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual 2/1]" {
		t.Fatalf("kept placements = %s", got)
	}
}

func TestKittyDeletesOnTheOtherScreenKeepPlacements(t *testing.T) {
	window := kittyPlacementWindow(t, "H=1,V=1")
	window.privateModes = map[string]bool{"1049": true}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b[?1049h\x1b_Ga=d,d=i,i=2\x1b\\"))
	if len(window.kittyPlacements) != 2 {
		t.Fatalf("an alternate-screen delete removed main-screen placements: %v",
			kittyPlacementKeys(window))
	}
}

func TestKittyRejectedParentKeepsThePlacement(t *testing.T) {
	window := kittyPlacementWindow(t, "H=1")
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,i=3,p=1,P=2,Q=1\x1b\\" +
			// Image 999 does not exist: the client answers ENOPARENT and
			// keeps placement 2/1, and 3/1 under it.
			"\x1b_Ga=p,i=2,p=1,P=999\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual 2/1 3/1]" {
		t.Fatalf("kept placements = %s", got)
	}
}

func TestKittyReparentedPlacementsReplayParentsFirst(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1\x1b\\" +
			"\x1b_Ga=p,i=3,p=1,P=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=3,Q=1\x1b\\"))

	replay := string(window.kittyPlacementReplayLocked())
	parent := strings.Index(replay, "a=p,i=3,p=1,P=1")
	child := strings.Index(replay, "a=p,i=2,p=1,P=3,Q=1")
	if parent < 0 || child < 0 || child < parent {
		t.Fatalf("reparented child replayed before its parent: %q", replay)
	}
}

func TestKittyPlacementsKeepTheScreenEachCommandRanOn(t *testing.T) {
	// Main-screen placements and the switch to the alternate screen arrive in
	// one chunk: the placements belong to the main screen.
	window := &muxWindow{id: "@1", privateModes: map[string]bool{"1049": true}}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1\x1b\\" +
			"\x1b[?1049h" +
			"\x1b_Ga=p,U=1,i=2\x1b\\"))
	for _, p := range window.kittyPlacements {
		if want := p.imageID == "2" && p.virtual(); p.alt != want {
			t.Fatalf("placement %s kept for alt=%v", p.key(), p.alt)
		}
	}
	// Back on the main screen the client still has them.
	window.privateModes["1049"] = false
	window.observeKittyGraphicsLocked([]byte("\x1b[?1049l"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual 2/1 2/virtual]" {
		t.Fatalf("kept placements = %s", got)
	}
}

func TestKittyReplayCarriesTheVirtualRootOfARelativePlacement(t *testing.T) {
	// Image 1's own transmission makes the virtual root, which has no
	// placeholder cell yet, and four newer images push it out of the
	// recency replay.
	window := &muxWindow{id: "@1"}
	stream := "\x1b_Ga=T,U=1,i=1,c=2,r=1," + kittyPixelRoot + "\x1b\\" +
		"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
		"\x1b_Ga=p,i=2,p=1,P=1,c=1,r=1\x1b\\"
	for id := 3; id <= 6; id++ {
		stream += fmt.Sprintf("\x1b_Ga=t,i=%d,%s\x1b\\", id, kittyPixelRoot)
	}
	window.observeKittyGraphicsLocked([]byte(stream))

	followUp := kittyReplayFollowUp(t, window)
	child := strings.Index(followUp, "a=p,i=2,p=1,P=1")
	root := strings.Index(followUp, "a=t,U=1,i=1")
	if child < 0 {
		t.Fatalf("relative placement not replayed: %q", followUp)
	}
	if root < 0 || root > child {
		t.Fatalf("the virtual root's image does not precede its child: %q", followUp)
	}
}

func TestKittyKeptPlacementsKeepOnlyTheKeysAReplayNeeds(t *testing.T) {
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\"))
	// A display command has no payload, and its control keys are numbers:
	// whatever else it carries is not kept, however large.
	padding := strings.Repeat("A", 1<<20)
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=p,U=1,i=1,c=0002,r=1,q=1;" + padding + "\x1b\\" +
			"\x1b_Ga=p,i=2,p=3,P=1,H=-1,c=1,r=1,junk=" + padding + "\x1b\\"))

	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual 2/3]" {
		t.Fatalf("kept placements = %s", got)
	}
	for _, p := range window.kittyPlacements {
		if len(p.command) > 128 {
			t.Fatalf("placement %s keeps a %d-byte command", p.key(), len(p.command))
		}
	}
	replay := string(window.kittyPlacementReplayLocked())
	want := "\x1b_Ga=p,U=1,i=1,c=2,r=1,q=2\x1b\\" +
		"\x1b_Ga=p,i=2,p=3,P=1,H=-1,c=1,r=1,q=2\x1b\\"
	if replay != want {
		t.Fatalf("replay = %q, want %q", replay, want)
	}
}

func TestKittyDeletedRootVirtualPlacementStaysDeleted(t *testing.T) {
	for _, tc := range []struct{ name, setup, delete string }{
		{"by id", "", "\x1b_Ga=d,d=i,i=1\x1b\\"},
		{"by its placement id", "", "\x1b_Ga=d,d=i,i=1,p=5\x1b\\"},
		{"by range", "", "\x1b_Ga=d,d=r,x=1,y=1\x1b\\"},
		// A display command replaced the root's virtual placement; deleting
		// the replacement leaves the image with none.
		{"after a replacement", "\x1b_Ga=p,U=1,i=1,p=6,c=1,r=1\x1b\\", "\x1b_Ga=d,d=i,i=1,p=6\x1b\\"},
	} {
		for _, alt := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s alt=%v", tc.name, alt), func(t *testing.T) {
				window := &muxWindow{id: "@1", privateModes: map[string]bool{"1049": alt}}
				enter := ""
				if alt {
					enter = "\x1b[?1049h"
				}
				window.observeKittyGraphicsLocked([]byte(enter +
					"\x1b_Ga=T,U=1,i=1,p=5,c=1,r=1," + kittyPixelRoot + "\x1b\\" +
					"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" + tc.setup + tc.delete +
					// The client has no placement of image 1 left to hang
					// this one off, and rejects it.
					"\x1b_Ga=p,i=2,p=1,P=1,c=1,r=1\x1b\\"))

				if got := kittyPlacementKeys(window); len(got) != 0 {
					t.Fatalf("kept placements = %v", got)
				}
				// A reattach must not bring the deleted virtual placement back.
				images, _ := window.kittyImageReplaySelectionLocked(nil)
				replay := string(images) + kittyReplayFollowUp(t, window)
				if strings.Contains(replay, "U=1") || strings.Contains(replay, "a=p") {
					t.Fatalf("replay restores deleted placements: %q", replay)
				}
				if !strings.Contains(replay, "a=t,i=1,") {
					t.Fatalf("replay lost image 1: %q", replay)
				}
			})
		}
	}

	// A delete naming another placement leaves the root's virtual one.
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,U=1,i=1,p=5,c=1,r=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=d,d=i,i=1,p=7\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1,c=1,r=1\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[2/1]" {
		t.Fatalf("kept placements = %s", got)
	}
	if images, _ := window.kittyImageReplaySelectionLocked(nil); !strings.Contains(string(images), "a=t,U=1,i=1,") {
		t.Fatalf("replay lost the root's virtual placement: %q", images)
	}
}

func TestKittyRootVirtualPlacementFollowsTheClient(t *testing.T) {
	// Once a display command replaces the root's virtual placement, the
	// root's placement id names nothing on the client.
	window := &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,U=1,i=1,p=5,c=1,r=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=1,p=6,c=2,r=1\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1,Q=5,c=1,r=1\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[1/virtual]" {
		t.Fatalf("kept placements = %s", got)
	}
	// A virtual placement with a parent is rejected, so its image's own
	// transmission makes none.
	window = &muxWindow{id: "@1"}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=3," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,U=1,i=3,c=1,r=1\x1b\\" +
			"\x1b_Ga=T,U=1,P=3,i=1,c=1,r=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=p,i=2,p=1,P=1,c=1,r=1\x1b\\"))
	if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[3/virtual]" {
		t.Fatalf("kept placements = %s", got)
	}
}

// The client keeps placements per screen. A delete on the alternate screen
// leaves the virtual placement a main-screen image's own transmission made,
// and the placements hanging off it, for the main screen and its replay.
func TestKittyAlternateScreenDeleteKeepsTheMainScreenRoot(t *testing.T) {
	for _, delete := range []string{
		"\x1b_Ga=d,d=i,i=1\x1b\\",
		"\x1b_Ga=d,d=i,i=1,p=5\x1b\\",
		"\x1b_Ga=d,d=r,x=1,y=1\x1b\\",
	} {
		window := &muxWindow{id: "@1", privateModes: map[string]bool{}}
		window.observeKittyGraphicsLocked([]byte(
			"\x1b_Ga=T,U=1,i=1,p=5,c=1,r=1," + kittyPixelRoot + "\x1b\\" +
				"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\" +
				"\x1b_Ga=p,i=2,p=1,P=1,c=1,r=1\x1b\\"))
		window.privateModes["1049"] = true
		window.observeKittyGraphicsLocked([]byte("\x1b[?1049h" + delete))
		window.privateModes["1049"] = false
		window.observeKittyGraphicsLocked([]byte("\x1b[?1049l"))

		if got := fmt.Sprint(kittyPlacementKeys(window)); got != "[2/1]" {
			t.Fatalf("%q: kept placements = %s", delete, got)
		}
		images, _ := window.kittyImageReplaySelectionLocked(nil)
		if !strings.Contains(string(images), "a=t,U=1,i=1,") {
			t.Fatalf("%q: replay lost the root's virtual placement: %q", delete, images)
		}
		if followUp := kittyReplayFollowUp(t, window); !strings.Contains(followUp, "a=p,i=2,p=1,P=1,") {
			t.Fatalf("%q: replay lost the relative placement: %q", delete, followUp)
		}
	}

	// Nor can an alternate-screen placement hang off it: the client has no
	// such parent there.
	window := &muxWindow{id: "@1", privateModes: map[string]bool{}}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,U=1,i=1,c=1,r=1," + kittyPixelRoot + "\x1b\\" +
			"\x1b_Ga=t,i=2," + kittyPixelRoot + "\x1b\\"))
	window.privateModes["1049"] = true
	window.observeKittyGraphicsLocked([]byte("\x1b[?1049h\x1b_Ga=p,i=2,p=1,P=1,c=1,r=1\x1b\\"))
	if got := kittyPlacementKeys(window); len(got) != 0 {
		t.Fatalf("kept placements = %v", got)
	}
}
