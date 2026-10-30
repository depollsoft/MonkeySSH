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

func TestVTKittyDirectPlacementIsAnchoredToItsCell(t *testing.T) {
	s := newTerminalScreen(40, 10)
	s.Write([]byte("\x1b_Ga=t,f=100,i=1,q=2;AAAA\x1b\\" + vtKittyPlaceAt))
	assertVTKittyPlaced(t, s, "1/1@4,2")

	// Only a placement at a cell is followed: a virtual or relative one, a
	// store-only transmission, a command naming no image or both an id and
	// a number, and an image the client has to give an id of its own are
	// not.
	s.Write([]byte(
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
	s.Write([]byte(vtKittyPlaceAt + "\x1b[8;1H\x1b_Ga=p,i=1,p=1,C=1\x1b\\"))
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
	for i := 1; i <= vtKittyPlacementLimit+3; i++ {
		s.Write([]byte(fmt.Sprintf("\x1b_Ga=p,i=%d,C=1\x1b\\", i)))
	}
	if len(s.kittyDirect) != vtKittyPlacementLimit || s.kittyDirect[0].imageID != "4" {
		t.Fatalf("kept %d placements from image %s", len(s.kittyDirect), s.kittyDirect[0].imageID)
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
	s.Write([]byte("\x1b[2;3H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[4;1H\n\n"))
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
	s.Write([]byte("\x1b[2;1H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[6;1H\x1b_Ga=p,i=2,C=1\x1b\\" +
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
			s.Write([]byte("\x1b[?1049h" + tc.stream))
			assertVTKittyPlaced(t, s, tc.want...)
		})
	}
}

func TestVTKittyDirectPlacementFollowsInsertedAndDeletedLines(t *testing.T) {
	setup := func() *terminalScreen {
		s := newTerminalScreen(20, 8)
		s.Write([]byte("\x1b[2;8r\x1b[4;3H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[7;3H\x1b_Ga=p,i=2,C=1\x1b\\"))
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
	s.Write([]byte("\x1b[2;6H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[2;3H\x1b[2@"))
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
	s.Write([]byte("text\x1b[2;3H\x1b_Ga=p,i=1,C=1\x1b\\" +
		"\x1b[2J\x1b[K\x1b[2;1H\x1b[2K\x1b[5X\x1b[1J\x1b[J"))
	assertVTKittyPlaced(t, s, "1/@1,2")
	// Clearing at a prompt keeps the screen as history, placement and all.
	s.Write([]byte("\x1b[3;1H\x1b]133;A\x07$ \x1b[2J"))
	assertVTKittyPlaced(t, s, "1/@-2,2")
}

func TestVTKittyDirectPlacementDeletesMatchTheClient(t *testing.T) {
	setup := func() *terminalScreen {
		s := newTerminalScreen(20, 10)
		s.Write([]byte(
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
	s.Write([]byte("\x1b[?1049h\x1b_Ga=p,i=1,C=1\x1b\\\x1b_Ga=d,d=i,i=1\x1b\\"))
	assertVTKittyPlaced(t, s, all...)
}

func TestVTKittyDirectPlacementsGoWithResetsAndScreenClears(t *testing.T) {
	s := newTerminalScreen(20, 4)
	s.Write([]byte("\x1b_Ga=p,i=1,C=1\x1b\\\x1b[?1049h\x1b[2;2H\x1b_Ga=p,i=2,C=1\x1b\\"))
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

func TestVTKittyPlacementMovesTheCursorPastAKnownSpan(t *testing.T) {
	s := newTerminalScreen(20, 6)
	s.Write([]byte("\x1b[2;3H\x1b_Ga=p,i=1,c=4,r=2\x1b\\"))
	if row, col := s.CursorPosition(); row != 2 || col != 6 {
		t.Fatalf("cursor at %d,%d after a 4x2 image, want 2,6", row, col)
	}
	// Past the right edge it wraps to the start of the next row.
	s.Write([]byte("\x1b[2;18H\x1b_Ga=T,f=100,i=2,c=4,r=1;AAAA\x1b\\"))
	if row, col := s.CursorPosition(); row != 2 || col != 0 {
		t.Fatalf("cursor at %d,%d after wrapping, want 2,0", row, col)
	}
	// At the bottom it scrolls, taking the placement with it.
	s.Write([]byte("\x1b[6;1H\x1b_Ga=p,i=3,c=1,r=3\x1b\\"))
	if row, col := s.CursorPosition(); row != 5 || col != 1 {
		t.Fatalf("cursor at %d,%d at the bottom, want 5,1", row, col)
	}
	assertVTKittyPlaced(t, s, "1/@-1,2", "2/@-1,17", "3/@3,0")
	// C=1 keeps it, and an image sized by its pixels moves it by an amount
	// the model cannot know, so the model leaves it.
	s.Write([]byte("\x1b[1;1H\x1b_Ga=p,i=4,c=4,r=2,C=1\x1b\\\x1b_Ga=p,i=4,c=4\x1b\\"))
	if row, col := s.CursorPosition(); row != 0 || col != 0 {
		t.Fatalf("cursor at %d,%d, want 0,0", row, col)
	}
}

func TestVTKittyDirectPlacementReflowsWithItsCell(t *testing.T) {
	s := newTerminalScreen(10, 4)
	// "0123456789ABCDE" wraps after 9; the placement is on C, the 13th cell.
	s.Write([]byte("0123456789ABCDE\x1b[2;3H\x1b_Ga=p,i=1,C=1\x1b\\\x1b[4;1H"))
	assertVTKittyPlaced(t, s, "1/@1,2")
	s.Resize(20, 4)
	assertVTKittyPlaced(t, s, "1/@0,12")
	// Three rows of five, with the cell the third of the last, and the two
	// rows above it pushed into the scrollback by the rows below.
	s.Resize(5, 4)
	assertVTKittyPlaced(t, s, "1/@0,2")
	// The scrollback reflows too: five rows of three put the cell first in
	// the last, at the top of the screen again.
	s.Write([]byte("\x1b[?1049h\x1b[1;5H\x1b_Ga=p,i=2,C=1\x1b\\"))
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
		s.Write([]byte("\x1b[?1049h" +
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
	s.Write([]byte("\x1b_Ga=p,i=1,C=1\x1b\\"))
	clone := s.Clone()
	clone.Write([]byte("\x1b_Ga=p,i=2,C=1\x1b\\\x1b[1;1H\x1b[1L"))
	assertVTKittyPlaced(t, s, "1/@0,0")
	assertVTKittyPlaced(t, clone, "1/@1,0", "2/@1,0")
}
