package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
)

func TestHermesAgentToolMapping(t *testing.T) {
	for _, name := range []string{"hermes", "hermes-agent", "/home/demo/.local/bin/hermes"} {
		if got := agentToolFromCommandName(name); got != "hermes" {
			t.Fatalf("agentToolFromCommandName(%q) = %q, want hermes", name, got)
		}
	}
	if got := agentToolFromCommandText("hermes --yolo"); got != "hermes" {
		t.Fatalf("agentToolFromCommandText(launch) = %q, want hermes", got)
	}
	// Hermes is a Python entry-point script. Linux names the process after
	// the script; macOS reports the interpreter (truncated) as comm, so the
	// script has to be found in argv.
	for _, process := range []struct{ name, comm, args string }{
		{"linux", "hermes", "/home/demo/.hermes/venv/bin/python3 /home/demo/.local/bin/hermes --yolo"},
		{"macos", "/Users/demo/.her", "/Users/demo/.hermes/venv/bin/python /Users/demo/.local/bin/hermes"},
	} {
		if got := commandNameFromProcessFields(process.comm, process.args); got != "hermes" {
			t.Fatalf("%s: commandNameFromProcessFields = %q, want hermes", process.name, got)
		}
	}
}

func TestOpenClawAgentToolMapping(t *testing.T) {
	if got := agentToolFromCommandText("openclaw tui --session main"); got != "openclaw" {
		t.Fatalf("agentToolFromCommandText(launch) = %q, want openclaw", got)
	}
	// The Node CLI renames its process, so ps shows the title, not node.
	if got := commandNameFromProcessFields("openclaw", "openclaw"); got != "openclaw" {
		t.Fatalf("commandNameFromProcessFields = %q, want openclaw", got)
	}
}

// inlineTUIHistory is the output of an agent that draws inline on the normal
// screen, such as Hermes's default prompt_toolkit REPL or OpenClaw's TUI: the
// transcript is printed into the normal screen and scrolls into the
// scrollback, while the input area under it is repainted in place with
// relative cursor moves on every status tick.
func inlineTUIHistory(width int) []byte {
	var b bytes.Buffer
	b.WriteString("\x1b[2J\x1b[H")
	for line := 1; line <= 60; line++ {
		fmt.Fprintf(&b, "transcript line %d\r\n", line)
	}
	rule := strings.Repeat("─", width)
	fmt.Fprintf(&b, "%s\r\n status 0s\r\n%s\r\n❯ ", rule, rule)
	for tick := 1; b.Len() <= 2*windowReplayLimitBytes; tick++ {
		fmt.Fprintf(&b, "\x1b[?25l\x1b[2A\r status %ds\x1b[K\r\r\n\r\r\n\x1b[2C\x1b[?25h", tick)
	}
	return b.Bytes()
}

