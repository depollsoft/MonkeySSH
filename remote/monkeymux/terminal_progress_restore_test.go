package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
)

func TestRestoredProcessesDoNotInheritTerminalProgress(t *testing.T) {
	for _, tool := range []string{"pi", "codex", "claude", ""} {
		for state := 1; state <= 4; state++ {
			t.Run(fmt.Sprintf("%s/state-%d", tool, state), func(t *testing.T) {
				percentage := 42
				progress := &terminalProgressSnapshot{State: state, Percentage: &percentage}
				if state == 3 {
					progress.Percentage = nil
				}
				options := createWindowOptionsForRestore(restoreWindowState{
					Name: tool, AgentTool: tool, AgentToolConfirmed: tool != "",
					AgentSessionID: "saved-session", TerminalProgress: progress,
				}, false)
				if options.terminalProgress != nil {
					t.Fatalf("new process inherited stale progress: %#v", options.terminalProgress)
				}
				if tool == "pi" && (!strings.Contains(options.command, "saved-session") || options.agentSessionID != "saved-session") {
					t.Fatalf("Pi resume identity was lost: %#v", options)
				}
				window := &muxWindow{name: tool, terminalProgress: options.terminalProgress}
				window.observeTerminalMetadataLocked([]byte("\x1b[2J\x1b[HPi resumed idle\r\n"))
				if window.terminalProgress != nil {
					t.Fatal("idle/redraw output revived old progress")
				}
				window.observeTerminalMetadataLocked([]byte("\x1b]9;4;3\x07"))
				if window.terminalProgress == nil || window.terminalProgress.State != 3 {
					t.Fatal("fresh busy progress was not recorded")
				}
				window.observeTerminalMetadataLocked([]byte("\x1b]9;4;0\x07"))
				if window.terminalProgress != nil {
					t.Fatal("fresh progress clear was not recorded")
				}
			})
		}
	}
}

func TestNativeAcpHandoffRetainsLiveTerminalProgress(t *testing.T) {
	const bridgeID = "0123456789abcdef0123456789abcdef"
	percentage := 61
	progress := &terminalProgressSnapshot{State: 1, Percentage: &percentage}
	options := createWindowOptionsForRestore(restoreWindowState{
		Name: "Pi", AgentTool: "pi", NativeAcpBridgeID: bridgeID,
		NativeAcpProviderID: "builtin:pi-acp", TerminalProgress: progress,
	}, false)
	if options.nativeAcpBridgeID != bridgeID || options.command != "" {
		t.Fatalf("live ACP bridge was replaced with a CLI launch: %#v", options)
	}
	if options.terminalProgress == nil || options.terminalProgress.State != 1 || options.terminalProgress.Percentage == nil || *options.terminalProgress.Percentage != 61 {
		t.Fatalf("live ACP progress was lost: %#v", options.terminalProgress)
	}
	*options.terminalProgress.Percentage = 99
	if percentage != 61 {
		t.Fatal("handoff progress aliases its source snapshot")
	}
}

func TestRestoredShellHistoryDropsProgressOnly(t *testing.T) {
	for _, framing := range []struct{ name, open, close string }{
		{"esc-bel", "\x1b]", "\x07"},
		{"esc-st", "\x1b]", "\x1b\\"},
		{"c1-bel", "\x9d", "\x07"},
		{"c1-st", "\x9d", "\x9c"},
	} {
		t.Run(framing.name, func(t *testing.T) {
			prefix := "before\x1b]2;shell title\x07\x1b]9;9;/repo\x07"
			suffix := "after\x1b]8;;https://example.com\x07label\x1b]8;;\x07"
			var markers string
			for _, payload := range []string{"9;4;1;50", "9;4;2", "9; 4 ;3", "9;4;4;70", "9;4;0"} {
				markers += framing.open + payload + framing.close
			}
			history := []byte(prefix + markers + suffix)
			options := createWindowOptionsForRestore(restoreWindowState{
				Name: "shell", CurrentCommand: "sh", HistoryStartsAtGround: true,
				HistoryBase64: base64.StdEncoding.EncodeToString(history),
			}, false)
			if got, want := string(options.history), prefix+suffix; got != want {
				t.Fatalf("restored history = %q, want %q", got, want)
			}
			// A normal reconnect still belongs to the running process and must
			// preserve its progress, even though upgrade restore removes it.
			if replay := stripTerminalQueriesFromReplay(history); !bytes.Equal(replay, history) {
				t.Fatalf("normal reconnect changed progress: %q", replay)
			}
		})
	}
}

func TestRestoredShellHistoryPreservesProgressLikeTextAndControlPayloads(t *testing.T) {
	// UTF-8 continuation 0x9d must not be treated as a C1 OSC introducer, and
	// OSC-like bytes inside a DCS payload belong to that outer sequence.
	history := []byte("literal ]9;4;3 \xc4\x9d9;4;3\x07\x1bPinside\x1b]9;4;3\x07\x1b\\end")
	options := createWindowOptionsForRestore(restoreWindowState{
		Name: "shell", CurrentCommand: "sh", HistoryStartsAtGround: true,
		HistoryBase64: base64.StdEncoding.EncodeToString(history),
	}, false)
	if !bytes.Equal(options.history, history) {
		t.Fatalf("non-progress history changed: %q", options.history)
	}
}
