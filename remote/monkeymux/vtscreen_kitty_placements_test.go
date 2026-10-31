package main

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// vtKittyPlaced lists the direct placements the model follows, oldest
// first, as "image/placement@row,col", with an "alt:" prefix on the
// alternate screen.
func vtKittyPlaced(s *terminalScreen) []string {
	var placed []string
	for _, p := range s.kittyDirect {
		screen := ""
		if p.alt {
			screen = "alt:"
		}
		placed = append(placed, fmt.Sprintf("%s%s/%s@%d,%d", screen, p.imageID, p.placementID, p.row, p.col))
	}
	return placed
}

func assertVTKittyPlaced(t *testing.T, s *terminalScreen, want ...string) {
	t.Helper()
	if got := vtKittyPlaced(s); !reflect.DeepEqual(got, want) && (len(got) != 0 || len(want) != 0) {
		t.Fatalf("placements = %q, want %q", got, want)
	}
}

const vtKittyPlaceAt = "\x1b[5;3H\x1b_Ga=p,i=1,p=1,c=8,r=3,C=1,q=2\x1b\\"

// vtKittyUploads transmits images store-only, on the screen shown, so that
// display commands can place them.
func vtKittyUploads(ids ...int) string {
	var out strings.Builder
	for _, id := range ids {
		fmt.Fprintf(&out, "\x1b_Ga=t,f=100,i=%d,q=2;AAAA\x1b\\", id)
	}
	return out.String()
}

func TestVTKittyDirectPlacementIsAnchoredToItsCell(t *testing.T) {
	s := newTerminalScreen(40, 10)
	s.Write([]byte("\x1b_Ga=t,f=100,i=1,q=2;AAAA\x1b\\" + vtKittyPlaceAt))
	assertVTKittyPlaced(t, s, "1/1@4,2")

	// Only a placement at a cell is followed: a virtual or relative one, a
	// store-only transmission, a command naming no image or both an id and
	// a number, and an image the client has to give an id of its own are
	// not.
	s.Write([]byte(vtKittyUploads(2) +
		"\x1b_Ga=p,U=1,i=2\x1b\\" +
		"\x1b_Ga=p,i=2,p=1,P=1\x1b\\" +
		"\x1b_Ga=t,f=100,i=3;AAAA\x1b\\" +
		"\x1b_Ga=p,C=1\x1b\\" +
		"\x1b_Ga=p,i=2,I=4,C=1\x1b\\" +
		"\x1b_Ga=T,f=100,I=5,C=1;AAAA\x1b\\" +
		"\x1b_Ga=T,f=100,C=1;AAAA\x1b\\" +
		"\x1b_Ga=x,i=2,C=1\x1b\\"))
	assertVTKittyPlaced(t, s, "1/1@4,2")

	// A transmission that displays its image places it at the cursor,
	// unless the client rejects it before looking at the data.
	s.Write([]byte(
		"\x1b[2;7H\x1b_Ga=T,f=100,i=6,C=1;AAAA\x1b\\" +
			"\x1b_Ga=T,t=f,f=100,i=7,C=1;AAAA\x1b\\" +
			"\x1b_Ga=T,i=8,C=1;AAAA\x1b\\" +
			"\x1b_Ga=T,f=24,s=1,v=1,i=9,C=1;AAAA\x1b\\"))
	assertVTKittyPlaced(t, s, "1/1@4,2", "6/@1,6", "9/@1,6")
}

func TestVTKittyDirectPlacementsReplaceAndAccumulateAsInTheClient(t *testing.T) {
	s := newTerminalScreen(40, 10)
	// The same image and placement id move the placement; without one,
	// each command adds another.
	s.Write([]byte(vtKittyUploads(1, 2) + vtKittyPlaceAt + "\x1b[8;1H\x1b_Ga=p,i=1,p=1,C=1\x1b\\"))
	assertVTKittyPlaced(t, s, "1/1@7,0")
	s.Write([]byte("\x1b_Ga=p,i=2,C=1\x1b\\\x1b[H\x1b_Ga=p,i=2,C=1\x1b\\"))
	assertVTKittyPlaced(t, s, "1/1@7,0", "2/@7,0", "2/@0,0")

	// A relative placement with the same ids may replace it; the model
	// cannot tell, so the placement goes.
	s.Write([]byte("\x1b_Ga=p,i=1,p=1,P=9\x1b\\"))
	assertVTKittyPlaced(t, s, "2/@7,0", "2/@0,0")

	// Retransmitting an image takes every placement it has on the screen.
	s.Write([]byte("\x1b_Ga=t,f=100,i=2,q=2;AAAA\x1b\\"))
	assertVTKittyPlaced(t, s)
}

func TestVTKittyDirectPlacementsAreBounded(t *testing.T) {
	s := newTerminalScreen(40, 10)
	s.Write([]byte(vtKittyUploads(1)))
	for i := 1; i <= vtKittyPlacementLimit+3; i++ {
		s.Write([]byte(fmt.Sprintf("\x1b_Ga=p,i=1,p=%d,C=1\x1b\\", i)))
	}
	if len(s.kittyDirect) != vtKittyPlacementLimit || s.kittyDirect[0].placementID != "4" {
		t.Fatalf("kept %d placements from %v", len(s.kittyDirect), vtKittyPlaced(s)[:1])
	}
	// So are the images the model knows the client holds.
	for i := 2; i <= vtKittyImageLimit+3; i++ {
		s.Write([]byte(vtKittyUploads(i)))
	}
	if ids := s.kittyStores[0].ids; len(ids) != vtKittyImageLimit || ids[0] != "4" {
		t.Fatalf("knows %d images from %s", len(ids), ids[0])
	}
	// Only the keys a replay needs are kept, whatever the command carried.
	s.Write([]byte("\x1b_Ga=T,f=100,i=900,c=2,r=1,C=1,q=2;" + strings.Repeat("A", 4096) + "\x1b\\"))
	last := s.kittyDirect[len(s.kittyDirect)-1]
	if got := string(last.command); got != "\x1b_Ga=p,i=900,c=2,r=1,C=1,q=2\x1b\\" {
		t.Fatalf("kept command %q", got)
	}
}

