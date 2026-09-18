package main

import (
	"unicode/utf8"
)

// terminalScreen is an authoritative screen model for a window: an xterm-style
// emulation of the pane output that can be rendered back into escape sequences
// at any time. MonkeyMux forwards raw bytes to attached clients, but whenever it
// needs to paint a client from scratch (a client attached while the foreground
// app coalesced its resize, an oversized repaint) the picture must come from
// here rather than from a tail of the byte history: a byte tail is not a frame.
//
// The model keeps the main and alternate grids, a bounded main-screen
// scrollback, the cursor, current rendition, tab stops, charsets, the scroll
// region and the DEC private modes that affect layout. Parser state persists
// across Write calls so sequences may be split at any byte boundary.
type terminalScreen struct {
	width  int
	height int

	main      vtGrid
	alt       vtGrid
	altActive bool

	// scrollback holds main-screen lines that scrolled off the top, already
	// rendered to escape sequences (attributes included, rendition left at
	// default). Bytes are far cheaper than cell rows and are exactly what
	// RenderFrame needs to emit.
	scrollback [][]byte

	attrs      vtAttrs
	top        int // scroll region, 0-based inclusive
	bottom     int
	originMode bool
	autowrap   bool
	insertMode bool
	cursorOn   bool
	tabs       []bool
	g0Graphics bool
	g1Graphics bool
	shiftOut   bool

	savedMain vtSavedCursor
	savedAlt  vtSavedCursor
	scoCursor vtSavedCursor

	lastPrinted rune

	parser vtParser
}

const (
	vtScrollbackLimit = 1000
	// Bounds on the grid a client can ask for: a malformed size must not
	// allocate an unbounded pair of cell grids.
	vtMaxColumns = 4096
	vtMaxRows    = 1024
	vtMaxCells   = 400_000
	// Per-sequence parser bounds; longer input is ignored, never retained.
	vtIntermediateLimit = 8
	vtCombiningLimit    = 8
)

// clampVTSize bounds a requested geometry to something a terminal can show.
func clampVTSize(width, height int) (int, int) {
	if width <= 0 {
		width = defaultColumns
	}
	if height <= 0 {
		height = defaultRows
	}
	width = clampInt(width, 1, vtMaxColumns)
	height = clampInt(height, 1, vtMaxRows)
	for width*height > vtMaxCells {
		if height > width {
			height = vtMaxCells / width
		} else {
			width = vtMaxCells / height
		}
	}
	return width, height
}

type vtGrid struct {
	rows        [][]vtCell
	cursorRow   int
	cursorCol   int
	pendingWrap bool
}

type vtSavedCursor struct {
	valid      bool
	row        int
	col        int
	attrs      vtAttrs
	originMode bool
	g0Graphics bool
	g1Graphics bool
	shiftOut   bool
}

// vtCell holds one grid cell. r == 0 means blank. width is 1 or 2 for a cell
// that starts a glyph and 0 for the continuation cell of a wide glyph.
type vtCell struct {
	r     rune
	comb  []rune
	width uint8
	attrs vtAttrs
}

func (c vtCell) blank() bool {
	return (c.r == 0 || c.r == ' ') && len(c.comb) == 0 && c.width != 0
}

func (c vtCell) isDefaultBlank() bool {
	return c.blank() && c.attrs == (vtAttrs{})
}

type vtColorKind uint8

const (
	vtColorDefault vtColorKind = iota
	vtColorIndexed
	vtColorRGB
)

type vtColor struct {
	kind  vtColorKind
	index uint8
	r     uint8
	g     uint8
	b     uint8
}

const (
	vtAttrBold uint16 = 1 << iota
	vtAttrDim
	vtAttrItalic
	vtAttrBlink
	vtAttrInverse
	vtAttrHidden
	vtAttrStrike
)

type vtAttrs struct {
	fg      vtColor
	bg      vtColor
	ul      vtColor
	flags   uint16
	ulStyle uint8 // 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed
}

func newTerminalScreen(width, height int) *terminalScreen {
	width, height = clampVTSize(width, height)
	s := &terminalScreen{width: width, height: height}
	s.main = newVTGrid(width, height)
	s.alt = newVTGrid(width, height)
	s.resetState()
	return s
}

func newVTGrid(width, height int) vtGrid {
	g := vtGrid{rows: make([][]vtCell, height)}
	for i := range g.rows {
		g.rows[i] = newVTRow(width)
	}
	return g
}

func newVTRow(width int) []vtCell {
	row := make([]vtCell, width)
	for i := range row {
		row[i].width = 1
	}
	return row
}

func (s *terminalScreen) resetState() {
	s.attrs = vtAttrs{}
	s.top = 0
	s.bottom = s.height - 1
	s.originMode = false
	s.autowrap = true
	s.insertMode = false
	s.cursorOn = true
	s.tabs = make([]bool, s.width)
	for i := 8; i < s.width; i += 8 {
		s.tabs[i] = true
	}
	s.g0Graphics = false
	s.g1Graphics = false
	s.shiftOut = false
	s.savedMain = vtSavedCursor{}
	s.savedAlt = vtSavedCursor{}
	s.scoCursor = vtSavedCursor{}
	s.parser = vtParser{}
}

// Reset is RIS: both grids are cleared and every mode returns to its default.
// The scrollback is kept.
func (s *terminalScreen) Reset() {
	s.main = newVTGrid(s.width, s.height)
	s.alt = newVTGrid(s.width, s.height)
	s.altActive = false
	s.resetState()
}

func (s *terminalScreen) Size() (int, int) {
	return s.width, s.height
}

func (s *terminalScreen) AlternateScreenActive() bool {
	return s.altActive
}

func (s *terminalScreen) grid() *vtGrid {
	if s.altActive {
		return &s.alt
	}
	return &s.main
}

// CursorPosition is 0-based and absolute on the active grid.
func (s *terminalScreen) CursorPosition() (int, int) {
	g := s.grid()
	return g.cursorRow, g.cursorCol
}

