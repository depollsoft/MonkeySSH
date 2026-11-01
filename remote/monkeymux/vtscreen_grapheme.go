package main

import "slices"

// Grapheme clustering in the screen model is DEC private mode 2027, set by
// default and by RIS, left alone by DECSTR, as in Ghostty. With it set, a code
// point that continues the cluster in the glyph before the cursor joins that
// glyph's cell, which may turn wide or narrow, instead of taking a cell of its
// own (joinCluster). With it reset, only code points of width 0 join the glyph
// before the cursor, and never change its width (attachCombining). The
// client's Buffer.writeChar in third_party/xterm follows the same rules, and
// both pass testdata/grapheme_cluster_parity.json: a frame painted from the
// model has to land on the cells the client laid out from the same output.

// vtModeChangeReach is how far back from the latest output a replay of
// retained output can start: the longest history a window keeps.
const vtModeChangeReach = windowFullReplayHistoryLimitBytes

// setGraphemeCluster sets mode 2027, recording where it changed for
// GraphemeClusterAt. Each change takes a sequence of output (RIS, at
// least), so the output within vtModeChangeReach bounds how many are kept.
func (s *terminalScreen) setGraphemeCluster(on bool) {
	if on == s.graphemeCluster {
		return
	}
	s.graphemeCluster = on
	s.graphemeChanges = append(s.graphemeChanges, s.written)
	// A change no replay starts before only sets the mode before the next.
	for len(s.graphemeChanges) > 1 && s.graphemeChanges[1] <= s.written-vtModeChangeReach {
		s.graphemeBefore = !s.graphemeBefore
		s.graphemeChanges = s.graphemeChanges[1:]
	}
}

// StartGraphemeCluster sets mode 2027 as it was before the output the model
// reads first, for a model built from a window's retained output.
func (s *terminalScreen) StartGraphemeCluster(on bool) {
	s.graphemeCluster, s.graphemeBefore = on, on
	s.graphemeChanges = nil
}

// GraphemeClusterAt reports whether mode 2027 was set at offset at of the
// output, in the terms of Written. A replay of retained output from there
// has to start in that mode to lay the output out as the model did, when
// the output changes the mode later on.
func (s *terminalScreen) GraphemeClusterAt(at int64) bool {
	// Each change flips the mode.
	changes, _ := slices.BinarySearch(s.graphemeChanges, at+1)
	return s.graphemeBefore != (changes%2 == 1)
}

// joinCluster prints r into the glyph before the cursor, with clustering on,
// when no grapheme cluster boundary falls between that glyph's code points and
// r. It reports whether it took r, appended to the glyph or dropped as part
// of it; false leaves r to start a glyph of its own.
func (s *terminalScreen) joinCluster(r rune) bool {
	g := s.grid()
	col := g.cursorCol
	// A pending wrap follows the glyph in the cursor's own cell, which on a
	// one-column screen is in column 0.
	if col == 0 && !g.pendingWrap {
		return false
	}
	row := g.rows[g.cursorRow]
	// The glyph before the cursor is the one a pending wrap follows, with or
	// without autowrap. Ghostty instead checks, without autowrap, whether the
	// last column holds anything, which picks an old glyph there after a
	// cursor move.
	prevCol := col - 1
	if g.pendingWrap {
		prevCol = col
	}
	if row[prevCol].width == 0 && prevCol > 0 {
		prevCol--
	}
	cell := &row[prevCol]
	if cell.r == 0 {
		return false
	}
	last, brk := vtClusterBreak(*cell, r)
	if brk {
		return false
	}
	if len(cell.comb) >= vtCombiningLimit {
		return true
	}
	switch graphemeWidthEffectOf(last, r) {
	case graphemeIgnore:
		return true
	case graphemeWide:
		if cell.width == 2 {
			break
		}
		if prevCol == s.width-1 {
			// Without autowrap, or on a one-column screen, which has no room
			// for the second half on any row, the glyph stays as it is.
			if !s.autowrap || s.width < 2 {
				return true
			}
			// A glyph widened in the last column moves to the next row, as a
			// wide glyph printed there does, leaving the cell erased.
			moved := *cell
			row[prevCol] = s.blankCell()
			s.wrapToNextLine()
			row, prevCol = g.rows[g.cursorRow], 0
			row[0] = vtCell{r: moved.r, comb: moved.comb, width: 2, sem: s.semantic().content, attrs: s.attrs}
			cell = &row[0]
		} else {
			cell.width = 2
		}
		half := prevCol + 1
		if half+1 < len(row) && row[half].width == 2 {
			row[half+1] = blankedHalf(row[half+1])
		}
		row[half] = vtCell{width: 0, sem: s.semantic().content, attrs: s.attrs}
		if half == s.width-1 {
			g.cursorCol, g.pendingWrap = half, true
		} else {
			g.cursorCol, g.pendingWrap = half+1, false
		}
	case graphemeNarrow:
		if cell.width != 2 {
			break
		}
		cell.width = 1
		// The second half is left an empty cell with its background.
		if prevCol+1 < len(row) {
			row[prevCol+1] = blankedHalf(row[prevCol+1])
		}
		g.cursorCol, g.pendingWrap = min(prevCol+1, s.width-1), false
	}
	cell.comb = append(cell.comb, r)
	return true
}

