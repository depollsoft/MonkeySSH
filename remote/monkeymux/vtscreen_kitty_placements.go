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
// gives those an id of its own. A client reopened on the window it showed
// keeps what it holds (activeWindowReplayPrefix leaves physical placements),
// unless a replay of the window's output deletes it to place its images
// again (kittyVisiblePlacementsDelete); a replay of another window makes the app
// delete them first, from the window it names (monkeyMuxReplayWindowOSC).
//
// The client places an image only when the store of the screen it is on
// holds it, and answers ENOENT otherwise. The model follows each screen's
// store (vtKittyStore) only to decide whether to record a placement, and
// cannot follow it exactly: the client evicts images under caps the model
// does not keep (graphics_manager.dart: 128 images awaiting their first
// decode, unplaced ones first, and 256 decoded ones, least used first) and
// drops an image whose data fails to decode. Where it cannot tell, the model
// keeps the image: a replay then places it again with q=2 and C=1, and a
// client that lacks it answers that silently, though such a placement also
// keeps its blank row through a shrink that the client gives up
// (resizeMainRows). Deletes freeing data it follows as the client does,
// counting the virtual and relative placements it sees. Nor does the model
// move its cursor past a placed image as the client does; it leaves it
// unknown (endString).

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

// vtKittyCommandReach is how far back in its output the model remembers
// commands. A replay carries at most windowReplayLimitBytes of output, so
// only a command that ended within that much can be the one its cut falls
// on (KittyCutCommand); every command takes bytes, so this bounds how many
// the model keeps.
const vtKittyCommandReach = windowReplayLimitBytes

// vtKittyCommand is a command that placed an image at the cursor on the main
// screen (a=T, or a=p, neither virtual nor relative), of an image with an
// id, a number or neither. A shell window's replay carries only the end of
// its output, which can begin among a transmission's later chunks, or just
// after it, and so place nothing; the replay places the image again with the
// command (KittyCutCommand).
type vtKittyCommand struct {
	// start and end are where its first APC string began and its last one
	// ended, as offsets in what the model has read (Written).
	start, end int64
	// col is the cursor's column when it placed the image.
	col int
	// transmits records an image transmission (a=T), and place an a=p that
	// places its image again, moving the cursor past it unless the command
	// kept it where it was (C=1).
	transmits bool
	place     []byte
}

// noteKittyCommand remembers a command that placed an image at the cursor
// on the main screen, which began at start and ends here.
func (s *terminalScreen) noteKittyCommand(args map[string]string, start int64, transmits bool) {
	stale := 0
	for stale < len(s.kittyCommands) && s.kittyCommands[stale].end < s.written-vtKittyCommandReach {
		stale++
	}
	s.kittyCommands = append(s.kittyCommands[:0], s.kittyCommands[stale:]...)
	command := vtKittyCommand{start: start, end: s.written, col: s.grid().cursorCol, transmits: transmits}
	if transmits {
		tail := ",q=2\x1b\\"
		if kittyIntValue(args["C"]) == 1 {
			tail = ",C=1" + tail
		}
		command.place = kittyPlacementCommand(args, tail)
	}
	s.kittyCommands = append(s.kittyCommands, command)
}

// KittyPlacedImages reports whether the output placed an image at the
// cursor on the main screen, which a client showing it may still hold.
func (s *terminalScreen) KittyPlacedImages() bool {
	return s != nil && len(s.kittyCommands) > 0
}

// KittyCutCommand returns the command that a replay of the output from
// carried on leaves out, if the output after it is within the replay's
// reach: the newest command that began before carried, if it ended at or
// after cut, where the replay's limit cut the output. A replay that starts
// with it again paints everything after it. One that ended before cut had
// output after it that the replay leaves out, so its row is above the first
// one the replay paints.
func (s *terminalScreen) KittyCutCommand(cut, carried int64) (vtKittyCommand, bool) {
	if s == nil {
		return vtKittyCommand{}, false
	}
	for i := len(s.kittyCommands) - 1; i >= 0; i-- {
		if command := s.kittyCommands[i]; command.start < carried {
			return command, command.end >= cut
		}
	}
	return vtKittyCommand{}, false
}