// Clone returns an independent deep copy.
func (s *terminalScreen) Clone() *terminalScreen {
	if s == nil {
		return nil
	}
	c := *s
	c.main = s.main.clone()
	c.alt = s.alt.clone()
	// Rendered lines are never mutated, so the clone may share them.
	c.scrollback = append([][]byte(nil), s.scrollback...)
	c.tabs = append([]bool(nil), s.tabs...)
	c.parser = s.parser.clone()
	return &c
}

func (g vtGrid) clone() vtGrid {
	c := g
	c.rows = make([][]vtCell, len(g.rows))
	for i, row := range g.rows {
		c.rows[i] = cloneVTRow(row)
	}
	return c
}

func cloneVTRow(row []vtCell) []vtCell {
	out := make([]vtCell, len(row))
	copy(out, row)
	for i := range out {
		if len(out[i].comb) > 0 {
			out[i].comb = append([]rune(nil), out[i].comb...)
		}
	}
	return out
}

// Resize changes both grids to width x height without reflow.
func (s *terminalScreen) Resize(width, height int) {
	if width <= 0 || height <= 0 {
		return
	}
	width, height = clampVTSize(width, height)
	if width == s.width && height == s.height {
		return
	}
	s.resizeGrid(&s.main, width, height, true)
	s.resizeGrid(&s.alt, width, height, false)
	if width != s.width {
		tabs := make([]bool, width)
		for i := range tabs {
			if i < len(s.tabs) {
				tabs[i] = s.tabs[i]
			} else {
				tabs[i] = i%8 == 0
			}
		}
		s.tabs = tabs
	}
	s.width = width
	s.height = height
	s.top = 0
	s.bottom = height - 1
	for _, saved := range []*vtSavedCursor{&s.savedMain, &s.savedAlt, &s.scoCursor} {
		if saved.row >= height {
			saved.row = height - 1
		}
		if saved.col >= width {
			saved.col = width - 1
		}
	}
}

func (s *terminalScreen) resizeGrid(g *vtGrid, width, height int, keepScrollback bool) {
	for i := range g.rows {
		g.rows[i] = resizeVTRow(g.rows[i], width)
	}
	if height < len(g.rows) {
		drop := len(g.rows) - height
		// Prefer dropping blank rows below the cursor; otherwise the top rows
		// leave the grid (and, on the main screen, enter the scrollback) so
		// the cursor row survives.
		fromTop := 0
		if g.cursorRow >= height {
			fromTop = g.cursorRow - height + 1
		}
		if fromTop > 0 {
			if keepScrollback {
				for _, row := range g.rows[:fromTop] {
					s.pushScrollback(row)
				}
			}
			g.rows = g.rows[fromTop:]
			g.cursorRow -= fromTop
			drop -= fromTop
		}
		if drop > 0 {
			g.rows = g.rows[:len(g.rows)-drop]
		}
	}
	for len(g.rows) < height {
		g.rows = append(g.rows, newVTRow(width))
	}
	if g.cursorCol >= width {
		g.cursorCol = width - 1
	}
	if g.cursorRow >= height {
		g.cursorRow = height - 1
	}
	g.pendingWrap = false
}

func resizeVTRow(row []vtCell, width int) []vtCell {
	if len(row) == width {
		return row
	}
	if len(row) > width {
		row = row[:width]
		// A wide glyph cut in half becomes a blank.
		if width > 0 && row[width-1].width == 2 {
			row[width-1] = vtCell{width: 1}
		}
		return row
	}
	out := make([]vtCell, width)
	copy(out, row)
	for i := len(row); i < width; i++ {
		out[i].width = 1
	}
	return out
}

func (s *terminalScreen) pushScrollback(row []vtCell) {
	line := renderVTCells(make([]byte, 0, 64), row, true)
	s.scrollback = append(s.scrollback, line)
	if len(s.scrollback) > vtScrollbackLimit {
		excess := len(s.scrollback) - vtScrollbackLimit
		copy(s.scrollback, s.scrollback[excess:])
		for i := len(s.scrollback) - excess; i < len(s.scrollback); i++ {
			s.scrollback[i] = nil
		}
		s.scrollback = s.scrollback[:len(s.scrollback)-excess]
	}
}

// HasVisibleContent reports whether the active grid paints anything: a glyph
// or a coloured background.
func (s *terminalScreen) HasVisibleContent() bool {
	if s == nil {
		return false
	}
	for _, row := range s.grid().rows {
		for _, cell := range row {
			if !cell.blank() || cell.attrs.bg.kind != vtColorDefault ||
				(cell.attrs.flags&vtAttrInverse != 0) {
				return true
			}
		}
	}
	return false
}

// TextRows returns the active grid as plain text, one string per row, with
// trailing spaces trimmed and wide glyphs emitted once.
func (s *terminalScreen) TextRows() []string {
	rows := make([]string, 0, s.height)
	for _, row := range s.grid().rows {
		rows = append(rows, vtRowText(row))
	}
	return rows
}

func vtRowText(row []vtCell) string {
	buf := make([]rune, 0, len(row))
	end := len(row)
	for end > 0 && row[end-1].blank() {
		end--
	}
	for _, cell := range row[:end] {
		if cell.width == 0 {
			continue
		}
		if cell.r == 0 {
			buf = append(buf, ' ')
		} else {
			buf = append(buf, cell.r)
		}
		buf = append(buf, cell.comb...)
	}
	return string(buf)
}

// ---- parser ---------------------------------------------------------------

type vtParserState uint8

const (
	vtGround vtParserState = iota
	vtEscape
	vtEscapeIntermediate
	vtCSIEntry
	vtCSIParam
	vtCSIIntermediate
	vtCSIIgnore
	vtOSCString
	vtOSCEscape
	vtSOSString // DCS, SOS, PM, APC: skipped until ST
	vtSOSEscape
)

const vtCSIParamLimit = 64