func TestVTKittyDirectPlacementFollowsItsLineIntoTheScrollback(t *testing.T) {
	s := newTerminalScreen(40, 4)
	s.Write([]byte(vtKittyUploads(1) + "\x1b[2;3H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[4;1H\n\n"))
	assertVTKittyPlaced(t, s, "1/@-1,2")
	if strings.Contains(string(s.RenderFrame()), "a=p") {
		t.Fatal("a placement in the scrollback was placed on the screen")
	}
	// A taller screen brings the line back, and the placement with it.
	s.Resize(40, 6)
	assertVTKittyPlaced(t, s, "1/@1,2")
	// A shorter one gives up the blank rows below the cursor first...
	s.Write([]byte("\x1b[3;1H"))
	s.Resize(40, 4)
	assertVTKittyPlaced(t, s, "1/@1,2")
	// ...and then scrolls rows into the scrollback.
	s.Write([]byte("\x1b[4;1H"))
	s.Resize(40, 3)
	assertVTKittyPlaced(t, s, "1/@0,2")
	s.Resize(40, 4)
	s.Write([]byte("\x1b[4;1H\n\n\n"))
	assertVTKittyPlaced(t, s, "1/@-2,2")
	// It goes once its line leaves the scrollback, or the scrollback goes.
	clone := s.Clone()
	clone.Write([]byte(strings.Repeat("\n", vtScrollbackLimit)))
	assertVTKittyPlaced(t, clone)
	s.Write([]byte("\x1b[3J"))
	assertVTKittyPlaced(t, s)

	// A region whose top margin is the first row feeds the scrollback, and
	// the rows below it stay.
	s = newTerminalScreen(40, 6)
	s.Write([]byte(vtKittyUploads(1, 2) + "\x1b[2;1H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[6;1H\x1b_Ga=p,i=2,C=1\x1b\\" +
		"\x1b[1;4r\x1b[4;1H\n"))
	assertVTKittyPlaced(t, s, "1/@0,0", "2/@5,0")
}

func TestVTKittyDirectPlacementFollowsRegionScrollsAsKitty(t *testing.T) {
	for _, tc := range []struct {
		name   string
		stream string
		want   []string
	}{
		{
			// Inside the region it scrolls with the text.
			name:   "inside",
			stream: "\x1b[3;8r\x1b[5;2H\x1b_Ga=p,i=1,c=2,r=2,C=1\x1b\\\x1b[8;1H\n",
			want:   []string{"alt:1/@3,1"},
		},
		{
			// Reaching past the bottom margin it stays put.
			name:   "past the margin",
			stream: "\x1b[3;8r\x1b[7;2H\x1b_Ga=p,i=1,c=2,r=4,C=1\x1b\\\x1b[8;1H\n",
			want:   []string{"alt:1/@6,1"},
		},
		{
			// Scrolling partly out of the region, the client crops it to
			// pixels the model does not know.
			name:   "cropped",
			stream: "\x1b[3;8r\x1b[3;2H\x1b_Ga=p,i=1,c=2,r=2,C=1\x1b\\\x1b[8;1H\n",
			want:   nil,
		},
		{
			// Whether one sized by its image reaches past a margin depends
			// on the pixels.
			name:   "sized by the image",
			stream: "\x1b[3;8r\x1b[5;2H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[8;1H\n",
			want:   nil,
		},
		{
			// A region spanning the screen has no margin to reach past.
			name:   "whole screen",
			stream: "\x1b[5;2H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[10;1H\n\n",
			want:   []string{"alt:1/@2,1"},
		},
		{
			name:   "scrolled off the top",
			stream: "\x1b[2;2H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[10;1H\n\n",
			want:   nil,
		},
		{
			// Scrolling down moves it down, and out of the region it goes.
			name:   "down",
			stream: "\x1b[3;8r\x1b[4;2H\x1b_Ga=p,i=1,c=1,r=1,C=1\x1b\\\x1b[3;1H\x1bM\x1b[2T",
			want:   []string{"alt:1/@6,1"},
		},
		{
			name:   "down and out",
			stream: "\x1b[3;8r\x1b[7;2H\x1b_Ga=p,i=1,c=1,r=1,C=1\x1b\\\x1b[3;1H\x1b[2T",
			want:   nil,
		},
		{
			name:   "outside the region",
			stream: "\x1b[3;8r\x1b[2;2H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[9;2H\x1b_Ga=p,i=2,C=1\x1b\\\x1b[8;1H\n\x1b[3;1H\x1bM",
			want:   []string{"alt:1/@1,1", "alt:2/@8,1"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTerminalScreen(20, 10)
			s.Write([]byte("\x1b[?1049h" + vtKittyUploads(1, 2) + tc.stream))
			assertVTKittyPlaced(t, s, tc.want...)
		})
	}
}

