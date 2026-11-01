package main

import (
	"slices"
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
//
// The direct Kitty placements on the screen are placed again on their cells
// once the rows are painted, before the cursor is restored (see
// vtscreen_kitty_placements.go).
func (s *terminalScreen) RenderFrame() []byte {
	return s.RenderFrameReplacing(nil)
}

// RenderFrameReplacing is RenderFrame placing again only the direct
// placements of the images replace accepts, those the replay carries, or
// every one for nil. A replay that places a main-screen image again first
// deletes the client's copies of it (KittyMainPlacementDeletes).
func (s *terminalScreen) RenderFrameReplacing(replace func(imageID string) bool) []byte {
	if s == nil {
		return nil
	}
	g := s.grid()
	out, marks := s.appendGridFrame(make([]byte, 0, 4096), g, !s.altActive)
	out = s.appendKittyPlacements(out, s.altActive, replace)
	out = s.appendSavedCursor(out, g, *s.saved(), marks)
	out = marks.resume(out)
	if s.insertMode {
		out = append(out, "\x1b[4h"...)
	}
	if s.top != 0 || s.bottom != s.height-1 {
		out = appendVTRegion(out, s.top, s.bottom)
	}
	if s.originMode {
		out = append(out, "\x1b[?6h"...)
	}
	if s.originMode && (g.cursorRow < s.top || g.cursorRow > s.bottom) {
		out = s.appendVTCursorOutsideRegion(out, g, marks)
	} else {
		row := g.cursorRow
		if s.originMode {
			row -= s.top
		}
		out = s.appendVTCursor(out, g.rows[g.cursorRow], row, g.cursorCol, g.pendingWrap, marks, g.cursorRow)
	}
	// Last, since restoring a deferred wrap prints a glyph again under the
	// content it was written as.
	out = marks.finish(out)
	out = appendVTCharsets(out, s.g0Graphics, s.g1Graphics, s.shiftOut)
	out = appendVTSGR(out, s.attrs)
	return out
}

// RenderMainScreen paints the main screen an alternate-screen application
// hides, with its scrollback and saved cursor, for a client that was reset
// onto its main screen. A window replay sends it before re-entering the
// alternate screen, so the application's exit finds the main screen the model
// kept rather than a cleared one. The cursor is left where that exit puts it:
// on the cursor mode 1049 saved on entry (home with the default rendition
// once a DECSTR reset it), with the origin mode, rendition and charsets it
// saved, all of which the replayed 1049 entry saves again, or on the main
// cursor for 47 and 1047. It is nil while the main screen shows; RenderFrame
// paints it then. Its direct Kitty placements are placed again as RenderFrame
// places them.
func (s *terminalScreen) RenderMainScreen() []byte {
	return s.RenderMainScreenReplacing(nil)
}

// RenderMainScreenReplacing is RenderMainScreen placing again only the direct
// placements of the images replace accepts, as RenderFrameReplacing does.
func (s *terminalScreen) RenderMainScreenReplacing(replace func(imageID string) bool) []byte {
	if s == nil || !s.altActive {
		return nil
	}
	g := &s.main
	// The main screen's marks are painted into the client's main buffer,
	// which keeps its own prompt state for the application's exit to find.
	out, marks := s.appendGridFrame(make([]byte, 0, 4096), g, true)
	out = s.appendKittyPlacements(out, false, replace)
	if saved := s.savedMain; s.altSavedCursor {
		out = marks.resume(out)
		// DECSET 6 homes the cursor, so it goes first. The frame left the
		// scroll region full, where an origin-relative row is the row.
		if saved.originMode {
			out = append(out, "\x1b[?6h"...)
		}
		out = s.appendVTCursor(out, g.rows[saved.row], saved.row, saved.col, saved.pendingWrap, marks, saved.row)
		out = marks.finish(out)
		out = appendVTSGR(out, saved.attrs)
		return appendVTCharsets(out, saved.g0Graphics, saved.g1Graphics, saved.shiftOut)
	}
	out = s.appendSavedCursor(out, g, s.savedMain, marks)
	out = marks.resume(out)
	out = s.appendVTCursor(out, g.rows[g.cursorRow], g.cursorRow, g.cursorCol, g.pendingWrap, marks, g.cursorRow)
	return marks.finish(out)
}

// appendGridFrame paints g onto a reset client, after the main screen's
// retained scrollback when withScrollback is set, and leaves the rendition
// reset. Scroll region, origin mode and insert mode are left off, and mode
// 2027 as the model has it. It returns the prompt marks it painted with,
// whose finish the caller appends once it has restored the cursor.
func (s *terminalScreen) appendGridFrame(out []byte, g *vtGrid, withScrollback bool) ([]byte, *vtSemanticFrame) {
	// Insert mode stays off until RenderFrame restores it; painting under it
	// would shift cells instead of replacing them, such as the glyphs a soft
	// wrap prints and the row then paints over. Grapheme clustering is set as
	// the model has it before any cell, which is painted for that mode.
	out = appendVTGraphemeMode(out, s.graphemeCluster)
	out = append(out, "\x1b[?6l\x1b[r\x1b[0m\x1b[4l"...)
	out = s.appendTabStops(out)
	withScrollback = withScrollback && s.scrollback.len() > 0
	softWraps := s.renderedSoftWraps(g, withScrollback)
	marks := s.semanticFrame(g, withScrollback)
	out = marks.begin(out)
	// Lines are counted from the first painted scrollback line for marks.
	history := 0
	if withScrollback {
		history = s.scrollback.len()
	}
	if softWraps && !s.autowrap {
		out = append(out, "\x1b[?7h"...)
	}
	if withScrollback {
		// Stored lines are painted for a client that clusters graphemes.
		if !s.graphemeCluster {
			out = appendVTGraphemeMode(out, true)
		}
		out = append(out, "\x1b[H"...)
		// Stored lines are decoded only around a soft wrap; prev keeps the
		// last line's cells when its own wrap needed them.
		var decoder vtLineDecoder
		var prev []vtCell
		for i := range history {
			line := s.scrollback.at(i)
			var cells []vtCell
			switch {
			case i > 0 && line.wrapped:
				if prev == nil {
					prev = s.scrollback.at(i-1).decode(&decoder, s.width)
				}
				cells = line.decode(&decoder, s.width)
				out = appendVTSoftWrap(out, prev, cells, s.height > 1, marks, true)
				// The wrap scrolled this row in while the glyph it printed set
				// the rendition, so the row may be filled with that background,
				// and the stored line skips the cells it leaves default. Erase
				// the row first, with ECH since EL would also clear the wrap.
				out = appendVTCSICount(out, s.width, 'X')
			case i > 0:
				out = append(out, "\x1b[0m\r\n"...)
			}
			out = marks.beginLine(out, i, line.prompt, i > 0, true)
			if marks != nil && (line.prompt != vtPromptNone || len(line.sem) > 0) {
				// A line with a mark, or a cell written as prompt or input,
				// is painted from its cells, so they travel with it.
				if cells == nil {
					cells = line.decode(&decoder, s.width)
				}
				out = renderVTCellsMarked(out, cells, marks, true)
			} else {
				out = append(out, line.text...)
			}
			prev = cells
		}
		if !s.graphemeCluster {
			out = appendVTGraphemeMode(out, false)
		}
		if g.wrapped[0] {
			if prev == nil {
				prev = s.scrollback.at(history-1).decode(&decoder, s.width)
			}
			out = appendVTSoftWrap(out, prev, g.rows[0], s.height > 1, marks, s.graphemeCluster)
			// Erased for the same reason; the row is painted below.
			out = appendVTCSICount(out, s.width, 'X')
		} else {
			out = append(out, "\x1b[0m\r\n"...)
		}
		out = marks.beginLine(out, history, g.prompt[0], true, true)
		out = marks.push(out)
		for i := 1; i < s.height; i++ {
			out = append(out, "\r\n"...)
		}
	}
	for r, row := range g.rows {
		softWrap := r > 0 && g.wrapped[r]
		if softWrap {
			out = appendVTSoftWrap(out, g.rows[r-1], row, true, marks, s.graphemeCluster)
		} else {
			out = appendVTCursorPosition(out, r, 0)
		}
		out = marks.beginLine(out, history+r, g.prompt[r], softWrap, !vtRowReclaimable(row) || r == g.cursorRow)
		before := len(out)
		out = renderVTCellsMarked(out, row, marks, s.graphemeCluster)
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
	return append(out, "\x1b[0m"...), marks
}

// appendSavedCursor reproduces the DECSC state saved on g's screen, which
// live output may DECRC into after the frame. DECSC captures position,
// deferred wrap, rendition, origin mode and charsets, so all of them are
// staged, saved, and the staging undone. marks are those of the prompt the
// frame painted, if any.
func (s *terminalScreen) appendSavedCursor(out []byte, g *vtGrid, saved vtSavedCursor, marks *vtSemanticFrame) []byte {
	// A cursor never saved is home unless a resize moved it (restoreCursor).
	if !saved.valid && saved.row == 0 && saved.col == 0 {
		return out
	}
	// DECSET 6 homes the cursor, so it goes first. The scroll region is
	// still full, where an origin-relative row is the row, so a row outside
	// the region, which only DECRC itself goes to, is reached too.
	if saved.originMode {
		out = append(out, "\x1b[?6h"...)
	}
	out = s.appendVTCursor(out, g.rows[saved.row], saved.row, saved.col, saved.pendingWrap, marks, -1)
	out = appendVTSGR(out, saved.attrs)
	out = appendVTCharsets(out, saved.g0Graphics, saved.g1Graphics, saved.shiftOut)
	out = append(out, "\x1b7\x1b[0m\x1b[?6l\x1b[r"...)
	return appendVTCharsets(out, false, false, false)
}

// appendVTCursorOutsideRegion puts the client's cursor on g's cursor row,
// which in origin mode is outside the scroll region RenderFrame has set. CUP
// counts rows from the region's top and stops at its margins there, so only
// DECRC, which restores a saved row as it is, puts a cursor on such a row;
// outside the region it then moves up and down freely. When the saved cursor
// is outside the region in origin mode too, as the one restored to get there
// usually is, the frame restores it and moves on from there. Otherwise it
// saves the cursor first and restores that, which leaves it, with the saved
// rendition and charsets, as the saved cursor.
func (s *terminalScreen) appendVTCursorOutsideRegion(out []byte, g *vtGrid, marks *vtSemanticFrame) []byte {
	saved := *s.saved()
	restored := clampInt(saved.row, 0, s.height-1)
	if !saved.originMode || (restored >= s.top && restored <= s.bottom) {
		out = append(out, "\x1b[r"...)
		out = s.appendVTCursor(out, g.rows[g.cursorRow], g.cursorRow, g.cursorCol, g.pendingWrap, marks, g.cursorRow)
		out = appendVTSGR(out, saved.attrs)
		out = appendVTCharsets(out, saved.g0Graphics, saved.g1Graphics, saved.shiftOut)
		out = append(out, "\x1b7"...)
		out = appendVTRegion(out, s.top, s.bottom)
		return append(out, "\x1b8"...)
	}
	out = append(out, "\x1b8"...)
	if rows := g.cursorRow - restored; rows != 0 {
		out = append(out, "\x1b["...)
		final := byte('B')
		if rows < 0 {
			rows, final = -rows, 'A'
		}
		out = strconv.AppendInt(out, int64(rows), 10)
		out = append(out, final)
	}
	return s.appendVTCursor(out, g.rows[g.cursorRow], -1, g.cursorCol, g.pendingWrap, marks, g.cursorRow)
}

// appendVTCursor moves the client cursor to row, col of a row holding cells.
// A deferred wrap cannot be addressed directly, so the glyph in the last
// column is printed again and the client defers the wrap exactly as the
// model, under the semantic content it was written as when marks are those
// of a painted prompt. A last column with nothing in it, which a tab with no
// stop left reaches, is reached by that tab again rather than by printing a
// space into it. The rendition is left at the reprinted glyph's. screenRow
// is the cursor's row on the client's screen when it is the cursor the frame
// ends at (vtSemanticFrame.cursorContent), and -1 otherwise. The client is in
// the model's clustering mode. A row of -1 leaves the client's cursor on the
// row it is on, and moves it along that row (CHA).
func (s *terminalScreen) appendVTCursor(out []byte, cells []vtCell, row, col int, pendingWrap bool, marks *vtSemanticFrame, screenRow int) []byte {
	position := func(out []byte, col int) []byte {
		if row < 0 {
			out = append(out, "\x1b["...)
			out = strconv.AppendInt(out, int64(col+1), 10)
			return append(out, 'G')
		}
		return appendVTCursorPosition(out, row, col)
	}
	if !pendingWrap || len(cells) == 0 {
		return position(out, col)
	}
	last := len(cells) - 1
	if !vtSoftWrapEdgePrintable(cells) {
		out = position(out, last)
		return append(out, '\t')
	}
	if cells[last].width == 0 && last > 0 {
		last--
	}
	out = position(out, last)
	// A second half a code point writes takes its content as the glyph
	// does.
	content := vtContentSwitch(marks.content)
	if screenRow >= 0 {
		content = func(out []byte, sem uint8) []byte { return marks.cursorContent(out, sem, screenRow) }
	}
	out = content(out, cells[last].sem)
	plan := planVTGlyph(cells[last], vtGlyphBefore(cells, last), s.graphemeCluster, vtEdge(len(cells), last))
	if !plan.whole(cells[last]) {
		// The row holds the glyph already; a tab with no stop left reaches
		// the deferred wrap after it.
		out = position(out, len(cells)-1)
		return append(out, '\t')
	}
	return renderVTGlyph(out, cells, last, plan, s.graphemeCluster, content)
}

// renderedSoftWraps reports whether painting g has to reproduce a soft wrap:
// in the scrollback emitted with it, or below its first row, or into the first
// row from that scrollback.
func (s *terminalScreen) renderedSoftWraps(g *vtGrid, withScrollback bool) bool {
	for r, wrapped := range g.wrapped {
		if wrapped && (r > 0 || withScrollback) {
			return true
		}
	}
	if !withScrollback {
		return false
	}
	for i := 1; i < s.scrollback.len(); i++ {
		if s.scrollback.at(i).wrapped {
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
//
// A glyph printed again keeps the content it was written as (marks); the
// row's own cells are painted again afterwards, so the content the glyph that
// wraps onto it is printed under does not matter. Nor does that glyph, which
// a space stands in for when the client would join it to the glyph before
// the wrap. But the content in force when it wraps decides whether the client
// marks the new row as continuing a prompt, which the row's beginLine then
// corrects from what the marks emitted last, so the whole glyph, a second
// half its code points write included, keeps that content. clustered is the
// client's mode 2027.
func appendVTSoftWrap(out []byte, prev, next []vtCell, prevOnScreen bool, marks *vtSemanticFrame, clustered bool) []byte {
	width := len(prev)
	if last := prev[width-1]; last.unwritten() && width > 1 && len(next) > 1 &&
		next[0].r != 0 && next[0].width == 2 {
		// How the client gets here itself: a wide glyph printed in the last
		// column erases that cell with the background it is printed in, and
		// wraps. That is its second half's when the code point that first
		// widens it is the one that writes that half (appendVTGlyph).
		plan := planVTGlyph(next[0], vtGlyphBefore(prev, width-1), clustered, false)
		bg := next[0].attrs.bg
		if plan.widens > 0 && plan.wideAt == plan.widens {
			bg = vtGlyphHalf(next, 0).attrs.bg
		}
		if plan.whole(next[0]) && last.attrs == (vtAttrs{bg: bg}) {
			out = append(out, "\x1b[0m"...)
			out = appendVTCSICount(out, width, 'G')
			out = renderVTGlyph(out, next, 0, plan, clustered, nil)
			return append(out, "\x1b[0m\r"...)
		}
	}
	if !prevOnScreen && !vtSoftWrapEdgePrintable(prev) {
		return append(out, "\x1b[0m\r\n"...)
	}
	out = append(out, "\x1b[0m"...)
	eraseLast := false
	// end is the glyph the wrap follows on the client.
	var end vtCell
	switch last := prev[width-1]; {
	case last.width == 0 && width > 1 && prev[width-2].width == 2:
		out = appendVTCSICount(out, width-1, 'G')
		out = marks.content(out, prev[width-2].sem)
		plan := planVTGlyph(prev[width-2], vtGlyphBefore(prev, width-2), clustered, false)
		if plan.whole(prev[width-2]) {
			out = renderVTGlyph(out, prev, width-2, plan, clustered, marks.content)
		} else {
			out = appendVTCSICount(out, width, 'G')
			out = append(out, '\t')
		}
		end = prev[width-2]
	case last.width == 1 && last.r != 0:
		out = appendVTCSICount(out, width, 'G')
		out = marks.content(out, last.sem)
		plan := planVTGlyph(last, vtGlyphBefore(prev, width-1), clustered, vtEdge(width, width-1))
		if plan.whole(last) {
			out = renderVTGlyph(out, prev, width-1, plan, clustered, marks.content)
		} else {
			// The row holds the glyph already; a tab with no stop left
			// reaches the deferred wrap after it.
			out = append(out, '\t')
		}
		end = last
	default:
		out = appendVTCSICount(out, width, 'G')
		out = append(out, ' ')
		eraseLast = true
		end = vtCell{r: ' ', width: 1}
	}
	out = append(out, "\x1b[0m"...)
	eraseFirst := false
	var plan vtGlyphPlan
	if first := next[0]; first.r != 0 && (first.width == 1 || first.width == 2 && len(next) > 1) {
		plan = planVTGlyph(first, end, clustered, vtEdge(len(next), 0))
	}
	if plan.whole(next[0]) {
		out = renderVTGlyph(out, next, 0, plan, clustered, nil)
	} else {
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
// cells at the end of the row are left out. Each glyph is printed for a client
// that clusters graphemes (planVTGlyph), as a frame paints a stored line.
func renderVTCells(out []byte, row []vtCell) []byte {
	return renderVTCellsMarked(out, row, nil, true)
}

// renderVTCellsMarked is renderVTCells with the semantic prompt marks of the
// prompt being painted, if any, put before the written cells they change, for
// a client whose mode 2027 is clustered.
func renderVTCellsMarked(out []byte, row []vtCell, marks *vtSemanticFrame, clustered bool) []byte {
	end := len(row)
	for end > 0 && row[end-1].isDefaultUnwritten() {
		end--
	}
	current := vtAttrs{}
	// left is the glyph the client holds before the cursor.
	left := vtCell{width: 1}
	// The glyphs from moved on, which printing in place would push to the
	// next row or erase, are printed one column to their left while the row
	// is still blank and moved right with ICH, each as the content it was
	// written as. That is set with the cursor where they are printed, perhaps
	// the start of the row, where a C would end the row's mark, so as content
	// alone; the cells before them then set the content again, so the last
	// one's is set once more after them, where they are, as any cell's is.
	moved := vtMovedRun(row, clustered)
	if moved < len(row) {
		if moved > 1 {
			out = appendVTCSICount(out, moved-1, 'C')
		}
		// The glyph left of that column may be there already, from a soft
		// wrap.
		printed := vtGlyphBefore(row, moved-1)
		for i := moved; i < len(row); i++ {
			cell := row[i]
			plan := planVTGlyph(cell, printed, clustered, false)
			if plan.n == 0 {
				out = appendVTCSICount(out, 1, 'C')
				printed = vtCell{width: 1}
				continue
			}
			out = marks.content(out, cell.sem)
			if cell.attrs != current {
				out = appendVTSGR(out, cell.attrs)
				current = cell.attrs
			}
			out = appendVTGlyph(out, cell, plan, clustered, cell, marks.content)
			printed = plan.printed(cell)
		}
		out = append(out, "\x1b[0m"...)
		out = appendVTCSICount(out, len(row)-moved, 'D')
		out = append(out, "\x1b[@\r"...)
		current, end = vtAttrs{}, moved
	}
	// The glyph before moved ones must not widen over them on its way.
	edge := func(col int) bool {
		return vtEdge(len(row), col) || col == moved-1 && row[col].width == 1
	}
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
			left = vtCell{width: 1}
			i = run
			continue
		}
		if run := vtStandaloneRun(row, i, end, left, clustered, edge); run > i+int(cell.width) {
			out, current, left = appendVTStandaloneRun(out, row, i, run, left, marks, clustered, current, edge)
			i = run
			continue
		}
		if cell.r < 0x80 && len(cell.comb) == 0 {
			// Most cells: ASCII prints alike in both modes and joins nothing.
			out = marks.cell(out, i, cell.sem)
			if cell.attrs != current {
				out = appendVTSGR(out, cell.attrs)
				current = cell.attrs
			}
			out = append(out, byte(cell.r))
			left = cell
			i++
			continue
		}
		plan := planVTGlyph(cell, left, clustered, edge(i))
		if plan.n == 0 {
			// A glyph the client cannot start here stays unwritten.
			out = appendVTCSICount(out, int(cell.width), 'C')
			left = vtCell{width: 1}
			i++
			continue
		}
		out = marks.cell(out, i, cell.sem)
		if cell.attrs != current {
			out = appendVTSGR(out, cell.attrs)
			current = cell.attrs
		}
		half := vtGlyphHalf(row, i)
		var content vtContentSwitch
		if plan.widens > 0 {
			content = func(out []byte, sem uint8) []byte { return marks.cell(out, i+1, sem) }
		}
		out = appendVTGlyph(out, cell, plan, clustered, half, content)
		if plan.widens > 0 {
			current = half.attrs
		}
		left = plan.printed(cell)
		i++
		if plan.spills && i < len(row) && row[i].unwritten() {
			// The glyph was wide on its way to one column and left its
			// second half behind, which the model may have erased since.
			if row[i].attrs != current {
				out = appendVTSGR(out, row[i].attrs)
				current = row[i].attrs
			}
			out = append(out, "\x1b[X"...)
		}
	}
	if moved < len(row) {
		out = marks.cell(out, len(row)-1, row[len(row)-1].sem)
	}
	return out
}

// appendVTStandaloneRun paints the glyph at col of row and the run after it
// up to stop that would join it if printed after it (vtStandaloneRun): the
// run first, from the right, each glyph onto blank cells, then the glyph at
// col, where the client's cursor is. The run's glyphs are printed as the
// content they were written as, set alone; once the glyph at col is painted
// with its marks, theirs follow, in column order and where they are, as any
// cell's (renderVTCellsMarked), so the app sees the marks a painting from the
// left would put there. It returns, for renderVTCellsMarked, the rendition in
// force and the glyph before the cursor, which it leaves at stop.
func appendVTStandaloneRun(
	out []byte,
	row []vtCell,
	col, stop int,
	left vtCell,
	marks *vtSemanticFrame,
	clustered bool,
	current vtAttrs,
	edge func(int) bool,
) ([]byte, vtAttrs, vtCell) {
	cell := row[col]
	if col == 0 {
		// The row is blank but for the glyph a soft wrap onto it printed.
		out = appendVTCSICount(out, int(cell.width), 'X')
	}
	var run []int
	for c := col + int(cell.width); c < stop; c += int(row[c].width) {
		run = append(run, c)
	}
	var last vtCell
	for k, c := range slices.Backward(run) {
		glyph, half := row[c], vtGlyphHalf(row, c)
		plan := planVTGlyph(glyph, vtCell{width: 1}, clustered, edge(c))
		out = appendVTCSICount(out, c+1, 'G')
		out = marks.content(out, glyph.sem)
		if glyph.attrs != current {
			out = appendVTSGR(out, glyph.attrs)
			current = glyph.attrs
		}
		out = appendVTGlyph(out, glyph, plan, clustered, half, marks.content)
		if plan.widens > 0 {
			current = half.attrs
		}
		if k == len(run)-1 {
			last = plan.printed(glyph)
		}
	}
	out = appendVTCSICount(out, col+1, 'G')
	out = marks.cell(out, col, cell.sem)
	plan := planVTGlyph(cell, left, clustered, edge(col))
	if cell.attrs != current {
		out = appendVTSGR(out, cell.attrs)
		current = cell.attrs
	}
	half := vtGlyphHalf(row, col)
	var content vtContentSwitch
	if plan.widens > 0 {
		content = func(out []byte, sem uint8) []byte { return marks.cell(out, col+1, sem) }
	}
	out = appendVTGlyph(out, cell, plan, clustered, half, content)
	if plan.widens > 0 {
		current = half.attrs
	}
	for _, c := range run {
		glyph := row[c]
		if marks.changes(glyph.sem) {
			out = appendVTCSICount(out, c+1, 'G')
			out = marks.cell(out, c, glyph.sem)
		}
		half := vtGlyphHalf(row, c)
		if planVTGlyph(glyph, vtCell{width: 1}, clustered, edge(c)).widens > 0 && marks.changes(half.sem) {
			out = appendVTCSICount(out, c+2, 'G')
			out = marks.cell(out, c+1, half.sem)
		}
	}
	if stop < len(row) {
		out = appendVTCSICount(out, stop+1, 'G')
	}
	return out, current, last
}

// vtMovedRun is the first column of the glyphs renderVTCellsMarked moves into
// place at the end of row, or len(row) for none. The last column may hold a
// cluster wide on its way to one column, which a resize or an insertion left
// there: printed there, it would move to the next row. So it is moved in from
// the column before, and so is every such cluster before it, since printing
// one in place would write over the next, as long as a column is left before
// them to move them in from. Without one, the first is printed short of what
// would widen it, or not at all.
func vtMovedRun(row []vtCell, clustered bool) int {
	edge := len(row) - 1
	if edge < 1 || row[edge].width != 1 || row[edge].r == 0 {
		return len(row)
	}
	cell := row[edge]
	fit := planVTGlyph(cell, vtGlyphBefore(row, edge), clustered, true)
	if fit.whole(cell) || planVTGlyph(cell, vtGlyphBefore(row, edge-1), clustered, false).n <= fit.n {
		return len(row)
	}
	moved := edge
	for moved > 1 {
		prev := row[moved-1]
		if prev.width != 1 || prev.r == 0 ||
			planVTGlyph(prev, vtGlyphBefore(row, moved-1), clustered, true).whole(prev) {
			break
		}
		moved--
	}
	return moved
}

// vtGlyphHalf is the second half of the glyph at col of row, or the glyph
// itself for a glyph one column wide.
func vtGlyphHalf(row []vtCell, col int) vtCell {
	if row[col].width == 2 && col+1 < len(row) {
		return row[col+1]
	}
	return row[col]
}

// renderVTGlyph prints the glyph at col of row as plan says, in its
// rendition, so the client's cursor ends up after it with any deferred wrap
// it causes. Spaces stand in for a never-written cell and for one the plan
// cannot start. clustered is the client's mode 2027, and content sets the
// content of a second half a code point writes, as the glyph's was set.
func renderVTGlyph(out []byte, row []vtCell, col int, plan vtGlyphPlan, clustered bool, content vtContentSwitch) []byte {
	cell := row[col]
	if cell.attrs != (vtAttrs{}) {
		out = appendVTSGR(out, cell.attrs)
	}
	if cell.r == 0 || plan.n == 0 {
		for range max(int(cell.width), 1) {
			out = append(out, ' ')
		}
		return out
	}
	return appendVTGlyph(out, cell, plan, clustered, vtGlyphHalf(row, col), content)
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
