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
) bool {
	imageID := w.kittyPlacementImageIDLocked(args)
	if imageID == "" || len(command) == 0 {
		return false
	}
	placementID := kittyIDValue(args["p"])
	alt := w.alternateScreenModeActiveLocked()
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
		// The parent is physical or unknown, so no replay could restore this
		// placement. It still replaces a kept one with the same ids.
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
		command:     rewriteKittyReplayCommand(command, false),
	})
	w.removeOrphanedKittyPlacementsLocked()
	return true
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
	if len(w.kittyPlacements) == 0 {
		return false
	}
	rootVirtual := kittyRootPlacementKey(imageID)
	changed := w.removeKittyPlacementsLocked(func(p kittyRetainedPlacement) bool {
		return p.imageID == imageID || p.parent == rootVirtual
	})
	return w.removeOrphanedKittyPlacementsLocked() || changed
}

// observeKittyPlacementDeleteLocked applies a delete command (a=d) to the kept
// placements the way the client applies it to its own: by image id, number or
// id range with the virtual placement included, and by position for relative
// placements, whose position MonkeyMux cannot work out, so every one goes.
func (w *muxWindow) observeKittyPlacementDeleteLocked(args map[string]string) bool {
	if len(w.kittyPlacements) == 0 {
		return false
	}
	selector := strings.ToLower(args["d"])
	placementID := kittyIDValue(args["p"])
	var match func(kittyRetainedPlacement) bool
	switch selector {
	case "i", "n":
		imageID := w.kittyPlacementImageIDLocked(args)
		if imageID == "" {
			return false
		}
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
		match = func(p kittyRetainedPlacement) bool {
			image, rooted := strings.CutPrefix(p.parent, "root:")
			return inRange(p.imageID) || (rooted && inRange(image))
		}
	case "f":
		return false
	default:
		match = func(p kittyRetainedPlacement) bool { return !p.virtual() }
	}
	changed := w.removeKittyPlacementsLocked(match)
	return w.removeOrphanedKittyPlacementsLocked() || changed
}

// applyKittyImageDeleteLocked applies a delete command (a=d) to the retained
// placements and image data as the client applies it to its own. Uppercase
// I and N without a placement id free the image; with one, the client frees
// it only if that placement was its last, which MonkeyMux cannot tell, so the
// image stays. R frees the images whose ids are in x..y. The positional
// selectors free images placed at a cell MonkeyMux cannot see; those stay
// too, since an image kept for nothing costs only replay bytes while a
// dropped one leaves its placeholder cells blank after an attach.
func (w *muxWindow) applyKittyImageDeleteLocked(event kittyGraphicsEvent) bool {
	changed := w.observeKittyPlacementDeleteLocked(event.control)
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

// reconcileKittyPlacementScreenLocked drops the relative placements kept for
// the alternate screen when the window enters or leaves it: the client
// clears that screen's placements on 1049h and 1047l. Virtual placements
// survive a clear on the client and are kept.
func (w *muxWindow) reconcileKittyPlacementScreenLocked() {
	alt := w.alternateScreenModeActiveLocked()
	if alt == w.kittyPlacementsAlt {
		return
	}
	w.kittyPlacementsAlt = alt
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
	var out []byte
	for _, p := range w.kittyPlacements {
		if p.alt == alt {
			out = append(out, p.command...)
		}
	}
	return out
}

// kittyPlacementImageIDsLocked returns the images the kept placements of the
// shown screen display, which a replay must carry for them to be placed.
func (w *muxWindow) kittyPlacementImageIDsLocked() []string {
	alt := w.alternateScreenModeActiveLocked()
	var ids []string
	for _, p := range w.kittyPlacements {
		if p.alt == alt {
			ids = append(ids, p.imageID)
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