// TestInlineAgentWindowSwitchKeepsTranscript is the regression test for
// switching back to a Hermes window, or any other inline TUI, and finding the
// transcript gone. The status ticks push the transcript out of the shell
// replay tail within a minute or two, and replaying those relative moves onto
// a cleared client paints nothing but the status line.
func TestInlineAgentWindowSwitchKeepsTranscript(t *testing.T) {
	// The last one is a program the helper does not know by name.
	for _, tool := range []string{"hermes", "openclaw", "some-inline-tui"} {
		t.Run(tool, func(t *testing.T) {
			server := newMuxServerWithSize("test", 80, 24)
			window := &muxWindow{id: "@2", index: 1, foregroundCommand: tool, foregroundPid: 42}
			window.appendHistoryLocked(inlineTUIHistory(80))
			server.windows = []*muxWindow{{id: "@1"}, window}
			server.activeID = "@1"
			primary := &recordingConn{}
			registerTestAttachClient(t, server, primary, "phone", 80, 24)
			if err := server.selectWindow(window.id); err != nil {
				t.Fatal(err)
			}
			// The app answers the resize by erasing its own rows and drawing
			// them again; it cannot repaint the transcript above them.
			rule := strings.Repeat("─", 80)
			server.handleWindowOutput(
				window.id,
				[]byte("\x1b[?25l\x1b[3A\r\x1b[J"+rule+"\r\n status redrawn\r\n"+rule+"\r\n❯ \x1b[?25h"),
			)
			server.mu.Lock()
			generation := window.redrawForwardingGeneration
			server.mu.Unlock()
			server.resumePausedAttachForwarding(window.id, generation)
			waitForTestAttachWrites(t, server)

			client := newTerminalScreen(80, 24)
			client.Write([]byte(primary.String()))
			rows := client.TextRows()
			for row := 0; row < 20; row++ {
				if want := fmt.Sprintf("transcript line %d", row+41); rows[row] != want {
					t.Fatalf("row %d = %q, want %q; screen:\n%s", row, rows[row], want, strings.Join(rows, "\n"))
				}
			}
			if rows[21] != " status redrawn" || rows[23] != "❯" {
				t.Fatalf("input area was not redrawn: %q", rows[20:])
			}
			if len(client.scrollback) == 0 || vtScrollbackText(client.scrollback[0]) != "transcript line 1" {
				t.Fatalf("scrollback lost the start of the transcript: %d lines", len(client.scrollback))
			}
		})
	}
}

// Without the command line a Hermes or OpenClaw window was started with, which
// carries flags such as --profile, a restore must not relaunch them. The window
// comes back as a plain shell and stays one, even when a snapshot from a helper
// that did not know the agent still names the window after it.
func TestUnrelaunchableAgentWindowRestoresAsConfirmedShell(t *testing.T) {
	history := base64.StdEncoding.EncodeToString([]byte("agent screen"))
	for _, tool := range []string{"hermes", "openclaw"} {
		for name, state := range map[string]restoreWindowState{
			"current snapshot": {
				Name: tool, CurrentCommand: tool, AgentTool: tool,
				AgentToolConfirmed: true, HistoryBase64: history, HistoryStartsAtGround: true,
			},
			"snapshot without agent metadata": {
				Name: tool, CurrentCommand: tool,
				HistoryBase64: history, HistoryStartsAtGround: true,
			},
		} {
			t.Run(tool+"/"+name, func(t *testing.T) {
				options := createWindowOptionsForRestore(state, true)
				if options.command != "" || options.agentTool != "" {
					t.Fatalf("restore relaunched %s: command=%q tool=%q", tool, options.command, options.agentTool)
				}
				if len(options.history) != 0 {
					t.Fatal("TUI history replayed into a new shell")
				}
				newTool, confirmed := newWindowAgentTool(options, options.name)
				if newTool != "" || !confirmed {
					t.Fatalf("restored window should be a confirmed shell, got tool=%q confirmed=%v", newTool, confirmed)
				}
				window := &muxWindow{
					name: options.name, paneTitle: options.paneTitle, command: "zsh",
					agentTool: newTool, agentToolConfirmed: confirmed,
				}
				if got := window.agentToolLocked(); got != "" {
					t.Fatalf("restored shell named %q was taken for %q", window.name, got)
				}
			})
		}
	}
}

// Where a launched window closes with its program, an open one still runs
// it, even when the process table names only the shell or a runtime; where it
// can outlive the program, a shell in the foreground means the agent is gone.
func TestLaunchedWindowWithShellForeground(t *testing.T) {
	state := restoreWindowState{
		CurrentCommand: "pwsh", AgentTool: "openclaw", AgentToolConfirmed: true,
		LaunchCommand: "openclaw tui",
	}
	options := createWindowOptionsForRestore(state, true)
	if relaunched := options.command != ""; relaunched == launchedWindowOutlivesProgram {
		t.Fatalf("relaunched %v (%q) where a launched window outlives its program: %v",
			relaunched, options.command, launchedWindowOutlivesProgram)
	}
}
