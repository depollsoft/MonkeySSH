package main

import (
	"bytes"
	"strconv"
)

// Semantic prompts (OSC 133, and VS Code's OSC 633) in the screen model,
// mirroring third_party/xterm/lib/src/core/semantic_prompt.dart: a cell keeps
// whether it was written as prompt, input or output, a row whether a prompt
// starts on it or it continues one, and each screen the content the next cell
// takes and the options of the current prompt. The client uses them to move
// the shell's cursor to a tapped cell and to keep the screen as history when
// a shell clears it at a prompt (Ctrl-L), so the model has to agree with it on
// both, and a frame painted from the model carries every mark it keeps
// (vtSemanticFrame).

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

// The shell status the app shows (TerminalShellStatus), read from the marks of
// both screens as applyTerminalShellIntegrationOsc does: A and D the prompt, B
// and I the command being edited, C a command running.
const (
	vtShellNone uint8 = iota
	vtShellPrompt
	vtShellEditing
	vtShellRunning
)

// vtShellState is what the app keeps from the marks of both screens: the
// status, and the exit status of the last D that carried a number, or "". A
// frame ends with them where the app reads them.
type vtShellState struct {
	status uint8
	exit   string
}

// apply reads the status an OSC 133 or 633 mark sets.
func (sh *vtShellState) apply(args [][]byte) {
	switch string(args[0]) {
	case "A", "N":
		sh.status = vtShellPrompt
	case "B", "I":
		sh.status, sh.exit = vtShellEditing, ""
	case "C":
		sh.status, sh.exit = vtShellRunning, ""
	case "D":
		sh.status = vtShellPrompt
		if len(args) > 1 {
			if _, err := strconv.Atoi(string(args[1])); err == nil {
				sh.exit = string(args[1])
			}
		}
	}
}

