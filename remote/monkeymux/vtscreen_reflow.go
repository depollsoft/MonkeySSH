package main

// vtLine is a main-screen line while it is reflowed: its cells, whether it
// continues the line above it, and the anchors on it.
type vtLine struct {
	cells   []vtCell
	wrapped bool
	anchors []vtReflowAnchor
	// prompt is the line's semantic prompt row mark.
	prompt uint8
}

// vtReflowAnchor is a cell on a line being reflowed, carried along like the
// client's CellAnchor: the cursor's (vtReflowCursorAnchor), or a Kitty
// placement's, by its index. x may be the column past the last one, where a
// deferred wrap leaves the cursor.
type vtReflowAnchor struct {
	id int
	x  int
}

// vtReflowCursorAnchor identifies the cursor's anchor.
const vtReflowCursorAnchor = -1

// vtReflowMarkAnchor is the anchor id of a prompt mark carried through a
// reflow with the first cell of its row, with the mark below it: vtReflow adds
// and removes them itself, so no other anchor id is this low.
const vtReflowMarkAnchor = -2

// vtStartsPrompt reports a mark the shell set as a prompt starting on its row
// (SemanticPromptRow.startsPrompt in the client), which a reflow keeps with the
// row's text, rather than one a row got by being reached inside a prompt.
func vtStartsPrompt(mark uint8) bool {
	return mark == vtPromptPrimary || mark == vtPromptSecondary
}

// vtReflow rewraps lines from oldWidth to newWidth. Each logical line, a line
// and the wrapped lines after it, is joined and split again; every resulting
// line has newWidth cells. Each anchor moves with its cell.
//
// This is a port of reflow() in third_party/xterm/lib/src/core/reflow.dart,
// including its corners, because the model has to land on the rows the
// client shows: an empty line keeps its place inside a logical line, a
// line that only grows keeps its cells past its content, and a wide glyph
// that would straddle the new edge moves whole to the next line. The anchors
// follow the rules for the client's CellAnchor.
func vtReflow(lines []vtLine, oldWidth, newWidth int) []vtLine {
	out := make([]vtLine, 0, len(lines))
	for i := 0; i < len(lines); i++ {
		r := vtLineReflow{oldWidth: oldWidth, newWidth: newWidth}
		first := lines[i].prompt
		marked := first != vtPromptNone
		r.add(lines[i])
		for i+1 < len(lines) && lines[i+1].wrapped {
			i++
			line := lines[i]
			marked = marked || line.prompt != vtPromptNone
			if vtStartsPrompt(line.prompt) {
				// A prompt the shell marked on a row inside the logical line
				// (VS Code's A after output that wrapped, a secondary prompt
				// after prompt text that did) travels with the first cell of
				// that row, like any anchor.
				line.anchors = append(line.anchors,
					vtReflowAnchor{id: vtReflowMarkAnchor - int(line.prompt)})
			}
			r.add(line)
		}
		// The line keeps its prompt mark on its first row; the rows it wraps
		// onto continue it when any of its rows was part of a prompt, and the
		// row that now holds the start of a marked row's text takes its mark,
		// unless a prompt starts on it already.
		reflowed := r.finish()
		for j := range reflowed {
			switch {
			case j == 0:
				reflowed[j].prompt = first
			case marked:
				reflowed[j].prompt = vtPromptContinuation
			default:
				reflowed[j].prompt = vtPromptNone
			}
		}
		for j := range reflowed {
			reflowed[j].anchors = vtTakeMarkAnchors(reflowed[j].anchors, &reflowed[j].prompt)
		}
		out = append(out, reflowed...)
	}
	for i := range out {
		out[i].cells = vtCloseSplitGlyphs(resizeVTRow(out[i].cells, newWidth))
		vtClampAnchors(out[i].anchors, newWidth)
	}
	return out
}

// vtTakeMarkAnchors removes the mark anchors from anchors, in place, and sets
// the first of them as the line's mark unless a prompt starts on it already.
func vtTakeMarkAnchors(anchors []vtReflowAnchor, mark *uint8) []vtReflowAnchor {
	kept := anchors[:0]
	for _, anchor := range anchors {
		if anchor.id > vtReflowMarkAnchor {
			kept = append(kept, anchor)
			continue
		}
		if !vtStartsPrompt(*mark) {
			*mark = uint8(vtReflowMarkAnchor - anchor.id)
		}
	}
	return kept
}

// vtCloseSplitGlyphs blanks a wide glyph's half left alone at either edge of
// a row: a first half in the last column, or a second half in the first. Only
// a one-column screen splits a wide glyph so, and a glyph wider than its row
// would make the next reflow read past the row's end.
func vtCloseSplitGlyphs(row []vtCell) []vtCell {
	if last := len(row) - 1; last >= 0 && row[last].width == 2 {
		row[last] = blankedHalf(row[last])
	}
	if len(row) > 0 && row[0].width == 0 {
		row[0] = blankedHalf(row[0])
	}
	return row
}