// vtClusterBreak replays the code points of a glyph cell through the
// grapheme break rules and reports whether a cluster ends between them and r,
// along with the last of them.
func vtClusterBreak(cell vtCell, r rune) (last rune, brk bool) {
	var state graphemeBreakState
	last = cell.r
	for _, x := range cell.comb {
		graphemeBreak(last, x, &state)
		last = x
	}
	return last, graphemeBreak(last, r, &state)
}

// appendVTGraphemeMode sets or resets mode 2027.
func appendVTGraphemeMode(out []byte, on bool) []byte {
	if on {
		return append(out, "\x1b[?2027h"...)
	}
	return append(out, "\x1b[?2027l"...)
}

// vtGlyphPlan is how a frame prints the code points of a glyph cell, its base
// first: the first n of them, each with clustering set where its bit in
// clustered is set and reset where it is clear. n is 0 for a cell the client
// cannot start where it is.
type vtGlyphPlan struct {
	n         int
	clustered uint16
	// widens is the code point after the base that last turns the cell
	// wide, which writes its second half in the rendition then current, or
	// 0, and wideAt the one it is first wide after, 0 for a base that starts
	// wide. spills reports a cell left one column wide that was wide on the
	// way, whose second half stays behind as an empty cell.
	widens int
	wideAt int
	spills bool
}

// whole reports whether the plan prints every code point of cell.
func (p vtGlyphPlan) whole(cell vtCell) bool {
	return p.n == 1+len(cell.comb)
}

// printed is the cell the client holds once the plan has printed cell.
func (p vtGlyphPlan) printed(cell vtCell) vtCell {
	if p.n == 0 {
		return vtCell{width: 1}
	}
	cell.comb = cell.comb[:p.n-1]
	return cell
}

