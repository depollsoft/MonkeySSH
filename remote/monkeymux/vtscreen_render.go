package main

import (
	"strconv"
)

// RenderFrame serialises the current picture into escape sequences that
// reproduce it on a client whose terminal was just reset (the sequence is
// applied after activeWindowReplayPrefix and after the window's private modes
// were re-enabled). The output is self-contained: every visible row is
// addressed absolutely, attributes are always emitted as a full reset+set,
// and the scroll region, origin mode, cursor, charsets and current rendition
// are restored at the end so that live incremental updates from the
// foreground application continue to apply correctly.
//
// On the main screen the retained scrollback is emitted first, one line per
// "\r\n", followed by enough blank lines to push all of it above the visible
// area, so the client's scrollback matches the server's.
//
// A line that soft-wraps from the one above is reached by wrapping onto it
// instead (appendVTSoftWrap), so the client marks it as a continuation just as
// the model does and reflows it the same way on the next width change.
func (s *terminalScreen) RenderFrame() []byte {
	if s == nil {
		return nil
	}
	out := make([]byte, 0, 4096)
	// Insert mode is restored at the end; painting under it would shift
	// cells instead of replacing them, such as the glyphs a soft wrap prints
	// and the row then paints over.
	out = append(out, "\x1b[?6l\x1b[r\x1b[0m\x1b[4l"...)
	out = s.appendTabStops(out)
	g := s.grid()
	softWraps := s.renderedSoftWraps()
	if softWraps && !s.autowrap {
		out = append(out, "\x1b[?7h"...)
	}
	if !s.altActive && len(s.scrollback) > 0 {
		out = append(out, "\x1b[H"...)
		// Stored lines are decoded only around a soft wrap; prev keeps the
		// last line's cells when its own wrap needed them.
		var decoder vtLineDecoder
		var prev []vtCell
		for i, line := range s.scrollback {
			var cells []vtCell
			switch {
			case i > 0 && s.scrollbackWrapped[i]:
				if prev == nil {
					prev = decoder.decode(s.scrollback[i-1], s.width)
				}
				cells = decoder.decode(line, s.width)
				out = appendVTSoftWrap(out, prev, cells, s.height > 1)
				// The wrap scrolled this row in while the glyph it printed set
				// the rendition, so the row may be filled with that background,
				// and the stored line skips the cells it leaves default. Erase
				// the row first, with ECH since EL would also clear the wrap.
				out = appendVTCSICount(out, s.width, 'X')
			case i > 0:
				out = append(out, "\x1b[0m\r\n"...)
			}
			out = append(out, line...)
			prev = cells
		}
		if g.wrapped[0] {
			if prev == nil {
				prev = decoder.decode(s.scrollback[len(s.scrollback)-1], s.width)
			}
			out = appendVTSoftWrap(out, prev, g.rows[0], s.height > 1)
			// Erased for the same reason; the row is painted below.
			out = appendVTCSICount(out, s.width, 'X')
		} else {
			out = append(out, "\x1b[0m\r\n"...)
		}
		for i := 1; i < s.height; i++ {
			out = append(out, "\r\n"...)
		}
	}
	for r, row := range g.rows {
		if r > 0 && g.wrapped[r] {
			out = appendVTSoftWrap(out, g.rows[r-1], row, true)
		} else {
			out = appendVTCursorPosition(out, r, 0)
		}
		before := len(out)
		out = renderVTCells(out, row)
		full := len(row) > 0 && !row[len(row)-1].isDefaultUnwritten()
		if len(out) != before || full {
			out = append(out, "\x1b[0m"...)
		}
		if !full {
			if g.wrapped[r] {
				// EL would also clear the client's wrap flag.
				out = appendVTCSICount(out, s.width, 'X')
			} else {
				out = append(out, "\x1b[K"...)
			}
		}
	}
	if softWraps && !s.autowrap {
		out = append(out, "\x1b[?7l"...)
	}
	out = append(out, "\x1b[0m"...)
	if sco := s.scoCursor; sco.valid {
		// SCOSC state for a later CSI u.
		out = appendVTCursorPosition(out, sco.row, sco.col)
		out = append(out, "\x1b[s"...)
	}
	if saved := *s.saved(); saved.valid {
		// DECSC state: live output may DECRC into it after the frame. DECSC
		// captures position, rendition, origin mode and charsets, so stage
		// all of them, save, then undo the staging.
		if saved.originMode && (s.top != 0 || s.bottom != s.height-1) {
			out = appendVTRegion(out, s.top, s.bottom)
		}
		if saved.originMode {
			out = append(out, "\x1b[?6h"...)
			out = appendVTCursorPosition(out, saved.row-s.top, saved.col)
		} else {
			out = appendVTCursorPosition(out, saved.row, saved.col)
		}
		out = appendVTSGR(out, saved.attrs)
		out = appendVTCharsets(out, saved.g0Graphics, saved.g1Graphics, saved.shiftOut)
		out = append(out, "\x1b7\x1b[0m\x1b[?6l\x1b[r"...)
		out = appendVTCharsets(out, false, false, false)
	}
	if s.insertMode {
		out = append(out, "\x1b[4h"...)
	}
	if s.top != 0 || s.bottom != s.height-1 {
		out = appendVTRegion(out, s.top, s.bottom)
	}
	if s.originMode {
		out = append(out, "\x1b[?6h"...)
	}
	row := g.cursorRow
	if s.originMode {
		row -= s.top
		if row < 0 {
			row = 0
		}
	}
	if g.pendingWrap && s.width > 0 {
		// A deferred wrap cannot be addressed directly: re-print the glyph in
		// the last column so the client defers the wrap exactly as the model.
		cells := g.rows[g.cursorRow]
		col := s.width - 1
		if cells[col].width == 0 && col > 0 {
			col--
		}
		out = appendVTCursorPosition(out, row, col)
		out = renderVTGlyphs(out, cells[col:])
	} else {
		out = appendVTCursorPosition(out, row, g.cursorCol)
	}
	out = appendVTCharsets(out, s.g0Graphics, s.g1Graphics, s.shiftOut)
	out = appendVTSGR(out, s.attrs)
	return out
}

