package main

import (
	"slices"
	"strings"
)

// Direct Kitty placements in the screen model.
//
// A program places an image directly at the cursor with a=T or a=p, neither
// virtual (U=) nor relative to a parent (P=). The client anchors it to the
// cell under the cursor (a CellAnchor on the line) and it moves with that
// line: through scrolls, line insertions and deletions, the scrollback, and
// the reflow of a width change. It goes when its line goes, and with a
// delete, a retransmission of its image, a reset, or a clear of the
// alternate screen. Erasing the cells under it leaves it in place
// (Buffer._eraseRange preserves the anchors of physical placements).
//
// A frame painted from the model cannot carry the command that made one, so
// the model follows each placement the same way, and RenderFrame and
// RenderMainScreen place again the ones on the screen they paint. Only
// placements of an image with an explicit id (i=) are followed: a frame
// cannot name an image sent by number (I=) or with neither, since the client
// gives those an id of its own. A replay deletes every placement on the
// client's main screen first (activeWindowReplayPrefix), so after a reopen
// such an image is gone from a window replayed from its frame; a shell
// window's history replay places it again.
//
// The client places an image only when the store of the screen it is on
// holds it, and answers ENOENT otherwise. The model follows each screen's
// store (vtKittyStore) only to decide whether to record a placement, and
// cannot follow it exactly: the client evicts images under caps the model
// does not keep (graphics_manager.dart: 128 images awaiting their first
// decode, unplaced ones first, and 256 decoded ones, least used first) and
// drops an image whose data fails to decode. Where it cannot tell, the model
// keeps the image: a replay then places it again with q=2 and C=1, and a
// client that lacks it answers that silently. Nor does the model move its
// cursor past a placed image as the client does; it leaves it unknown
// (endString).

// vtKittyPlacementLimit bounds the direct placements the model follows; the
// oldest goes first.
const vtKittyPlacementLimit = 256

// vtKittyPlacement is a direct placement the client keeps.
type vtKittyPlacement struct {
	imageID     string
	placementID string // the p= key, "" without one
	alt         bool
	// row and col are the cell it is anchored to on its screen. A negative
	// row is a line of the main screen's scrollback, -1 the newest.
	row, col int
	// cols and rows are the cells it covers from there, 0 for a side its
	// image's pixels size (kittyPlacementSpan).
	cols, rows int
	z          int
	// command places it again at the cursor (kittyDirectPlacementReplayCommand).
	command []byte
}

func (p *vtKittyPlacement) span() kittyCellSpan {
	return kittyCellSpan{col: p.col, row: p.row, cols: p.cols, rows: p.rows}
}

// vtKittyChunk is a transmission (m=1) still arriving. The client takes
// the keys of its first chunk and runs the command when the last one
// arrives, at the cursor as it is then.
type vtKittyChunk struct {
	open bool
	args map[string]string
}

// vtKittyImageLimit bounds each set a vtKittyStore keeps; the oldest goes
// first.
const vtKittyImageLimit = 256

// vtKittyStore is what the model knows of the image store the client keeps
// for one screen (each Buffer has its own GraphicsManager): the ids of the
// images it holds, transmitted in full and not freed, which a display
// command can place. untracked lists the images it holds with placements the
// model does not follow, virtual or relative, which keep the image when a
// delete freeing data removes the last placement the model follows.
type vtKittyStore struct {
	ids       vtKittyIDs
	untracked vtKittyIDs
}

// vtKittyIDs is a bounded set of ids, oldest first.
type vtKittyIDs []string

func (ids vtKittyIDs) has(id string) bool {
	for _, known := range ids {
		if known == id {
			return true
		}
	}
	return false
}

func (ids *vtKittyIDs) add(id string) {
	ids.remove(id)
	*ids = append(*ids, id)
	if extra := len(*ids) - vtKittyImageLimit; extra > 0 {
		*ids = append((*ids)[:0], (*ids)[extra:]...)
	}
}

func (ids *vtKittyIDs) remove(id string) {
	ids.removeIf(func(known string) bool { return known == id })
}

func (ids *vtKittyIDs) removeIf(match func(id string) bool) {
	kept := (*ids)[:0]
	for _, id := range *ids {
		if !match(id) {
			kept = append(kept, id)
		}
	}
	*ids = kept
}

