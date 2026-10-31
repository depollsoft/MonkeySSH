package main

import "bytes"

// kittyPlaceholderUTF8 is the placeholder code point as a rendered scrollback
// line holds it.
var kittyPlaceholderUTF8 = []byte(string(kittyPlaceholderRune))

// kittyPlaceholderCellID returns the image id a Kitty Unicode placeholder cell
// shows and the mask of the low bits its color carries; ok is false for any
// other cell.
func kittyPlaceholderCellID(cell vtCell) (id, mask uint32, ok bool) {
	if cell.r != kittyPlaceholderRune {
		return 0, 0, false
	}
	switch cell.attrs.fg.kind {
	case vtColorRGB:
		fg := cell.attrs.fg
		id = uint32(fg.r)<<16 | uint32(fg.g)<<8 | uint32(fg.b)
		mask = 0xFFFFFF
	case vtColorIndexed:
		id, mask = uint32(cell.attrs.fg.index), 0xFF
	default:
		return 0, 0, false
	}
	if len(cell.comb) >= 3 {
		if high, ok := kittyPlaceholderDiacriticValue(cell.comb[2]); ok {
			id |= uint32(high) << 24
		}
	}
	return id, mask, true
}

// PlaceholderOrigin returns the top-left of the Kitty Unicode placeholder
// cells that show imageID: their smallest column and smallest row, which is
// where the client puts the image's virtual placement as the parent of
// relative placements. Like the client it looks through the whole buffer, so
// on the main screen the scrollback counts too, a line of it as a negative
// row (-1 the newest). Cells whose color carries only the low bits of the id
// count when no cell carries all of it, as in the client.
//
// known is false when a line the scrollback dropped held a cell that may
// show the image: the client keeps a longer scrollback, and may still place
// the image there.
func (s *terminalScreen) PlaceholderOrigin(imageID uint32) (col, row int, ok, known bool) {
	if s == nil || imageID == 0 {
		return 0, 0, false, true
	}
	if !s.altActive && s.kittyPlaceholderMayBeEvicted(imageID) {
		return 0, 0, false, false
	}
	type origin struct {
		col, row int
		found    bool
	}
	include := func(o *origin, col, row int) {
		if !o.found || col < o.col {
			o.col = col
		}
		if !o.found || row < o.row {
			o.row = row
		}
		o.found = true
	}
	var exact, masked origin
	scan := func(cells []vtCell, row int) {
		for col, cell := range cells {
			id, mask, ok := kittyPlaceholderCellID(cell)
			switch {
			case !ok:
			case id == imageID:
				include(&exact, col, row)
			case id == imageID&mask:
				include(&masked, col, row)
			}
		}
	}
	if !s.altActive {
		var decoder vtLineDecoder
		history := s.scrollback.len()
		for i := range history {
			if line := s.scrollback.at(i); bytes.Contains(line.text, kittyPlaceholderUTF8) {
				scan(decoder.decode(line.text, s.width), i-history)
			}
		}
	}
	for row, cells := range s.grid().rows {
		scan(cells, row)
	}
	if exact.found {
		return exact.col, exact.row, true, true
	}
	return masked.col, masked.row, masked.found, true
}

// noteEvictedKittyPlaceholders records the placeholder cells of a line the
// scrollback is dropping, by the low byte of their image id, which is all
// that both an exact and a masked match of an image's id need agree on.
func (s *terminalScreen) noteEvictedKittyPlaceholders(line *vtScrollbackLine) {
	if !bytes.Contains(line.text, kittyPlaceholderUTF8) {
		return
	}
	var decoder vtLineDecoder
	for _, cell := range decoder.decode(line.text, renderedLineColumns(line.text)) {
		if id, _, ok := kittyPlaceholderCellID(cell); ok {
			low := id & 0xFF
			s.kittyEvictedPlaceholders[low/64] |= 1 << (low % 64)
		}
	}
}

// kittyPlaceholderMayBeEvicted reports whether a line the scrollback dropped
// held a placeholder cell that may show imageID.
func (s *terminalScreen) kittyPlaceholderMayBeEvicted(imageID uint32) bool {
	low := imageID & 0xFF
	return s.kittyEvictedPlaceholders[low/64]&(1<<(low%64)) != 0
}