// appendOutputMark makes the next cells output and keeps the row marks and
// the prompt's options: D, with the exit status. The app also reads it as the
// shell at a prompt, so a frame of a running command leaves the app showing
// the prompt before it; only C says otherwise.
func (sh *vtShellState) appendOutputMark(out []byte) []byte {
	out = append(out, "\x1b]133;D"...)
	if sh.exit != "" {
		out = append(out, ';')
		out = append(out, sh.exit...)
	}
	return append(out, '\x07')
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
	s.shell.apply(args)
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

// vtSemanticFrame re-emits the row marks and cell contents of a screen while
// a frame paints it, with the prompt options and exit status in force, so a
// client painted from the model keeps what the model keeps everywhere: the
// prompt the cursor is at, which it moves the shell's cursor in and keeps as
// history on a clear, and every earlier one in the screen and the replayed
// scrollback. Only marks without side effects on the screen are used: A at
// the home of a blank screen, whose mark ED 2 and ED 3 undo again (begin), P
// for a row's mark, B for input, VS Code's H for prompt text and D for output
// (vtShellState.appendOutputMark); never C, which the app takes for a
// command starting, nor I except to end with input that ends with its line.
//
// The client marks a row a newline or a wrap reaches as continuing the prompt
// while it writes a prompt or its input, so the content is set to output
// before a row the model leaves unmarked is reached (beforeIndex), and any
// other mark is set once the row is (beginLine). Inside a row every written
// cell takes the content it was written as, as does a glyph printed again to
// restore a deferred wrap (content).
type vtSemanticFrame struct {
	state *vtSemanticState
	shell *vtShellState
	// emitted is the content the client writes now, and status what the app
	// shows from the marks so far.
	emitted uint8
	status  uint8
}

// semanticFrame returns the marks to paint g with, and the scrollback when
// withScrollback is set, or nil when there is nothing to carry: no mark and no
// cell written as prompt or input, no prompt options and no exit status. The
// app reads the marks for its shell status, which a screen without shell
// integration leaves alone.
func (s *terminalScreen) semanticFrame(g *vtGrid, withScrollback bool) *vtSemanticFrame {
	state := &s.semAlt
	if g == &s.main {
		state = &s.semMain
	}
	if *state == (vtSemanticState{}) && s.shell == (vtShellState{}) && !s.semanticMarked(g, withScrollback) {
		return nil
	}
	return &vtSemanticFrame{state: state, shell: &s.shell}
}

func (s *terminalScreen) semanticMarked(g *vtGrid, withScrollback bool) bool {
	for r, row := range g.rows {
		if g.prompt[r] != vtPromptNone {
			return true
		}
		for _, cell := range row {
			if cell.sem != vtSemOutput {
				return true
			}
		}
	}
	if !withScrollback {
		return false
	}
	for i := range s.scrollback.len() {
		if line := s.scrollback.at(i); line.prompt != vtPromptNone || len(line.sem) > 0 {
			return true
		}
	}
	return false
}

// begin is called before anything is painted, with the client's screen and
// scrollback blank. It sets the prompt options with an A, and the exit status
// with a D; ED 2 erases the mark A gave the home row again (on a blank screen
// it scrolls nothing into the scrollback) and ED 3 ends its content, as the
// replay prefix did.
func (f *vtSemanticFrame) begin(out []byte) []byte {
	if f == nil {
		return out
	}
	out = append(out, "\x1b[H\x1b]133;A"...)
	out = f.state.appendOptions(out)
	out = append(out, '\x07')
	f.status = vtShellPrompt
	if f.shell.exit != "" {
		out = f.outputMark(out)
	}
	return append(out, "\x1b[2J\x1b[3J"...)
}

// beforeIndex is called before a newline or a soft wrap reaches a line with
// mark: the client marks the row it reaches as continuing the prompt unless
// output is in force.
func (f *vtSemanticFrame) beforeIndex(out []byte, mark uint8) []byte {
	if f == nil || mark != vtPromptNone {
		return out
	}
	return f.content(out, vtSemOutput)
}

// beginLine is called with the cursor at the start of a line with mark, which
// a newline or a soft wrap reached when indexed is set. The mark the client
// gave the row on reaching it is kept; any other is set, which makes the next
// cells prompt.
func (f *vtSemanticFrame) beginLine(out []byte, mark uint8, indexed bool) []byte {
	if f == nil || mark == vtPromptNone {
		return out
	}
	if indexed && f.emitted != vtSemOutput && mark == vtPromptContinuation {
		return out
	}
	f.emitted = vtSemPrompt
	return appendVTPromptMark(out, mark)
}

// content is called before a cell is written as sem, or printed again as it
// was written to restore a deferred wrap.
func (f *vtSemanticFrame) content(out []byte, sem uint8) []byte {
	if f == nil || sem == f.emitted {
		return out
	}
	switch sem {
	case vtSemInput:
		return f.inputMark(out)
	case vtSemPrompt:
		f.emitted = vtSemPrompt
		return append(out, "\x1b]633;H\x07"...)
	}
	return f.outputMark(out)
}

func (f *vtSemanticFrame) inputMark(out []byte) []byte {
	f.emitted, f.status = vtSemInput, vtShellEditing
	return append(out, "\x1b]133;B\x07"...)
}

func (f *vtSemanticFrame) outputMark(out []byte) []byte {
	f.emitted, f.status = vtSemOutput, vtShellPrompt
	return f.shell.appendOutputMark(out)
}

// finish leaves the client writing what the model is, whatever the last
// painted cell was, and the app showing the status the model has, as far as
// a mark without side effects can say: the prompt (D, with the exit status)
// or the command being edited (B), set before the content when the content
// alone would leave the app elsewhere. A command running (C) cannot be said,
// and the content comes first: input that ended with its line (I) before its
// command started leaves the app showing the prompt rather than the command
// being edited. The cursor's row is painted already, so only the content is
// set, never a mark.
func (f *vtSemanticFrame) finish(out []byte) []byte {
	if f == nil {
		return out
	}
	if f.state.content == vtSemInput && f.state.eolInput {
		f.status = vtShellEditing
		return append(out, "\x1b]133;I\x07"...)
	}
	switch {
	case f.shell.status == vtShellPrompt && f.status != vtShellPrompt:
		out = f.outputMark(out)
	case f.shell.status == vtShellEditing && f.status != vtShellEditing:
		out = f.inputMark(out)
	}
	return f.content(out, f.state.content)
}

// appendVTPromptMark marks the cursor's line as P does, with the kind that
// gives mark exactly, and makes the next cells prompt.
func appendVTPromptMark(out []byte, mark uint8) []byte {
	switch mark {
	case vtPromptContinuation:
		return append(out, "\x1b]133;P;k=c\x07"...)
	case vtPromptSecondary:
		return append(out, "\x1b]133;P;k=s\x07"...)
	}
	return append(out, "\x1b]133;P;k=i\x07"...)
}