func (store vtKittyStore) clone() vtKittyStore {
	return vtKittyStore{
		ids:       append(vtKittyIDs(nil), store.ids...),
		untracked: append(vtKittyIDs(nil), store.untracked...),
	}
}

// kittyStore is the store of the screen shown.
func (s *terminalScreen) kittyStore() *vtKittyStore {
	if s.altActive {
		return &s.kittyStores[1]
	}
	return &s.kittyStores[0]
}

// observeKittyGraphics follows a Kitty graphics command, given the control
// keys of its APC string, for the images the client holds and the direct
// placements it keeps. truncated reports keys past what the parser keeps.
func (s *terminalScreen) observeKittyGraphics(control []byte, truncated bool) {
	if truncated {
		// Whatever it was, it may have ended a transmission, or deleted or
		// replaced anything on this screen. The model forgets the
		// placements: one the client still has is missing after a replay,
		// rather than one it deleted coming back.
		s.kittyChunk = vtKittyChunk{}
		alt := s.altActive
		s.dropKittyPlacements(func(p *vtKittyPlacement) bool { return p.alt == alt })
		return
	}
	args := parseKittyControl(string(control))
	if kittyBareContinuation(args) {
		// A continuation of nothing is ignored (graphicsCommandStart).
		if s.kittyChunk.open && args["m"] != "1" {
			chunk := s.kittyChunk
			s.kittyChunk = vtKittyChunk{}
			s.runKittyGraphics(chunk.args)
		}
		return
	}
	// A new command abandons a transmission still open.
	s.abandonKittyChunk()
	if args["m"] == "1" {
		s.kittyChunk = vtKittyChunk{open: true, args: args}
		return
	}
	s.runKittyGraphics(args)
}

// abandonKittyChunk follows the client dropping a transmission that will
// never complete (_abandonGraphicsTransmission): one of an explicit image id
// replaced that image as it began, so the image and its placements on the
// screen go.
func (s *terminalScreen) abandonKittyChunk() {
	if !s.kittyChunk.open {
		return
	}
	args := s.kittyChunk.args
	s.kittyChunk = vtKittyChunk{}
	action := args["a"]
	imageID := kittyIDValue(args["i"])
	if (action == "" || action == "t" || action == "T") && imageID != "" &&
		!kittyNonZero(args["I"]) {
		s.dropKittyImage(imageID)
	}
}

// runKittyGraphics follows a complete graphics command, as graphicsCommandEnd
// runs it.
func (s *terminalScreen) runKittyGraphics(args map[string]string) {
	if !kittyGraphicsKeysValid(args) ||
		(kittyNonZero(args["i"]) && kittyNonZero(args["I"])) {
		// The client rejects the command outright, as Kitty does.
		return
	}
	action := args["a"]
	if action == "" {
		action = "t"
	}
	imageID := kittyIDValue(args["i"])
	store := s.kittyStore()
	virtual, relative := kittyNonZero(args["U"]), kittyNonZero(args["P"])
	switch action {
	case "t", "T":
		accepted := kittyTransmissionAccepted(args)
		if imageID != "" {
			// A retransmission replaces the image and every placement it has
			// on this screen, and one the client rejects leaves no image
			// (replaceImageForRetransmission).
			s.dropKittyImage(imageID)
			if accepted {
				store.ids.add(imageID)
			}
		}
		switch {
		case !accepted || imageID == "":
		case virtual || relative:
			store.untracked.add(imageID)
		case action == "T":
			s.placeKittyImage(args, imageID)
		}
	case "p":
		switch {
		case imageID == "" || !store.ids.has(imageID):
			// An image the model does not follow, or one the client does
			// not hold: it answers ENOENT and places nothing
			// (_placeStoredGraphics).
		case virtual && relative:
			// The client rejects a virtual relative placement.
		case virtual || relative:
			store.untracked.add(imageID)
			// A relative placement replaces one with the same image and
			// placement id when the client accepts it, which depends on a
			// parent the model does not follow.
			if placementID := kittyIDValue(args["p"]); relative && placementID != "" {
				alt := s.altActive
				s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
					return p.alt == alt && p.imageID == imageID && p.placementID == placementID
				})
			}
		default:
			s.placeKittyImage(args, imageID)
		}
	case "d":
		s.deleteKittyPlacements(args)
	}
}

