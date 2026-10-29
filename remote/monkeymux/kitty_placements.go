package main

import (
	"bytes"
	"strconv"
	"strings"
)

// Kitty placements MonkeyMux replays after the images on attach.
//
// A replay restores image data and the screen, but never a physical placement:
// the screen model skips APC strings, so it cannot say where one went. Two
// kinds of placement are positioned without a cell of their own and come back
// correctly: a virtual placement (a=p,U=1), which the Unicode placeholder cells
// in the replayed frame display, and a relative placement (P=), which sits a
// cell offset from its parent and moves with it. A relative placement is kept
// only while its parent chain ends at a virtual placement that is kept too,
// since a physical parent never comes back.
//
// The client keeps one placement per image and placement id and replaces it
// when the same pair is sent again, so a replay never duplicates one; a
// relative placement without a placement id would add a copy on every attach
// and is not kept.

// maxRetainedKittyPlacements bounds the placements kept per window.
const maxRetainedKittyPlacements = 256

// kittyRelativePlacementDepthLimit mirrors the client's (and Kitty's) limit of
// eight parent links in a relative placement chain.
const kittyRelativePlacementDepthLimit = 8

// kittyPlacementTracking is the state, beyond the kept placements, that
// MonkeyMux needs to follow the client's placements through window output.
type kittyPlacementTracking struct {
	// modeCarry is the start of an alternate-screen mode change cut off at
	// the end of the last output, which the next output completes.
	modeCarry []byte
	// physical lists the physical placements the window made, which a replay
	// never restores but a relative placement can name as its parent. A
	// delete MonkeyMux cannot resolve leaves them listed, so a relative
	// placement naming one is taken as accepted and is not kept.
	physical []kittyPhysicalPlacement
	// chunk, chunkScreen and chunkWritten give the screen model as it stood
	// at a positional delete in the output being observed: a copy taken
	// before chunk was written, advanced to each delete in turn.
	chunk        []byte
	chunkScreen  *terminalScreen
	chunkWritten int
}

// kittyPhysicalPlacement is a physical placement a window made.
type kittyPhysicalPlacement struct {
	imageID     string
	placementID string
	alt         bool
}

// maxTrackedKittyPhysicalPlacements bounds the physical placements listed.
const maxTrackedKittyPhysicalPlacements = 512

// kittyRetainedPlacement is one kept virtual or relative placement.
type kittyRetainedPlacement struct {
	// imageID is the retained image the placement shows.
	imageID string
	// placementID is the client's placement id (p=), "" when it has none.
	placementID string
	// parent is the key of the parent placement, or "" for a virtual one. A
	// virtual placement made by its image's own transmission (a=T,U=1) has
	// the key kittyRootPlacementKey(image).
	parent string
	// alt records that the placement was made on the alternate screen.
	alt bool
	// horizontal and vertical are the cell offsets from the parent (H=, V=);
	// cols and rows are the explicit cell span (c=, r=), 0 when the image
	// sizes it; z is its z-index. A delete by position or z-index matches on
	// them as the client does.
	horizontal, vertical int
	cols, rows           int
	z                    int
	// command is the a=p command replayed for it, with replies silenced.
	command []byte
}

// key identifies the placement the way the client does: by image and
// placement id, except that an image has a single virtual placement, which
// its relative placements hang off whatever its placement id.
func (p kittyRetainedPlacement) key() string {
	if p.virtual() {
		return kittyVirtualPlacementKey(p.imageID)
	}
	return kittyPlacementKey(p.imageID, p.placementID)
}

func (p kittyRetainedPlacement) virtual() bool { return p.parent == "" }

func kittyPlacementKey(imageID, placementID string) string {
	return imageID + "/" + placementID
}

func kittyVirtualPlacementKey(imageID string) string {
	return imageID + "/virtual"
}

// kittyRootPlacementKey names the virtual placement a retained root
// transmission makes for itself (a=T or a=t with U=1).
func kittyRootPlacementKey(imageID string) string {
	return "root:" + imageID
}

// kittyNonZero reads a Kitty numeric key the way the client does: present and
// any non-zero value.
func kittyNonZero(value string) bool {
	n, err := strconv.ParseUint(value, 10, 32)
	return err == nil && n != 0
}

