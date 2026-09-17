//go:build !windows

package main

import (
	"strings"
	"testing"
)

func TestMuseWindowSwitchThemeRefreshDoesNotInjectColorReplies(t *testing.T) {
	for _, command := range []string{"muse", "muse-bin-1.3.0-R3233.1"} {
		t.Run(command, func(t *testing.T) {
			window := &muxWindow{
				id: "@1", foregroundCommand: command, foregroundPid: 42,
			}
			inputReader, server := newThemeQueryTestServer(t, window)
			server.windows = append(server.windows, &muxWindow{id: "@2"})
			server.activeID = "@1"
			window.observeTerminalModesLocked([]byte("\x1b[?1004h"))

			const background = "\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"
			server.themeHint = []byte(background)
			// Muse queries colors at startup. Answering that query must not opt
			// it into unsolicited replies after later window switches.
			server.handleWindowOutput(window.id, []byte("\x1b]11;?\x1b\\"))
			got := readPipeUntil(t, inputReader, func(output string) bool {
				return strings.Contains(output, background)
			})
			if got != background {
				t.Fatalf("startup reply = %q, want %q", got, background)
			}

			for range 3 {
				if err := server.selectWindow("@2"); err != nil {
					t.Fatal(err)
				}
				if err := server.selectWindow(window.id); err != nil {
					t.Fatal(err)
				}
				// The app refreshes the theme after an active-window change.
				if !server.sendThemeHint(background) {
					t.Fatal("focus-aware Muse did not receive a focus refresh")
				}
				got = readPipeUntil(t, inputReader, func(output string) bool {
					return strings.Contains(output, "\x1b[I")
				})
				if got != "\x1b[O\x1b[I" {
					t.Fatalf("window switch input = %q, want only focus reports", got)
				}
			}

			// A real re-query must still receive the current background color.
			server.handleWindowOutput(window.id, []byte("\x1b]11;?\x1b\\"))
			got = readPipeUntil(t, inputReader, func(output string) bool {
				return strings.Contains(output, background)
			})
			if got != background {
				t.Fatalf("live reply = %q, want %q", got, background)
			}
		})
	}
}