// planVTGlyph plans how a frame prints cell at the client's cursor so that the
// client builds the cell the model holds: the same code points, in one cell of
// the same width. Mostly that is printing them all under the mode the client
// is in, clustered, but a cell written under the other mode, or painted next
// to a glyph it was not printed after, may need the other mode for some of its
// code points, and the plan switches as rarely as it can. left is the glyph
// the client may join the first code point to: the one before the cursor, or
// the one a pending wrap follows, or none (a zero cell). edge reports a cell
// in the last column, which a code point widening it would move to the next
// row. A cell the client cannot rebuild whole loses the code points at its
// end it would not take.
func planVTGlyph(cell vtCell, left vtCell, clustered, edge bool) vtGlyphPlan {
	if len(cell.comb) == 0 {
		return planVTSingleGlyph(cell, left, clustered, edge)
	}
	const unreachable = 1 << 30
	cell.comb = cell.comb[:min(len(cell.comb), vtCombiningLimit)]
	// Each code point printed at full fidelity costs nothing, a mode switch
	// one, and each one left out more than every switch together.
	const dropCost = 1 + vtCombiningLimit + 1
	switchCost := func(from, to int) int {
		if from != to {
			return 1
		}
		return 0
	}
	start := 0
	if clustered {
		start = 1
	}
	want := int(cell.width) - 1
	if want < 0 || want > 1 {
		return vtGlyphPlan{}
	}
	// cost[w][m] is the cheapest way to print the code points so far into a
	// cell of width w+1, the last of them with clustering m (1 set); from
	// records the state each step was reached from, w<<1|m.
	var cost [2][2]int
	var from [1 + vtCombiningLimit][2][2]uint8
	for w := range cost {
		cost[w] = [2]int{unreachable, unreachable}
	}
	for m := range 2 {
		width := runeWidth(cell.r)
		if m == 1 {
			if left.r != 0 && graphemeMayContinue(cell.r) {
				if _, brk := vtClusterBreak(left, cell.r); !brk {
					continue
				}
			}
			width = graphemeStartWidth(cell.r)
		}
		if width < 1 || width > 2 || edge && width == 2 {
			continue
		}
		cost[width-1][m] = switchCost(start, m)
	}
	best, bestCost, bestMode := 0, unreachable, 0
	consider := func(n int) {
		total := (1 + len(cell.comb) - n) * dropCost
		for m := range 2 {
			if c := cost[want][m] + total; c < bestCost {
				best, bestCost, bestMode = n, c, m
			}
		}
	}
	consider(1)
	var state graphemeBreakState
	last := cell.r
	for i, x := range cell.comb {
		brk := graphemeBreak(last, x, &state)
		effect := graphemeWidthEffectOf(last, x)
		last = x
		joins := !brk && effect != graphemeIgnore
		attaches := runeWidth(x) == 0 &&
			(!isEmojiVariationSelector(x) || isExtendedPictographic(cell.r))
		var next [2][2]int
		for w := range next {
			next[w] = [2]int{unreachable, unreachable}
		}
		step := func(w, m, c int, parent uint8) {
			if c < next[w][m] {
				next[w][m] = c
				from[i+1][w][m] = parent
			}
		}
		for w := range 2 {
			for m := range 2 {
				c := cost[w][m]
				if c >= unreachable {
					continue
				}
				parent := uint8(w<<1 | m)
				if joins {
					switch {
					case effect == graphemeWide && w == 0 && edge:
					case effect == graphemeWide:
						step(1, 1, c+switchCost(m, 1), parent)
					case effect == graphemeNarrow:
						step(0, 1, c+switchCost(m, 1), parent)
					default:
						step(w, 1, c+switchCost(m, 1), parent)
					}
				}
				if attaches {
					step(w, 0, c+switchCost(m, 0), parent)
				}
			}
		}
		cost = next
		consider(i + 2)
	}
	if bestCost >= unreachable {
		return vtGlyphPlan{}
	}
	plan := vtGlyphPlan{n: best}
	w, m := want, bestMode
	for i := best - 1; i >= 0; i-- {
		if m == 1 {
			plan.clustered |= 1 << i
		}
		if w == 1 {
			plan.spills = want == 0
			plan.wideAt = i
		}
		if i > 0 {
			parent := from[i][w][m]
			if w == 1 && parent>>1 == 0 && plan.widens == 0 {
				plan.widens = i
			}
			w, m = int(parent>>1), int(parent&1)
		}
	}
	return plan
}

// planVTSingleGlyph is planVTGlyph for a glyph of one code point, most of
// them: printed under the mode the client is in unless that mode starts it at
// another width or joins it to the glyph before.
func planVTSingleGlyph(cell vtCell, left vtCell, clustered, edge bool) vtGlyphPlan {
	width := int(cell.width)
	if edge && width == 2 {
		return vtGlyphPlan{}
	}
	legacy := runeWidth(cell.r)
	if !graphemeMayContinue(cell.r) {
		// Nearly all of Latin-1 joins no cluster, and starts at its width.
		if legacy != width {
			return vtGlyphPlan{}
		}
		if clustered {
			return vtGlyphPlan{n: 1, clustered: 1}
		}
		return vtGlyphPlan{n: 1}
	}
	start := legacy
	if start == 0 {
		start = graphemeStartWidth(cell.r)
	}
	joins := false
	if left.r != 0 {
		_, brk := vtClusterBreak(left, cell.r)
		joins = !brk
	}
	switch g := start == width && !joins; {
	case g && (clustered || legacy != width):
		return vtGlyphPlan{n: 1, clustered: 1}
	case legacy == width:
		return vtGlyphPlan{n: 1}
	}
	return vtGlyphPlan{}
}