// renderedSoftWraps reports whether a frame has to reproduce a soft wrap: in
// the scrollback it emits, or on the screen below its first row, or into the
// first row from the scrollback.
func (s *terminalScreen) renderedSoftWraps() bool {
	g := s.grid()
	for r, wrapped := range g.wrapped {
		if wrapped && (r > 0 || (!s.altActive && len(s.scrollback) > 0)) {
			return true
		}
	}
	if s.altActive {
		return false
	}
	for _, wrapped := range s.scrollbackWrapped[min(1, len(s.scrollbackWrapped)):] {
		if wrapped {
			return true
		}
	}
	return false
}

// appendVTSoftWrap moves the client from the row prev was painted on to the
// start of the next row by autowrap, so the client marks that row as the
// soft-wrapped continuation of prev, as BufferLine.isWrapped. It prints the
// glyph in prev's last column and next's first glyph after it, which wraps,
// and stands in a space for a cell that has no glyph to print, erasing it
// again afterwards. The cursor ends in column 0 of the new row with the
// rendition reset, ready for next's cells to be painted over what is there.
//
// prevOnScreen reports whether prev's row is still on the screen once the
// wrap has scrolled: on a one-row screen it is in the history, out of reach of
// the erase, so a stand-in there would stay written. That wrap is dropped
// instead, unless it needs no stand-in.
func appendVTSoftWrap(out []byte, prev, next []vtCell, prevOnScreen bool) []byte {
	width := len(prev)
	if last := prev[width-1]; last.unwritten() && width > 1 && len(next) > 1 &&
		next[0].r != 0 && next[0].width == 2 && last.attrs == (vtAttrs{bg: next[0].attrs.bg}) {
		// How the client gets here itself: a wide glyph printed in the last
		// column erases that cell with the glyph's background and wraps.
		out = append(out, "\x1b[0m"...)
		out = appendVTCSICount(out, width, 'G')
		out = renderVTGlyphs(out, next[:2])
		return append(out, "\x1b[0m\r"...)
	}
	if !prevOnScreen && !vtSoftWrapEdgePrintable(prev) {
		return append(out, "\x1b[0m\r\n"...)
	}
	out = append(out, "\x1b[0m"...)
	eraseLast := false
	switch last := prev[width-1]; {
	case last.width == 0 && width > 1 && prev[width-2].width == 2:
		out = appendVTCSICount(out, width-1, 'G')
		out = renderVTGlyphs(out, prev[width-2:])
	case last.width == 1 && last.r != 0:
		out = appendVTCSICount(out, width, 'G')
		out = renderVTGlyphs(out, prev[width-1:])
	default:
		out = appendVTCSICount(out, width, 'G')
		out = append(out, ' ')
		eraseLast = true
	}
	out = append(out, "\x1b[0m"...)
	eraseFirst := false
	switch first := next[0]; {
	case first.r != 0 && first.width == 2 && len(next) > 1:
		out = renderVTGlyphs(out, next[:2])
	case first.r != 0 && first.width == 1:
		out = renderVTGlyphs(out, next[:1])
	default:
		out = append(out, ' ')
		eraseFirst = true
	}
	out = append(out, "\x1b[0m"...)
	if eraseLast {
		out = append(out, "\x1b[A"...)
		out = appendVTCSICount(out, width, 'G')
		out = appendVTErase(out, prev[width-1].attrs)
		out = append(out, "\x1b[B"...)
	}
	if eraseFirst {
		out = append(out, '\r')
		out = appendVTErase(out, next[0].attrs)
	}
	return append(out, '\r')
}

