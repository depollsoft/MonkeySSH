package main

import (
	"bytes"
	"slices"
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
// for a row's mark, B for input, VS Code's H for prompt text, D for output
// (vtShellState.appendOutputMark) and C where a command's output begins; I
// only to end with input that ends with its line.
//
// The app adds a command mark at the cursor on C and reads it as a command
// running, which gates its completion and command-review features, so C is
// emitted where the command started: on the unmarked row that follows a
// prompt or its input (commandMark), which is also where the client marked
// the row as continuing the prompt when a newline or a wrap reached it, a
// mark that C at the start of the row undoes. Any other mark is set once the
// row is reached (beginLine), and inside a row every written cell takes the
// content it was written as, as does a glyph printed again to restore a
// deferred wrap (content). A running command whose C arrived on its input
// row starts at the first output cell after that input on the row (cell),
// and one with no output painted after its input right after it (resume); one
// the replay shows no start of, its prompt above the replayed scrollback,
// gets its C before anything is painted (finish).
type vtSemanticFrame struct {
	state *vtSemanticState
	shell *vtShellState
	// emitted is the content the client writes now, and status what the app
	// shows from the marks so far.
	emitted uint8
	status  uint8
	// pushed is set while the newlines that push the scrollback above the
	// screen run with output in force although the last painted cell was
	// prompt or input (push); beginAt is where in the output begin ended, for
	// a C that has to come first.
	pushed  bool
	beginAt int
	// line is the line being painted, counted from the first painted
	// scrollback line, and command the last cell written as prompt or input
	// (line -1 for none): the running command's output starts after it, and
	// started is set once its C, not an earlier command's, was emitted, at
	// commandAt. history is how many scrollback lines are painted, and width
	// the screen's.
	line      int
	command   vtCellPosition
	started   bool
	commandAt vtCellPosition
	history   int
	width     int
}

// vtCellPosition is a cell of a frame: its line in paint order and column.
type vtCellPosition struct {
	line, col int
}

// semanticFrame returns the marks to paint g with, and the scrollback when
// withScrollback is set, or nil when there is nothing to carry: no mark and no
// cell written as prompt or input, no prompt options, and, for the main
// screen, which a replay paints first, no shell status. The app reads the
// marks for its shell status, which a screen without shell integration
// leaves alone.
func (s *terminalScreen) semanticFrame(g *vtGrid, withScrollback bool) *vtSemanticFrame {
	state := &s.semAlt
	if g == &s.main {
		state = &s.semMain
	}
	if *state == (vtSemanticState{}) && (g != &s.main || s.shell == (vtShellState{})) &&
		!s.semanticMarked(g, withScrollback) {
		return nil
	}
	history := 0
	if withScrollback {
		history = s.scrollback.len()
	}
	return &vtSemanticFrame{
		state: state, shell: &s.shell, command: s.lastSemanticCell(g, withScrollback),
		history: history, width: s.width,
	}
}

// lastSemanticCell is the last cell of g, after the scrollback when
// withScrollback is set, that was written as prompt or input, in paint order.
// A marked row whose cells output overwrote counts as one before its first
// cell (column -1): its command's output starts at the row's start.
func (s *terminalScreen) lastSemanticCell(g *vtGrid, withScrollback bool) vtCellPosition {
	history := 0
	if withScrollback {
		history = s.scrollback.len()
	}
	for r := len(g.rows) - 1; r >= 0; r-- {
		for col := len(g.rows[r]) - 1; col >= 0; col-- {
			if g.rows[r][col].sem != vtSemOutput {
				return vtCellPosition{history + r, col}
			}
		}
		if g.prompt[r] != vtPromptNone {
			return vtCellPosition{history + r, -1}
		}
	}
	for i := history - 1; i >= 0; i-- {
		line := s.scrollback.at(i)
		if len(line.sem) > 0 {
			return vtCellPosition{i, len(line.sem) - 1}
		}
		if line.prompt != vtPromptNone {
			return vtCellPosition{i, -1}
		}
	}
	return vtCellPosition{-1, -1}
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
// replay prefix did. A C that has to come first goes after them (beginAt),
// since the clears would drop the command mark the app puts on the home row.
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
	out = append(out, "\x1b[2J\x1b[3J"...)
	f.beginAt = len(out)
	return out
}

// push is called before the newlines that push the scrollback above the
// screen: the rows they push in are painted afterwards, where a row's mark
// is set, so here they must take none.
func (f *vtSemanticFrame) push(out []byte) []byte {
	if f == nil || f.emitted == vtSemOutput {
		return out
	}
	out = f.outputMark(out)
	f.pushed = true
	return out
}

// beginLine is called with the cursor at the start of line, with mark, which
// a newline or a soft wrap reached when indexed is set, and which has a
// written cell or the cursor on it when written is set. An unmarked line
// after a prompt or its input is where its command's output begins (C, which
// also undoes the continuation mark the client gave a line reached by a
// newline or a wrap), unless it is a blank line the shell never reached. On a
// marked line the mark the client gave the row on reaching it is kept; any
// other is set, which makes the next cells prompt.
func (f *vtSemanticFrame) beginLine(out []byte, line int, mark uint8, indexed, written bool) []byte {
	if f == nil {
		return out
	}
	f.line = line
	if mark == vtPromptNone {
		if indexed && f.emitted != vtSemOutput || !indexed && written && (f.emitted != vtSemOutput || f.pushed) {
			// After the last prompt or input cell it is the running
			// command's; before it an earlier command's.
			return f.commandMark(out, line > f.command.line, 0)
		}
		return out
	}
	f.pushed = false
	if indexed && f.emitted != vtSemOutput && mark == vtPromptContinuation {
		return out
	}
	f.emitted = vtSemPrompt
	return appendVTPromptMark(out, mark)
}

// commandMark is C at col of the line being painted: the command whose
// prompt or input was painted last runs from here, the running one when
// running is set. The app clears the exit status with it, as the shell's C
// did.
func (f *vtSemanticFrame) commandMark(out []byte, running bool, col int) []byte {
	f.emitted, f.status, f.pushed = vtSemOutput, vtShellRunning, false
	if running && !f.started {
		f.started, f.commandAt = true, vtCellPosition{f.line, col}
	}
	return append(out, "\x1b]133;C\x07"...)
}

// resume is called once the saved cursor is restored, before the cursor is
// placed, for a command the model has running. One the paint showed no
// output of starts right after its prompt or input: C at the start of a row
// would end the row's mark, so never in column 0. One whose C came before a
// glyph the saved cursor printed again as input, to restore its deferred
// wrap, which left the app editing, gets C again where it was, on a row the
// app has a command mark on already, so it adds none. A place in the
// scrollback, out of the cursor's reach, is left to finish.
func (f *vtSemanticFrame) resume(out []byte) []byte {
	if f == nil || f.shell.status != vtShellRunning || f.started && f.status == vtShellRunning {
		return out
	}
	at := f.commandAt
	if !f.started {
		if f.command.line < 0 {
			return out
		}
		at = vtCellPosition{f.command.line, min(max(f.command.col+1, 1), f.width-1)}
	}
	if at.line < f.history {
		return out
	}
	out = appendVTCursorPosition(out, at.line-f.history, at.col)
	return f.commandMark(out, true, at.col)
}

// cell is called before the cell at col of the line being painted is
// written as sem. Output after the last prompt or input cell on its row is
// where a running command, whose C arrived on that row, started.
func (f *vtSemanticFrame) cell(out []byte, col int, sem uint8) []byte {
	if f == nil || sem == f.emitted {
		return out
	}
	// A marked row output overwrote (column -1) gets its C after its first
	// cell (resume): one at the row's start would undo its mark.
	if sem == vtSemOutput && f.shell.status == vtShellRunning &&
		f.line == f.command.line && f.command.col >= 0 && col > f.command.col {
		return f.commandMark(out, true, col)
	}
	return f.content(out, sem)
}

// content is called before a cell is written as sem, or printed again as it
// was written to restore a deferred wrap.
func (f *vtSemanticFrame) content(out []byte, sem uint8) []byte {
	if f == nil || sem == f.emitted {
		return out
	}
	f.pushed = false
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
// painted cell was, and the app showing the status the model has: the prompt
// (D, with the exit status) or the command being edited (B), set before the
// content when the content alone would leave the app elsewhere, or a command
// running, whose C the frame emitted where its output begins or after its
// input (resume), or else puts at the cursor, or, when its prompt is above
// what the frame replays, before everything painted, where the app marks the
// first replayed line. The content comes first:
// input that ended with its line (I) before its command started leaves the
// app showing the prompt rather than the command being edited. The cursor's
// row is painted already, so only the content is set, never a mark.
func (f *vtSemanticFrame) finish(out []byte) []byte {
	if f == nil {
		return out
	}
	if f.shell.status == vtShellRunning && !f.started {
		if f.command.line < 0 {
			// Nothing painted after it set a status: no row is marked and
			// no cell is prompt or input.
			out = slices.Insert(out, f.beginAt, []byte("\x1b]133;C\x07")...)
			f.started, f.status = true, vtShellRunning
		} else {
			out = f.commandMark(out, true, -1)
		}
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
	case f.shell.status == vtShellRunning && f.status != vtShellRunning:
		// A glyph printed again as input after the command's C, to restore
		// the cursor's deferred wrap or a saved one resume could not reach,
		// left the app editing; D would leave it at the prompt.
		out = f.commandMark(out, true, -1)
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