// kittyIDValue normalizes an id key: "" for absent or zero.
func kittyIDValue(value string) string {
	if !kittyNonZero(value) {
		return ""
	}
	return strings.TrimLeft(value, "0")
}

// kittyPlacementCommandKeys are the display keys a relative placement made by
// an a=T root keeps when it is replayed as an a=p command.
var kittyPlacementCommandKeys = []string{
	"p", "P", "Q", "H", "V", "c", "r", "x", "y", "w", "h", "X", "Y", "z",
}

// kittyRelativeCommandFromRoot builds the a=p command that replays the
// relative placement an a=T root with P= makes. Only a root with an explicit
// image id can be placed again by id.
func kittyRelativeCommandFromRoot(args map[string]string) []byte {
	id := kittyIDValue(args["i"])
	if id == "" {
		return nil
	}
	var out bytes.Buffer
	out.WriteString("\x1b_Ga=p,i=")
	out.WriteString(id)
	for _, key := range kittyPlacementCommandKeys {
		if value, ok := args[key]; ok && value != "" {
			out.WriteString("," + key + "=" + value)
		}
	}
	out.WriteString(",q=2\x1b\\")
	return out.Bytes()
}

// kittyRootIsVirtual reports whether the retained root transmission of
// imageID also made a virtual placement, and its placement id.
func (w *muxWindow) kittyRootIsVirtual(imageID string) (bool, string) {
	root := w.kittyImages[imageID]
	end := kittyApcEnd(root, 0)
	if end < 0 {
		return false, ""
	}
	args := parseKittyControl(kittyControl(root, 0, end))
	return kittyNonZero(args["U"]), kittyIDValue(args["p"])
}

// kittyPlacementImageIDLocked resolves the image a placement command names:
// its id, or the image its I= number maps to.
func (w *muxWindow) kittyPlacementImageIDLocked(args map[string]string) string {
	if id := kittyIDValue(args["i"]); id != "" {
		return id
	}
	if number := kittyIDValue(args["I"]); number != "" {
		return w.kittyImageNumberToID[number]
	}
	return ""
}

// observeKittyPlacementLocked records a display command (a=p) or the
// placement an a=T root with P= makes. command is what replays it. It reports
// whether the retained set changed.
func (w *muxWindow) observeKittyPlacementLocked(
	args map[string]string,
	command []byte,
	alt bool,
) bool {
	imageID := w.kittyPlacementImageIDLocked(args)
	if imageID == "" || len(command) == 0 {
		return false
	}
	placementID := kittyIDValue(args["p"])
	virtual := kittyNonZero(args["U"])
	parentImage := kittyIDValue(args["P"])
	switch {
	case virtual && parentImage != "":
		// The client rejects a virtual relative placement.
		return false
	case virtual:
		// The client keeps one virtual placement per image; a new one
		// replaces it, and its relative placements stay attached.
		w.addKittyPlacementLocked(kittyRetainedPlacement{
			imageID:     imageID,
			placementID: placementID,
			alt:         alt,
			command:     rewriteKittyReplayCommand(command, false),
		})
		w.removeOrphanedKittyPlacementsLocked()
		return true
	case parentImage == "":
		// A physical placement: it replaces any kept placement with the
		// same image and placement id, and is not kept itself.
		w.noteKittyPhysicalPlacementLocked(imageID, placementID, alt)
		if placementID == "" {
			return false
		}
		key := kittyPlacementKey(imageID, placementID)
		changed := w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
			return p.key() == key && p.alt == alt
		})
		return w.removeOrphanedKittyPlacementsLocked() || changed
	}

	if placementID == "" {
		// Without a placement id every replay would add another copy.
		return false
	}
	key := kittyPlacementKey(imageID, placementID)
	parent, ok := w.kittyPlacementParentLocked(
		parentImage,
		kittyIDValue(args["Q"]),
		alt,
	)
	if !ok {
		if !w.kittyPhysicalParentLocked(
			parentImage,
			kittyIDValue(args["Q"]),
			alt,
		) {
			// The client has no such parent placement either: it answers
			// ENOPARENT and keeps the placement it had.
			return false
		}
		// The parent is a physical placement, which no replay restores, so
		// neither can this placement be. It replaces a kept one with the
		// same ids on the client, so that one goes.
		changed := w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
			return p.key() == key && p.alt == alt
		})
		return w.removeOrphanedKittyPlacementsLocked() || changed
	}
	if !w.kittyPlacementChainAcceptsLocked(key, parent, alt) {
		// The client rejects a self parent, a cycle or a chain too deep and
		// keeps what it had.
		return false
	}
	w.addKittyPlacementLocked(kittyRetainedPlacement{
		imageID:     imageID,
		placementID: placementID,
		parent:      parent,
		alt:         alt,
		horizontal:  kittyIntValue(args["H"]),
		vertical:    kittyIntValue(args["V"]),
		cols:        kittyIntValue(args["c"]),
		rows:        kittyIntValue(args["r"]),
		z:           kittyIntValue(args["z"]),
		command:     rewriteKittyReplayCommand(command, false),
	})
	w.removeOrphanedKittyPlacementsLocked()
	return true
}