// dropKittyImage follows the client replacing or dropping an image on the
// screen shown: its placements there go, and the store no longer holds it.
func (s *terminalScreen) dropKittyImage(imageID string) {
	alt := s.altActive
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		return p.alt == alt && p.imageID == imageID
	})
	store := s.kittyStore()
	store.ids.remove(imageID)
	store.untracked.remove(imageID)
}

// kittyGraphicsKeysValid applies the checks the client makes of every
// graphics command before running it (kittyGraphicsFlagKeysValid): an
// action, delete selector, medium or compression it does not know rejects
// the command.
func kittyGraphicsKeysValid(args map[string]string) bool {
	known := func(key, values string) bool {
		value := args[key]
		return value == "" || (len(value) == 1 && strings.Contains(values, value))
	}
	return known("a", "tTqpdfac") &&
		known("d", "aAiIcCnNpPqQxXyYzZrRfF") &&
		known("t", "dfts") &&
		known("o", "z")
}

// kittyTransmissionAccepted reports whether the client stores and displays a
// transmission rather than answering it with an error before looking at its
// data (kittyGraphicsTransmissionError): only direct data (t=d) in a format
// it reads, raw pixels with a size, and no side over the limit. The data
// itself the model takes as valid.
func kittyTransmissionAccepted(args map[string]string) bool {
	if medium := args["t"]; medium != "" && medium != "d" {
		return false
	}
	raw := true
	if format := args["f"]; format != "" {
		switch n, ok := kittyNumber(format); {
		case !ok:
			return false
		case n == 100:
			raw = false
		case n != 0 && n != 24 && n != 32:
			return false
		}
	}
	width, height := kittyIntValue(args["s"]), kittyIntValue(args["v"])
	if width > kittyMaxImageDimension || height > kittyMaxImageDimension {
		return false
	}
	return !raw || (width > 0 && height > 0)
}

// kittyMaxImageDimension is the client's limit on either side of an image
// (kittyGraphicsMaxImageDimension).
const kittyMaxImageDimension = 10000

// kittyBareContinuation reports a chunk that only continues a transmission:
// m= and q= are its only keys (_isBareContinuationArgs in the client).
func kittyBareContinuation(args map[string]string) bool {
	if _, ok := args["m"]; !ok {
		return false
	}
	for key := range args {
		if key != "m" && key != "q" {
			return false
		}
	}
	return true
}

// placeKittyImage follows a direct placement of imageID the client makes at
// the cursor.
func (s *terminalScreen) placeKittyImage(args map[string]string, imageID string) {
	g := s.grid()
	placementID := kittyIDValue(args["p"])
	alt := s.altActive
	if placementID != "" {
		// The same image and placement id replace the placement.
		s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
			return p.alt == alt && p.imageID == imageID && p.placementID == placementID
		})
	}
	span := kittyPlacementSpan(
		g.cursorCol, g.cursorRow,
		kittyIntValue(args["c"]), kittyIntValue(args["r"]),
	)
	s.kittyDirect = append(s.kittyDirect, vtKittyPlacement{
		imageID:     imageID,
		placementID: placementID,
		alt:         alt,
		row:         span.row,
		col:         span.col,
		cols:        span.cols,
		rows:        span.rows,
		z:           kittyIntValue(args["z"]),
		command:     kittyDirectPlacementReplayCommand(args),
	})
	if extra := len(s.kittyDirect) - vtKittyPlacementLimit; extra > 0 {
		s.kittyDirect = append(s.kittyDirect[:0], s.kittyDirect[extra:]...)
	}
}

