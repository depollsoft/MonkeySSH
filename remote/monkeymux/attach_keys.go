package main

import (
	"strconv"
	"strings"
)

// Agent TUIs such as Claude Code, Codex, Copilot CLI, and OpenCode switch the
// attached terminal into an enhanced keyboard encoding — the kitty keyboard
// protocol (CSI > flags u, CSI = flags ; mode u) and/or xterm modifyOtherKeys
// (CSI > 4 ; level m). The terminal then reports Ctrl-B as ESC [ 98 ; 5 u or
// ESC [ 27 ; 5 ; 98 ~ instead of the 0x02 byte, so the prefix and the command
// key after it have to be recognized in those encodings as well.

const attachKeyEventMaxLength = 64

// Kitty keyboard protocol modifier bits (the encoded value is 1 + bits).
const (
	attachKeyModifierShift    = 1
	attachKeyModifierCtrl     = 4
	attachKeyModifierCapsLock = 64
	attachKeyModifierNumLock  = 128
)

// attachKeyEvent is one key decoded from an enhanced keyboard encoding.
type attachKeyEvent struct {
	// code is the unshifted key (kitty) or the produced character
	// (modifyOtherKeys).
	code rune
	// shifted is the kitty alternate shifted key, or 0 when not reported.
	shifted rune
	// text is the first kitty associated-text code point, or 0.
	text      rune
	modifiers int
	release   bool
}

// parseAttachKeyEvent decodes a key event at the start of data: kitty
// `CSI code[:shifted[:base]] [; modifiers[:event] [; text]] u` or xterm
// modifyOtherKeys `CSI 27 ; modifiers ; code ~`. It returns the event and the
// encoded length, or ok false when data does not start with a complete one.
func parseAttachKeyEvent(data []byte) (attachKeyEvent, int, bool) {
	if len(data) < 4 || data[0] != 0x1b || data[1] != '[' {
		return attachKeyEvent{}, 0, false
	}
	end := -1
	for i := 2; i < len(data) && i < attachKeyEventMaxLength; i++ {
		value := data[i]
		if value == 'u' || value == '~' {
			end = i
			break
		}
		if (value < '0' || value > '9') && value != ';' && value != ':' {
			return attachKeyEvent{}, 0, false
		}
	}
	if end < 0 {
		return attachKeyEvent{}, 0, false
	}
	params := strings.Split(string(data[2:end]), ";")
	var event attachKeyEvent
	var ok bool
	if data[end] == 'u' {
		event, ok = parseKittyKeyParams(params)
	} else {
		event, ok = parseModifyOtherKeysParams(params)
	}
	if !ok {
		return attachKeyEvent{}, 0, false
	}
	return event, end + 1, true
}

// isIncompleteAttachKeyEvent reports whether data is the start of an enhanced
// key sequence that later input could complete: ESC, ESC [, or ESC [ followed
// only by parameter bytes.
func isIncompleteAttachKeyEvent(data []byte) bool {
	if len(data) == 0 || data[0] != 0x1b || len(data) >= attachKeyEventMaxLength {
		return false
	}
	if len(data) == 1 {
		return true
	}
	if data[1] != '[' {
		return false
	}
	for _, value := range data[2:] {
		if (value < '0' || value > '9') && value != ';' && value != ':' {
			return false
		}
	}
	return true
}

func parseKittyKeyParams(params []string) (attachKeyEvent, bool) {
	if len(params) > 3 {
		return attachKeyEvent{}, false
	}
	keys := strings.Split(params[0], ":")
	if len(keys) > 3 {
		return attachKeyEvent{}, false
	}
	code, ok := parseAttachKeyNumber(keys[0])
	if !ok {
		return attachKeyEvent{}, false
	}
	event := attachKeyEvent{code: rune(code)}
	if len(keys) > 1 && keys[1] != "" {
		shifted, ok := parseAttachKeyNumber(keys[1])
		if !ok {
			return attachKeyEvent{}, false
		}
		event.shifted = rune(shifted)
	}
	if len(params) > 1 && params[1] != "" {
		modifierField, eventType, hasEventType := strings.Cut(params[1], ":")
		modifiers, ok := parseAttachKeyModifiers(modifierField)
		if !ok {
			return attachKeyEvent{}, false
		}
		event.modifiers = modifiers
		if hasEventType {
			kind, ok := parseAttachKeyNumber(eventType)
			if !ok || kind < 1 || kind > 3 {
				return attachKeyEvent{}, false
			}
			event.release = kind == 3
		}
	}
	if len(params) > 2 && params[2] != "" {
		first, _, _ := strings.Cut(params[2], ":")
		text, ok := parseAttachKeyNumber(first)
		if !ok {
			return attachKeyEvent{}, false
		}
		event.text = rune(text)
	}
	return event, true
}

func parseModifyOtherKeysParams(params []string) (attachKeyEvent, bool) {
	if len(params) != 3 || params[0] != "27" {
		return attachKeyEvent{}, false
	}
	modifiers, ok := parseAttachKeyModifiers(params[1])
	if !ok {
		return attachKeyEvent{}, false
	}
	code, ok := parseAttachKeyNumber(params[2])
	if !ok {
		return attachKeyEvent{}, false
	}
	// modifyOtherKeys reports the character the key produced, so any Shift is
	// already applied to it.
	return attachKeyEvent{
		code:      rune(code),
		shifted:   rune(code),
		modifiers: modifiers,
	}, true
}

func parseAttachKeyNumber(value string) (int, bool) {
	if value == "" || strings.ContainsAny(value, ":;") {
		return 0, false
	}
	number, err := strconv.Atoi(value)
	if err != nil || number < 0 || number > 0x10ffff {
		return 0, false
	}
	return number, true
}

func parseAttachKeyModifiers(value string) (int, bool) {
	encoded, ok := parseAttachKeyNumber(value)
	if !ok || encoded < 1 {
		return 0, false
	}
	return (encoded - 1) &^ (attachKeyModifierCapsLock | attachKeyModifierNumLock), true
}

// isModifierOrLockKey reports whether the event is a bare modifier or lock
// key, which kitty reports on its own when all keys are sent as escape codes.
func (e attachKeyEvent) isModifierOrLockKey() bool {
	// CAPS_LOCK..NUM_LOCK and LEFT_SHIFT..ISO_LEVEL5_SHIFT in the kitty
	// functional-key table.
	return (e.code >= 57358 && e.code <= 57360) ||
		(e.code >= 57441 && e.code <= 57454)
}

// legacyByte returns the single byte a terminal without an enhanced keyboard
// encoding would have sent for this key, so prefix commands keep meaning the
// same thing in every encoding.
func (e attachKeyEvent) legacyByte() (byte, bool) {
	character := e.code
	modifiers := e.modifiers
	if modifiers&attachKeyModifierShift != 0 {
		switch {
		case e.text != 0:
			character = e.text
		case e.shifted != 0:
			character = e.shifted
		case character >= 'a' && character <= 'z':
			character -= 'a' - 'A'
		default:
			return 0, false
		}
		modifiers &^= attachKeyModifierShift
	} else if e.text != 0 {
		character = e.text
	}
	if character < 0 || character > 0x7f {
		return 0, false
	}
	switch modifiers {
	case 0:
		return byte(character), true
	case attachKeyModifierCtrl:
		switch {
		case character >= 'a' && character <= 'z':
			return byte(character - 'a' + 1), true
		case character >= '@' && character <= '_':
			return byte(character) & 0x1f, true
		case character == ' ':
			return 0, true
		}
	}
	return 0, false
}