// kittyIntValue reads a signed Kitty numeric key, 0 when absent or invalid.
func kittyIntValue(value string) int {
	n, err := strconv.ParseInt(value, 10, 32)
	if err != nil {
		return 0
	}
	return int(n)
}

// noteKittyPhysicalPlacementLocked lists a physical placement the window made
// (a=p, or a=T, without U= or P=); the same image and placement id replace it.
func (w *muxWindow) noteKittyPhysicalPlacementLocked(
	imageID, placementID string,
	alt bool,
) {
	t := &w.kittyTracking
	if placementID != "" {
		for _, p := range t.physical {
			if p.imageID == imageID && p.placementID == placementID && p.alt == alt {
				return
			}
		}
	}
	t.physical = append(t.physical, kittyPhysicalPlacement{
		imageID:     imageID,
		placementID: placementID,
		alt:         alt,
	})
	if len(t.physical) > maxTrackedKittyPhysicalPlacements {
		t.physical = t.physical[1:]
	}
}

// kittyPhysicalParentLocked reports whether a physical placement listed on the
// screen could be the parent P=/Q= names: one with that placement id, or any
// when Q= is absent.
func (w *muxWindow) kittyPhysicalParentLocked(
	parentImage, parentPlacement string,
	alt bool,
) bool {
	for _, p := range w.kittyTracking.physical {
		if p.imageID == parentImage && p.alt == alt &&
			(parentPlacement == "" || p.placementID == parentPlacement) {
			return true
		}
	}
	return false
}

// forgetKittyPhysicalPlacementsLocked unlists the physical placements match
// selects, for the deletes and replacements MonkeyMux can resolve exactly.
func (w *muxWindow) forgetKittyPhysicalPlacementsLocked(
	match func(kittyPhysicalPlacement) bool,
) {
	t := &w.kittyTracking
	kept := t.physical[:0]
	for _, p := range t.physical {
		if !match(p) {
			kept = append(kept, p)
		}
	}
	t.physical = kept
}

// kittyPlacementParentLocked finds the kept placement a relative placement's
// P=/Q= names on the same screen: the one with that placement id, or the
// oldest when Q= is absent, as the client picks it. A virtual placement made
// by the parent image's own transmission counts too.
func (w *muxWindow) kittyPlacementParentLocked(
	parentImage, parentPlacement string,
	alt bool,
) (string, bool) {
	for _, p := range w.kittyPlacements {
		if p.imageID == parentImage && p.alt == alt &&
			(parentPlacement == "" || p.placementID == parentPlacement) {
			return p.key(), true
		}
	}
	if virtual, placementID := w.kittyRootIsVirtual(parentImage); virtual &&
		(parentPlacement == "" || parentPlacement == placementID) {
		return kittyRootPlacementKey(parentImage), true
	}
	return "", false
}

// kittyPlacementChainAcceptsLocked applies the client's checks to a relative
// placement key with parent: not its own parent, no cycle, and at most
// kittyRelativePlacementDepthLimit links.
func (w *muxWindow) kittyPlacementChainAcceptsLocked(
	key, parent string,
	alt bool,
) bool {
	link := parent
	for depth := 1; ; depth++ {
		if link == key {
			return false
		}
		next, found := "", false
		for _, p := range w.kittyPlacements {
			if p.key() == link && p.alt == alt {
				next, found = p.parent, true
				break
			}
		}
		if !found || next == "" {
			return true // a virtual placement roots the chain
		}
		if depth >= kittyRelativePlacementDepthLimit {
			return false
		}
		link = next
	}
}

