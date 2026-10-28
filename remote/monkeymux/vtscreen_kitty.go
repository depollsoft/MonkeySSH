package main

// PlaceholderOrigin returns the top-left of the Kitty Unicode placeholder
// cells on the visible screen that show imageID: their smallest column and
// smallest row, which is where the client puts the image's virtual placement
// as the parent of relative placements. Cells whose color carries only the
// low bits of the id count when no cell carries all of it, as in the client.
func (s *terminalScreen) PlaceholderOrigin(imageID uint32) (col, row int, ok bool) {
	if s == nil || imageID == 0 {
		return 0, 0, false
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
	for rowIndex, cells := range s.grid().rows {
		for colIndex, cell := range cells {
			if cell.r != kittyPlaceholderRune {
				continue
			}
			var low, mask uint32
			switch cell.attrs.fg.kind {
			case vtColorRGB:
				fg := cell.attrs.fg
				low = uint32(fg.r)<<16 | uint32(fg.g)<<8 | uint32(fg.b)
				mask = 0xFFFFFF
			case vtColorIndexed:
				low, mask = uint32(cell.attrs.fg.index), 0xFF
			default:
				continue
			}
			id := low
			if len(cell.comb) >= 3 {
				if high, ok := kittyPlaceholderDiacriticValue(cell.comb[2]); ok {
					id |= uint32(high) << 24
				}
			}
			switch {
			case id == imageID:
				include(&exact, colIndex, rowIndex)
			case id == imageID&mask:
				include(&masked, colIndex, rowIndex)
			}
		}
	}
	if exact.found {
		return exact.col, exact.row, true
	}
	return masked.col, masked.row, masked.found
}