// vtSoftWrapEdgePrintable reports whether the cell that ends row can be
// printed again as itself to reach the deferred wrap.
func vtSoftWrapEdgePrintable(row []vtCell) bool {
	width := len(row)
	last := row[width-1]
	return (last.width == 1 && last.r != 0) ||
		(last.width == 0 && width > 1 && row[width-2].width == 2)
}

// appendVTErase erases the cell under the cursor back to never-written, with
// the background it had, and resets the rendition.
func appendVTErase(out []byte, attrs vtAttrs) []byte {
	out = appendVTSGR(out, attrs)
	out = append(out, "\x1b[X"...)
	return append(out, "\x1b[0m"...)
}

func appendVTRegion(out []byte, top, bottom int) []byte {
	out = append(out, "\x1b["...)
	out = strconv.AppendInt(out, int64(top+1), 10)
	out = append(out, ';')
	out = strconv.AppendInt(out, int64(bottom+1), 10)
	return append(out, 'r')
}

func appendVTCharsets(out []byte, g0Graphics, g1Graphics, shiftOut bool) []byte {
	if g0Graphics {
		out = append(out, "\x1b(0"...)
	} else {
		out = append(out, "\x1b(B"...)
	}
	if g1Graphics {
		out = append(out, "\x1b)0"...)
	} else {
		out = append(out, "\x1b)B"...)
	}
	if shiftOut {
		return append(out, 0x0e)
	}
	return append(out, 0x0f)
}

// renderVTCells appends a row's cells. Trailing default blanks are omitted
// when trimTrailing is set. Attributes are tracked from "default" at the start
// of the row, so the caller must reset the rendition before each row.
// renderVTCells serialises one row onto a destination row that is still
// blank: a cleared screen, a fresh scrollback line, or a scratch row. Cells
// nothing was written to are skipped with CUF, or erased with ECH when they
// carry a background, rather than printed as spaces, so the destination ends
// up with the same never-written cells as the source. Which cells were written
// decides which rows a resize may reclaim, in the model and in the client
// alike, so a repainted or restored row has to keep it. Never-written default
// cells at the end of the row are left out.
func renderVTCells(out []byte, row []vtCell) []byte {
	end := len(row)
	for end > 0 && row[end-1].isDefaultUnwritten() {
		end--
	}
	current := vtAttrs{}
	var buf [utf8Max]byte
	for i := 0; i < end; {
		cell := row[i]
		if cell.width == 0 {
			i++
			continue
		}
		if cell.unwritten() {
			run := i + 1
			for run < end && row[run].unwritten() && row[run].attrs == cell.attrs {
				run++
			}
			if cell.attrs != (vtAttrs{}) {
				if cell.attrs != current {
					out = appendVTSGR(out, cell.attrs)
					current = cell.attrs
				}
				out = appendVTCSICount(out, run-i, 'X')
			}
			if run < len(row) {
				out = appendVTCSICount(out, run-i, 'C')
			}
			i = run
			continue
		}
		if cell.attrs != current {
			out = appendVTSGR(out, cell.attrs)
			current = cell.attrs
		}
		out = append(out, encodeRune(buf[:], cell.r)...)
		for _, comb := range cell.comb {
			out = append(out, encodeRune(buf[:], comb)...)
		}
		i++
	}
	return out
}