type vtParser struct {
	state         vtParserState
	params        []byte
	intermediates []byte
	private       byte
	utf8          [4]byte
	utf8Len       int
	utf8Need      int
	// stringUtf8 counts UTF-8 continuation bytes still expected inside an
	// OSC/DCS/APC string, so a 0x9c continuation byte is not taken for ST.
	stringUtf8 int
	// Scratch space reused by csiParams so dispatch allocates nothing.
	values []int
	starts []int
	groups [][]int
}

func (p vtParser) clone() vtParser {
	c := p
	c.params = append([]byte(nil), p.params...)
	c.intermediates = append([]byte(nil), p.intermediates...)
	c.values, c.starts, c.groups = nil, nil, nil
	return c
}

// inStringRune tracks multi-byte UTF-8 inside a control string and reports
// whether b is part of such a rune (and therefore never a terminator).
func (p *vtParser) inStringRune(b byte) bool {
	if p.stringUtf8 > 0 {
		if b&0xC0 == 0x80 {
			p.stringUtf8--
			return true
		}
		p.stringUtf8 = 0
		return false
	}
	switch {
	case b&0xE0 == 0xC0:
		p.stringUtf8 = 1
	case b&0xF0 == 0xE0:
		p.stringUtf8 = 2
	case b&0xF8 == 0xF0:
		p.stringUtf8 = 3
	default:
		return false
	}
	return true
}

func (p *vtParser) clear() {
	p.params = p.params[:0]
	p.intermediates = p.intermediates[:0]
	p.private = 0
}

// Write parses and applies pane output.
func (s *terminalScreen) Write(data []byte) {
	for i := 0; i < len(data); {
		b := data[i]
		if s.parser.state == vtGround && s.parser.utf8Need == 0 &&
			b >= 0x20 && b < 0x7f {
			i += s.printASCIIRun(data[i:])
			continue
		}
		s.step(b)
		i++
	}
}

// printASCIIRun writes a run of printable ASCII straight into the grid, the
// common case for transcript text, without the per-byte state machine. It
// returns how many bytes it consumed.
func (s *terminalScreen) printASCIIRun(data []byte) int {
	n := 0
	for n < len(data) && data[n] >= 0x20 && data[n] < 0x7f {
		n++
	}
	graphics := s.g0Graphics
	if s.shiftOut {
		graphics = s.g1Graphics
	}
	if graphics || s.insertMode {
		for _, b := range data[:n] {
			s.print(rune(b))
		}
		return n
	}
	g := s.grid()
	i := 0
	for i < n {
		if g.pendingWrap {
			s.print(rune(data[i]))
			i++
			continue
		}
		row := g.rows[g.cursorRow]
		col := g.cursorCol
		count := n - i
		if count > s.width-col {
			count = s.width - col
		}
		if row[col].width == 0 && col > 0 {
			row[col-1] = vtCell{width: 1, attrs: row[col-1].attrs}
		}
		for j := 0; j < count; j++ {
			row[col+j] = vtCell{r: rune(data[i+j]), width: 1, attrs: s.attrs}
		}
		if col+count < len(row) && row[col+count].width == 0 {
			row[col+count] = vtCell{width: 1, attrs: row[col+count].attrs}
		}
		s.lastPrinted = rune(data[i+count-1])
		i += count
		if col+count >= s.width {
			g.cursorCol = s.width - 1
			g.pendingWrap = true
		} else {
			g.cursorCol = col + count
		}
	}
	return n
}

func (s *terminalScreen) step(b byte) {
	p := &s.parser
	switch p.state {
	case vtGround:
		if p.utf8Need > 0 {
			if b&0xC0 == 0x80 {
				p.utf8[p.utf8Len] = b
				p.utf8Len++
				if p.utf8Len == p.utf8Need {
					r, _ := utf8.DecodeRune(p.utf8[:p.utf8Len])
					p.utf8Need = 0
					p.utf8Len = 0
					s.print(r)
				}
				return
			}
			// Invalid continuation: emit a replacement and reprocess b.
			p.utf8Need = 0
			p.utf8Len = 0
			s.print(utf8.RuneError)
		}
		switch {
		case b == 0x1b:
			p.state = vtEscape
			p.clear()
		case b < 0x20 || b == 0x7f:
			s.execute(b)
		case b < 0x80:
			s.print(rune(b))
		case b == 0x9b:
			// Raw 8-bit CSI, as the server's own output parser reads it.
			p.state = vtCSIEntry
			p.clear()
		case b == 0x9d:
			p.state = vtOSCString
			p.stringUtf8 = 0
		case b == 0x90:
			p.state = vtSOSString
			p.stringUtf8 = 0
		case b == 0x9c:
			// A stray string terminator.
		case b&0xE0 == 0xC0:
			p.utf8[0] = b
			p.utf8Len = 1
			p.utf8Need = 2
		case b&0xF0 == 0xE0:
			p.utf8[0] = b
			p.utf8Len = 1
			p.utf8Need = 3
		case b&0xF8 == 0xF0:
			p.utf8[0] = b
			p.utf8Len = 1
			p.utf8Need = 4
		default:
			s.print(utf8.RuneError)
		}
	case vtEscape:
		switch {
		case b == 0x1b:
			p.clear()
		case b == '[':
			p.state = vtCSIEntry
			p.clear()
		case b == ']':
			p.state = vtOSCString
			p.stringUtf8 = 0
		case b == 'P' || b == 'X' || b == '^' || b == '_':
			p.state = vtSOSString
			p.stringUtf8 = 0
		case b >= 0x20 && b <= 0x2f:
			p.intermediates = append(p.intermediates, b)
			p.state = vtEscapeIntermediate
		case b < 0x20:
			s.execute(b)
		default:
			p.state = vtGround
			s.escapeDispatch(b)
		}
	case vtEscapeIntermediate:
		switch {
		case b == 0x1b:
			p.state = vtEscape
			p.clear()
		case b >= 0x20 && b <= 0x2f:
			if len(p.intermediates) < vtIntermediateLimit {
				p.intermediates = append(p.intermediates, b)
			} else {
				p.state = vtCSIIgnore
			}
		case b < 0x20:
			s.execute(b)
		default:
			p.state = vtGround
			s.escapeDispatch(b)
		}
	case vtCSIEntry, vtCSIParam, vtCSIIntermediate, vtCSIIgnore:
		s.stepCSI(b)
	case vtOSCString:
		switch {
		case p.inStringRune(b):
		case b == 0x07 || b == 0x9c:
			p.state = vtGround
		case b == 0x1b:
			p.state = vtOSCEscape
		case b == 0x18 || b == 0x1a:
			p.state = vtGround
		}
	case vtOSCEscape:
		if b == '\\' {
			p.state = vtGround
		} else if b == 0x1b {
			p.state = vtOSCEscape
		} else {
			// Not a string terminator: xterm treats ESC as ending the OSC and
			// starts a new escape sequence with this byte.
			p.state = vtEscape
			p.clear()
			s.step(b)
		}
	case vtSOSString:
		switch {
		case p.inStringRune(b):
		case b == 0x1b:
			p.state = vtSOSEscape
		case b == 0x9c, b == 0x18, b == 0x1a:
			p.state = vtGround
		}
	case vtSOSEscape:
		if b == '\\' {
			p.state = vtGround
		} else if b != 0x1b {
			p.state = vtSOSString
		}
	}
}