// addKittyPlacementLocked keeps p, replacing a kept placement with the same
// key on the same screen where it stood, so the replay order still puts
// parents before their children.
func (w *muxWindow) addKittyPlacementLocked(p kittyRetainedPlacement) {
	key := p.key()
	for index, existing := range w.kittyPlacements {
		if existing.key() == key && existing.alt == p.alt {
			w.kittyPlacements[index] = p
			return
		}
	}
	w.kittyPlacements = append(w.kittyPlacements, p)
	for len(w.kittyPlacements) > maxRetainedKittyPlacements {
		w.kittyPlacements = w.kittyPlacements[1:]
		w.removeOrphanedKittyPlacementsLocked()
	}
}

func (w *muxWindow) removeKittyPlacementsLocked(
	match func(kittyRetainedPlacement) bool,
) bool {
	kept := w.kittyPlacements[:0]
	for _, p := range w.kittyPlacements {
		if !match(p) {
			kept = append(kept, p)
		}
	}
	changed := len(kept) != len(w.kittyPlacements)
	for index := len(kept); index < len(w.kittyPlacements); index++ {
		w.kittyPlacements[index] = kittyRetainedPlacement{}
	}
	w.kittyPlacements = kept
	return changed
}

// removeOrphanedKittyPlacementsLocked drops relative placements whose parent
// is no longer kept, repeatedly, so a whole subtree goes with its root.
func (w *muxWindow) removeOrphanedKittyPlacementsLocked() bool {
	changed := false
	for {
		alive := make(map[string]bool, len(w.kittyPlacements))
		for _, p := range w.kittyPlacements {
			alive[p.key()+"@"+strconv.FormatBool(p.alt)] = true
		}
		removed := w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
			if p.virtual() {
				return false
			}
			if image, ok := strings.CutPrefix(p.parent, "root:"); ok {
				virtual, _ := w.kittyRootIsVirtual(image)
				return !virtual
			}
			return !alive[p.parent+"@"+strconv.FormatBool(p.alt)]
		})
		if !removed {
			return changed
		}
		changed = true
	}
}

// dropKittyImagePlacementsLocked forgets every kept placement of imageID and
// the relative placements that hang off them: the image was retransmitted,
// which replaces it and every placement it had, or it is gone.
func (w *muxWindow) dropKittyImagePlacementsLocked(imageID string) bool {
	if len(w.kittyPlacements) == 0 && len(w.kittyTracking.physical) == 0 {
		return false
	}
	w.forgetKittyPhysicalPlacementsLocked(func(p kittyPhysicalPlacement) bool {
		return p.imageID == imageID
	})
	rootVirtual := kittyRootPlacementKey(imageID)
	changed := w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
		return p.imageID == imageID || p.parent == rootVirtual
	})
	return w.removeOrphanedKittyPlacementsLocked() || changed
}