// renderVTGlyphs prints cells as glyphs, a space for a never-written cell, so
// the cursor ends up after them with any deferred wrap the last one causes.
func renderVTGlyphs(out []byte, cells []vtCell) []byte {
	current := vtAttrs{}
	var buf [utf8Max]byte
	for _, cell := range cells {
		if cell.width == 0 {
			continue
		}
		if cell.attrs != current {
			out = appendVTSGR(out, cell.attrs)
			current = cell.attrs
		}
		r := cell.r
		if r == 0 {
			r = ' '
		}
		out = append(out, encodeRune(buf[:], r)...)
		for _, comb := range cell.comb {
			out = append(out, encodeRune(buf[:], comb)...)
		}
	}
	return out
}

func appendVTCSICount(out []byte, count int, final byte) []byte {
	out = append(out, "\x1b["...)
	out = strconv.AppendInt(out, int64(count), 10)
	return append(out, final)
}

const utf8Max = 4

func encodeRune(buf []byte, r rune) []byte {
	n := encodeRuneInto(buf, r)
	return buf[:n]
}

func encodeRuneInto(buf []byte, r rune) int {
	switch {
	case r < 0x80:
		buf[0] = byte(r)
		return 1
	case r < 0x800:
		buf[0] = byte(0xC0 | r>>6)
		buf[1] = byte(0x80 | r&0x3F)
		return 2
	case r < 0x10000:
		buf[0] = byte(0xE0 | r>>12)
		buf[1] = byte(0x80 | (r>>6)&0x3F)
		buf[2] = byte(0x80 | r&0x3F)
		return 3
	default:
		buf[0] = byte(0xF0 | r>>18)
		buf[1] = byte(0x80 | (r>>12)&0x3F)
		buf[2] = byte(0x80 | (r>>6)&0x3F)
		buf[3] = byte(0x80 | r&0x3F)
		return 4
	}
}

// appendVTSGR emits a full reset+set rendition so the result never depends on
// earlier state.
func appendVTSGR(out []byte, a vtAttrs) []byte {
	out = append(out, "\x1b[0"...)
	if a.flags&vtAttrBold != 0 {
		out = append(out, ";1"...)
	}
	if a.flags&vtAttrDim != 0 {
		out = append(out, ";2"...)
	}
	if a.flags&vtAttrItalic != 0 {
		out = append(out, ";3"...)
	}
	switch a.ulStyle {
	case 1:
		out = append(out, ";4"...)
	case 2, 3, 4, 5:
		out = append(out, ";4:"...)
		out = strconv.AppendInt(out, int64(a.ulStyle), 10)
	}
	if a.flags&vtAttrBlink != 0 {
		out = append(out, ";5"...)
	}
	if a.flags&vtAttrInverse != 0 {
		out = append(out, ";7"...)
	}
	if a.flags&vtAttrHidden != 0 {
		out = append(out, ";8"...)
	}
	if a.flags&vtAttrStrike != 0 {
		out = append(out, ";9"...)
	}
	out = appendVTColor(out, a.fg, 30, 38)
	out = appendVTColor(out, a.bg, 40, 48)
	if a.ul.kind != vtColorDefault {
		out = appendVTColor(out, a.ul, 0, 58)
	}
	return append(out, 'm')
}

func appendVTColor(out []byte, c vtColor, base int, extended int) []byte {
	switch c.kind {
	case vtColorIndexed:
		if base > 0 && c.index < 8 {
			out = append(out, ';')
			return strconv.AppendInt(out, int64(base+int(c.index)), 10)
		}
		if base > 0 && c.index < 16 {
			out = append(out, ';')
			return strconv.AppendInt(out, int64(base+60+int(c.index)-8), 10)
		}
		out = append(out, ';')
		out = strconv.AppendInt(out, int64(extended), 10)
		out = append(out, ";5;"...)
		return strconv.AppendInt(out, int64(c.index), 10)
	case vtColorRGB:
		out = append(out, ';')
		out = strconv.AppendInt(out, int64(extended), 10)
		out = append(out, ";2;"...)
		out = strconv.AppendInt(out, int64(c.r), 10)
		out = append(out, ';')
		out = strconv.AppendInt(out, int64(c.g), 10)
		out = append(out, ';')
		return strconv.AppendInt(out, int64(c.b), 10)
	}
	return out
}