// deleteKittyPlacements applies a delete command (a=d) to the placements on
// the screen it runs on, matching them as the client does (deletePlacements),
// with the matching kitty_placements.go applies to the placements it keeps.
// The model follows only placements of explicit image ids, which an image
// number never names, so a delete by number (d=n, or d=i with I= alone)
// matches none of them.
//
// An uppercase selector also frees the data of each image it matched that
// has no placement left (_imageHasPlacements), and with d=I and d=R without
// p= every image it names. Where the model cannot tell, because the image
// may have placements the model does not follow, it keeps the image.
func (s *terminalScreen) deleteKittyPlacements(args map[string]string) {
	selector := kittyDeleteSelectorOf(args)
	frees := args["d"] != "" && args["d"] != selector
	store := s.kittyStore()
	imageID := kittyIDValue(args["i"])
	placementID := kittyIDValue(args["p"])
	var match func(p *vtKittyPlacement) bool
	switch selector {
	case "i", "n":
		// Either names the image by its id when it has one, and by its
		// number (I=), which the model does not follow, when not
		// (_deleteGraphics).
		if imageID == "" {
			return
		}
		match = func(p *vtKittyPlacement) bool {
			return p.imageID == imageID && (placementID == "" || p.placementID == placementID)
		}
		if frees && placementID == "" {
			store.ids.remove(imageID)
			store.untracked.remove(imageID)
		}
	case "r":
		first, last := kittyDeleteRange(args)
		inRange := func(id string) bool { return kittyIDInRange(id, first, last) }
		match = func(p *vtKittyPlacement) bool { return inRange(p.imageID) }
		if frees {
			store.ids.removeIf(inRange)
			store.untracked.removeIf(inRange)
		}
	case "z":
		z, ok := kittyDeleteZ(args)
		if !ok {
			return
		}
		match = func(p *vtKittyPlacement) bool { return p.z == z }
	case "a", "c", "p", "q", "x", "y":
		z, hasZ := kittyDeleteZ(args)
		g := s.grid()
		cell := kittyDeleteCellOf(selector, args, g.cursorRow, g.cursorCol)
		match = func(p *vtKittyPlacement) bool {
			if selector == "q" && (!hasZ || p.z != z) {
				return false
			}
			return p.span().deletedBy(selector, cell, s.height)
		}
	default:
		return
	}
	alt := s.altActive
	var matched []string
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if p.alt != alt || !match(p) {
			return false
		}
		matched = append(matched, p.imageID)
		return true
	})
	if !frees || selector == "r" || ((selector == "i" || selector == "n") && placementID == "") {
		return
	}
	// The images it matched placements of go once they have none left.
	for _, id := range matched {
		if !s.kittyImagePlacedOn(id, alt) && !store.untracked.has(id) {
			store.ids.remove(id)
		}
	}
}

// kittyImagePlacedOn reports whether the model follows a placement of
// imageID on a screen.
func (s *terminalScreen) kittyImagePlacedOn(imageID string, alt bool) bool {
	for i := range s.kittyDirect {
		if p := &s.kittyDirect[i]; p.alt == alt && p.imageID == imageID {
			return true
		}
	}
	return false
}

// dropKittyPlacements forgets the placements match selects.
func (s *terminalScreen) dropKittyPlacements(match func(p *vtKittyPlacement) bool) {
	kept := s.kittyDirect[:0]
	for i := range s.kittyDirect {
		if !match(&s.kittyDirect[i]) {
			kept = append(kept, s.kittyDirect[i])
		}
	}
	clear(s.kittyDirect[len(kept):])
	s.kittyDirect = kept
}

// shiftKittyPlacementLines moves the placements anchored to the lines from
// top to bottom of the shown screen by delta rows, as inserting or deleting
// lines moves them in the client (Buffer.insertLines and deleteLines). One
// whose line leaves that range goes with the line.
func (s *terminalScreen) shiftKittyPlacementLines(top, bottom, delta int) {
	if len(s.kittyDirect) == 0 {
		return
	}
	alt := s.altActive
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if p.alt != alt || p.row < top || p.row > bottom {
			return false
		}
		p.row += delta
		return p.row < top || p.row > bottom
	})
}

// scrollKittyPlacementsUp follows scrollRegionUp. A main-screen region at the
// first row feeds the scrollback: its lines, and every line already there,
// move up with their placements as in the client, whose new line goes in
// below the region. Any other region scroll moves its placements as Kitty
// specifies (scrollKittyPlacementRegion).
func (s *terminalScreen) scrollKittyPlacementsUp(top, bottom, n int) {
	if len(s.kittyDirect) == 0 {
		return
	}
	if s.altActive || top != 0 {
		s.scrollKittyPlacementRegion(top, bottom, -n)
		return
	}
	for i := range s.kittyDirect {
		if p := &s.kittyDirect[i]; !p.alt && p.row <= bottom {
			p.row -= n
		}
	}
	s.pruneKittyScrollback()
}

