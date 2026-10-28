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

// Row marks, as SemanticPromptRow in the client.
const (
	vtPromptNone uint8 = iota
	vtPromptPrimary
	vtPromptContinuation
)

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
// default) and r a primary prompt, c and s a continuation.
func promptKind(options [][]byte) uint8 {
	for _, option := range options {
		if len(option) == 3 && option[0] == 'k' && option[1] == '=' {
			switch option[2] {
			case 'c', 's':
				return vtPromptContinuation
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
			s.startPrompt(nil, true)
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
		s.startPrompt(options, promptKind(options) == vtPromptPrimary)
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

// startPrompt starts a prompt. A primary one is a new prompt and drops the
// options of the last; a continuation keeps them and takes those it names.
func (s *terminalScreen) startPrompt(options [][]byte, primary bool) {
	st := s.semantic()
	if primary {
		st.resetOptions()
	}
	st.applyOptions(options)
	if primary {
		s.markPrompt(vtPromptPrimary)
	} else {
		s.markPrompt(vtPromptContinuation)
	}
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
	g.prompt[g.cursorRow] = vtPromptContinuation
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
// currentPromptRows in the client, within the grid.
func (s *terminalScreen) promptRows() (start, end int, ok bool) {
	if s.altActive {
		return 0, 0, false
	}
	g := &s.main
	row := g.cursorRow
	if g.prompt[row] == vtPromptNone && s.semMain.content == vtSemOutput {
		return 0, 0, false
	}
	start = row
	for g.prompt[start] == vtPromptContinuation && start > 0 && g.prompt[start-1] != vtPromptNone {
		start--
	}
	end = row
	for end+1 < len(g.rows) && g.prompt[end+1] == vtPromptContinuation {
		end++
	}
	return start, end, true
}

// vtSemanticFrame re-emits the marks of the prompt the cursor is at while a
// frame paints the main screen, so a client painted from the model can move
// the shell's cursor and keep history on a clear right away. A frame paints
// onto a client whose replay prefix ended any open prompt (CSI 3 J), so the
// rows before the prompt need nothing. Only marks without side effects are
// used: A at a row start (no fresh line there), P, B and I; never C or D,
// which the app takes for a command starting or finishing. So nothing is
// emitted unless the cursor is in a prompt or its input, and cells written as
// output inside the prompt take the content in force.
type vtSemanticFrame struct {
	state   *vtSemanticState
	grid    *vtGrid
	start   int
	end     int
	row     int
	emitted uint8
}

// semanticFrame returns the marks to paint g with, or nil.
func (s *terminalScreen) semanticFrame(g *vtGrid) *vtSemanticFrame {
	if g != &s.main || s.altActive || s.semMain.content == vtSemOutput {
		return nil
	}
	start, end, ok := s.promptRows()
	if !ok {
		return nil
	}
	return &vtSemanticFrame{state: &s.semMain, grid: g, start: start, end: end, row: -1}
}

// beginRow is called with the cursor at the start of row r, which a soft wrap
// reached when wrapped is set.
func (f *vtSemanticFrame) beginRow(out []byte, r int, wrapped bool) []byte {
	if f == nil {
		return out
	}
	if r < f.start || r > f.end {
		f.row = -1
		return out
	}
	f.row = r
	switch {
	case r == f.start:
		// A primary prompt resets the client's options, which the model's
		// replace; a continuation row is marked so after it.
		out = append(out, "\x1b]133;A"...)
		out = f.state.appendOptions(out)
		out = append(out, '\x07')
		if f.grid.prompt[r] == vtPromptContinuation {
			out = append(out, "\x1b]133;P;k=s\x07"...)
		}
		f.emitted = vtSemPrompt
	case !wrapped:
		out = append(out, "\x1b]133;P;k=s\x07"...)
		f.emitted = vtSemPrompt
	}
	// A soft wrap inside the prompt marks the row on its own.
	return out
}

// cell is called before a written cell of the row being painted.
func (f *vtSemanticFrame) cell(out []byte, sem uint8) []byte {
	if f == nil || f.row < 0 || sem == f.emitted {
		return out
	}
	switch sem {
	case vtSemInput:
		out = append(out, "\x1b]133;B\x07"...)
	case vtSemPrompt:
		if f.grid.prompt[f.row] == vtPromptPrimary {
			out = append(out, "\x1b]133;P;k=i\x07"...)
		} else {
			out = append(out, "\x1b]133;P;k=s\x07"...)
		}
	default:
		return out
	}
	f.emitted = sem
	return out
}

// finish leaves the client writing input when the model is, whatever the
// last painted cell was.
func (f *vtSemanticFrame) finish(out []byte) []byte {
	if f == nil || f.state.content != vtSemInput {
		return out
	}
	if f.state.eolInput {
		return append(out, "\x1b]133;I\x07"...)
	}
	if f.emitted != vtSemInput {
		out = append(out, "\x1b]133;B\x07"...)
	}
	return out
}