// ---- character width -----------------------------------------------------

type runeRange struct{ lo, hi rune }

var zeroWidthRanges = []runeRange{
	{0x0300, 0x036F}, {0x0483, 0x0489}, {0x0591, 0x05BD}, {0x05BF, 0x05BF},
	{0x05C1, 0x05C2}, {0x05C4, 0x05C5}, {0x05C7, 0x05C7}, {0x0610, 0x061A},
	{0x064B, 0x065F}, {0x0670, 0x0670}, {0x06D6, 0x06DC}, {0x06DF, 0x06E4},
	{0x06E7, 0x06E8}, {0x06EA, 0x06ED}, {0x0711, 0x0711}, {0x0730, 0x074A},
	{0x07A6, 0x07B0}, {0x0816, 0x082D}, {0x0859, 0x085B}, {0x08D3, 0x08E1},
	{0x08E3, 0x0902}, {0x093A, 0x093A}, {0x093C, 0x093C}, {0x0941, 0x0948},
	{0x094D, 0x094D}, {0x0951, 0x0957}, {0x0962, 0x0963}, {0x0981, 0x0981},
	{0x09BC, 0x09BC}, {0x09C1, 0x09C4}, {0x09CD, 0x09CD}, {0x0E31, 0x0E31},
	{0x0E34, 0x0E3A}, {0x0E47, 0x0E4E}, {0x0EB1, 0x0EB1}, {0x0EB4, 0x0EBC},
	{0x0EC8, 0x0ECD}, {0x1AB0, 0x1AFF}, {0x1DC0, 0x1DFF}, {0x200B, 0x200F},
	{0x2028, 0x202E}, {0x2060, 0x2064}, {0x20D0, 0x20FF}, {0xFE00, 0xFE0F},
	{0xFE20, 0xFE2F}, {0xFEFF, 0xFEFF}, {0x1F3FB, 0x1F3FF}, {0xE0100, 0xE01EF},
}

var wideRanges = []runeRange{
	{0x1100, 0x115F}, {0x231A, 0x231B}, {0x2329, 0x232A}, {0x23E9, 0x23EC},
	{0x23F0, 0x23F0}, {0x23F3, 0x23F3}, {0x25FD, 0x25FE}, {0x2614, 0x2615},
	{0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1},
	{0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26CE, 0x26CE},
	{0x26D4, 0x26D4}, {0x26EA, 0x26EA}, {0x26F2, 0x26F3}, {0x26F5, 0x26F5},
	{0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B},
	{0x2728, 0x2728}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755},
	{0x2757, 0x2757}, {0x2795, 0x2797}, {0x27B0, 0x27B0}, {0x27BF, 0x27BF},
	{0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55}, {0x2E80, 0x303E},
	{0x3041, 0x33FF}, {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA4CF},
	{0xA960, 0xA97F}, {0xAC00, 0xD7A3}, {0xF900, 0xFAFF}, {0xFE10, 0xFE19},
	{0xFE30, 0xFE6F}, {0xFF00, 0xFF60}, {0xFFE0, 0xFFE6}, {0x16FE0, 0x16FE4},
	{0x17000, 0x18AFF}, {0x1B000, 0x1B2FF}, {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF},
	{0x1F18E, 0x1F18E}, {0x1F191, 0x1F19A}, {0x1F1E6, 0x1F1FF}, {0x1F200, 0x1F251},
	{0x1F300, 0x1F320}, {0x1F32D, 0x1F335}, {0x1F337, 0x1F37C}, {0x1F37E, 0x1F393},
	{0x1F3A0, 0x1F3CA}, {0x1F3CF, 0x1F3D3}, {0x1F3E0, 0x1F3F0}, {0x1F3F4, 0x1F3F4},
	{0x1F3F8, 0x1F43E}, {0x1F440, 0x1F440}, {0x1F442, 0x1F4FC}, {0x1F4FF, 0x1F53D},
	{0x1F54B, 0x1F54E}, {0x1F550, 0x1F567}, {0x1F57A, 0x1F57A}, {0x1F595, 0x1F596},
	{0x1F5A4, 0x1F5A4}, {0x1F5FB, 0x1F64F}, {0x1F680, 0x1F6C5}, {0x1F6CC, 0x1F6CC},
	{0x1F6D0, 0x1F6D2}, {0x1F6D5, 0x1F6D7}, {0x1F6DC, 0x1F6DF}, {0x1F6EB, 0x1F6EC},
	{0x1F6F4, 0x1F6FC}, {0x1F7E0, 0x1F7EB}, {0x1F7F0, 0x1F7F0}, {0x1F90C, 0x1F93A},
	{0x1F93C, 0x1F945}, {0x1F947, 0x1F9FF}, {0x1FA70, 0x1FAFF}, {0x20000, 0x2FFFD},
	{0x30000, 0x3FFFD},
}

