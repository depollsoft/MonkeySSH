package main

import (
	"strings"
	"testing"
)

func TestParseAttachKeyEventLegacyBytes(t *testing.T) {
	for _, test := range []struct {
		name   string
		input  string
		length int
		want   byte
	}{
		{"kitty ctrl-b", "\x1b[98;5u", 7, 0x02},
		{"kitty ctrl-b press event", "\x1b[98;5:1u", 9, 0x02},
		{"kitty ctrl-b repeat event", "\x1b[98;5:2u", 9, 0x02},
		{"kitty ctrl-b with caps lock", "\x1b[98;69u", 8, 0x02},
		{"kitty ctrl-b with num lock", "\x1b[98;133u", 9, 0x02},
		{"kitty ctrl-b alternate keys", "\x1b[98:66;5u", 10, 0x02},
		{"modifyOtherKeys ctrl-b", "\x1b[27;5;98~", 10, 0x02},
		{"modifyOtherKeys ctrl-B", "\x1b[27;5;66~", 10, 0x02},
		{"kitty plain d", "\x1b[100u", 6, 'd'},
		{"kitty shifted alternate ampersand", "\x1b[55:38;2u", 10, '&'},
		{"kitty associated text ampersand", "\x1b[55;2;38u", 10, '&'},
		{"kitty shift letter", "\x1b[100;2u", 8, 'D'},
		{"modifyOtherKeys shifted ampersand", "\x1b[27;2;38~", 10, '&'},
		{"kitty escape", "\x1b[27u", 5, 0x1b},
		{"kitty digit with trailing input", "\x1b[50ud", 5, '2'},
	} {
		t.Run(test.name, func(t *testing.T) {
			event, length, ok := parseAttachKeyEvent([]byte(test.input))
			if !ok || length != test.length {
				t.Fatalf("parse = %+v, %d, %v; want length %d", event, length, ok, test.length)
			}
			got, ok := event.legacyByte()
			if !ok || got != test.want {
				t.Fatalf("legacy byte = %q, %v; want %q", got, ok, test.want)
			}
		})
	}
}

func TestParseAttachKeyEventRejectsOtherSequences(t *testing.T) {
	for _, input := range []string{
		"\x1b[A",       // arrow key
		"\x1b[1;5A",    // modified arrow key
		"\x1b[3~",      // delete
		"\x1b[3;5~",    // ctrl-delete
		"\x1b[200~",    // bracketed paste start
		"\x1b[?5u",     // kitty flags report
		"\x1b[<0;1;2M", // SGR mouse
		"\x1b[98;5",    // incomplete
		"\x1b[;5u",     // missing key code
		"\x1b[98;0u",   // invalid modifiers
		"\x1b[98;5:4u", // invalid event type
		"\x02",
	} {
		if event, length, ok := parseAttachKeyEvent([]byte(input)); ok {
			t.Fatalf("parse(%q) = %+v, %d; want no key event", input, event, length)
		}
	}
}

func TestAttachKeyEventLegacyByteRejectsUnmappedKeys(t *testing.T) {
	for _, input := range []string{
		"\x1b[98;3u",    // alt-b
		"\x1b[98;7u",    // ctrl-alt-b
		"\x1b[55;2u",    // shift-7 without alternate key or text
		"\x1b[233u",     // é
		"\x1b[57376u",   // F13
		"\x1b[49;5u",    // ctrl-1
		"\x1b[27;3;98~", // modifyOtherKeys alt-b
	} {
		event, _, ok := parseAttachKeyEvent([]byte(input))
		if !ok {
			t.Fatalf("parse(%q) failed", input)
		}
		if got, ok := event.legacyByte(); ok {
			t.Fatalf("legacy byte for %q = %q; want none", input, got)
		}
	}
}

func TestAttachModeTrackerResetsModesPanesLeftOn(t *testing.T) {
	var output strings.Builder
	tracker := newAttachModeTracker(&output)
	stream := "plain\x1b[>5u\x1b[>4;2m\x1b[?1000;1006h\x1b[?2004h\x1b[?1h" +
		"\x1b[?25l\x1b]0;title\x07\x1b[?2004l\x1b[1;31mtext"
	// Feed the stream a byte at a time so every sequence straddles writes.
	for i := range len(stream) {
		if _, err := tracker.Write([]byte{stream[i]}); err != nil {
			t.Fatal(err)
		}
	}
	if output.String() != stream {
		t.Fatalf("tracker output = %q, want passthrough %q", output.String(), stream)
	}
	want := "\x1b[<99u\x1b[=0;1u\x1b[>4;0m\x1b[?1000l\x1b[?1006l\x1b[?1l\x1b[?25h"
	if got := string(tracker.resetSequence()); got != want {
		t.Fatalf("reset = %q, want %q", got, want)
	}
}

func TestAttachModeTrackerLeavesUntouchedTerminalAlone(t *testing.T) {
	var output strings.Builder
	tracker := newAttachModeTracker(&output)
	for _, chunk := range []string{
		"shell prompt $ ",
		"\x1b[?1000h\x1b[?1000l\x1b[?25l\x1b[?25h",
		"\x1b[>4;2m\x1b[>4;0m\x1b[>4;1m\x1b[>4m",
		"\x1b[<u\x1b[?u\x1b[s\x1b[u\x1b[4h",
	} {
		if _, err := tracker.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	if got := tracker.resetSequence(); len(got) != 0 {
		t.Fatalf("reset = %q, want none", got)
	}
}

func TestAttachModeTrackerResetsBothKittyScreens(t *testing.T) {
	for _, test := range []struct {
		name   string
		stream string
		want   string
	}{
		{
			name:   "detached on the main screen",
			stream: "\x1b[>5u\x1b[?1049h\x1b[>1u\x1b[?1049l",
			want: kittyKeyboardResetSequence +
				"\x1b[?1049h" + kittyKeyboardResetSequence + "\x1b[?1049l",
		},
		{
			// A full-screen app was active: leave its screen so the shell
			// prints on the main screen again, resetting both stacks.
			name:   "detached on the alternate screen",
			stream: "\x1b[>5u\x1b[?1049h\x1b[>1u",
			want: kittyKeyboardResetSequence + "\x1b[?1049l" +
				kittyKeyboardResetSequence,
		},
		{
			name:   "alternate screen without keyboard modes",
			stream: "\x1b[?1049hvim",
			want:   "\x1b[?1049l",
		},
		{
			name:   "terminal reset by RIS",
			stream: "\x1b[>5u\x1b[?1000h\x1b[?1049h\x1bcplain",
			want:   "",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output strings.Builder
			tracker := newAttachModeTracker(&output)
			if _, err := tracker.Write([]byte(test.stream)); err != nil {
				t.Fatal(err)
			}
			if got := string(tracker.resetSequence()); got != test.want {
				t.Fatalf("reset = %q, want %q", got, test.want)
			}
		})
	}
}