func TestVTKittyDirectPlacementFollowsInsertedAndDeletedLines(t *testing.T) {
	setup := func() *terminalScreen {
		s := newTerminalScreen(20, 8)
		s.Write([]byte(vtKittyUploads(1, 2) + "\x1b[2;8r\x1b[4;3H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[7;3H\x1b_Ga=p,i=2,C=1\x1b\\"))
		return s
	}
	for _, tc := range []struct {
		name, stream string
		want         []string
	}{
		// Lines move with their placements, whatever the placement covers,
		// and a line pushed out of the region takes its placement with it.
		{"insert above", "\x1b[3;1H\x1b[1L", []string{"1/@4,2", "2/@7,2"}},
		{"insert pushing out", "\x1b[3;1H\x1b[2L", []string{"1/@5,2"}},
		{"delete above", "\x1b[2;1H\x1b[1M", []string{"1/@2,2", "2/@5,2"}},
		{"delete the line", "\x1b[4;1H\x1b[1M", []string{"2/@5,2"}},
		{"insert below", "\x1b[5;1H\x1b[1L", []string{"1/@3,2", "2/@7,2"}},
		{"outside the region", "\x1b[1;1H\x1b[3M", []string{"1/@3,2", "2/@6,2"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := setup()
			s.Write([]byte(tc.stream))
			assertVTKittyPlaced(t, s, tc.want...)
		})
	}
}

func TestVTKittyDirectPlacementFollowsInsertedAndDeletedCells(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte(vtKittyUploads(1) + "\x1b[2;6H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[2;3H\x1b[2@"))
	assertVTKittyPlaced(t, s, "1/@1,7")
	s.Write([]byte("\x1b[2;2H\x1b[3P"))
	assertVTKittyPlaced(t, s, "1/@1,4")
	// Insert mode pushes it right as each glyph goes in.
	s.Write([]byte("\x1b[4h\x1b[2;1Hab\x1b[4l"))
	assertVTKittyPlaced(t, s, "1/@1,6")
	// Deleting its cell, or pushing it off the end of the row, removes it.
	clone := s.Clone()
	clone.Write([]byte("\x1b[2;7H\x1b[P"))
	assertVTKittyPlaced(t, clone)
	s.Write([]byte("\x1b[2;1H\x1b[14@"))
	assertVTKittyPlaced(t, s)
}

func TestVTKittyDirectPlacementSurvivesErases(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte(vtKittyUploads(1) + "text\x1b[2;3H\x1b_Ga=p,i=1,C=1\x1b\\" +
		"\x1b[2J\x1b[K\x1b[2;1H\x1b[2K\x1b[5X\x1b[1J\x1b[J"))
	assertVTKittyPlaced(t, s, "1/@1,2")
	// Clearing at a prompt keeps the screen as history, placement and all.
	s.Write([]byte("\x1b[3;1H\x1b]133;A\x07$ \x1b[2J"))
	assertVTKittyPlaced(t, s, "1/@-2,2")
}

func TestVTKittyDirectPlacementDeletesMatchTheClient(t *testing.T) {
	setup := func() *terminalScreen {
		s := newTerminalScreen(20, 10)
		s.Write([]byte(vtKittyUploads(1, 2, 3) +
			"\x1b[2;3H\x1b_Ga=p,i=1,p=1,c=2,r=2,C=1\x1b\\" +
			"\x1b[5;6H\x1b_Ga=p,i=1,p=2,c=1,r=1,z=-1,C=1\x1b\\" +
			"\x1b[8;9H\x1b_Ga=p,i=2,c=3,r=1,z=5,C=1\x1b\\" +
			"\x1b[1;15H\x1b_Ga=p,i=3,C=1\x1b\\"))
		return s
	}
	all := []string{"1/1@1,2", "1/2@4,5", "2/@7,8", "3/@0,14"}
	for _, tc := range []struct {
		name, command string
		left          []string
	}{
		{"by image", "a=d,d=i,i=1", []string{"2/@7,8", "3/@0,14"}},
		{"by image and placement", "a=d,d=I,i=1,p=2", []string{"1/1@1,2", "2/@7,8", "3/@0,14"}},
		{"by number", "a=d,d=n,I=1", all},
		{"by id range", "a=d,d=r,x=2,y=3", []string{"1/1@1,2", "1/2@4,5"}},
		{"by z-index", "a=d,d=z,z=5", []string{"1/1@1,2", "1/2@4,5", "3/@0,14"}},
		{"by z-index absent", "a=d,d=z", all},
		{"all on screen", "a=d", nil},
		{"at the cursor", "a=d,d=c", []string{"1/2@4,5", "2/@7,8", "3/@0,14"}},
		{"at a cell", "a=d,d=p,x=4,y=3", []string{"1/2@4,5", "2/@7,8", "3/@0,14"}},
		{"at a cell beside it", "a=d,d=P,x=5,y=3", all},
		{"at a cell and z-index", "a=d,d=q,x=6,y=5,z=-1", []string{"1/1@1,2", "2/@7,8", "3/@0,14"}},
		{"at a cell, other z-index", "a=d,d=q,x=6,y=5,z=0", all},
		{"in a column", "a=d,d=x,x=11", []string{"1/1@1,2", "1/2@4,5", "3/@0,14"}},
		// Sized by its image, a placement may reach any row below it.
		{"in a row", "a=d,d=Y,y=8", []string{"1/1@1,2", "1/2@4,5"}},
		{"unknown selector", "a=d,d=w", all},
		{"animation frames", "a=d,d=f", all},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := setup()
			// The cursor sits on the first placement's lower right cell.
			s.Write([]byte("\x1b[3;4H\x1b_G" + tc.command + "\x1b\\"))
			assertVTKittyPlaced(t, s, tc.left...)
		})
	}

	// A delete runs on the screen it was sent on.
	s := setup()
	s.Write([]byte("\x1b[?1049h" + vtKittyUploads(1) + "\x1b_Ga=p,i=1,C=1\x1b\\\x1b_Ga=d,d=i,i=1\x1b\\"))
	assertVTKittyPlaced(t, s, all...)
}