// vtClampAnchors keeps anchors within a line cut or grown to length, as
// resizing a BufferLine repositions its anchors.
func vtClampAnchors(anchors []vtReflowAnchor, length int) {
	for i := range anchors {
		anchors[i].x = min(anchors[i].x, length)
	}
}

// vtLineReflow is the reflow of one logical line (_LineReflow in the client).
// cells and filled are the line being built: filled counts the cells placed
// in it, while cells may run further when the builder reuses a line that only
// grows, whose cells past its content are kept. anchors are the anchors that
// have moved onto that line.
type vtLineReflow struct {
	oldWidth int
	newWidth int
	lines    []vtLine
	cells    []vtCell
	filled   int
	anchors  []vtReflowAnchor
}

func (r *vtLineReflow) add(line vtLine) {
	trimmed := vtTrimmedLength(line.cells, r.oldWidth)
	if trimmed == 0 {
		// Cells still waiting in the builder come before an empty line, or
		// an erased continuation row would land ahead of the text it
		// continued.
		if r.filled > 0 {
			r.lines = append(r.lines, r.take())
		}
		r.lines = append(r.lines, line)
		return
	}
	if len(r.lines) > 0 || r.filled > 0 {
		r.addPart(&line, 0, trimmed)
		return
	}
	if r.newWidth >= r.oldWidth {
		r.cells, r.filled, r.anchors = line.cells, trimmed, line.anchors
		return
	}
	// The line stays first; addPart appends the lines its tail fills after it.
	head := len(r.lines)
	r.lines = append(r.lines, line)
	if trimmed > r.newWidth {
		from := r.newWidth
		if line.cells[r.newWidth-1].width == 2 {
			from--
		}
		r.addPart(&line, from, trimmed)
	}
	line.cells = resizeVTRow(line.cells, r.newWidth)
	vtClampAnchors(line.anchors, r.newWidth)
	r.lines[head] = line
}

// addPart appends cells [from, to) of line, starting a new line each time the
// current one fills up. An anchor in the range moves with its cell, one at
// the end of it with the last cell, and one past it to the same distance past
// the appended cells.
func (r *vtLineReflow) addPart(line *vtLine, from, to int) {
	src := line.cells
	for left := to - from; left > 0; {
		count := left
		lineFilled := false
		if remaining := r.newWidth - r.filled; count >= remaining {
			count = remaining
			lineFilled = true
		}
		// A wide glyph that would end the line moves on to the next one. With
		// one cell left the line ends there instead, and only a line one
		// column wide takes the glyph's first half, so the reflow progresses.
		if lineFilled && src[from+count-1].width == 2 {
			if count > 1 {
				count--
			} else if r.filled > 0 {
				count = 0
			}
		}
		end := from + count
		line.anchors = r.takeAnchors(line.anchors, r.filled-from, func(x int) bool {
			return x >= from && (x < end || (x == to && end == to))
		})
		r.cells = append(r.cells[:r.filled], src[from:end]...)
		r.filled += count
		vtClampAnchors(r.anchors, r.filled)
		from += count
		left -= count
		if lineFilled {
			r.lines = append(r.lines, r.take())
		}
	}
	line.anchors = r.takeAnchors(line.anchors, r.filled-to, func(x int) bool {
		return x >= to
	})
}

// takeAnchors moves the anchors moved selects onto the line being built,
// shifted by offset, and returns the ones left. anchors itself is left as it
// was, and a new slice is made only when an anchor moves.
func (r *vtLineReflow) takeAnchors(
	anchors []vtReflowAnchor,
	offset int,
	moved func(x int) bool,
) []vtReflowAnchor {
	var left []vtReflowAnchor
	for i, anchor := range anchors {
		if !moved(anchor.x) {
			if left != nil {
				left = append(left, anchor)
			}
			continue
		}
		if left == nil {
			left = append(make([]vtReflowAnchor, 0, len(anchors)), anchors[:i]...)
		}
		r.anchors = append(r.anchors, vtReflowAnchor{id: anchor.id, x: anchor.x + offset})
	}
	if left == nil {
		return anchors
	}
	return left
}

func (r *vtLineReflow) take() vtLine {
	line := vtLine{cells: r.cells, wrapped: len(r.lines) > 0, anchors: r.anchors}
	r.cells, r.filled, r.anchors = nil, 0, nil
	return line
}

// finish returns the logical line's new lines. An anchor left on a line that
// never received a cell is dropped with it, as in the client.
func (r *vtLineReflow) finish() []vtLine {
	if r.filled > 0 {
		r.lines = append(r.lines, r.take())
	}
	return r.lines
}

// vtTrimmedLength is the column just past the last glyph within the first
// width cells: BufferLine.getTrimmedLength in the client, where any written
// cell counts, a space included.
func vtTrimmedLength(row []vtCell, width int) int {
	for i := min(width, len(row)) - 1; i >= 0; i-- {
		if row[i].r != 0 {
			return min(i+max(int(row[i].width), 1), len(row))
		}
	}
	return 0
}
