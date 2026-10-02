package main

import (
	"bytes"
	"io"
	"slices"
	"strconv"
	"strings"
)

// attachInputModePrivateModes are the DEC private modes a pane can leave
// switched on that change what the local terminal sends back as input. They
// are reset when an attach ends, in this order, if the pane enabled them.
var attachInputModePrivateModes = []int{
	1000, 1002, 1003, 1005, 1006, 1015, // mouse reporting
	1004, // focus reporting
	2004, // bracketed paste
	1,    // application cursor keys
}

const attachCursorVisibleMode = 25

// attachAlternateScreenModes switch between the main and alternate screens.
var attachAlternateScreenModes = []int{47, 1047, 1049}

const attachModeTrackerMaxCSI = 64

const (
	attachModeTrackerGround = iota
	attachModeTrackerEscape
	attachModeTrackerCSI
)

// attachModeTracker passes attach output to the local terminal and remembers
// the input modes the panes switch on, so the terminal can be handed back in a
// usable state when the attach ends. Without it, a detach from an agent window
// leaves the terminal in, say, the kitty keyboard protocol, and the shell that
// resumes receives ESC [ 99 ; 5 u for Ctrl-C.
type attachModeTracker struct {
	w     io.Writer
	state int
	csi   []byte
	// kittyKeyboard records kitty keyboard changes on the main [0] and
	// alternate [1] screens, which keep independent stacks.
	kittyKeyboard   [2]bool
	alternateScreen bool
	modifyOtherKeys bool
	privateModes    map[int]bool
}

func newAttachModeTracker(w io.Writer) *attachModeTracker {
	return &attachModeTracker{w: w, privateModes: map[int]bool{}}
}

func (t *attachModeTracker) Write(p []byte) (int, error) {
	for rest := p; len(rest) > 0; rest = rest[1:] {
		if t.state == attachModeTrackerGround {
			index := bytes.IndexByte(rest, 0x1b)
			if index < 0 {
				break
			}
			rest = rest[index:]
		}
		t.observe(rest[0])
	}
	return t.w.Write(p)
}

func (t *attachModeTracker) observe(value byte) {
	switch t.state {
	case attachModeTrackerGround:
		if value == 0x1b {
			t.state = attachModeTrackerEscape
		}
	case attachModeTrackerEscape:
		switch value {
		case '[':
			t.state = attachModeTrackerCSI
			t.csi = t.csi[:0]
		case 0x1b:
		case 'c':
			// RIS resets the terminal, so nothing needs switching back off.
			*t = attachModeTracker{w: t.w, csi: t.csi[:0], privateModes: map[int]bool{}}
		default:
			t.state = attachModeTrackerGround
		}
	case attachModeTrackerCSI:
		switch {
		case value >= 0x40 && value <= 0x7e:
			t.apply(string(t.csi), value)
			t.state = attachModeTrackerGround
		case value == 0x1b:
			t.state = attachModeTrackerEscape
		case value >= 0x20 && value <= 0x3f && len(t.csi) < attachModeTrackerMaxCSI:
			t.csi = append(t.csi, value)
		default:
			t.state = attachModeTrackerGround
		}
	}
}

func (t *attachModeTracker) apply(params string, final byte) {
	switch final {
	case 'u':
		// CSI > flags u pushes and CSI = flags ; mode u sets kitty keyboard
		// flags. A pop alone cannot switch the protocol on.
		if strings.HasPrefix(params, ">") || strings.HasPrefix(params, "=") {
			t.kittyKeyboard[t.screenIndex()] = true
		}
	case 'm':
		// CSI > 4 ; level m sets xterm modifyOtherKeys; a missing or zero
		// level switches it back off.
		if !strings.HasPrefix(params, ">") {
			return
		}
		if resource, level, _ := strings.Cut(params[1:], ";"); resource == "4" {
			t.modifyOtherKeys = level != "" && level != "0"
		}
	case 'h', 'l':
		if !strings.HasPrefix(params, "?") {
			return
		}
		for _, field := range strings.Split(params[1:], ";") {
			mode, err := strconv.Atoi(field)
			if err != nil {
				continue
			}
			switch {
			case slices.Contains(attachAlternateScreenModes, mode):
				t.alternateScreen = final == 'h'
			case mode == attachCursorVisibleMode ||
				slices.Contains(attachInputModePrivateModes, mode):
				t.privateModes[mode] = final == 'h'
			}
		}
	}
}

func (t *attachModeTracker) screenIndex() int {
	if t.alternateScreen {
		return 1
	}
	return 0
}

// resetSequence returns the sequences that leave the alternate screen, switch
// off the input modes the panes left on, and show a cursor a pane hid. It is
// empty when the panes left the terminal as they found it.
func (t *attachModeTracker) resetSequence() []byte {
	var reset []byte
	if t.alternateScreen {
		if t.kittyKeyboard[1] {
			reset = append(reset, kittyKeyboardResetSequence...)
		}
		reset = append(reset, "\x1b[?1049l"...)
	}
	if t.kittyKeyboard[0] {
		reset = append(reset, kittyKeyboardResetSequence...)
	}
	if t.kittyKeyboard[1] && !t.alternateScreen {
		reset = append(reset, "\x1b[?1049h"+kittyKeyboardResetSequence+"\x1b[?1049l"...)
	}
	if t.modifyOtherKeys {
		reset = append(reset, "\x1b[>4;0m"...)
	}
	for _, mode := range attachInputModePrivateModes {
		if t.privateModes[mode] {
			reset = append(reset, "\x1b[?"+strconv.Itoa(mode)+"l"...)
		}
	}
	if visible, ok := t.privateModes[attachCursorVisibleMode]; ok && !visible {
		reset = append(reset, "\x1b[?25h"...)
	}
	return reset
}
