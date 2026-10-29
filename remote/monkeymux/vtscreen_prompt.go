package main

import (
	"bytes"
)

// Semantic prompts (OSC 133, and VS Code's OSC 633) in the screen model,
// mirroring third_party/xterm/lib/src/core/semantic_prompt.dart: a cell keeps
// whether it was written as prompt, input or output, a row whether a prompt
// starts on it or it continues one, and each screen the content the next cell
// takes and the options of the current prompt. The client uses them to move
// the shell's cursor to a tapped cell and to keep the screen as history when
// a shell clears it at a prompt (Ctrl-L), so the model has to agree with it on
// both, and a frame painted from the model carries the current prompt's marks.

// Cell content, as SemanticContent in the client.
const (
	vtSemOutput uint8 = iota
	vtSemInput
	vtSemPrompt
)

// Row marks, as SemanticPromptRow in the client: a continuation is a row a
// wrap or newline reached inside a prompt or its input, or a continuation
// prompt (k=c, VS Code's 633;F); a secondary prompt (k=s) is one that
// relative click events count rows from.
const (
	vtPromptNone uint8 = iota
	vtPromptPrimary
	vtPromptContinuation
	vtPromptSecondary
)

// vtContinuesPrompt reports a row mark that continues the prompt on the row
// above (SemanticPromptRow.continuesPrompt in the client).
func vtContinuesPrompt(mark uint8) bool {
	return mark == vtPromptContinuation || mark == vtPromptSecondary
}

// The `cl` option values.
const (
	vtCursorKeysNone uint8 = iota
	vtCursorKeysLine
	vtCursorKeysMultiple
	vtCursorKeysVertical
	vtCursorKeysSmartVertical
)

// vtSemanticOSCLimit bounds how much of an OSC 133 or 633 payload the parser
// keeps: the mark and its options, aid included.
const vtSemanticOSCLimit = 512

// vtSemanticState is a screen's semantic prompt state (SemanticPromptState in
// the client).
type vtSemanticState struct {
	content     uint8
	eolInput    bool
	clickEvents uint8
	cursorKeys  uint8
	specialKey  bool
	noRedraw    bool
	aid         string
}

func (st *vtSemanticState) resetCursor() {
	st.content = vtSemOutput
	st.eolInput = false
}

func (st *vtSemanticState) resetOptions() {
	st.clickEvents = 0
	st.cursorKeys = vtCursorKeysNone
	st.specialKey = false
	st.noRedraw = false
	st.aid = ""
}

// applyOptions reads the key=value options of OSC 133 ; A, ignoring unknown
// and malformed ones.
func (st *vtSemanticState) applyOptions(options [][]byte) {
	for _, option := range options {
		key, value, ok := bytes.Cut(option, []byte{'='})
		if !ok {
			continue
		}
		switch string(key) {
		case "click_events":
			switch string(value) {
			case "0", "1", "2":
				st.clickEvents = value[0] - '0'
			}
		case "cl":
			switch string(value) {
			case "line":
				st.cursorKeys = vtCursorKeysLine
			case "m":
				st.cursorKeys = vtCursorKeysMultiple
			case "v":
				st.cursorKeys = vtCursorKeysVertical
			case "w":
				st.cursorKeys = vtCursorKeysSmartVertical
			}
		case "special_key":
			switch string(value) {
			case "0", "1":
				st.specialKey = value[0] == '1'
			}
		case "redraw":
			switch string(value) {
			case "0", "1", "last":
				st.noRedraw = string(value) == "0"
			}
		case "aid":
			st.aid = string(value)
		}
	}
}

// appendOptions writes the options back as OSC 133 ; A takes them.
func (st *vtSemanticState) appendOptions(out []byte) []byte {
	if st.clickEvents != 0 {
		out = append(out, ";click_events="...)
		out = append(out, '0'+st.clickEvents)
	}
	switch st.cursorKeys {
	case vtCursorKeysLine:
		out = append(out, ";cl=line"...)
	case vtCursorKeysMultiple:
		out = append(out, ";cl=m"...)
	case vtCursorKeysVertical:
		out = append(out, ";cl=v"...)
	case vtCursorKeysSmartVertical:
		out = append(out, ";cl=w"...)
	}
	if st.specialKey {
		out = append(out, ";special_key=1"...)
	}
	if st.noRedraw {
		out = append(out, ";redraw=0"...)
	}
	if st.aid != "" {
		out = append(out, ";aid="...)
		out = append(out, st.aid...)
	}
	return out
}

func (s *terminalScreen) semantic() *vtSemanticState {
	if s.altActive {
		return &s.semAlt
	}
	return &s.semMain
}