func TestVTKittyDirectPlacementsGoWithResetsAndScreenClears(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte(vtKittyUploads(1) + "\x1b_Ga=p,i=1,C=1\x1b\\\x1b[?1049h" + vtKittyUploads(2, 3) +
		"\x1b[2;2H\x1b_Ga=p,i=2,C=1\x1b\\"))
	assertVTKittyPlaced(t, s, "1/@0,0", "alt:2/@1,1")
	// Leaving with 1049 keeps the alternate screen; entering again clears it.
	s.Write([]byte("\x1b[?1049l"))
	assertVTKittyPlaced(t, s, "1/@0,0", "alt:2/@1,1")
	if frame := string(s.RenderFrame()); strings.Contains(frame, "i=2") {
		t.Fatalf("the main screen's frame placed an alternate-screen image: %q", frame)
	}
	s.Write([]byte("\x1b[?1049h"))
	assertVTKittyPlaced(t, s, "1/@0,0")
	// 1047 clears it on the way out, 47 never.
	s.Write([]byte("\x1b[2;2H\x1b_Ga=p,i=2,C=1\x1b\\\x1b[?1049l\x1b[?47h\x1b[3;3H\x1b_Ga=p,i=3,C=1\x1b\\\x1b[?47l\x1b[?47h"))
	assertVTKittyPlaced(t, s, "1/@0,0", "alt:2/@1,1", "alt:3/@2,2")
	s.Write([]byte("\x1b[?1047l"))
	assertVTKittyPlaced(t, s, "1/@0,0")
	s.Write([]byte("\x1b[?1047h\x1b_Ga=p,i=2,C=1\x1b\\\x1bc"))
	assertVTKittyPlaced(t, s)
}

