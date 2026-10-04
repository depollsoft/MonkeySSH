package main

// vtLine is a main-screen line while it is reflowed: its cells and whether it
// continues the line above it.
type vtLine struct {
	cells   []vtCell
	wrapped bool
}

// vtReflow rewraps lines from oldWidth to newWidth. Each logical line, a line
// and the wrapped lines after it, is joined and split again; every resulting
// line has newWidth cells.
//
// This is a port of reflow() in third_party/xterm/lib/src/core/reflow.dart,
// including its corners, because the model has to land on the rows the
// client shows: an empty line keeps its place even inside a logical line, a
// line that only grows keeps its cells past its content, and a wide glyph
// that would straddle the new edge moves whole to the next line.
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
	}
	return out
}

// vtLineReflow is the reflow of one logical line (_LineReflow in the client).
// cells and filled are the line being built: filled counts the cells placed
// in it, while cells may run further when the builder reuses a line that only
// grows, whose cells past its content are kept.
type vtLineReflow struct {
	oldWidth int
	newWidth int
	lines    []vtLine
	cells    []vtCell
	filled   int
}

func (r *vtLineReflow) add(line vtLine) {
	trimmed := vtTrimmedLength(line.cells, r.oldWidth)
	if trimmed == 0 {
		r.lines = append(r.lines, line)
		return
	}
	if len(r.lines) > 0 || r.filled > 0 {
		r.addPart(line.cells, 0, trimmed)
		return
	}
	if r.newWidth >= r.oldWidth {
		r.cells, r.filled = line.cells, trimmed
		return
	}
	head := len(r.lines)
	r.lines = append(r.lines, line)
	if trimmed > r.newWidth {
		from := r.newWidth
		if line.cells[r.newWidth-1].width == 2 {
			from--
		}
		r.addPart(line.cells, from, trimmed)
	}
	r.lines[head].cells = resizeVTRow(line.cells, r.newWidth)
}

// addPart appends cells [from, to) of src, starting a new line each time the
// current one fills up.
func (r *vtLineReflow) addPart(src []vtCell, from, to int) {
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
		r.cells = append(r.cells[:r.filled], src[from:from+count]...)
		r.filled += count
		from += count
		left -= count
		if lineFilled {
			r.lines = append(r.lines, r.take())
		}
	}
}

func (r *vtLineReflow) take() vtLine {
	line := vtLine{cells: r.cells, wrapped: len(r.lines) > 0}
	r.cells, r.filled = nil, 0
	return line
}

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