// observeKittyPlacementDeleteLocked applies a delete command (a=d) to the kept
// placements of the screen it ran on, matching them as the client does: by
// image id, number or id range with the virtual placement included, by
// z-index, and by position for relative placements, which sit at the
// placeholder cells of their virtual root plus their offsets. screen is the
// screen model as it stood at the command, or nil when MonkeyMux cannot tell.
//
// Where MonkeyMux cannot know whether the client matched a relative
// placement, it drops it: a reattach then shows the placement missing, where
// keeping it could bring back an image the client deleted. That covers a
// position delete without the screen at the command, an image sized by its
// own pixels (a side without c= or r= may reach any further cell), and a
// virtual root whose placeholder cells are only in the scrollback.
func (w *muxWindow) observeKittyPlacementDeleteLocked(
	args map[string]string,
	alt bool,
	screen *terminalScreen,
) bool {
	selector := strings.ToLower(args["d"])
	if selector == "" {
		selector = "a"
	}
	placementID := kittyIDValue(args["p"])
	var match func(kittyRetainedPlacement) bool
	switch selector {
	case "i", "n":
		imageID := w.kittyPlacementImageIDLocked(args)
		if imageID == "" {
			return false
		}
		w.forgetKittyPhysicalPlacementsLocked(func(p kittyPhysicalPlacement) bool {
			return p.alt == alt && p.imageID == imageID &&
				(placementID == "" || p.placementID == placementID)
		})
		// The virtual placement an image's own transmission made goes too
		// when the delete covers it, and with it the placements hanging off.
		_, rootPlacementID := w.kittyRootIsVirtual(imageID)
		rootVirtual := ""
		if placementID == "" || placementID == rootPlacementID {
			rootVirtual = kittyRootPlacementKey(imageID)
		}
		match = func(p kittyRetainedPlacement) bool {
			return (p.imageID == imageID &&
				(placementID == "" || p.placementID == placementID)) ||
				(rootVirtual != "" && p.parent == rootVirtual)
		}
	case "r":
		first, errFirst := strconv.ParseUint(args["x"], 10, 32)
		last, errLast := strconv.ParseUint(args["y"], 10, 32)
		if errFirst != nil || errLast != nil {
			return false
		}
		inRange := func(imageID string) bool {
			id, err := strconv.ParseUint(imageID, 10, 32)
			return err == nil && id >= first && id <= last
		}
		w.forgetKittyPhysicalPlacementsLocked(func(p kittyPhysicalPlacement) bool {
			return p.alt == alt && inRange(p.imageID)
		})
		match = func(p kittyRetainedPlacement) bool {
			image, rooted := strings.CutPrefix(p.parent, "root:")
			return inRange(p.imageID) || (rooted && inRange(image))
		}
	case "z":
		z := kittyIntValue(args["z"])
		match = func(p kittyRetainedPlacement) bool {
			return !p.virtual() && p.z == z
		}
	case "a", "c", "p", "q", "x", "y":
		match = w.kittyPositionalDeleteMatch(selector, args, screen)
	default:
		return false
	}
	if len(w.kittyPlacements) == 0 {
		return false
	}
	changed := w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
		return p.alt == alt && match(p)
	})
	return w.removeOrphanedKittyPlacementsLocked() || changed
}

// kittyPositionalDeleteMatch returns whether a positional delete removes a
// kept relative placement on the client, or may: see
// observeKittyPlacementDeleteLocked for when MonkeyMux cannot tell.
func (w *muxWindow) kittyPositionalDeleteMatch(
	selector string,
	args map[string]string,
	screen *terminalScreen,
) func(kittyRetainedPlacement) bool {
	if screen == nil {
		return func(p kittyRetainedPlacement) bool {
			return !p.virtual() && (selector != "q" ||
				p.z == kittyIntValue(args["z"]))
		}
	}
	x, hasX := kittyCellValue(args["x"])
	y, hasY := kittyCellValue(args["y"])
	if selector == "c" {
		row, col := screen.CursorPosition()
		x, y, hasX, hasY = col, row, true, true
	}
	z := kittyIntValue(args["z"])
	_, height := screen.Size()
	seen := make(map[string]bool)
	for _, id := range screen.PlaceholderImageIDs() {
		seen[id] = true
	}
	return func(p kittyRetainedPlacement) bool {
		if p.virtual() || (selector == "q" && p.z != z) {
			return false
		}
		col, row, root, placed := w.kittyPlacementCellLocked(p, screen)
		if !placed {
			// No placeholder cell of the root on screen. If it has none at
			// all the client has not placed this one either; one in the
			// scrollback could still put it anywhere.
			return seen[root]
		}
		// A side the image sizes by its pixels may reach any further cell.
		openRight, openDown := p.cols <= 0, p.rows <= 0
		lastCol := col + max(1, p.cols) - 1
		lastRow := row + max(1, p.rows) - 1
		coversX := hasX && x >= col && (openRight || x <= lastCol)
		coversY := hasY && y >= row && (openDown || y <= lastRow)
		switch selector {
		case "a":
			return row < height && (openDown || lastRow >= 0)
		case "x":
			return coversX
		case "y":
			return coversY
		default:
			return coversX && coversY
		}
	}
}

// kittyCellValue reads a 1-based Kitty cell coordinate as a 0-based one.
func kittyCellValue(value string) (int, bool) {
	n, err := strconv.ParseUint(value, 10, 32)
	if err != nil || n == 0 {
		return 0, false
	}
	return int(n) - 1, true
}