func TestVTKittyDirectPlacementOfAChunkedTransmission(t *testing.T) {
	s := newTerminalScreen(20, 4)
	// The last chunk displays the image, at the cursor as it is then.
	s.Write([]byte("\x1b_Ga=T,f=100,i=1,C=1,m=1;AAAA\x1b\\\x1b[3;4H\x1b_Gm=1;AAAA\x1b\\"))
	assertVTKittyPlaced(t, s)
	s.Write([]byte("\x1b_Gm=0;AAAA\x1b\\"))
	assertVTKittyPlaced(t, s, "1/@2,3")
	// A cancelled chunk abandons the transmission, and a later chunk
	// continues nothing.
	s.Write([]byte("\x1b_Ga=T,f=100,i=2,C=1,m=1;AAAA\x1b\\\x1b_Gm=1;AA\x18\x1b_Gm=0;AAAA\x1b\\"))
	assertVTKittyPlaced(t, s, "1/@2,3")
	// So does a new command.
	s.Write([]byte("\x1b_Ga=T,f=100,i=3,C=1,m=1;AAAA\x1b\\\x1b_Ga=q,i=4;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\"))
	assertVTKittyPlaced(t, s, "1/@2,3")
}

func TestVTKittyDirectPlacementReflowsWithItsCell(t *testing.T) {
	s := newTerminalScreen(10, 4)
	// "0123456789ABCDE" wraps after 9; the placement is on C, the 13th cell.
	s.Write([]byte(vtKittyUploads(1) + "0123456789ABCDE\x1b[2;3H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[4;1H"))
	assertVTKittyPlaced(t, s, "1/@1,2")
	s.Resize(20, 4)
	assertVTKittyPlaced(t, s, "1/@0,12")
	// Three rows of five, with the cell the third of the last, and the two
	// rows above it pushed into the scrollback by the rows below.
	s.Resize(5, 4)
	assertVTKittyPlaced(t, s, "1/@0,2")
	// The scrollback reflows too: five rows of three put the cell first in
	// the last, at the top of the screen again.
	s.Write([]byte("\x1b[?1049h" + vtKittyUploads(2) + "\x1b[1;5H\x1b_Ga=p,i=2,C=1\x1b\\"))
	s.Resize(3, 4)
	// The alternate screen is cut, and a cell past the edge moves to it.
	assertVTKittyPlaced(t, s, "1/@0,0", "alt:2/@0,3")
	if strings.Contains(string(s.RenderFrame()), "i=2") {
		t.Fatal("a placement past the edge was placed again")
	}
}

func TestVTKittyAltPlacementGoesWithTheRowsAShrinkGivesUp(t *testing.T) {
	setup := func() *terminalScreen {
		s := newTerminalScreen(20, 8)
		s.Write([]byte("\x1b[?1049h" + vtKittyUploads(1, 2, 3, 4) +
			"\x1b[1;1H\x1b_Ga=p,i=1,c=1,r=1,C=1\x1b\\" +
			"\x1b[3;1H\x1b_Ga=p,i=2,c=1,r=2,C=1\x1b\\" +
			"\x1b[3;5H\x1b_Ga=p,i=3,c=1,r=1,C=1\x1b\\" +
			"\x1b[3;9H\x1b_Ga=p,i=4,C=1\x1b\\"))
		return s
	}
	// Rows below the cursor go first, taking what reaches them: image 2
	// reaches row 3, and image 4 is sized by its pixels.
	s := setup()
	s.Write([]byte("\x1b[3;1H"))
	s.Resize(20, 4)
	assertVTKittyPlaced(t, s, "alt:1/@0,0", "alt:2/@2,0", "alt:3/@2,4")
	s = setup()
	s.Write([]byte("\x1b[3;1H"))
	s.Resize(20, 3)
	assertVTKittyPlaced(t, s, "alt:1/@0,0", "alt:3/@2,4")
	// Then rows from the top, with what is anchored there.
	s = setup()
	s.Write([]byte("\x1b[3;1H"))
	s.Resize(20, 2)
	assertVTKittyPlaced(t, s, "alt:3/@1,4")
}

func TestVTKittyDirectPlacementsSurviveAClone(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte(vtKittyUploads(1, 2) + "\x1b_Ga=p,i=1,C=1\x1b\\"))
	clone := s.Clone()
	clone.Write([]byte("\x1b_Ga=p,i=2,C=1\x1b\\\x1b[1;1H\x1b[1L"))
	assertVTKittyPlaced(t, s, "1/@0,0")
	assertVTKittyPlaced(t, clone, "1/@1,0", "2/@1,0")
}

// TestVTKittyFramePlacesImagesAgainAndRestoresTheCursor checks the frame's
// placements land on their cells after the rows are painted, and that the
// frame leaves the cursor, the saved cursor and the modes as it would
// without them.
func TestVTKittyFramePlacesImagesAgainAndRestoresTheCursor(t *testing.T) {
	stream := vtKittyUploads(1) + "\x1b[?6h\x1b[2;9r" + // origin mode inside a region
		"\x1b[2;3Hhello\x1b7\x1b[1;5H\x1b(0q\x1b[4h\x1b[31m" +
		"\x1b[4;3H\x1b_Ga=p,i=1,p=1,c=8,r=3,C=1,q=2\x1b\\\x1b[6;2H"
	s := newTerminalScreen(30, 10)
	s.Write([]byte(stream))
	assertVTKittyPlaced(t, s, "1/1@4,2")

	frame := string(s.RenderFrame())
	place := "\x1b[5;3H\x1b_Ga=p,i=1,p=1,c=8,r=3,C=1,q=2\x1b\\"
	at := strings.Index(frame, place)
	if at < 0 || strings.Count(frame, "a=p") != 1 {
		t.Fatalf("frame does not place the image once on its cell: %q", frame)
	}
	if strings.Contains(frame, "a=d") {
		t.Fatalf("frame deletes placements itself: %q", frame)
	}
	if paint := strings.Index(frame, "hello"); paint > at {
		t.Fatalf("the image was placed before the rows were painted: %q", frame)
	}
	if save := strings.Index(frame, "\x1b7"); save < at {
		t.Fatalf("the image was placed after the saved cursor was staged: %q", frame)
	}

	without := s.Clone()
	without.kittyDirect = nil
	bare := string(without.RenderFrame())
	if strings.Replace(frame, place, "", 1) != bare {
		t.Fatalf("placements changed more than their own commands:\n%q\n%q", frame, bare)
	}
	painted := func(frame string) *terminalScreen {
		c := newTerminalScreen(30, 10)
		// A replay sends the image before the frame.
		c.Write([]byte(activeWindowReplayPrefix + vtKittyUploads(1) + frame))
		return c
	}
	a, b := painted(frame), painted(bare)
	ar, ac := a.CursorPosition()
	br, bc := b.CursorPosition()
	if ar != br || ac != bc || a.grid().pendingWrap != b.grid().pendingWrap {
		t.Fatalf("cursor %d,%d with placements, %d,%d without", ar, ac, br, bc)
	}
	if !reflect.DeepEqual(a.savedMain, b.savedMain) || a.originMode != b.originMode ||
		a.insertMode != b.insertMode || a.top != b.top || a.bottom != b.bottom ||
		a.attrs != b.attrs || a.g0Graphics != b.g0Graphics {
		t.Fatal("placements changed the state the frame restores")
	}
	if !reflect.DeepEqual(a.TextRows(), s.TextRows()) {
		t.Fatalf("frame painted %q, want %q", a.TextRows(), s.TextRows())
	}
	// The painted model follows the placement as the client would.
	assertVTKittyPlaced(t, a, "1/1@4,2")
}

func TestVTKittyMainScreenFramePlacesItsImagesBehindTheAlternateScreen(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte(vtKittyUploads(1) + "\x1b[2;2H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[?1049h" +
		vtKittyUploads(2) + "\x1b[3;3H\x1b_Ga=p,i=2,C=1\x1b\\"))
	main := string(s.RenderMainScreen())
	if !strings.Contains(main, "\x1b[2;2H\x1b_Ga=p,i=1,C=1,q=2\x1b\\") || strings.Contains(main, "i=2") {
		t.Fatalf("main screen frame = %q", main)
	}
	alt := string(s.RenderFrame())
	if !strings.Contains(alt, "\x1b[3;3H\x1b_Ga=p,i=2,C=1,q=2\x1b\\") || strings.Contains(alt, "i=1") {
		t.Fatalf("alternate screen frame = %q", alt)
	}
	if ids := s.KittyPlacementImageIDs(); !reflect.DeepEqual(ids, []string{"2"}) {
		t.Fatalf("shown screen's placement images = %v", ids)
	}
	if ids := s.KittyPlacementImageIDsOn(false); !reflect.DeepEqual(ids, []string{"1"}) {
		t.Fatalf("main screen's placement images = %v", ids)
	}
	// A frame places again only the images the replay carries.
	if main := string(s.RenderMainScreenReplacing(func(string) bool { return false })); strings.Contains(main, "a=p") {
		t.Fatalf("placed an image the replay does not carry: %q", main)
	}
	// Without placements the frames are what they were.
	s.Write([]byte("\x1bc"))
	if strings.Contains(string(s.RenderFrame()), "\x1b_G") {
		t.Fatal("a frame without placements carries a graphics command")
	}
}

