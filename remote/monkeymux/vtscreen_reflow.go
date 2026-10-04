package main

// vtLine is a main-screen line while it is reflowed: its cells, whether it
// continues the line above it, and the cursor when it is on this line.
type vtLine struct {
	cells   []vtCell
	wrapped bool
	cursor  vtReflowCursor
}

// vtReflowCursor is the cursor's cell on a line being reflowed, carried along
// like the client's CellAnchor. x may be the column past the last one, where
// a deferred wrap leaves the cursor.
type vtReflowCursor struct {
	set bool
	x   int
}

// vtReflow rewraps lines from oldWidth to newWidth. Each logical line, a line
// and the wrapped lines after it, is joined and split again; every resulting
// line has newWidth cells. The cursor moves with its cell.
//
// This is a port of reflow() in third_party/xterm/lib/src/core/reflow.dart,
// including its corners, because the model has to land on the rows the
// client shows: an empty line keeps its place even inside a logical line, a
// line that only grows keeps its cells past its content, and a wide glyph
// that would straddle the new edge moves whole to the next line. The cursor
// follows the rules for the CellAnchor the client puts on its cell.
func vtReflow(lines []vtLine, oldWidth, newWidth int) []vtLine {
	out := make([]vtLine, 0, len(lines))
	for i := 0; i < len(lines); i++ {
		r := vtLineReflow{oldWidth: oldWidth, newWidth: newWidth}
		r.add(lines[i])
		for i+1 < len(lines) && lines[i+1].wrapped {
			i++
			r.add(lines[i])
		}
		out = append(out, r.finish()...)
	}
	for i := range out {
		out[i].cells = resizeVTRow(out[i].cells, newWidth)
		out[i].cursor.clamp(newWidth)
	}
	return out
}

// clamp keeps the cursor within a line cut or grown to length, as resizing a
// BufferLine repositions its anchors.
func (c *vtReflowCursor) clamp(length int) {
	if c.set && c.x > length {
		c.x = length
	}
}

// vtLineReflow is the reflow of one logical line (_LineReflow in the client).
// cells and filled are the line being built: filled counts the cells placed
// in it, while cells may run further when the builder reuses a line that only
// grows, whose cells past its content are kept. cursor is the cursor when it
// has moved onto that line.
type vtLineReflow struct {
	oldWidth int
	newWidth int
	lines    []vtLine
	cells    []vtCell
	filled   int
	cursor   vtReflowCursor
}

func (r *vtLineReflow) add(line vtLine) {
	trimmed := vtTrimmedLength(line.cells, r.oldWidth)
	if trimmed == 0 {
		r.lines = append(r.lines, line)
		return
	}
	if len(r.lines) > 0 || r.filled > 0 {
		r.addPart(&line, 0, trimmed)
		return
	}
	if r.newWidth >= r.oldWidth {
		r.cells, r.filled, r.cursor = line.cells, trimmed, line.cursor
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
	line.cursor.clamp(r.newWidth)
	r.lines[head] = line
}

// addPart appends cells [from, to) of line, starting a new line each time the
// current one fills up. A cursor in the range moves with its cell, one at the
// end of it with the last cell, and one past it to the same distance past the
// appended cells.
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
		if c := line.cursor; c.set && c.x >= from && (c.x < from+count || (c.x == to && from+count == to)) {
			r.cursor = vtReflowCursor{set: true, x: r.filled + c.x - from}
			line.cursor = vtReflowCursor{}
		}
		r.cells = append(r.cells[:r.filled], src[from:from+count]...)
		r.filled += count
		r.cursor.clamp(r.filled)
		from += count
		left -= count
		if lineFilled {
			r.lines = append(r.lines, r.take())
		}
	}
	if c := line.cursor; c.set && c.x >= to {
		r.cursor = vtReflowCursor{set: true, x: r.filled + c.x - to}
		line.cursor = vtReflowCursor{}
	}
}

func (r *vtLineReflow) take() vtLine {
	line := vtLine{cells: r.cells, wrapped: len(r.lines) > 0, cursor: r.cursor}
	r.cells, r.filled, r.cursor = nil, 0, vtReflowCursor{}
	return line
}

// finish returns the logical line's new lines. A cursor left on a line that
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
			return i + max(int(row[i].width), 1)
		}
	}
	return 0
}
