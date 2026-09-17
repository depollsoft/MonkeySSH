//go:build !windows

package main

import (
	"strings"
	"testing"
)

func TestThemeRefreshProactivelyNotifiesAndAnswersNewPalette(t *testing.T) {
	for _, modeSubscription := range []bool{false, true} {
		name := "focus-triggered query"
		if modeSubscription {
			name = "theme-notification-triggered query"
		}
		t.Run(name, func(t *testing.T) {
			window := &muxWindow{id: "@1", foregroundPid: 42}
			inputReader, server := newThemeQueryTestServer(t, window)
			server.activeID = window.id
			window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
			if modeSubscription {
				window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
			}
			for _, theme := range []struct{ mode, foreground, background string }{
				{"\x1b[?997;1n", "\x1b]10;rgb:ffff/ffff/ffff\x1b\\", "\x1b]11;rgb:0000/0000/0000\x1b\\"},
				{"\x1b[?997;2n", "\x1b]10;rgb:0000/0000/0000\x1b\\", "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"},
			} {
				// The app has not issued a new color query. The terminal initiates
				// the update with the notifications the app requested.
				if !server.sendThemeHint(theme.mode + theme.foreground + theme.background) {
					t.Fatal("theme update did not notify the foreground app")
				}
				got := readPipeUntil(t, inputReader, func(output string) bool {
					return strings.Contains(output, "\x1b[I")
				})
				want := "\x1b[O\x1b[I"
				if modeSubscription {
					want = theme.mode + want
				}
				if got != want {
					t.Fatalf("proactive notification = %q, want %q", got, want)
				}

				// A TUI reacts to the notification by querying its palette.
				// It gets the current colors, never the cached previous theme.
				server.handleWindowOutput(window.id, []byte("\x1b]10;?\x1b\\\x1b]11;?\x1b\\"))
				got = readPipeUntil(t, inputReader, func(output string) bool {
					return strings.Contains(output, theme.background)
				})
				if want = theme.foreground + theme.background; got != want {
					t.Fatalf("new palette = %q, want %q", got, want)
				}
			}
		})
	}
}