// The client keeps a blank row an image is anchored to through a shrink, as
// if it held text, and scrolls the top row away instead.
func TestVTKittyShrinkKeepsARowAnImageIsAnchoredTo(t *testing.T) {
	s := newTerminalScreen(20, 6)
	s.Write([]byte("a\r\nb\r\nc" +
		"\x1b_Ga=t,f=100,i=1,q=2;AAAA\x1b\\" +
		"\x1b[6;1H\x1b_Ga=p,i=1,p=1,c=2,r=1,C=1,q=2\x1b\\\x1b[3;2H"))
	assertVTKittyPlaced(t, s, "1/1@5,0")

	s.Resize(20, 5)

	if got := s.TextRows(); !reflect.DeepEqual(got, []string{"b", "c", "", "", ""}) {
		t.Fatalf("rows = %q", got)
	}
	if row, _ := s.CursorPosition(); row != 1 {
		t.Fatalf("cursor row %d, want 1", row)
	}
	assertVTKittyPlaced(t, s, "1/1@4,0")
}

// TestVTKittyRecordsOnlyImagesTheClientHolds follows a display command as
// the client runs it: an image it does not hold on the screen shown is
// answered with ENOENT and placed nowhere, so the model records nothing.
func TestVTKittyRecordsOnlyImagesTheClientHolds(t *testing.T) {
	const upload = "\x1b_Ga=t,i=7," + kittyPixelRoot + "\x1b\\"
	const place = "\x1b_Ga=p,i=7,c=2,r=3\x1b\\X"
	const placeAgain = "\x1b_Ga=p,i=7,p=1,C=1\x1b\\\x1b[2;1H\x1b_Ga=p,i=7,p=2,C=1\x1b\\\x1b[H"
	for _, tc := range []struct {
		name, stream string
		placed       []string
	}{
		{"never sent", place, nil},
		{"sent", upload + place, []string{"7/@0,0"}},
		// RIS clears placements but keeps the images (fullReset).
		{"sent before a reset", upload + "\x1bc" + place, []string{"7/@0,0"}},
		// Each screen has its own store; a clear of the alternate screen
		// keeps its images.
		{"sent to the other screen", upload + "\x1b[?1049h" + place, nil},
		{"sent before a clear", "\x1b[?1049h" + upload + "\x1b[?1049l\x1b[?1049h" + place, []string{"alt:7/@0,0"}},
		// Uppercase deletes free the data of an image they leave with no
		// placement (_imageHasPlacements).
		{"freed by id", upload + "\x1b_Ga=d,d=I,i=7\x1b\\" + place, nil},
		{"freed with its placement", upload + "\x1b_Ga=p,i=7,C=1\x1b\\\x1b_Ga=d,d=A\x1b\\" + place, nil},
		{"not placed when all are freed", upload + "\x1b_Ga=d,d=A\x1b\\" + place, []string{"7/@0,0"}},
		{"freed with its last placement", upload + placeAgain + "\x1b_Ga=d,d=I,i=7,p=1\x1b\\\x1b_Ga=d,d=I,i=7,p=2\x1b\\" + place, nil},
		{"kept with a placement left", upload + placeAgain + "\x1b_Ga=d,d=I,i=7,p=1\x1b\\" + place, []string{"7/2@1,0", "7/@0,0"}},
		// One with a virtual placement the model does not follow may still
		// have it, so the model keeps it.
		{"kept with a virtual placement", upload + "\x1b_Ga=p,U=1,i=7,c=2,r=1\x1b\\\x1b_Ga=p,i=7,p=1,C=1\x1b\\\x1b_Ga=d,d=I,i=7,p=1\x1b\\" + place, []string{"7/@0,0"}},
		// Its virtual and relative placements count as placements too.
		{"freed with its virtual placement", upload + "\x1b_Ga=p,U=1,i=7,c=1,r=1,p=1\x1b\\\x1b_Ga=d,d=I,i=7,p=1\x1b\\" + place, nil},
		{"kept by a relative placement", upload + vtKittyUploads(3) + "\x1b_Ga=p,U=1,i=3,c=1,r=1\x1b\\" +
			"\x1b_Ga=p,i=7,p=1,C=1\x1b\\\x1b_Ga=p,i=7,p=2,P=3\x1b\\\x1b_Ga=d,d=I,i=7,p=1\x1b\\" + place, []string{"7/@0,0"}},
		{"freed once its relative placement's parent goes", upload + vtKittyUploads(3) + "\x1b_Ga=p,i=3,p=1,C=1\x1b\\" +
			"\x1b_Ga=p,i=7,p=2,P=3,Q=1\x1b\\\x1b_Ga=p,i=7,p=1,C=1\x1b\\\x1b_Ga=d,d=i,i=3\x1b\\\x1b_Ga=d,d=I,i=7,p=1\x1b\\" + place, nil},
		// A retransmission the client rejects, or abandons, leaves no image.
		{"rejected retransmission", upload + "\x1b_Ga=t,i=7,f=24;AAAA\x1b\\" + place, nil},
		{"abandoned retransmission", upload + "\x1b_Ga=t,i=7,f=32,s=1,v=1,m=1;/wAA\x1b\\\x1b_Ga=q,i=9;AAAA\x1b\\" + place, nil},
		{"cancelled retransmission", upload + "\x1b_Ga=t,i=7,f=32,s=1,v=1,m=1;/wAA\x1b\\\x1b_Gm=1;/w\x18" + place, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := newTerminalScreen(10, 6)
			s.Write([]byte(tc.stream))
			assertVTKittyPlaced(t, s, tc.placed...)
		})
	}
}