// vtKittyChunk is a transmission (m=1) still arriving. The client takes
// the keys of its first chunk and runs the command when the last one
// arrives, at the cursor as it is then.
type vtKittyChunk struct {
	open bool
	args map[string]string
	// start is where its first chunk began (vtKittyCommand).
	start int64
}

// vtKittyImageLimit bounds each set a vtKittyStore keeps; the oldest goes
// first.
const vtKittyImageLimit = 256

// vtKittyStore is what the model knows of the image store the client keeps
// for one screen (each Buffer has its own GraphicsManager): the ids of the
// images it holds, transmitted in full and not freed, which a display
// command can place, and the placements of them the model does not follow
// onto cells: the one virtual placement the client keeps per image
// (setVirtualPlacement) and those relative to a parent (P=). A delete that
// frees data frees an image only once it has no placement of any kind left
// (_imageHasPlacements), so they count for it too.
type vtKittyStore struct {
	ids      vtKittyIDs
	virtual  vtKittyRefs
	relative vtKittyRefs
}

// vtKittyRef is a virtual or relative placement: of imageID, with the
// client's placementID ("" without one); a relative one hangs off an image
// parent and has a z-index, which a delete by z-index matches.
type vtKittyRef struct {
	imageID, placementID string
	parent               string
	z                    int
}

// vtKittyRefs is a bounded list of placements, oldest first.
type vtKittyRefs []vtKittyRef

// keep adds ref to refs, replacing one of the same image (a virtual
// placement) or the same image and placement id, bounded like the ids.
func (refs *vtKittyRefs) keep(ref vtKittyRef, sameImage bool) {
	refs.removeIf(func(r vtKittyRef) bool {
		return r.imageID == ref.imageID &&
			(sameImage || (ref.placementID != "" && r.placementID == ref.placementID))
	})
	*refs = append(*refs, ref)
	if extra := len(*refs) - vtKittyImageLimit; extra > 0 {
		*refs = append((*refs)[:0], (*refs)[extra:]...)
	}
}

func (refs *vtKittyRefs) removeIf(match func(vtKittyRef) bool) (removed []string) {
	kept := (*refs)[:0]
	for _, ref := range *refs {
		if match(ref) {
			removed = append(removed, ref.imageID)
		} else {
			kept = append(kept, ref)
		}
	}
	clear((*refs)[len(kept):])
	*refs = kept
	return removed
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
		ids:      append(vtKittyIDs(nil), store.ids...),
		virtual:  append(vtKittyRefs(nil), store.virtual...),
		relative: append(vtKittyRefs(nil), store.relative...),
	}
}

// forget follows the client dropping imageID's data, which takes its
// virtual and relative placements with it.
func (store *vtKittyStore) forget(imageID string) {
	store.ids.remove(imageID)
	same := func(r vtKittyRef) bool { return r.imageID == imageID }
	store.virtual.removeIf(same)
	store.relative.removeIf(same)
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
			s.runKittyGraphics(chunk.args, chunk.start)
		}
		return
	}
	// A new command abandons a transmission still open.
	s.abandonKittyChunk()
	if args["m"] == "1" {
		s.kittyChunk = vtKittyChunk{open: true, args: args, start: s.kittyAPCStart}
		return
	}
	s.runKittyGraphics(args, s.kittyAPCStart)
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
// runs it; its first APC string began at start.
func (s *terminalScreen) runKittyGraphics(args map[string]string, start int64) {
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
	if !s.altActive && !virtual && !relative &&
		(action == "T" && kittyTransmissionAccepted(args) ||
			action == "p" && (imageID != "" || kittyNonZero(args["I"]))) {
		s.noteKittyCommand(args, start, action == "T")
	}
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
		case virtual && !relative:
			s.keepKittyVirtualPlacement(args, imageID)
		case relative && action == "T":
			s.keepKittyRelativePlacement(args, imageID)
		case !virtual && !relative && action == "T":
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
		case virtual:
			s.keepKittyVirtualPlacement(args, imageID)
		case relative:
			s.keepKittyRelativePlacement(args, imageID)
		default:
			s.placeKittyImage(args, imageID)
		}
	case "d":
		s.deleteKittyPlacements(args)
	}
}