// isSemanticPromptOSC reports an OSC payload that is a shell integration mark
// ("133;" or "633;"). The parser asks for every byte of a long OSC, such as an
// inline image, so it compares bytes rather than calling into bytes.
func isSemanticPromptOSC(head []byte) bool {
	return len(head) >= 4 && head[3] == ';' && head[2] == '3' && head[1] == '3' &&
		(head[0] == '1' || head[0] == '6')
}

// promptKind is the row mark an OSC 133 command's k= option names: i (the
// default) and r a primary prompt, c a continuation and s a secondary prompt.
func promptKind(options [][]byte) uint8 {
	for _, option := range options {
		if len(option) == 3 && option[0] == 'k' && option[1] == '=' {
			switch option[2] {
			case 'c':
				return vtPromptContinuation
			case 's':
				return vtPromptSecondary
			case 'i', 'r':
				return vtPromptPrimary
			}
		}
	}
	return vtPromptPrimary
}

// applySemanticPromptOSC applies an OSC 133 or 633 mark (applySemanticPromptOsc
// in the client). payload is the OSC without its introducer and terminator.
func (s *terminalScreen) applySemanticPromptOSC(payload []byte) {
	code := payload[:3]
	args := bytes.Split(payload[4:], []byte{';'})
	st := s.semantic()
	if bytes.Equal(code, []byte("633")) {
		// VS Code's marks; its A does not start a fresh line.
		switch string(args[0]) {
		case "A":
			s.startPrompt(nil, vtPromptPrimary)
		case "B", "G", "I":
			st.content, st.eolInput = vtSemInput, false
		case "C":
			s.endInput()
		case "D":
			st.resetCursor()
		case "F":
			s.markPrompt(vtPromptContinuation)
		case "H":
			st.content, st.eolInput = vtSemPrompt, false
		}
		return
	}
	options := args[1:]
	switch string(args[0]) {
	case "A", "N":
		s.freshLine()
		s.startPrompt(options, promptKind(options))
	case "P":
		s.markPrompt(promptKind(options))
	case "B":
		st.content, st.eolInput = vtSemInput, false
	case "I":
		st.content, st.eolInput = vtSemInput, true
	case "C":
		s.endInput()
	case "D":
		st.resetCursor()
	case "L":
		s.freshLine()
	}
}

// freshLine is OSC 133 ; L: a new line unless the cursor is at a line start.
func (s *terminalScreen) freshLine() {
	g := s.grid()
	if g.cursorCol == 0 {
		return
	}
	s.cursorKnown = false
	g.cursorCol = 0
	g.pendingWrap = false
	s.index()
}

// startPrompt starts a prompt of kind row. A primary one is a new prompt and
// drops the options of the last; any other keeps them and takes those it
// names.
func (s *terminalScreen) startPrompt(options [][]byte, row uint8) {
	st := s.semantic()
	if row == vtPromptPrimary {
		st.resetOptions()
	}
	st.applyOptions(options)
	s.markPrompt(row)
}

func (s *terminalScreen) markPrompt(row uint8) {
	st := s.semantic()
	st.content, st.eolInput = vtSemPrompt, false
	g := s.grid()
	g.prompt[g.cursorRow] = row
}

// endInput is OSC 133 ; C. A prompt row the cursor is at the start of is
// output after all (fish, which marks no continuation prompts).
func (s *terminalScreen) endInput() {
	s.semantic().resetCursor()
	g := s.grid()
	if g.cursorCol == 0 {
		g.prompt[g.cursorRow] = vtPromptNone
	}
}

// semanticAfterIndex runs after every index: a row reached while a prompt or
// its input is written continues it, unless the input ended with its line.
// A row the prompt already marked keeps its mark: the shell moved up and back
// down without repainting it.
func (s *terminalScreen) semanticAfterIndex() {
	st := s.semantic()
	if st.content == vtSemOutput {
		return
	}
	if st.eolInput {
		st.resetCursor()
		return
	}
	g := s.grid()
	if g.prompt[g.cursorRow] == vtPromptNone {
		g.prompt[g.cursorRow] = vtPromptContinuation
	}
}

// scrollClearAtPrompt keeps the screen as history when ED 2 clears it at a
// prompt (scrollClearAtPrompt in the client, after Ghostty 1.4): on the main
// screen, when the last row with text, or a prompt row below it, belongs to a
// prompt, the rows down to the last non-empty one scroll into the scrollback
// before the erase.
func (s *terminalScreen) scrollClearAtPrompt() {
	if s.altActive {
		return
	}
	g := &s.main
	atPrompt := false
	for r := s.height - 1; r >= 0; r-- {
		if g.prompt[r] != vtPromptNone {
			atPrompt = true
			break
		}
		if vtRowHasText(g.rows[r]) {
			break
		}
	}
	if !atPrompt {
		return
	}
	for r := s.height - 1; r >= 0; r-- {
		if !vtRowEmpty(g.rows[r]) {
			s.scrollRegionUp(0, s.height-1, r+1)
			return
		}
	}
}