// TestVTKittyPlacementLeavesTheCursorUnknown: the client moves its cursor
// past an image it places, by the image's size, unless the image is missing
// or the command says C=1. The model cannot follow either for certain, so
// it keeps its cursor and leaves it unknown.
func TestVTKittyPlacementLeavesTheCursorUnknown(t *testing.T) {
	s := newTerminalScreen(10, 6)
	s.Write([]byte("\x1b[H\x1b_Ga=t,i=7," + kittyPixelRoot + "\x1b\\\x1b_Ga=p,i=7,c=2,r=3\x1b\\"))
	if row, col := s.CursorPosition(); row != 0 || col != 0 {
		t.Fatalf("cursor at %d,%d, want 0,0", row, col)
	}
	if _, ok := s.CursorPositionReport(); ok {
		t.Fatal("the model answers for a cursor the client moved")
	}
	assertVTKittyPlaced(t, s, "7/@0,0")
}

// TestVTKittyReplayCommandNamesKeysInDecimal: the client reads 0x keys as
// numbers, and a replay names them in decimal.
func TestVTKittyReplayCommandNamesKeysInDecimal(t *testing.T) {
	s := newTerminalScreen(10, 6)
	s.Write([]byte("\x1b_Ga=t,i=7," + kittyPixelRoot + "\x1b\\\x1b_Ga=p,i=0x7,c=0x2,r=1,C=1\x1b\\"))
	assertVTKittyPlaced(t, s, "7/@0,0")
	if got := string(s.kittyDirect[0].command); got != "\x1b_Ga=p,i=7,c=2,r=1,C=1,q=2\x1b\\" {
		t.Fatalf("replay command %q", got)
	}
}

// TestVTKittyRetransmissionReplacesPlacementsWhenItCompletes keeps a
// placement until the retransmission of its image ends: until then the
// client still has it, and keeps its row through a shrink.
func TestVTKittyRetransmissionReplacesPlacementsWhenItCompletes(t *testing.T) {
	s := newTerminalScreen(20, 6)
	s.Write([]byte("A\r\nB\x1b_Ga=t,i=1," + kittyPixelRoot + "\x1b\\" +
		"\x1b[6;1H\x1b_Ga=p,i=1,c=2,r=1,C=1\x1b\\\x1b[2;2H" +
		"\x1b_Ga=t,i=1,f=32,s=1,v=1,m=1;/wAA\x1b\\"))
	assertVTKittyPlaced(t, s, "1/@5,0")
	s.Resize(20, 5)
	if got := s.TextRows(); !reflect.DeepEqual(got, []string{"B", "", "", "", ""}) {
		t.Fatalf("rows = %q, want A scrolled away", got)
	}
	assertVTKittyPlaced(t, s, "1/@4,0")
	s.Write([]byte("\x1b_Gm=0;/w==\x1b\\"))
	assertVTKittyPlaced(t, s)
	// The image is the new one, and placing it works.
	s.Write([]byte("\x1b_Ga=p,i=1,C=1\x1b\\"))
	assertVTKittyPlaced(t, s, "1/@0,1")
}

// TestVTKittyPixelOffsetsKeepThePlacementSpan: the client shrinks an image
// by its in-cell offset (X=, Y=) inside the cells c= and r= give it, so the
// offset never reaches another cell, for deletes and region scrolls alike.
func TestVTKittyPixelOffsetsKeepThePlacementSpan(t *testing.T) {
	s := newTerminalScreen(10, 6)
	s.Write([]byte("\x1b_Ga=t,i=42," + kittyPixelRoot + "\x1b\\" +
		"\x1b[3;2H\x1b_Ga=p,i=42,c=2,r=1,X=1,Y=1,C=1\x1b\\" +
		"\x1b_Ga=d,d=x,x=4\x1b\\\x1b_Ga=d,d=y,y=4\x1b\\"))
	assertVTKittyPlaced(t, s, "42/@2,1")
	s.Write([]byte("\x1b_Ga=d,d=x,x=3\x1b\\"))
	assertVTKittyPlaced(t, s)

	// Inside a region the offset does not reach past the bottom margin, so
	// the placement scrolls with the text.
	s = newTerminalScreen(20, 10)
	s.Write([]byte("\x1b[?1049h" + vtKittyUploads(1) +
		"\x1b[3;8r\x1b[7;2H\x1b_Ga=p,i=1,c=2,r=2,Y=5,C=1\x1b\\\x1b[8;1H\n"))
	assertVTKittyPlaced(t, s, "alt:1/@5,1")
}