func (s *terminalScreen) stepCSI(b byte) {
	p := &s.parser
	switch {
	case b == 0x1b:
		p.state = vtEscape
		p.clear()
		return
	case b == 0x18 || b == 0x1a:
		p.state = vtGround
		return
	case b < 0x20:
		s.execute(b)
		return
	case b == 0x7f:
		return
	}
	switch p.state {
	case vtCSIEntry:
		switch {
		case b >= '0' && b <= '9' || b == ';' || b == ':':
			p.params = append(p.params, b)
			p.state = vtCSIParam
		case b >= '<' && b <= '?':
			p.private = b
			p.state = vtCSIParam
		case b >= 0x20 && b <= 0x2f:
			p.intermediates = append(p.intermediates, b)
			p.state = vtCSIIntermediate
		default:
			p.state = vtGround
			s.csiDispatch(b)
		}
	case vtCSIParam:
		switch {
		case b >= '0' && b <= '9' || b == ';' || b == ':':
			if len(p.params) < vtCSIParamLimit {
				p.params = append(p.params, b)
			}
		case b >= '<' && b <= '?':
			p.state = vtCSIIgnore
		case b >= 0x20 && b <= 0x2f:
			p.intermediates = append(p.intermediates, b)
			p.state = vtCSIIntermediate
		default:
			p.state = vtGround
			s.csiDispatch(b)
		}
	case vtCSIIntermediate:
		switch {
		case b >= 0x20 && b <= 0x2f:
			if len(p.intermediates) < vtIntermediateLimit {
				p.intermediates = append(p.intermediates, b)
			} else {
				p.state = vtCSIIgnore
			}
		case b >= 0x40 && b <= 0x7e:
			p.state = vtGround
			s.csiDispatch(b)
		default:
			p.state = vtCSIIgnore
		}
	case vtCSIIgnore:
		if b >= 0x40 && b <= 0x7e {
			p.state = vtGround
		}
	}
}

// csiParams splits the raw parameter bytes into groups of sub-parameters:
// "1;2:3;;4" -> [[1] [2 3] [0] [4]]. Missing values read as 0. The returned
// slices alias parser scratch space and are only valid until the next call.
func (p *vtParser) csiParams() [][]int {
	p.values = append(p.values[:0], 0)
	p.starts = append(p.starts[:0], 0)
	value := 0
	for _, b := range p.params {
		switch {
		case b >= '0' && b <= '9':
			if value < 100000 {
				value = value*10 + int(b-'0')
			}
			p.values[len(p.values)-1] = value
		case b == ':':
			p.values = append(p.values, 0)
			value = 0
		case b == ';':
			p.starts = append(p.starts, len(p.values))
			p.values = append(p.values, 0)
			value = 0
		}
	}
	p.starts = append(p.starts, len(p.values))
	p.groups = p.groups[:0]
	for i := 0; i+1 < len(p.starts); i++ {
		p.groups = append(p.groups, p.values[p.starts[i]:p.starts[i+1]])
	}
	return p.groups
}

func (p *vtParser) param(groups [][]int, index int, fallback int) int {
	if index < len(groups) && groups[index][0] != 0 {
		return groups[index][0]
	}
	return fallback
}

// ---- execution ------------------------------------------------------------

func (s *terminalScreen) execute(b byte) {
	g := s.grid()
	switch b {
	case 0x08: // BS
		if g.cursorCol > 0 {
			g.cursorCol--
		}
		g.pendingWrap = false
	case 0x09: // HT
		s.tabForward(1)
	case 0x0a, 0x0b, 0x0c: // LF VT FF
		s.index()
	case 0x0d: // CR
		g.cursorCol = 0
		g.pendingWrap = false
	case 0x0e: // SO
		s.shiftOut = true
	case 0x0f: // SI
		s.shiftOut = false
	}
}

func (s *terminalScreen) escapeDispatch(final byte) {
	p := &s.parser
	if len(p.intermediates) > 0 {
		switch p.intermediates[0] {
		case '(':
			s.g0Graphics = final == '0'
		case ')':
			s.g1Graphics = final == '0'
		case '#':
			if final == '8' {
				s.screenAlignment()
			}
		}
		return
	}
	g := s.grid()
	switch final {
	case '7':
		s.saveCursor()
	case '8':
		s.restoreCursor()
	case 'D':
		s.index()
	case 'E':
		g.cursorCol = 0
		g.pendingWrap = false
		s.index()
	case 'H':
		if g.cursorCol < len(s.tabs) {
			s.tabs[g.cursorCol] = true
		}
	case 'M':
		s.reverseIndex()
	case 'c':
		s.Reset()
	}
}

func (s *terminalScreen) saved() *vtSavedCursor {
	if s.altActive {
		return &s.savedAlt
	}
	return &s.savedMain
}

