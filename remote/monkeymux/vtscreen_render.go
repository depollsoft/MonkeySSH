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
func (s *terminalScreen) RenderFrame() []byte {
	if s == nil {
		return nil
	}
	out := make([]byte, 0, 4096)
	out = append(out, "\x1b[?6l\x1b[r\x1b[0m"...)
	out = s.appendTabStops(out)
	if !s.altActive && len(s.scrollback) > 0 {
		out = append(out, "\x1b[H"...)
		for _, line := range s.scrollback {
			out = append(out, line...)
			out = append(out, "\x1b[0m\r\n"...)
		}
		for i := 1; i < s.height; i++ {
			out = append(out, "\r\n"...)
		}
	}
	for r, row := range s.grid().rows {
		out = append(out, "\x1b["...)
		out = strconv.AppendInt(out, int64(r+1), 10)
		out = append(out, ";1H"...)
		before := len(out)
		out = renderVTCells(out, row, true)
		full := len(row) > 0 && !row[len(row)-1].isDefaultBlank()
		if len(out) != before || full {
			out = append(out, "\x1b[0m"...)
		}
		if !full {
			out = append(out, "\x1b[K"...)
		}
	}
	out = append(out, "\x1b[0m"...)
	g := s.grid()
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
		out = renderVTCells(out, cells[col:], false)
	} else {
		out = appendVTCursorPosition(out, row, g.cursorCol)
	}
	out = appendVTCharsets(out, s.g0Graphics, s.g1Graphics, s.shiftOut)
	out = appendVTSGR(out, s.attrs)
	return out
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
func renderVTCells(out []byte, row []vtCell, trimTrailing bool) []byte {
	end := len(row)
	if trimTrailing {
		for end > 0 && row[end-1].isDefaultBlank() {
			end--
		}
	}
	current := vtAttrs{}
	var buf [utf8Max]byte
	for i := 0; i < end; i++ {
		cell := row[i]
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
	if inRuneRanges(r, zeroWidthRanges) {
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