// scrollKittyPlacementRegion moves the placements of a scroll region as the
// client's GraphicsManager.beginRegionScroll and endRegionScroll do: a
// placement inside the region scrolls with the text, one reaching past a
// margin stays where it is, and one scrolled out of the region goes. The
// client crops a placement the scroll leaves partly outside, to the image's
// pixels, which the model does not know, so the model forgets it; it also
// forgets one it cannot tell scrolls, whose image sizes its height. A region
// spanning the screen has no margin for a placement to reach past, and only
// its top edge crops.
func (s *terminalScreen) scrollKittyPlacementRegion(top, bottom, delta int) {
	if len(s.kittyDirect) == 0 {
		return
	}
	margins := top != 0 || bottom != s.height-1
	alt := s.altActive
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if p.alt != alt || p.row < top || p.row > bottom {
			return false
		}
		known := p.rows > 0
		last := p.row + p.rows - 1
		switch {
		case margins && !known:
			return true
		case margins && last > bottom:
			return false
		}
		p.row += delta
		last += delta
		return p.row < top || p.row > bottom || (margins && last > bottom)
	})
}

// shiftKittyPlacementCells moves the placements on the cursor's row from
// column col on by delta columns, as inserting or deleting cells moves the
// client's anchors (BufferLine.insertCells and removeCells): one in deleted
// cells, or pushed off the end of the row, goes.
func (s *terminalScreen) shiftKittyPlacementCells(col, delta int) {
	if len(s.kittyDirect) == 0 || delta == 0 {
		return
	}
	alt, row := s.altActive, s.grid().cursorRow
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if p.alt != alt || p.row != row || p.col < col {
			return false
		}
		if delta < 0 && p.col < col-delta {
			return true
		}
		p.col += delta
		return p.col >= s.width
	})
}

// pruneKittyScrollback forgets the main-screen placements whose lines left
// the scrollback.
func (s *terminalScreen) pruneKittyScrollback() {
	oldest := -s.scrollback.len()
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		return !p.alt && p.row < oldest
	})
}

// dropKittyScrollbackPlacements follows ED 3, which empties the scrollback.
func (s *terminalScreen) dropKittyScrollbackPlacements() {
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		return !p.alt && p.row < 0
	})
}

// dropKittyAltPlacements follows a clear of the alternate screen.
func (s *terminalScreen) dropKittyAltPlacements() {
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool { return p.alt })
}

// kittyMainRowsResized follows resizeMainRows from the main grid's row count
// and cursor row before it. Growing brought lines back from the scrollback
// above the screen, moving the cursor down by as many, or added rows below,
// leaving the cursor where it was. Shrinking moved the cursor up once for
// each top row it pushed into the scrollback and dropped the rest from the
// bottom, with their placements, as the client pops a line.
func (s *terminalScreen) kittyMainRowsResized(oldRows, oldCursorRow int) {
	if len(s.kittyDirect) == 0 {
		return
	}
	g := &s.main
	shift := g.cursorRow - oldCursorRow
	keep := oldRows
	if len(g.rows) < oldRows {
		keep = len(g.rows) - shift
	}
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if p.alt {
			return false
		}
		if p.row >= keep {
			return true
		}
		p.row += shift
		return false
	})
	s.pruneKittyScrollback()
}

// kittyPlacementAnchoredOnMainRow reports whether a direct placement is
// anchored to the main grid's row, which the client then keeps through a
// shrink as if it held text (Buffer._isReclaimableRow).
func (s *terminalScreen) kittyPlacementAnchoredOnMainRow(row int) bool {
	for i := range s.kittyDirect {
		if p := &s.kittyDirect[i]; !p.alt && p.row == row {
			return true
		}
	}
	return false
}