// kittyPlacementCellLocked resolves a kept relative placement to the screen
// cell the client puts it at: the top-left placeholder cell of its virtual
// root in screen, plus every offset on the way down. root is the root image.
func (w *muxWindow) kittyPlacementCellLocked(
	p kittyRetainedPlacement,
	screen *terminalScreen,
) (col, row int, root string, placed bool) {
	col, row = p.horizontal, p.vertical
	link := p.parent
	for depth := 0; depth <= kittyRelativePlacementDepthLimit; depth++ {
		if image, ok := strings.CutPrefix(link, "root:"); ok {
			return kittyVirtualOrigin(screen, image, col, row)
		}
		var parent *kittyRetainedPlacement
		for index := range w.kittyPlacements {
			if w.kittyPlacements[index].key() == link &&
				w.kittyPlacements[index].alt == p.alt {
				parent = &w.kittyPlacements[index]
				break
			}
		}
		if parent == nil {
			return 0, 0, "", false
		}
		if parent.virtual() {
			return kittyVirtualOrigin(screen, parent.imageID, col, row)
		}
		col += parent.horizontal
		row += parent.vertical
		link = parent.parent
	}
	return 0, 0, "", false
}

func kittyVirtualOrigin(
	screen *terminalScreen,
	imageID string,
	col, row int,
) (int, int, string, bool) {
	id, err := strconv.ParseUint(imageID, 10, 32)
	if err != nil {
		return 0, 0, imageID, false
	}
	originCol, originRow, ok := screen.PlaceholderOrigin(uint32(id))
	if !ok {
		return 0, 0, imageID, false
	}
	return originCol + col, originRow + row, imageID, true
}

// snapshotKittyScreenLocked copies the screen model before chunk is written
// to it, when chunk deletes placements by position and some are kept, so the
// delete can be matched against the screen as it stood at the command.
func (w *muxWindow) snapshotKittyScreenLocked(chunk []byte) {
	t := &w.kittyTracking
	t.chunk, t.chunkScreen, t.chunkWritten = nil, nil, 0
	if len(w.kittyPlacements) == 0 || w.screen == nil ||
		!kittyChunkHasPositionalDelete(chunk) {
		return
	}
	t.chunk, t.chunkScreen = chunk, w.screen.Clone()
}

// releaseKittyScreenSnapshotLocked drops the copy snapshotKittyScreenLocked
// took once the chunk has been observed.
func (w *muxWindow) releaseKittyScreenSnapshotLocked() {
	t := &w.kittyTracking
	t.chunk, t.chunkScreen, t.chunkWritten = nil, nil, 0
}

// kittyScreenAtLocked returns the screen model as it stood at the graphics
// command at offset in data (end is where the command ends), or nil when it
// cannot be known. A command that ends the output saw the model as it is
// now; an earlier one needs the copy taken before the output, advanced to it.
func (w *muxWindow) kittyScreenAtLocked(data []byte, offset, end int) *terminalScreen {
	if end >= len(data) {
		return w.screen
	}
	t := &w.kittyTracking
	if t.chunkScreen == nil || len(t.chunk) > len(data) ||
		!bytes.Equal(data[len(data)-len(t.chunk):], t.chunk) {
		return nil
	}
	start := offset - (len(data) - len(t.chunk))
	if start < t.chunkWritten {
		return nil
	}
	t.chunkScreen.Write(t.chunk[t.chunkWritten:start])
	t.chunkWritten = start
	return t.chunkScreen
}

// kittyChunkHasPositionalDelete reports whether data holds a graphics delete
// that selects placements by position.
func kittyChunkHasPositionalDelete(data []byte) bool {
	for index := 0; ; {
		start := bytes.Index(data[index:], []byte("\x1b_G"))
		if start < 0 {
			return false
		}
		start += index
		end := start + 3
		for end < len(data) && data[end] != ';' && data[end] != '\x1b' {
			end++
		}
		args := parseKittyControl(string(data[start+3 : end]))
		if args["a"] == "d" {
			switch strings.ToLower(args["d"]) {
			case "", "a", "c", "p", "q", "x", "y":
				return true
			}
		}
		index = end
	}
}