// dropKittyImage follows the client replacing or dropping an image on the
// screen shown: its placements there go, with those relative to them, and
// the store no longer holds it.
func (s *terminalScreen) dropKittyImage(imageID string) {
	alt := s.altActive
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		return p.alt == alt && p.imageID == imageID
	})
	store := s.kittyStore()
	store.forget(imageID)
	store.relative.removeIf(func(r vtKittyRef) bool { return r.parent == imageID })
}

// keepKittyVirtualPlacement follows a virtual placement (U=1) of a held
// image, which the client keeps, one per image, only with a size in cells on
// both sides (setVirtualPlacement).
func (s *terminalScreen) keepKittyVirtualPlacement(args map[string]string, imageID string) {
	if kittyIntValue(args["c"]) <= 0 || kittyIntValue(args["r"]) <= 0 {
		return
	}
	ref := vtKittyRef{imageID: imageID, placementID: kittyIDValue(args["p"])}
	s.kittyStore().virtual.keep(ref, true)
}

// keepKittyRelativePlacement follows a placement of a held image relative to
// a parent (P=). It replaces a placement with the same image and placement
// id, direct ones included, when the client accepts it, which depends on
// the parent: the model takes it as accepted, and counts it only while its
// parent has a placement (kittyImagePlaced).
func (s *terminalScreen) keepKittyRelativePlacement(args map[string]string, imageID string) {
	ref := vtKittyRef{
		imageID:     imageID,
		placementID: kittyIDValue(args["p"]),
		parent:      kittyIDValue(args["P"]),
		z:           kittyIntValue(args["z"]),
	}
	if ref.placementID != "" {
		alt := s.altActive
		s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
			return p.alt == alt && p.imageID == imageID && p.placementID == ref.placementID
		})
	}
	s.kittyStore().relative.keep(ref, false)
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
		// The same image and placement id replace the placement, relative
		// or not (_takePlacementIdForReplacement).
		s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
			return p.alt == alt && p.imageID == imageID && p.placementID == placementID
		})
		s.kittyStore().relative.removeIf(func(r vtKittyRef) bool {
			return r.imageID == imageID && r.placementID == placementID
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
// The virtual and relative placements the store follows go as the client
// matches them: by id, placement id, id range and, relative ones, z-index;
// a delete of all visible placements takes the relative ones, which sit at
// their parents. A delete by a cell is taken to miss them, since the model
// does not know where they are.
//
// An uppercase selector also frees the data of each image it removed a
// placement of, or with d=I and d=R without p= named, once the image has no
// placement of any kind left (_imageHasPlacements).
func (s *terminalScreen) deleteKittyPlacements(args map[string]string) {
	selector := kittyDeleteSelectorOf(args)
	frees := args["d"] != "" && args["d"] != selector
	store := s.kittyStore()
	imageID := kittyIDValue(args["i"])
	placementID := kittyIDValue(args["p"])
	var match func(p *vtKittyPlacement) bool
	var matchVirtual, matchRelative func(vtKittyRef) bool
	var named []string
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
		matchVirtual = func(r vtKittyRef) bool {
			return r.imageID == imageID && (placementID == "" || r.placementID == placementID)
		}
		matchRelative = matchVirtual
		if placementID == "" {
			named = []string{imageID}
		}
	case "r":
		first, last := kittyDeleteRange(args)
		inRange := func(id string) bool { return kittyIDInRange(id, first, last) }
		match = func(p *vtKittyPlacement) bool { return inRange(p.imageID) }
		matchVirtual = func(r vtKittyRef) bool { return inRange(r.imageID) }
		matchRelative = matchVirtual
		for _, id := range store.ids {
			if inRange(id) {
				named = append(named, id)
			}
		}
	case "z":
		z, ok := kittyDeleteZ(args)
		if !ok {
			return
		}
		match = func(p *vtKittyPlacement) bool { return p.z == z }
		matchRelative = func(r vtKittyRef) bool { return r.z == z }
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
		if selector == "a" {
			matchRelative = func(vtKittyRef) bool { return true }
		}
	default:
		return
	}
	alt := s.altActive
	matched := named
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool {
		if p.alt != alt || !match(p) {
			return false
		}
		matched = append(matched, p.imageID)
		return true
	})
	if matchVirtual != nil {
		matched = append(matched, store.virtual.removeIf(matchVirtual)...)
	}
	if matchRelative != nil {
		matched = append(matched, store.relative.removeIf(matchRelative)...)
	}
	if !frees {
		return
	}
	for _, id := range matched {
		if !s.kittyImagePlaced(id, alt, 0) {
			store.forget(id)
		}
	}
}