func (s *terminalScreen) saveCursor() {
	g := s.grid()
	*s.saved() = vtSavedCursor{
		valid:      true,
		row:        g.cursorRow,
		col:        g.cursorCol,
		attrs:      s.attrs,
		originMode: s.originMode,
		g0Graphics: s.g0Graphics,
		g1Graphics: s.g1Graphics,
		shiftOut:   s.shiftOut,
	}
}

func (s *terminalScreen) restoreCursor() {
	saved := *s.saved()
	g := s.grid()
	if !saved.valid {
		g.cursorRow, g.cursorCol = 0, 0
		s.attrs = vtAttrs{}
		s.originMode = false
		g.pendingWrap = false
		return
	}
	g.cursorRow = clampInt(saved.row, 0, s.height-1)
	g.cursorCol = clampInt(saved.col, 0, s.width-1)
	s.attrs = saved.attrs
	s.originMode = saved.originMode
	s.g0Graphics = saved.g0Graphics
	s.g1Graphics = saved.g1Graphics
	s.shiftOut = saved.shiftOut
	g.pendingWrap = false
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func (s *terminalScreen) index() {
	g := s.grid()
	if g.cursorRow == s.bottom {
		s.scrollUp(1)
	} else if g.cursorRow < s.height-1 {
		g.cursorRow++
	}
	g.pendingWrap = false
}

func (s *terminalScreen) reverseIndex() {
	g := s.grid()
	if g.cursorRow == s.top {
		s.scrollDown(1)
	} else if g.cursorRow > 0 {
		g.cursorRow--
	}
	g.pendingWrap = false
}

// scrollUp scrolls the region up by n lines; lines leaving a full-screen main
// region enter the scrollback.
func (s *terminalScreen) scrollUp(n int) {
	s.scrollRegionUp(s.top, s.bottom, n)
}

func (s *terminalScreen) scrollRegionUp(top, bottom, n int) {
	g := s.grid()
	if n <= 0 || top > bottom {
		return
	}
	size := bottom - top + 1
	if n > size {
		n = size
	}
	if !s.altActive && top == 0 && bottom == s.height-1 {
		for i := 0; i < n; i++ {
			s.pushScrollback(g.rows[top+i])
		}
	}
	// Recycle the rows leaving the region as the fresh rows entering it, so
	// scrolling output allocates nothing per line.
	recycled := make([][]vtCell, n)
	copy(recycled, g.rows[top:top+n])
	copy(g.rows[top:bottom+1], g.rows[top+n:bottom+1])
	for i := 0; i < n; i++ {
		g.rows[bottom-n+1+i] = s.clearRow(recycled[i])
	}
}

func (s *terminalScreen) scrollDown(n int) {
	s.scrollRegionDown(s.top, s.bottom, n)
}

func (s *terminalScreen) scrollRegionDown(top, bottom, n int) {
	g := s.grid()
	if n <= 0 || top > bottom {
		return
	}
	size := bottom - top + 1
	if n > size {
		n = size
	}
	recycled := make([][]vtCell, n)
	copy(recycled, g.rows[bottom+1-n:bottom+1])
	copy(g.rows[top+n:bottom+1], g.rows[top:bottom+1-n])
	for i := 0; i < n; i++ {
		g.rows[top+i] = s.clearRow(recycled[i])
	}
}

func (s *terminalScreen) tabForward(n int) {
	g := s.grid()
	for ; n > 0; n-- {
		col := g.cursorCol + 1
		for col < s.width && !s.tabs[col] {
			col++
		}
		if col >= s.width {
			col = s.width - 1
		}
		g.cursorCol = col
	}
	g.pendingWrap = false
}

func (s *terminalScreen) tabBackward(n int) {
	g := s.grid()
	for ; n > 0; n-- {
		col := g.cursorCol - 1
		for col > 0 && !s.tabs[col] {
			col--
		}
		if col < 0 {
			col = 0
		}
		g.cursorCol = col
	}
	g.pendingWrap = false
}

var decGraphicsMap = map[rune]rune{
	'`': '◆', 'a': '▒', 'b': '␉', 'c': '␌', 'd': '␍', 'e': '␊', 'f': '°', 'g': '±',
	'h': '␤', 'i': '␋', 'j': '┘', 'k': '┐', 'l': '┌', 'm': '└', 'n': '┼', 'o': '⎺',
	'p': '⎻', 'q': '─', 'r': '⎼', 's': '⎽', 't': '├', 'u': '┤', 'v': '┴', 'w': '┬',
	'x': '│', 'y': '≤', 'z': '≥', '{': 'π', '|': '≠', '}': '£', '~': '·',
}

func (s *terminalScreen) print(r rune) {
	graphics := s.g0Graphics
	if s.shiftOut {
		graphics = s.g1Graphics
	}
	if graphics {
		if mapped, ok := decGraphicsMap[r]; ok {
			r = mapped
		}
	}
	if r >= 0x80 && r < 0xA0 {
		// C1 controls arriving as UTF-8 are not glyphs; modern terminals
		// ignore them in UTF-8 mode.
		return
	}
	width := runeWidth(r)
	g := s.grid()
	if width == 0 {
		s.attachCombining(r)
		return
	}
	if g.pendingWrap {
		if s.autowrap {
			g.cursorCol = 0
			s.index()
		}
		g.pendingWrap = false
	}
	if width == 2 && g.cursorCol == s.width-1 {
		// A wide glyph does not fit in the last column.
		if s.autowrap {
			g.rows[g.cursorRow][g.cursorCol] = vtCell{width: 1, attrs: s.attrs}
			g.cursorCol = 0
			s.index()
		} else {
			g.cursorCol = s.width - 2
			if g.cursorCol < 0 {
				return
			}
		}
	}
	row := g.rows[g.cursorRow]
	if s.insertMode {
		// Never split a wide glyph: blank the pair straddling the insertion
		// point, and the pair whose continuation falls off the right edge.
		if row[g.cursorCol].width == 0 && g.cursorCol > 0 {
			row[g.cursorCol-1] = vtCell{width: 1, attrs: row[g.cursorCol-1].attrs}
			row[g.cursorCol] = vtCell{width: 1, attrs: row[g.cursorCol].attrs}
		}
		copy(row[g.cursorCol+width:], row[g.cursorCol:len(row)-width])
		for i := g.cursorCol; i < g.cursorCol+width && i < len(row); i++ {
			row[i] = vtCell{width: 1}
		}
		if last := len(row) - 1; last >= 0 && row[last].width == 2 {
			row[last] = vtCell{width: 1, attrs: row[last].attrs}
		}
	}
	col := g.cursorCol
	// Overwriting half of a wide glyph blanks the other half.
	if row[col].width == 0 && col > 0 {
		row[col-1] = vtCell{width: 1, attrs: row[col-1].attrs}
	}
	if width == 1 && row[col].width == 2 && col+1 < len(row) {
		row[col+1] = vtCell{width: 1, attrs: row[col+1].attrs}
	}
	row[col] = vtCell{r: r, width: uint8(width), attrs: s.attrs}
	s.lastPrinted = r
	if width == 2 {
		if col+2 < len(row) && row[col+1].width == 2 {
			row[col+2] = vtCell{width: 1, attrs: row[col+2].attrs}
		}
		row[col+1] = vtCell{width: 0, attrs: s.attrs}
	}
	if col+width >= s.width {
		g.cursorCol = s.width - 1
		g.pendingWrap = true
	} else {
		g.cursorCol = col + width
	}
}

func (s *terminalScreen) attachCombining(r rune) {
	g := s.grid()
	row := g.rows[g.cursorRow]
	col := g.cursorCol
	if g.pendingWrap {
		col = s.width - 1
	} else if col > 0 {
		col--
	} else {
		return
	}
	if row[col].width == 0 && col > 0 {
		col--
	}
	if row[col].r == 0 || len(row[col].comb) >= vtCombiningLimit {
		return
	}
	row[col].comb = append(row[col].comb, r)
}

func (s *terminalScreen) moveCursor(row, col int) {
	g := s.grid()
	minRow, maxRow := 0, s.height-1
	if s.originMode {
		minRow, maxRow = s.top, s.bottom
	}
	g.cursorRow = clampInt(row, minRow, maxRow)
	g.cursorCol = clampInt(col, 0, s.width-1)
	g.pendingWrap = false
}

func (s *terminalScreen) csiDispatch(final byte) {
	p := &s.parser
	if len(p.intermediates) > 0 {
		if string(p.intermediates) == "!" && final == 'p' {
			s.softReset()
		}
		return
	}
	groups := p.csiParams()
	g := s.grid()
	if p.private != 0 {
		if p.private == '?' && (final == 'h' || final == 'l') {
			for _, group := range groups {
				s.setPrivateMode(group[0], final == 'h')
			}
		}
		return
	}
	n := p.param(groups, 0, 1)
	switch final {
	case '@':
		s.insertChars(n)
	case 'A':
		s.moveCursorRelative(-n, 0)
	case 'B':
		s.moveCursorRelative(n, 0)
	case 'C':
		s.moveCursorRelative(0, n)
	case 'D':
		s.moveCursorRelative(0, -n)
	case 'E':
		g.cursorCol = 0
		s.moveCursorRelative(n, 0)
	case 'F':
		g.cursorCol = 0
		s.moveCursorRelative(-n, 0)
	case 'G', '`':
		g.cursorCol = clampInt(n-1, 0, s.width-1)
		g.pendingWrap = false
	case 'H', 'f':
		row := p.param(groups, 0, 1) - 1
		col := p.param(groups, 1, 1) - 1
		if s.originMode {
			row += s.top
		}
		s.moveCursor(row, col)
	case 'I':
		s.tabForward(n)
	case 'J':
		s.eraseDisplay(p.param(groups, 0, 0))
	case 'K':
		s.eraseLine(p.param(groups, 0, 0))
	case 'L':
		s.insertLines(n)
	case 'M':
		s.deleteLines(n)
	case 'P':
		s.deleteChars(n)
	case 'S':
		s.scrollUp(n)
	case 'T':
		s.scrollDown(n)
	case 'X':
		s.eraseChars(n)
	case 'Z':
		s.tabBackward(n)
	case 'a':
		s.moveCursorRelative(0, n)
	case 'b':
		if s.lastPrinted != 0 {
			for i := 0; i < n && i < s.width; i++ {
				s.print(s.lastPrinted)
			}
		}
	case 'd':
		row := n - 1
		if s.originMode {
			row += s.top
		}
		s.moveCursor(row, g.cursorCol)
	case 'e':
		s.moveCursorRelative(n, 0)
	case 'g':
		switch p.param(groups, 0, 0) {
		case 0:
			if g.cursorCol < len(s.tabs) {
				s.tabs[g.cursorCol] = false
			}
		case 3:
			for i := range s.tabs {
				s.tabs[i] = false
			}
		}
	case 'h', 'l':
		for _, group := range groups {
			if group[0] == 4 {
				s.insertMode = final == 'h'
			}
		}
	case 'm':
		s.applySGR(groups)
	case 'r':
		top := p.param(groups, 0, 1) - 1
		bottom := p.param(groups, 1, s.height) - 1
		top = clampInt(top, 0, s.height-1)
		bottom = clampInt(bottom, 0, s.height-1)
		if top < bottom {
			s.top = top
			s.bottom = bottom
			if s.originMode {
				s.moveCursor(s.top, 0)
			} else {
				s.moveCursor(0, 0)
			}
		}
	case 's':
		s.scoCursor = vtSavedCursor{valid: true, row: g.cursorRow, col: g.cursorCol}
	case 'u':
		if s.scoCursor.valid {
			g.cursorRow = clampInt(s.scoCursor.row, 0, s.height-1)
			g.cursorCol = clampInt(s.scoCursor.col, 0, s.width-1)
			g.pendingWrap = false
		}
	}
}

func (s *terminalScreen) moveCursorRelative(dRow, dCol int) {
	g := s.grid()
	row := g.cursorRow + dRow
	col := g.cursorCol + dCol
	minRow, maxRow := 0, s.height-1
	if g.cursorRow >= s.top && g.cursorRow <= s.bottom {
		if dRow < 0 {
			minRow = s.top
		}
		if dRow > 0 {
			maxRow = s.bottom
		}
	}
	g.cursorRow = clampInt(row, minRow, maxRow)
	g.cursorCol = clampInt(col, 0, s.width-1)
	g.pendingWrap = false
}

func (s *terminalScreen) setPrivateMode(mode int, on bool) {
	switch mode {
	case 6:
		s.originMode = on
		s.moveCursor(0, 0)
	case 7:
		s.autowrap = on
	case 12, 25:
		if mode == 25 {
			s.cursorOn = on
		}
	case 47:
		s.switchScreen(on, false, false)
	case 1047:
		s.switchScreen(on, false, true)
	case 1049:
		s.switchScreen(on, true, true)
	}
}

// softReset is DECSTR.
func (s *terminalScreen) softReset() {
	s.attrs = vtAttrs{}
	s.top = 0
	s.bottom = s.height - 1
	s.originMode = false
	s.autowrap = true
	s.insertMode = false
	s.cursorOn = true
	s.g0Graphics = false
	s.g1Graphics = false
	s.shiftOut = false
	*s.saved() = vtSavedCursor{}
	s.grid().pendingWrap = false
}

// screenAlignment is DECALN: fill the screen with E and home the cursor.
func (s *terminalScreen) screenAlignment() {
	g := s.grid()
	for r := range g.rows {
		for c := range g.rows[r] {
			g.rows[r][c] = vtCell{r: 'E', width: 1}
		}
	}
	s.top = 0
	s.bottom = s.height - 1
	s.originMode = false
	g.cursorRow, g.cursorCol = 0, 0
	g.pendingWrap = false
}

func (s *terminalScreen) switchScreen(toAlt bool, saveCursor bool, clear bool) {
	if toAlt == s.altActive {
		return
	}
	if toAlt {
		if saveCursor {
			s.saveCursor()
		}
		s.altActive = true
		if clear {
			s.alt = newVTGrid(s.width, s.height)
		}
		s.alt.cursorRow = s.main.cursorRow
		s.alt.cursorCol = s.main.cursorCol
		return
	}
	s.altActive = false
	if saveCursor {
		s.restoreCursor()
	}
}

func (s *terminalScreen) eraseDisplay(mode int) {
	g := s.grid()
	switch mode {
	case 0:
		s.eraseLine(0)
		for r := g.cursorRow + 1; r < s.height; r++ {
			s.clearRow(g.rows[r])
		}
	case 1:
		s.eraseLine(1)
		for r := 0; r < g.cursorRow; r++ {
			s.clearRow(g.rows[r])
		}
	case 2:
		for r := range g.rows {
			s.clearRow(g.rows[r])
		}
	case 3:
		s.scrollback = nil
	}
	g.pendingWrap = false
}

// blankRow erases with the current background (bce), as xterm does.
func (s *terminalScreen) blankRow() []vtCell {
	return s.clearRow(newVTRow(s.width))
}

// clearRow blanks a row in place with the current background.
func (s *terminalScreen) clearRow(row []vtCell) []vtCell {
	blank := s.blankCell()
	for i := range row {
		row[i] = blank
	}
	return row
}

func (s *terminalScreen) blankCell() vtCell {
	cell := vtCell{width: 1}
	cell.attrs.bg = s.attrs.bg
	return cell
}

func (s *terminalScreen) eraseLine(mode int) {
	g := s.grid()
	row := g.rows[g.cursorRow]
	from, to := 0, s.width
	switch mode {
	case 0:
		from = g.cursorCol
	case 1:
		to = g.cursorCol + 1
	}
	s.eraseCells(row, from, to)
	g.pendingWrap = false
}

func (s *terminalScreen) eraseCells(row []vtCell, from, to int) {
	from = clampInt(from, 0, len(row))
	to = clampInt(to, 0, len(row))
	if from > 0 && from < len(row) && row[from].width == 0 {
		row[from-1] = vtCell{width: 1, attrs: row[from-1].attrs}
	}
	if to < len(row) && row[to].width == 0 {
		row[to] = vtCell{width: 1, attrs: row[to].attrs}
	}
	for i := from; i < to; i++ {
		row[i] = s.blankCell()
	}
}

func (s *terminalScreen) eraseChars(n int) {
	g := s.grid()
	s.eraseCells(g.rows[g.cursorRow], g.cursorCol, g.cursorCol+n)
	g.pendingWrap = false
}

func (s *terminalScreen) insertChars(n int) {
	g := s.grid()
	row := g.rows[g.cursorRow]
	col := g.cursorCol
	if n > s.width-col {
		n = s.width - col
	}
	if row[col].width == 0 && col > 0 {
		row[col-1] = vtCell{width: 1, attrs: row[col-1].attrs}
		row[col] = vtCell{width: 1, attrs: row[col].attrs}
	}
	copy(row[col+n:], row[col:s.width-n])
	for i := col; i < col+n; i++ {
		row[i] = s.blankCell()
	}
	if row[s.width-1].width == 2 {
		row[s.width-1] = vtCell{width: 1, attrs: row[s.width-1].attrs}
	}
	g.pendingWrap = false
}

func (s *terminalScreen) deleteChars(n int) {
	g := s.grid()
	row := g.rows[g.cursorRow]
	col := g.cursorCol
	if n > s.width-col {
		n = s.width - col
	}
	if row[col].width == 0 && col > 0 {
		row[col-1] = vtCell{width: 1, attrs: row[col-1].attrs}
	}
	copy(row[col:], row[col+n:])
	for i := s.width - n; i < s.width; i++ {
		row[i] = s.blankCell()
	}
	if row[col].width == 0 {
		row[col] = vtCell{width: 1, attrs: row[col].attrs}
	}
	g.pendingWrap = false
}

func (s *terminalScreen) insertLines(n int) {
	g := s.grid()
	if g.cursorRow < s.top || g.cursorRow > s.bottom {
		return
	}
	s.scrollRegionDown(g.cursorRow, s.bottom, n)
	g.cursorCol = 0
	g.pendingWrap = false
}

func (s *terminalScreen) deleteLines(n int) {
	g := s.grid()
	if g.cursorRow < s.top || g.cursorRow > s.bottom {
		return
	}
	// Lines deleted inside a region never reach the scrollback.
	if n > s.bottom-g.cursorRow+1 {
		n = s.bottom - g.cursorRow + 1
	}
	recycled := make([][]vtCell, n)
	copy(recycled, g.rows[g.cursorRow:g.cursorRow+n])
	copy(g.rows[g.cursorRow:s.bottom+1], g.rows[g.cursorRow+n:s.bottom+1])
	for i := 0; i < n; i++ {
		g.rows[s.bottom-n+1+i] = s.clearRow(recycled[i])
	}
	g.cursorCol = 0
	g.pendingWrap = false
}

func (s *terminalScreen) applySGR(groups [][]int) {
	if len(groups) == 1 && len(groups[0]) == 1 && groups[0][0] == 0 {
		s.attrs = vtAttrs{}
		return
	}
	for i := 0; i < len(groups); i++ {
		group := groups[i]
		code := group[0]
		switch {
		case code == 0:
			s.attrs = vtAttrs{}
		case code == 1:
			s.attrs.flags |= vtAttrBold
		case code == 2:
			s.attrs.flags |= vtAttrDim
		case code == 3:
			s.attrs.flags |= vtAttrItalic
		case code == 4:
			style := 1
			if len(group) > 1 {
				style = group[1]
			}
			if style > 5 {
				style = 1
			}
			s.attrs.ulStyle = uint8(style)
		case code == 5 || code == 6:
			s.attrs.flags |= vtAttrBlink
		case code == 7:
			s.attrs.flags |= vtAttrInverse
		case code == 8:
			s.attrs.flags |= vtAttrHidden
		case code == 9:
			s.attrs.flags |= vtAttrStrike
		case code == 21:
			s.attrs.ulStyle = 2
		case code == 22:
			s.attrs.flags &^= vtAttrBold | vtAttrDim
		case code == 23:
			s.attrs.flags &^= vtAttrItalic
		case code == 24:
			s.attrs.ulStyle = 0
		case code == 25:
			s.attrs.flags &^= vtAttrBlink
		case code == 27:
			s.attrs.flags &^= vtAttrInverse
		case code == 28:
			s.attrs.flags &^= vtAttrHidden
		case code == 29:
			s.attrs.flags &^= vtAttrStrike
		case code >= 30 && code <= 37:
			s.attrs.fg = vtColor{kind: vtColorIndexed, index: uint8(code - 30)}
		case code == 38 || code == 48 || code == 58:
			color, consumed := parseExtendedColor(groups, i)
			i += consumed
			switch code {
			case 38:
				s.attrs.fg = color
			case 48:
				s.attrs.bg = color
			default:
				s.attrs.ul = color
			}
		case code == 39:
			s.attrs.fg = vtColor{}
		case code >= 40 && code <= 47:
			s.attrs.bg = vtColor{kind: vtColorIndexed, index: uint8(code - 40)}
		case code == 49:
			s.attrs.bg = vtColor{}
		case code == 59:
			s.attrs.ul = vtColor{}
		case code >= 90 && code <= 97:
			s.attrs.fg = vtColor{kind: vtColorIndexed, index: uint8(code - 90 + 8)}
		case code >= 100 && code <= 107:
			s.attrs.bg = vtColor{kind: vtColorIndexed, index: uint8(code - 100 + 8)}
		}
	}
}

// parseExtendedColor reads a 38/48/58 colour spec starting at groups[index].
// It returns the colour and how many additional groups were consumed.
func parseExtendedColor(groups [][]int, index int) (vtColor, int) {
	group := groups[index]
	if len(group) > 1 {
		// Colon form: 38:5:n or 38:2:[cs:]r:g:b
		switch group[1] {
		case 5:
			if len(group) > 2 {
				return vtColor{kind: vtColorIndexed, index: uint8(clampInt(group[2], 0, 255))}, 0
			}
		case 2:
			args := group[2:]
			if len(args) >= 4 {
				args = args[len(args)-3:]
			}
			if len(args) >= 3 {
				return vtColor{
					kind: vtColorRGB,
					r:    uint8(clampInt(args[0], 0, 255)),
					g:    uint8(clampInt(args[1], 0, 255)),
					b:    uint8(clampInt(args[2], 0, 255)),
				}, 0
			}
		}
		return vtColor{}, 0
	}
	if index+1 >= len(groups) {
		return vtColor{}, 0
	}
	switch groups[index+1][0] {
	case 5:
		if index+2 < len(groups) {
			return vtColor{kind: vtColorIndexed, index: uint8(clampInt(groups[index+2][0], 0, 255))}, 2
		}
		return vtColor{}, 1
	case 2:
		if index+4 < len(groups) {
			return vtColor{
				kind: vtColorRGB,
				r:    uint8(clampInt(groups[index+2][0], 0, 255)),
				g:    uint8(clampInt(groups[index+3][0], 0, 255)),
				b:    uint8(clampInt(groups[index+4][0], 0, 255)),
			}, 4
		}
		return vtColor{}, len(groups) - index - 1
	}
	return vtColor{}, 0
}

// CharsetSequence returns the sequence that puts a reset client into this
// screen's character-set state: the reset itself, then any DEC line-drawing
// designation and shift that is active.
func (s *terminalScreen) CharsetSequence() []byte {
	out := []byte("\x0f\x1b(B\x1b)B")
	if s == nil {
		return out
	}
	if s.g0Graphics {
		out = append(out, "\x1b(0"...)
	}
	if s.g1Graphics {
		out = append(out, "\x1b)0"...)
	}
	if s.shiftOut {
		out = append(out, 0x0e)
	}
	return out
}