// applyKittyImageDeleteLocked applies a delete command (a=d) to the retained
// placements and image data as the client applies it to its own. Uppercase
// I and N without a placement id free the image; with one, the client frees
// it only if that placement was its last, which MonkeyMux cannot tell, so the
// image stays. R frees the images whose ids are in x..y. The positional
// selectors free images placed at a cell MonkeyMux cannot see; those stay
// too, since an image kept for nothing costs only replay bytes while a
// dropped one leaves its placeholder cells blank after an attach.
func (w *muxWindow) applyKittyImageDeleteLocked(
	event kittyGraphicsEvent,
	alt bool,
	screen *terminalScreen,
) bool {
	changed := w.observeKittyPlacementDeleteLocked(event.control, alt, screen)
	switch event.control["d"] {
	case "I", "N":
		if kittyIDValue(event.control["p"]) != "" {
			return changed
		}
		id := event.id
		if id == "" && event.imageNumber != "" {
			id = w.kittyImageNumberToID[event.imageNumber]
		}
		return w.removeKittyImageLocked(id) || changed
	case "R":
		first, errFirst := strconv.ParseUint(event.control["x"], 10, 32)
		last, errLast := strconv.ParseUint(event.control["y"], 10, 32)
		if errFirst != nil || errLast != nil {
			return changed
		}
		for _, id := range append([]string(nil), w.kittyImageOrder...) {
			value, err := strconv.ParseUint(id, 10, 32)
			if err == nil && value >= first && value <= last {
				changed = w.removeKittyImageLocked(id) || changed
			}
		}
	}
	return changed
}

// kittyScreenModeChange is a DECSET or DECRST of an alternate-screen mode
// (1047 or 1049) at offset in a chunk of output.
type kittyScreenModeChange struct {
	offset int
	mode   int
	set    bool
}

// kittyScreenModeChanges finds the alternate-screen mode changes in data, in
// order, so each graphics command can be placed on the screen it ran on.
func kittyScreenModeChanges(data []byte) []kittyScreenModeChange {
	var changes []kittyScreenModeChange
	for index := 0; ; {
		start := bytes.Index(data[index:], []byte("\x1b[?"))
		if start < 0 {
			return changes
		}
		start += index
		end := start + 3
		for end < len(data) && (data[end] >= '0' && data[end] <= '9' || data[end] == ';') {
			end++
		}
		if end >= len(data) {
			return changes
		}
		if final := data[end]; final == 'h' || final == 'l' {
			for _, param := range bytes.Split(data[start+3:end], []byte{';'}) {
				mode, err := strconv.Atoi(string(param))
				if err == nil && (mode == 1047 || mode == 1049) {
					// It takes effect at its final byte.
					changes = append(changes, kittyScreenModeChange{
						offset: end,
						mode:   mode,
						set:    final == 'h',
					})
				}
			}
		}
		index = end
	}
}

// kittyScreenTracker follows the window's screen through a chunk of output.
// It starts where the last chunk left the window and applies each
// alternate-screen mode change at its offset.
type kittyScreenTracker struct {
	w       *muxWindow
	changes []kittyScreenModeChange
	next    int
}

func (w *muxWindow) newKittyScreenTrackerLocked(data []byte) *kittyScreenTracker {
	// A mode change cut off at the end of the last output completes here:
	// scan it with this output and place it at offset 0.
	carry := w.kittyTracking.modeCarry
	w.kittyTracking.modeCarry = nil
	scanned := data
	if len(carry) > 0 {
		scanned = append(append([]byte(nil), carry...), data...)
	}
	changes := kittyScreenModeChanges(scanned)
	for index := range changes {
		changes[index].offset = max(0, changes[index].offset-len(carry))
	}
	return &kittyScreenTracker{w: w, changes: changes}
}

// maxKittyModeCarryBytes bounds a cut-off mode change held for the next
// output.
const maxKittyModeCarryBytes = 32

// kittyPartialModeChange returns the start of a DEC private mode change that
// data ends inside (ESC, ESC [, ESC [ ? and its parameters), or nil.
func kittyPartialModeChange(data []byte) []byte {
	start := bytes.LastIndexByte(data, '\x1b')
	if start < 0 || len(data)-start > maxKittyModeCarryBytes {
		return nil
	}
	tail := data[start:]
	for index, b := range tail[1:] {
		switch {
		case index == 0 && b == '[', index == 1 && b == '?':
		case index >= 2 && (b >= '0' && b <= '9' || b == ';'):
		default:
			return nil
		}
	}
	return append([]byte(nil), tail...)
}

