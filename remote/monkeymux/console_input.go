package main

import (
	"bytes"
	"fmt"
	"unicode/utf16"
	"unicode/utf8"
)

// Suppress OSC/DCS replies for native console readers, including responses the
// attach router streams after its carry limit. Keep only parser state, never an
// unbounded reply. This state belongs to routed replies: interleaved user keys
// and pasted content must not be consumed as response payload.
// The router buffers incomplete introducers before it starts streaming, so a
// lone ESC outside a response remains an immediate Escape key.
type nativeConsoleResponseFilter struct {
	kind          byte
	escape        bool
	utf8Remaining int
}

func (f *nativeConsoleResponseFilter) filter(data []byte) ([]byte, bool) {
	output := make([]byte, 0, len(data))
	found := f.kind != 0
	for i := 0; i < len(data); i++ {
		b := data[i]
		continuation := f.utf8Remaining > 0 && b&0xc0 == 0x80
		if continuation {
			f.utf8Remaining--
		} else {
			f.utf8Remaining = trailingUtf8ContinuationCount(data[i : i+1])
		}
		if f.kind != 0 {
			if (f.escape && b == '\\') || (!continuation && b == 0x9c) || (f.kind == ']' && b == '\a') {
				f.kind = 0
			}
			f.escape = f.kind != 0 && b == '\x1b'
			continue
		}
		if b == '\x1b' && i+1 < len(data) && (data[i+1] == ']' || data[i+1] == 'P') {
			i++
			f.kind = data[i]
		} else if !continuation && (b == 0x9d || b == 0x90) {
			if b == 0x9d {
				f.kind = ']'
			} else {
				f.kind = 'P'
			}
		} else {
			output = append(output, b)
			continue
		}
		found = true
	}
	return output, found
}

// Native console readers have no paste event. Remove only the framing while
// retaining the payload, including literal control strings inside it. Holding
// incomplete markers avoids ConPTY timing out a lone ESC between input writes.
type nativeConsolePasteFilter struct {
	carry         []byte
	inPaste       bool
	utf8Remaining int
	unicodeCarry  []byte
	lastWasCR     bool
}

// Encode native paste characters without keyboard-layout-derived modifiers.
// Key-up boundaries prevent repeated characters from becoming one key record
// with a repeat count (which some native readers ignore). Key-up carries no
// Unicode character, so it cannot duplicate or disrupt UTF-16 surrogate pairs.
// Normalize newlines to native Return events and retain split UTF-8 code points.
func (f *nativeConsolePasteFilter) encode(input []byte) []byte {
	data := append(f.unicodeCarry, f.filter(input)...)
	f.unicodeCarry = nil
	end := 0
	for end < len(data) && utf8.FullRune(data[end:]) {
		_, size := utf8.DecodeRune(data[end:])
		end += size
	}
	f.unicodeCarry = append(f.unicodeCarry, data[end:]...)
	var output bytes.Buffer
	for _, codeUnit := range utf16.Encode([]rune(string(data[:end]))) {
		if codeUnit == '\n' && f.lastWasCR {
			f.lastWasCR = false
			continue
		}
		f.lastWasCR = codeUnit == '\r'
		virtualKey := uint16(0)
		switch codeUnit {
		case '\r', '\n':
			virtualKey, codeUnit = 13, '\r'
		case '\t':
			virtualKey = 9
		case '\x1b':
			virtualKey = 27
		case '\b':
			virtualKey = 8
		}
		fmt.Fprintf(&output, "\x1b[%d;0;%d;1;0;1_\x1b[%d;0;0;0;0;1_", virtualKey, codeUnit, virtualKey)
	}
	if !f.inPaste {
		f.lastWasCR = false
	}
	return output.Bytes()
}

func (f *nativeConsolePasteFilter) filter(input []byte) []byte {
	data := append(f.carry, input...)
	f.carry = nil
	leading := leadingUtf8ContinuationPrefix(data, f.utf8Remaining)
	f.utf8Remaining = nextQueryUtf8Remaining(data, f.utf8Remaining, leading)
	var output []byte
	for len(data) > 0 {
		sevenBit, eightBit := bracketedPasteStart7Bit, bracketedPasteStart8Bit
		if f.inPaste {
			sevenBit, eightBit = bracketedPasteEnd7Bit, bracketedPasteEnd8Bit
		}
		match := matchBracketedPasteMarker(data, sevenBit, eightBit, leading)
		if match.index >= 0 {
			output = append(output, data[:match.index]...)
			consumed := match.index + match.length
			data = data[consumed:]
			leading = max(0, leading-consumed)
			f.inPaste = !f.inPaste
			continue
		}
		suffix := bracketedPasteMarkerSuffixLength(data, sevenBit, eightBit, leading)
		output = append(output, data[:len(data)-suffix]...)
		f.carry = append(f.carry, data[len(data)-suffix:]...)
		break
	}
	return output
}
