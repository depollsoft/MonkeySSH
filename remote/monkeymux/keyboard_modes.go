package main

import (
	"strconv"
	"strings"
)

// The kitty keyboard protocol and xterm modifyOtherKeys change how the
// attached terminal encodes keys. Agents such as Claude Code, Codex, Copilot
// CLI, and OpenCode switch them on, and the request reaches the terminal with
// the rest of the active window's output. Each window's state is tracked so a
// window switch can restore it: otherwise a shell selected after an agent
// keeps receiving ESC [ 99 ; 5 u for Ctrl-C, and an agent selected after a
// shell loses the key reports it asked for.

// kittyKeyboardStackLimit bounds a window's tracked push stack. The protocol
// evicts the oldest entry once a terminal's own stack is full.
const kittyKeyboardStackLimit = 32

// kittyKeyboardResetSequence pops every entry, which resets the flags once the
// stack empties, and then clears flags set without a push.
const kittyKeyboardResetSequence = "\x1b[<99u\x1b[=0;1u"

// kittyKeyboardModes is one screen's kitty keyboard state: the active flags
// plus the flags each push saved underneath them.
type kittyKeyboardModes struct {
	flags int
	saved []int
}

func (k *kittyKeyboardModes) push(flags int) {
	if len(k.saved) == kittyKeyboardStackLimit {
		k.saved = k.saved[1:]
	}
	k.saved = append(k.saved, k.flags)
	k.flags = flags
}

func (k *kittyKeyboardModes) pop(count int) {
	for range max(count, 1) {
		if len(k.saved) == 0 {
			k.flags = 0
			return
		}
		k.flags = k.saved[len(k.saved)-1]
		k.saved = k.saved[:len(k.saved)-1]
	}
}

func (k *kittyKeyboardModes) set(flags int, mode int) {
	switch mode {
	case 2:
		k.flags |= flags
	case 3:
		k.flags &^= flags
	default:
		k.flags = flags
	}
}

// appendReplay resets the terminal's stack for the current screen and then
// rebuilds this state on it.
func (k kittyKeyboardModes) appendReplay(out []byte) []byte {
	out = append(out, kittyKeyboardResetSequence...)
	levels := append(append([]int(nil), k.saved...), k.flags)
	if levels[0] != 0 {
		out = append(out, "\x1b[="+strconv.Itoa(levels[0])+";1u"...)
	}
	for _, flags := range levels[1:] {
		out = append(out, "\x1b[>"+strconv.Itoa(flags)+"u"...)
	}
	return out
}

// observeKittyKeyboardLocked applies a kitty keyboard push (CSI > flags u),
// pop (CSI < count u), or set (CSI = flags ; mode u) to the current screen.
func (w *muxWindow) observeKittyKeyboardLocked(params string) {
	if params == "" {
		return
	}
	operation := params[0]
	if operation != '>' && operation != '<' && operation != '=' {
		return
	}
	first, second, _ := strings.Cut(params[1:], ";")
	value, ok := parseKeyboardModeParam(first, 0)
	if !ok {
		return
	}
	modes := &w.kittyKeyboard[0]
	if w.alternateScreenModeActiveLocked() {
		modes = &w.kittyKeyboard[1]
	}
	switch operation {
	case '>':
		modes.push(value)
		w.keyboardModesUsed = true
	case '<':
		modes.pop(value)
	case '=':
		mode, ok := parseKeyboardModeParam(second, 1)
		if !ok {
			return
		}
		modes.set(value, mode)
		w.keyboardModesUsed = true
	}
}

// observeModifyOtherKeysLocked applies xterm's CSI > 4 ; level m, where a
// missing level resets modifyOtherKeys to off.
func (w *muxWindow) observeModifyOtherKeysLocked(params string) {
	if !strings.HasPrefix(params, ">") {
		return
	}
	resource, level, _ := strings.Cut(params[1:], ";")
	if resource != "4" {
		return
	}
	value, ok := parseKeyboardModeParam(level, 0)
	if !ok {
		return
	}
	w.modifyOtherKeys = value
	if value != 0 {
		w.keyboardModesUsed = true
	}
}

func (w *muxWindow) resetKeyboardModesLocked() {
	w.kittyKeyboard = [2]kittyKeyboardModes{}
	w.modifyOtherKeys = 0
}

// keyboardModeReplayLocked restores the window's keyboard modes. It must be
// written while the terminal shows the main screen: it visits the alternate
// screen to restore that screen's independent kitty stack as well.
func (w *muxWindow) keyboardModeReplayLocked() []byte {
	replay := w.kittyKeyboard[0].appendReplay(nil)
	replay = append(replay, "\x1b[?1049h"...)
	replay = w.kittyKeyboard[1].appendReplay(replay)
	replay = append(replay, "\x1b[?1049l"...)
	return append(replay, "\x1b[>4;"+strconv.Itoa(w.modifyOtherKeys)+"m"...)
}

func parseKeyboardModeParam(value string, fallback int) (int, bool) {
	if value == "" {
		return fallback, true
	}
	number, err := strconv.Atoi(value)
	if err != nil || number < 0 || number > 0xffff {
		return 0, false
	}
	return number, true
}

// isKeyboardModeSequence reports whether a CSI sequence changes the kitty
// keyboard flags or modifyOtherKeys. Replays drop these from retained output
// and restore the tracked state instead, because a trimmed history holds only
// part of a window's pushes and pops.
func isKeyboardModeSequence(sequence []byte) bool {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return false
	}
	params := string(sequence[bodyStart : len(sequence)-1])
	if params == "" {
		return false
	}
	switch sequence[len(sequence)-1] {
	case 'u':
		return params[0] == '>' || params[0] == '<' || params[0] == '='
	case 'm':
		resource, _, _ := strings.Cut(params, ";")
		return resource == ">4"
	}
	return false
}