// vtScrollbackSem keeps the semantic content of a row entering the
// scrollback, up to its last cell that is not output, or nil when every cell
// is: a prompt that scrolls away and comes back with a taller screen is still
// a prompt and its input, as the client keeps it.
func vtScrollbackSem(row []vtCell) []uint8 {
	end := len(row)
	for end > 0 && row[end-1].sem == vtSemOutput {
		end--
	}
	if end == 0 {
		return nil
	}
	sem := make([]uint8, end)
	for i, cell := range row[:end] {
		sem[i] = cell.sem
	}
	return sem
}

// decode turns a scrollback line back into cells, semantic content included.
func (l *vtScrollbackLine) decode(decoder *vtLineDecoder, width int) []vtCell {
	cells := decoder.decode(l.text, width)
	for i := 0; i < len(l.sem) && i < len(cells); i++ {
		cells[i].sem = l.sem[i]
	}
	return cells
}

func vtRowHasText(row []vtCell) bool {
	for _, cell := range row {
		if cell.r != 0 || len(cell.comb) > 0 {
			return true
		}
	}
	return false
}

// vtRowEmpty reports a row with neither text nor a coloured background.
func vtRowEmpty(row []vtCell) bool {
	for _, cell := range row {
		if cell.r != 0 || len(cell.comb) > 0 || cell.attrs.bg.kind != vtColorDefault {
			return false
		}
	}
	return true
}

// promptRows returns the main-screen rows of the prompt the cursor is at, as
// currentPromptRows in the client: its first grid row and last, and, when it
// continues from lines in the scrollback, the first of those (else -1).
func (s *terminalScreen) promptRows() (history, start, end int, ok bool) {
	if s.altActive {
		return -1, 0, 0, false
	}
	g := &s.main
	row := g.cursorRow
	if g.prompt[row] == vtPromptNone && s.semMain.content == vtSemOutput {
		return -1, 0, 0, false
	}
	start = row
	for vtContinuesPrompt(g.prompt[start]) && start > 0 && g.prompt[start-1] != vtPromptNone {
		start--
	}
	end = row
	for end+1 < len(g.rows) && vtContinuesPrompt(g.prompt[end+1]) {
		end++
	}
	history = -1
	if start == 0 && vtContinuesPrompt(g.prompt[0]) {
		for i := s.scrollback.len() - 1; i >= 0 && s.scrollback.at(i).prompt != vtPromptNone; i-- {
			history = i
			if !vtContinuesPrompt(s.scrollback.at(i).prompt) {
				break
			}
		}
	}
	return history, start, end, true
}

// vtSemanticFrame re-emits the marks of the prompt the cursor is at while a
// frame paints the main screen and its scrollback, so a client painted from
// the model can move the shell's cursor and keep history on a clear right
// away, and resizes it the way the model does. A frame paints onto a client
// whose replay prefix ended any open prompt (CSI 3 J), so the lines before the
// prompt need nothing. Only marks without side effects are used: A at a line
// start (no fresh line there), P, B, I and VS Code's H; never C or D, which
// the app takes for a command starting or finishing. So nothing is emitted
// unless the cursor is in a prompt or its input, and cells written as output
// inside the prompt take the content in force.
//
// A row is marked only where the model marks it. The cursor can be in a
// prompt on a row the model leaves unmarked (the prompt row was deleted
// under it, or erased, or VS Code marked only the content), and then the
// prompt's options travel on an A that the frame erases again before it
// paints anything (begin).
type vtSemanticFrame struct {
	state *vtSemanticState
	grid  *vtGrid
	// history is the first scrollback line of the prompt, or -1; start and
	// end are its grid rows.
	history int
	start   int
	end     int
	// first is set until the prompt's first line has been reached; inPrompt
	// while one of its lines is painted, whose mark is mark.
	first    bool
	inPrompt bool
	mark     uint8
	emitted  uint8
	// unmarked is set when the prompt's first line is a grid row the model
	// does not mark.
	unmarked bool
}

// semanticFrame returns the marks to paint g with, or nil.
func (s *terminalScreen) semanticFrame(g *vtGrid) *vtSemanticFrame {
	if g != &s.main || s.altActive || s.semMain.content == vtSemOutput {
		return nil
	}
	history, start, end, ok := s.promptRows()
	if !ok {
		return nil
	}
	return &vtSemanticFrame{
		state: &s.semMain, grid: g, history: history, start: start, end: end, first: true,
		unmarked: history < 0 && g.prompt[start] == vtPromptNone,
	}
}

