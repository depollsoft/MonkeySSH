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
	if !bytes.HasPrefix(seq, []byte("\x1b_G")) ||
		!bytes.HasSuffix(seq, []byte("\x1b\\")) {
		return nil
	}
	control := seq[3 : len(seq)-2]
	if separator := bytes.IndexByte(control, ';'); separator >= 0 {
		control = control[:separator]
	}
	quiet, err := strconv.Atoi(parseKittyControl(string(control))["q"])
	if err == nil && quiet >= 2 {
		return nil
	}
	return rewriteKittyReplayCommand(seq, false)
}