// kittyImagePlaced reports whether imageID has a placement on a screen: one
// the model follows onto a cell, its virtual placement, or one relative to a
// parent that has one itself, as far down as the client lets a chain go.
func (s *terminalScreen) kittyImagePlaced(imageID string, alt bool, depth int) bool {
	if depth > kittyRelativePlacementDepthLimit {
		return false
	}
	for i := range s.kittyDirect {
		if p := &s.kittyDirect[i]; p.alt == alt && p.imageID == imageID {
			return true
		}
	}
	store := &s.kittyStores[0]
	if alt {
		store = &s.kittyStores[1]
	}
	for _, r := range store.virtual {
		if r.imageID == imageID {
			return true
		}
	}
	for _, r := range store.relative {
		if r.imageID == imageID && r.parent != imageID &&
			s.kittyImagePlaced(r.parent, alt, depth+1) {
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

// dropKittyAltPlacements follows a clear of the alternate screen, which
// keeps its images and their virtual placements (GraphicsManager.clear).
func (s *terminalScreen) dropKittyAltPlacements() {
	s.dropKittyPlacements(func(p *vtKittyPlacement) bool { return p.alt })
	s.kittyStores[1].relative = nil
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

// KittyMainPlacementDeletes returns what a replay sends, before the images,
// when it paints the main screen and places its direct placements again
// (replace as for RenderFrameReplacing). The replay prefix's ED 2 leaves a
// reopened client's own placements on the main screen. A frame that paints
// the scrollback scrolls the screen, which carries each of them up with its
// row, away from the cell it belongs on, so all of them go
// (kittyVisiblePlacementsDelete), and an image the replay leaves out, too
// large for it or sent without an id it can name, is left out cleanly; the
// prefix's ED 2 erased the placeholder cells that position relative
// placements of virtual ones, which the delete therefore keeps. A frame
// without scrollback paints over the client's placements in place: only a
// lowercase delete by id (a=d,d=i), which keeps the image data, of each
// image it places again, so that placing one without a placement id does
// not leave a second copy. That delete takes every placement of the image,
// wherever it is, and only those, so what the replay does not place again
// keeps whatever the client had. The alternate screen needs none: entering
// it cleared it.
func (s *terminalScreen) KittyMainPlacementDeletes(replace func(imageID string) bool) []byte {
	if s == nil {
		return nil
	}
	if s.scrollback.len() > 0 {
		return []byte(kittyVisiblePlacementsDelete)
	}
	var out []byte
	var deleted []string
	for i := range s.kittyDirect {
		p := &s.kittyDirect[i]
		if !s.kittyPlacementReplaced(p, false, replace) || slices.Contains(deleted, p.imageID) {
			continue
		}
		deleted = append(deleted, p.imageID)
		out = append(out, "\x1b_Ga=d,d=i,i="...)
		out = append(out, p.imageID...)
		out = append(out, ",q=2\x1b\\"...)
	}
	return out
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
