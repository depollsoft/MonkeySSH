package main

import "testing"

func TestThemeRefreshDoesNotOptInNewlyRecognizedAgents(t *testing.T) {
	const background = "\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"
	const mode = "\x1b[?997;1n"
	for _, tool := range []string{"muse", "future-agent"} {
		for _, focus := range []bool{false, true} {
			window := &muxWindow{agentTool: tool, agentToolConfirmed: true}
			// Remember a real startup query with a stable foreground identity.
			window.foregroundPid = 42
			window.observeTerminalMetadataLocked([]byte("\x1b]11;?\x1b\\"))
			if got := window.agentToolLocked(); got != tool {
				t.Fatalf("agent identity = %q, want %q", got, tool)
			}
			if focus {
				window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
			}
			if got := window.themeHintRefreshDataLocked([]byte(mode + background)); len(got) != 0 {
				t.Fatalf("%s focus=%t: unsolicited input = %q", tool, focus, got)
			}
			if got := window.themeHintFocusTransitionLocked(); got != focus {
				t.Fatalf("%s focus=%t: focus transition = %t", tool, focus, got)
			}
			// Explicit theme-update opt-in still works without an agent entry.
			window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
			if got := string(window.themeHintRefreshDataLocked([]byte(mode + background))); got != mode {
				t.Fatalf("%s focus=%t: opted-in refresh = %q, want %q", tool, focus, got, mode)
			}
		}
	}
}

func TestThemeRefreshPreservesLegacyAgentBehavior(t *testing.T) {
	const background = "\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"
	for _, tool := range []string{"claude", "copilot", "codex", "opencode", "antigravity", "cursor-agent", "pi"} {
		t.Run(tool, func(t *testing.T) {
			window := &muxWindow{foregroundCommand: tool}
			if got := window.themeHintRefreshDataLocked([]byte(background)); len(got) != 0 {
				t.Fatalf("refresh without focus mode = %q, want none", got)
			}
			window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
			if got := string(window.themeHintRefreshDataLocked([]byte(background))); got != background {
				t.Fatalf("legacy refresh = %q, want %q", got, background)
			}
			window.win32InputMode = true
			if got := window.themeHintRefreshDataLocked([]byte(background)); len(got) != 0 {
				t.Fatalf("ConPTY refresh = %q, want none", got)
			}
			// Preserve the legacy replay of observed queries under DEC 2031,
			// including when focus reporting has been disabled.
			window.win32InputMode = false
			window.foregroundPid = 42
			window.observeTerminalMetadataLocked([]byte("\x1b]4;0;?\x1b\\"))
			window.observeTerminalModesLocked([]byte("\x1b[?1004l\x1b[?2031h"))
			const palette = "\x1b]4;0;rgb:1111/2222/3333\x1b\\"
			const mode = "\x1b[?997;1n"
			if got := string(window.themeHintRefreshDataLocked([]byte(mode + background + palette))); got != mode+palette {
				t.Fatalf("legacy observed-query refresh = %q, want %q", got, mode+palette)
			}
		})
	}
}
