package main

import (
	"fmt"
	"testing"
)

func TestThemeRefreshUsesCapabilitiesNotAgentIdentity(t *testing.T) {
	const background = "\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"
	const mode = "\x1b[?997;1n"
	for _, tool := range []string{"", "muse", "future-agent", "claude", "copilot", "codex", "opencode", "antigravity", "cursor-agent", "pi"} {
		for _, focus := range []bool{false, true} {
			for _, subscribed := range []bool{false, true} {
				for _, win32 := range []bool{false, true} {
					t.Run(fmt.Sprintf("%s/focus=%t/subscribed=%t/win32=%t", tool, focus, subscribed, win32), func(t *testing.T) {
						window := &muxWindow{agentTool: tool, agentToolConfirmed: true, foregroundPid: 42, win32InputMode: win32}
						// A startup query is not a subscription to future OSC replies.
						window.observeTerminalMetadataLocked([]byte("\x1b]11;?\x1b\\"))
						if focus {
							window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
						}
						if subscribed {
							window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
						}
						want := ""
						if subscribed {
							want = mode
						}
						if got := string(window.themeHintRefreshDataLocked([]byte(mode + background))); got != want {
							t.Fatalf("theme notification = %q, want %q", got, want)
						}
						if got := window.themeHintFocusTransitionLocked(); got != focus {
							t.Fatalf("focus transition = %t, want %t", got, focus)
						}
						window.observeTerminalModesLocked([]byte("\x1b[?1004l\x1b[?2031l"))
						if len(window.themeHintRefreshDataLocked([]byte(mode+background))) != 0 || window.themeHintFocusTransitionLocked() {
							t.Fatal("refresh ignored disabled capabilities")
						}
					})
				}
			}
		}
	}
}