// at returns whether the alternate screen is up at offset in the chunk.
func (t *kittyScreenTracker) at(offset int) bool {
	for t.next < len(t.changes) && t.changes[t.next].offset < offset {
		change := t.changes[t.next]
		t.next++
		if change.mode == 1047 {
			t.w.kittyScreenMode1047 = change.set
		} else {
			t.w.kittyScreenMode1049 = change.set
		}
		t.w.setKittyPlacementScreenLocked(
			t.w.kittyScreenMode1047 || t.w.kittyScreenMode1049,
		)
	}
	return t.w.kittyPlacementsAlt
}

// finish settles the window on the screen its modes say it shows, which a
// mode change split across chunks may have hidden from the scan.
func (t *kittyScreenTracker) finish() {
	t.at(int(^uint(0) >> 1))
	t.w.kittyScreenMode1047 = t.w.privateModes["1047"]
	t.w.kittyScreenMode1049 = t.w.privateModes["1049"]
	t.w.setKittyPlacementScreenLocked(t.w.alternateScreenModeActiveLocked())
}

// setKittyPlacementScreenLocked records the screen the window shows. Entering
// or leaving the alternate screen clears that screen's placements on the
// client (1049h and 1047l), so the relative placements kept for it go;
// virtual placements survive a clear on the client and are kept.
func (w *muxWindow) setKittyPlacementScreenLocked(alt bool) {
	if alt == w.kittyPlacementsAlt {
		return
	}
	w.kittyPlacementsAlt = alt
	w.forgetKittyPhysicalPlacementsLocked(func(p kittyPhysicalPlacement) bool {
		return p.alt
	})
	if w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
		return p.alt && !p.virtual()
	}) {
		w.removeOrphanedKittyPlacementsLocked()
	}
}

// kittyPlacementReplayLocked returns the kept placements of the screen the
// window shows, parents first, to send after the images they show.
func (w *muxWindow) kittyPlacementReplayLocked() []byte {
	alt := w.alternateScreenModeActiveLocked()
	// A placement can be reparented to one made after it, so emit by
	// dependency rather than by age: a parent must exist on the client
	// before a child can be placed relative to it.
	emitted := make(map[string]bool, len(w.kittyPlacements))
	var out []byte
	for pass := 0; pass <= kittyRelativePlacementDepthLimit; pass++ {
		progressed := false
		for _, p := range w.kittyPlacements {
			if p.alt != alt || emitted[p.key()] {
				continue
			}
			if !p.virtual() && !strings.HasPrefix(p.parent, "root:") &&
				!emitted[p.parent] {
				continue
			}
			emitted[p.key()] = true
			out = append(out, p.command...)
			progressed = true
		}
		if !progressed {
			break
		}
	}
	return out
}

// kittyPlacementImageIDsLocked returns the images the kept placements of the
// shown screen display, which a replay must carry for them to be placed, and
// the images whose own transmission made the virtual root of one: without
// that root the client rejects the placement.
func (w *muxWindow) kittyPlacementImageIDsLocked() []string {
	alt := w.alternateScreenModeActiveLocked()
	var ids []string
	for _, p := range w.kittyPlacements {
		if p.alt == alt {
			ids = append(ids, p.imageID)
			if root, ok := strings.CutPrefix(p.parent, "root:"); ok {
				ids = append(ids, root)
			}
		}
	}
	return ids
}

// kittyRootTransient reports a root transmission's transient usage hint
// (N=1): Kitty may evict such an image first under storage pressure.
func kittyRootTransient(root []byte) bool {
	end := kittyApcEnd(root, 0)
	if end < 0 {
		return false
	}
	hints, err := strconv.ParseUint(
		parseKittyControl(kittyControl(root, 0, end))["N"],
		10,
		32,
	)
	return err == nil && hints&1 != 0
}

// kittyEvictionCandidateLocked picks the retained image to evict first: a
// transient one before any other, then the least recently changed.
func (w *muxWindow) kittyEvictionCandidateLocked() string {
	var victim string
	victimTransient := false
	for _, id := range w.kittyImageOrder {
		transient := kittyRootTransient(w.kittyImages[id])
		if victim == "" ||
			(transient && !victimTransient) ||
			(transient == victimTransient &&
				w.kittyImageSeq[id] < w.kittyImageSeq[victim]) {
			victim = id
			victimTransient = transient
		}
	}
	return victim
}