// vtContentSwitch puts the semantic content a cell is written as in force on
// the client, as the frame's marks do (vtSemanticFrame), or nil for none.
type vtContentSwitch func(out []byte, sem uint8) []byte

// appendVTGlyph prints the code points of cell as plan says, switching mode
// 2027 away from clustered for those it prints under the other mode and back
// after them. The client is in cell's rendition and content, and switches to
// those of half, the cell's second half, for the code point that last widens
// it, which writes that half: the content through content.
func appendVTGlyph(out []byte, cell vtCell, plan vtGlyphPlan, clustered bool, half vtCell, content vtContentSwitch) []byte {
	var buf [utf8Max]byte
	mode := clustered
	for i := range plan.n {
		r := cell.r
		if i > 0 {
			r = cell.comb[i-1]
		}
		if i == plan.widens && i > 0 {
			if content != nil {
				out = content(out, half.sem)
			}
			if half.attrs != cell.attrs {
				out = appendVTSGR(out, half.attrs)
			}
		}
		if set := plan.clustered&(1<<i) != 0; set != mode {
			out = appendVTGraphemeMode(out, set)
			mode = set
		}
		out = append(out, encodeRune(buf[:], r)...)
	}
	if mode != clustered {
		out = appendVTGraphemeMode(out, clustered)
	}
	return out
}

// vtEdge reports whether col is the last column of a row width columns wide,
// where planVTGlyph's edge applies: a glyph printed wide there, or widened,
// moves to the next row. A one-column row prints a wide glyph in place, and
// leaves one a code point would widen as it is.
func vtEdge(width, col int) bool {
	return col == width-1 && width > 1
}

// vtGlyphBefore is the glyph a code point printed at col of row may join: the
// cell left of col, or the first half of the wide glyph that cell ends, or
// none at the first column.
func vtGlyphBefore(row []vtCell, col int) vtCell {
	if col <= 0 || col > len(row) {
		return vtCell{width: 1}
	}
	col--
	if row[col].width == 0 && col > 0 {
		col--
	}
	return row[col]
}

// vtStandaloneRun is the end of the run of glyphs after the one at col of
// row, short of end, that printed after the glyph to their left would join
// it, as a skin tone swatch an emoji was later painted before does, but
// printed with nothing to their left stand alone. A frame prints them first,
// from the right, onto blank cells, and then the glyph at col
// (appendVTStandaloneRun). left is the glyph before col on the client, and
// edge reports a column a code point widening the glyph there would move it
// to the next row from. Without such a run it returns the column after the
// glyph at col. The run stops before a glyph that would leave a second half
// on the one to its right, as the glyph at col must not.
func vtStandaloneRun(row []vtCell, col, end int, left vtCell, clustered bool, edge func(int) bool) int {
	cell := row[col]
	next := col + int(cell.width)
	if next >= end || !vtMayJoinLeft(row[next]) {
		return next
	}
	plan := planVTGlyph(cell, left, clustered, edge(col))
	if !plan.whole(cell) || plan.spills {
		return next
	}
	stop, prev := next, plan.printed(cell)
	for next < end && vtMayJoinLeft(row[next]) {
		glyph := row[next]
		if planVTGlyph(glyph, prev, clustered, edge(next)).whole(glyph) {
			break
		}
		alone := planVTGlyph(glyph, vtCell{width: 1}, clustered, edge(next))
		if !alone.whole(glyph) || alone.spills {
			break
		}
		prev = alone.printed(glyph)
		next += int(glyph.width)
		stop = next
	}
	return stop
}

// vtMayJoinLeft reports whether cell holds a glyph that may join the one to
// its left when printed after it.
func vtMayJoinLeft(cell vtCell) bool {
	return cell.r >= 0x80 && cell.width != 0 && graphemeMayContinue(cell.r)
}