func inRuneRanges(r rune, ranges []runeRange) bool {
	lo, hi := 0, len(ranges)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		switch {
		case r < ranges[mid].lo:
			hi = mid - 1
		case r > ranges[mid].hi:
			lo = mid + 1
		default:
			return true
		}
	}
	return false
}

// runeWidth returns the number of cells a rune occupies: 0 for combining and
// zero-width characters, 2 for East Asian wide/fullwidth and emoji
// presentation, 1 otherwise.
func runeWidth(r rune) int {
	if r < 0x300 {
		if r == 0 {
			return 0
		}
		return 1
	}
	if inRuneRanges(r, zeroWidthRanges) || isKittyPlaceholderDiacritic(r) {
		return 0
	}
	if inRuneRanges(r, wideRanges) {
		return 2
	}
	return 1
}

func appendVTCursorPosition(out []byte, row, col int) []byte {
	out = append(out, "\x1b["...)
	out = strconv.AppendInt(out, int64(row+1), 10)
	out = append(out, ';')
	out = strconv.AppendInt(out, int64(col+1), 10)
	return append(out, 'H')
}

// appendTabStops replaces the client's tab stops with the model's. The client
// may carry stops from a previous window, so the set is always rebuilt, even
// when it is the default one. Emitted before any content because setting a
// stop moves the cursor.
func (s *terminalScreen) appendTabStops(out []byte) []byte {
	out = append(out, "\x1b[3g"...)
	for i, set := range s.tabs {
		if set {
			out = appendVTCursorPosition(out, 0, i)
			out = append(out, "\x1bH"...)
		}
	}
	return out
}

// kittyPlaceholderDiacritics are the combining marks the Kitty graphics
// unicode-placeholder protocol uses to encode row and column indices. The
// client consumes them as zero-width marks on the placeholder cell, so the
// model must too, or placeholder rows wrap at different columns on each side.
// Mirror of _kittyPlaceholderDiacritics in
// third_party/xterm/lib/src/terminal.dart; TestKittyPlaceholderDiacriticsMatchClient
// keeps the two lists identical.
var kittyPlaceholderDiacritics = []rune{
	0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
	0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
	0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
	0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
	0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
	0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
	0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
	0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
	0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
	0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
	0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
	0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
	0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
	0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
	0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
	0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
	0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
	0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
	0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
	0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
	0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
	0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
	0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
	0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
	0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
	0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
	0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
	0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
	0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
	0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
	0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
	0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
}

func isKittyPlaceholderDiacritic(r rune) bool {
	_, ok := kittyPlaceholderDiacriticValue(r)
	return ok
}

// kittyPlaceholderDiacriticValue returns the row/column/high-byte value a
// placeholder diacritic encodes: its index in kittyPlaceholderDiacritics, which
// is what _kittyPlaceholderDiacriticIndex resolves on the client.
func kittyPlaceholderDiacriticValue(r rune) (int, bool) {
	lo, hi := 0, len(kittyPlaceholderDiacritics)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		switch {
		case r < kittyPlaceholderDiacritics[mid]:
			hi = mid - 1
		case r > kittyPlaceholderDiacritics[mid]:
			lo = mid + 1
		default:
			return mid, true
		}
	}
	return 0, false
}
