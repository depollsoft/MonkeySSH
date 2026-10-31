package main

import (
	"bytes"
	"strconv"
)

// silencedKittyReplayCommand returns a graphics command from replayed raw
// history with q=2, or nil when seq is not a graphics command or is silent
// already. The program had its reply when the command first ran; running it
// again on attach must not send another, which nothing expects and which
// would be typed into the window as input.
func silencedKittyReplayCommand(seq []byte) []byte {
	start, end, ok := kittyCommandControl(seq)
	if !ok {
		return nil
	}
	quiet, err := strconv.Atoi(parseKittyControl(string(seq[start:end]))["q"])
	if err == nil && quiet >= 2 {
		return nil
	}
	return rewriteKittyReplayCommand(seq, false)
}

// kittyCommandControl locates the keys of seq, a whole graphics command
// introduced by ESC _ G or the 8-bit APC 0x9f G and ended by ESC \ or the
// 8-bit ST 0x9c, as the replay scanner reads one: they run from start to the
// payload's ';' or the terminator.
func kittyCommandControl(seq []byte) (start, end int, ok bool) {
	switch {
	case bytes.HasPrefix(seq, []byte("\x1b_G")):
		start = 3
	case bytes.HasPrefix(seq, []byte("\x9fG")):
		start = 2
	default:
		return 0, 0, false
	}
	switch {
	case bytes.HasSuffix(seq, []byte("\x1b\\")):
		end = len(seq) - 2
	case bytes.HasSuffix(seq, []byte{0x9c}):
		end = len(seq) - 1
	default:
		return 0, 0, false
	}
	if end < start {
		return 0, 0, false
	}
	if separator := bytes.IndexByte(seq[start:end], ';'); separator >= 0 {
		end = start + separator
	}
	return start, end, true
}