// TestVTKittyNumbersReadAsTheClientReadsThem: every key is a Dart
// int.tryParse, which takes whitespace, a sign, a 0x prefix and any 64-bit
// value.
func TestVTKittyNumbersReadAsTheClientReadsThem(t *testing.T) {
	for value, want := range map[string]int64{
		" 12": 12, "+5": 5, "0x10": 16, "-3": -3, "007": 7, "4294967295": 4294967295,
	} {
		if got, ok := kittyNumber(value); !ok || got != want {
			t.Fatalf("kittyNumber(%q) = %d, %v; want %d", value, got, ok, want)
		}
	}
	for _, value := range []string{"", "x", "99999999999999999999", "1.5", "--1"} {
		if got, ok := kittyNumber(value); ok {
			t.Fatalf("kittyNumber(%q) = %d, want none", value, got)
		}
	}
	s := newTerminalScreen(10, 6)
	s.Write([]byte("\x1b_Ga=t,i=42," + kittyPixelRoot + "\x1b\\\x1b_Ga=p,i=42,C=1\x1b\\" +
		"\x1b_Ga=d,d=r,x=1,y=4294967295\x1b\\"))
	assertVTKittyPlaced(t, s)
}

// TestVTKittyFreedImageLeavesNoRowToKeep: an image freed with its last,
// virtual, placement is not placed again, so no phantom placement keeps a
// blank row through a shrink that the client gives up.
func TestVTKittyFreedImageLeavesNoRowToKeep(t *testing.T) {
	s := newTerminalScreen(20, 5)
	s.Write([]byte("\x1b_Ga=t,i=1,U=1,c=1,r=1,p=1," + kittyPixelRoot + "\x1b\\" +
		"\x1b_Ga=d,d=I,i=1,p=1\x1b\\\x1b[5;1H\x1b_Ga=p,i=1,C=1\x1b\\" +
		"\x1b[1;1HA\r\nB"))
	assertVTKittyPlaced(t, s)
	s.Resize(20, 4)
	if got := s.TextRows(); !reflect.DeepEqual(got, []string{"A", "B", "", ""}) {
		t.Fatalf("rows = %q", got)
	}
}

// TestVTKittyMainFrameDeletesWhatItsScrollMoves: a frame of the main screen
// that paints its scrollback scrolls the client's screen, which would carry
// the placements the client kept away from their cells, so it deletes all of
// them; one that does not scroll deletes only the images it places again.
func TestVTKittyMainFrameDeletesWhatItsScrollMoves(t *testing.T) {
	s := newTerminalScreen(40, 10)
	s.Write([]byte(vtKittyUploads(1, 2) + "\x1b[2;1H\x1b_Ga=p,i=1,C=1,q=2\x1b\\\x1b[4;1H\x1b_Ga=p,i=2,C=1,q=2\x1b\\"))
	onlyOne := func(id string) bool { return id == "1" }
	if got := string(s.KittyMainPlacementDeletes(onlyOne)); got != "\x1b_Ga=d,d=i,i=1,q=2\x1b\\" {
		t.Fatalf("deletes without scrollback = %q", got)
	}
	s.Write([]byte("\x1b[10;1H\r\n\r\n"))
	if got := string(s.KittyMainPlacementDeletes(onlyOne)); got != kittyVisiblePlacementsDelete {
		t.Fatalf("deletes with scrollback = %q", got)
	}
}

// TestVTKittyCommandsRecordWhereTheyRan: the model remembers each command that
// placed an image at the cursor on the main screen, with an id, a number or
// neither, where in its output it began and ended, however that output was
// split, and the column it ran at; and for a transmission, how to place its
// image again. It forgets those that ended further back than a replay
// reaches.
func TestVTKittyCommandsRecordWhereTheyRan(t *testing.T) {
	stream := "ab\x1b_Ga=T,I=9,f=100,m=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\cd" +
		"\x1b_Ga=t,i=3,f=100;AAAA\x1b\\\x1b_Ga=p,i=3,c=2,C=1\x1b\\" +
		"\x1b[?1049h\x1b_Ga=T,i=4,f=100;AAAA\x1b\\\x1b[?1049l\x1b_Ga=T,U=1,i=5,c=1,r=1,f=100;AAAA\x1b\\"
	first := strings.Index(stream, "\x1b_Ga=T,I=9")
	second := strings.Index(stream, "cd")
	display := strings.Index(stream, "\x1b_Ga=p,i=3")
	for _, read := range []int{len(stream), 1, 7} {
		s := newTerminalScreen(40, 10)
		for at := 0; at < len(stream); at += read {
			s.Write([]byte(stream[at:min(at+read, len(stream))]))
		}
		want := []vtKittyCommand{
			{start: int64(first), end: int64(second), col: 2, transmits: true,
				place: []byte("\x1b_Ga=p,I=9,q=2\x1b\\")},
			// The transmission before it moved the client's cursor, which
			// the model does not follow: its column is lost.
			{start: int64(display), end: int64(display + len("\x1b_Ga=p,i=3,c=2,C=1\x1b\\")), col: -1},
		}
		if !reflect.DeepEqual(s.kittyCommands, want) || s.Written() != int64(len(stream)) {
			t.Fatalf("in reads of %d: commands = %+v, written %d", read, s.kittyCommands, s.Written())
		}
		if command, ok := s.KittyCutCommand(int64(first), int64(first+5)); !ok || command.start != int64(first) {
			t.Fatalf("in reads of %d: the cut inside the transmission finds %+v, %v", read, command, ok)
		}
		if _, ok := s.KittyCutCommand(int64(len(stream)-1), int64(len(stream))); ok {
			t.Fatalf("in reads of %d: a command that ended before the cut was found", read)
		}
	}
	s := newTerminalScreen(40, 10)
	s.Write([]byte(stream + strings.Repeat("x", vtKittyCommandReach) + "\x1b_Ga=p,i=3\x1b\\"))
	if len(s.kittyCommands) != 1 || !s.KittyPlacedImages() {
		t.Fatalf("commands past the reach = %+v", s.kittyCommands)
	}
}