// begin is called before anything is painted, with the client's screen and
// scrollback blank. For a prompt whose first line is unmarked it sets the
// prompt's options with an A, whose mark ED 2 erases again (on a blank
// screen it scrolls nothing into the scrollback) and whose content CSI 3 J
// ends, as the replay prefix did.
func (f *vtSemanticFrame) begin(out []byte) []byte {
	if f == nil || !f.unmarked {
		return out
	}
	out = append(out, "\x1b[H\x1b]133;A"...)
	out = f.state.appendOptions(out)
	return append(out, "\x07\x1b[2J\x1b[3J"...)
}

// beginHistoryLine is called with the cursor at the start of scrollback line
// i, which a soft wrap reached when wrapped is set. It reports whether the
// line belongs to the prompt, and so has to be painted with its marks.
func (f *vtSemanticFrame) beginHistoryLine(out []byte, i int, mark uint8, wrapped bool) ([]byte, bool) {
	if f == nil {
		return out, false
	}
	inPrompt := f.history >= 0 && i >= f.history
	return f.beginLine(out, inPrompt, mark, wrapped), inPrompt
}

// endHistory is called after the last scrollback line, and after the soft
// wrap that leads to the grid if there is one, before the newlines that push
// the scrollback above it. Input that ends with its line (I) lets the first
// newline end it, so those newlines do not mark the rows they reach as
// continuing the prompt.
func (f *vtSemanticFrame) endHistory(out []byte) []byte {
	if f == nil || f.emitted == vtSemOutput {
		return out
	}
	f.emitted = vtSemOutput
	f.inPrompt = false
	return append(out, "\x1b]133;I\x07"...)
}

// beginRow is called with the cursor at the start of grid row r, which a soft
// wrap reached when wrapped is set.
func (f *vtSemanticFrame) beginRow(out []byte, r int, wrapped bool) []byte {
	if f == nil {
		return out
	}
	return f.beginLine(out, r >= f.start && r <= f.end, f.grid.prompt[r], wrapped)
}

func (f *vtSemanticFrame) beginLine(out []byte, inPrompt bool, mark uint8, wrapped bool) []byte {
	f.inPrompt = inPrompt
	if !inPrompt {
		return out
	}
	f.mark = mark
	switch {
	case f.first && f.unmarked:
		// begin set the options already; the line keeps no mark.
		f.first = false
	case f.first:
		// A primary prompt resets the client's options, which the model's
		// replace; a line marked otherwise takes its mark after it.
		f.first = false
		out = append(out, "\x1b]133;A"...)
		out = f.state.appendOptions(out)
		out = append(out, '\x07')
		if mark != vtPromptPrimary {
			out = appendVTPromptContent(out, mark)
		}
		f.emitted = vtSemPrompt
	case !wrapped || f.emitted == vtSemOutput || mark != vtPromptContinuation:
		// A soft wrap inside the prompt marks the line a continuation on its
		// own, unless output was in force; any other line or mark is set.
		out = appendVTPromptContent(out, mark)
		f.emitted = vtSemPrompt
	}
	return out
}

// cell is called before a written cell of the row being painted.
func (f *vtSemanticFrame) cell(out []byte, sem uint8) []byte {
	if f == nil || !f.inPrompt || sem == f.emitted {
		return out
	}
	switch sem {
	case vtSemInput:
		out = append(out, "\x1b]133;B\x07"...)
	case vtSemPrompt:
		out = appendVTPromptContent(out, f.mark)
	default:
		return out
	}
	f.emitted = sem
	return out
}

// appendVTPromptContent makes the next cells prompt on a line with mark, and
// marks the line as P does with the kind that gives mark exactly: k=c a
// continuation, never the k=s secondary prompt that relative clicks count
// from. VS Code's H sets the content alone, for a line the model leaves
// unmarked.
func appendVTPromptContent(out []byte, mark uint8) []byte {
	switch mark {
	case vtPromptPrimary:
		return append(out, "\x1b]133;P;k=i\x07"...)
	case vtPromptContinuation:
		return append(out, "\x1b]133;P;k=c\x07"...)
	case vtPromptSecondary:
		return append(out, "\x1b]133;P;k=s\x07"...)
	}
	return append(out, "\x1b]633;H\x07"...)
}

// finish leaves the client writing the prompt or input the model is,
// whatever the last painted cell was. The cursor's row is painted already,
// so only the content is set, never a mark.
func (f *vtSemanticFrame) finish(out []byte) []byte {
	if f == nil {
		return out
	}
	switch {
	case f.state.content == vtSemPrompt && f.emitted != vtSemPrompt:
		return append(out, "\x1b]633;H\x07"...)
	case f.state.content != vtSemInput:
		return out
	case f.state.eolInput:
		return append(out, "\x1b]133;I\x07"...)
	case f.emitted != vtSemInput:
		return append(out, "\x1b]133;B\x07"...)
	}
	return out
}