// kittyAltResized follows resizeAlt, which gave up fromTop rows at the top
// and dropped rows at the bottom of oldRows, and cut or grew the rows to
// width. As in the client, a row given up takes every placement that reaches
// it (removePlacementsInRows), and one whose image sizes its height may reach
// any row below it; a placement past the new width moves back to its edge
// (BufferLine.resize).
func (s *terminalScreen) kittyAltResized(oldRows, fromTop, dropped, width int) {
	if len(s.kittyDirect) == 0 {
		return
	}
	firstDropped := oldRows - dropped
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if !p.alt {
			return false
		}
		if p.row < fromTop ||
			(dropped > 0 && (p.rows <= 0 || p.row+p.rows-1 >= firstDropped)) {
			return true
		}
		p.row -= fromTop
		p.col = min(p.col, width)
		return false
	})
}

// anchorKittyPlacements puts the main-screen placements on the lines a
// reflow carries, as anchors: lines holds the scrollback and then the
// screen, which starts at screenStart.
func (s *terminalScreen) anchorKittyPlacements(lines []vtLine, screenStart int) {
	for i := range s.kittyDirect {
		p := &s.kittyDirect[i]
		if p.alt {
			continue
		}
		if line := screenStart + p.row; line >= 0 && line < len(lines) {
			lines[line].anchors = append(lines[line].anchors, vtReflowAnchor{id: i, x: p.col})
		}
	}
}

// reflowedKittyPlacements moves the main-screen placements to where the
// reflow carried their anchors, the screen starting at screenStart of lines.
// A placement whose anchor the reflow dropped goes, as the client's does.
func (s *terminalScreen) reflowedKittyPlacements(lines []vtLine, screenStart int) {
	if len(s.kittyDirect) == 0 {
		return
	}
	placed := make([]bool, len(s.kittyDirect))
	for i, line := range lines {
		for _, anchor := range line.anchors {
			if anchor.id == vtReflowCursorAnchor {
				continue
			}
			p := &s.kittyDirect[anchor.id]
			p.row, p.col = i-screenStart, anchor.x
			placed[anchor.id] = true
		}
	}
	kept := s.kittyDirect[:0]
	for i, p := range s.kittyDirect {
		if p.alt || placed[i] {
			kept = append(kept, p)
		}
	}
	clear(s.kittyDirect[len(kept):])
	s.kittyDirect = kept
	s.pruneKittyScrollback()
}

func (s *terminalScreen) kittyPlacementOnScreen(p *vtKittyPlacement, alt bool) bool {
	return p.alt == alt && p.row >= 0 && p.row < s.height && p.col < s.width
}

// kittyPlacementReplaced reports whether a frame of a screen places p again:
// a placement on that screen, of an image replace accepts (nil accepts any).
func (s *terminalScreen) kittyPlacementReplaced(
	p *vtKittyPlacement,
	alt bool,
	replace func(imageID string) bool,
) bool {
	return s.kittyPlacementOnScreen(p, alt) && (replace == nil || replace(p.imageID))
}

// appendKittyPlacements places the screen's direct placements again, on
// their cells, after a frame painted it: at the cursor moved to each, with
// the cursor kept (C=1) for the frame's final restore. Only the images
// replace accepts are placed (nil accepts any). Placements in the scrollback
// are left out; the replay prefix cleared the client's scrollback, so they do
// not come back.
func (s *terminalScreen) appendKittyPlacements(
	out []byte,
	alt bool,
	replace func(imageID string) bool,
) []byte {
	for i := range s.kittyDirect {
		p := &s.kittyDirect[i]
		if !s.kittyPlacementReplaced(p, alt, replace) {
			continue
		}
		out = appendVTCursorPosition(out, p.row, p.col)
		out = append(out, p.command...)
	}
	return out
}

// KittyPlacementImageIDs returns the images the direct placements on the
// shown screen display, which a replay that paints it must send for them to
// be placed again.
func (s *terminalScreen) KittyPlacementImageIDs() []string {
	if s == nil {
		return nil
	}
	return s.KittyPlacementImageIDsOn(s.altActive)
}

// KittyPlacementImageIDsOn is KittyPlacementImageIDs for the main screen or
// the alternate one, shown or not.
func (s *terminalScreen) KittyPlacementImageIDsOn(alt bool) []string {
	if s == nil {
		return nil
	}
	var ids []string
	for i := range s.kittyDirect {
		if p := &s.kittyDirect[i]; s.kittyPlacementOnScreen(p, alt) && !slices.Contains(ids, p.imageID) {
			ids = append(ids, p.imageID)
		}
	}
	return ids
}
