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
		"delete by id":       "\x1b_Ga=d,d=i,i=1\x1b\\",
		"delete by range":    "\x1b_Ga=d,d=r,x=1,y=1\x1b\\",
		"retransmit":         "\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\",
		"physical re-place":  "\x1b_Ga=p,i=2,p=1\x1b\\\x1b_Ga=p,i=1,p=9\x1b\\",
		"positional delete":  "\x1b_Ga=d,d=p,x=1,y=1\x1b\\",
		"free the image":     "\x1b_Ga=d,d=I,i=1\x1b\\",
		"free a range":       "\x1b_Ga=d,d=R,x=1,y=2\x1b\\",
		"delete all visible": "\x1b_Ga=d\x1b\\",
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
	window.observeKittyGraphicsLocked([]byte("x"))
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
