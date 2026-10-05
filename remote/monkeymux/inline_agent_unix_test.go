//go:build !windows

package main

import (
	"encoding/base64"
	"os/exec"
	"runtime"
	"slices"
	"testing"
	"time"
)

// The relaunch commands below use POSIX shell syntax. Windows reads no
// command lines, so these windows restore as a shell there.

// An upgrade restarts Hermes and OpenClaw from the command line they were
// started with, so a profile and every other flag survive. Hermes continues the
// session it last used in the window's workspace, or starts afresh.
func TestAgentWindowWithoutLaunchEntryRestartsFromItsCommandLine(t *testing.T) {
	hermes := []string{"/home/demo/.hermes/venv/bin/python3", "/home/demo/.local/bin/hermes", "-p", "alfred"}
	for _, tc := range []struct {
		name    string
		tool    string
		argv    []string
		command string
	}{
		{
			name:    "hermes",
			tool:    "hermes",
			argv:    hermes,
			command: "'/home/demo/.hermes/venv/bin/python3' '/home/demo/.local/bin/hermes' '-p' 'alfred' --continue || '/home/demo/.hermes/venv/bin/python3' '/home/demo/.local/bin/hermes' '-p' 'alfred'",
		},
		{
			name:    "hermes resuming a session",
			tool:    "hermes",
			argv:    append(append([]string(nil), hermes...), "--resume", "20250305_091523_a1b2c3"),
			command: "'/home/demo/.hermes/venv/bin/python3' '/home/demo/.local/bin/hermes' '-p' 'alfred' '--resume' '20250305_091523_a1b2c3'",
		},
		{
			name:    "openclaw",
			tool:    "openclaw",
			argv:    []string{"openclaw", "tui", "--session", "main"},
			command: "'openclaw' 'tui' '--session' 'main'",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := restoreWindowState{
				Name: tc.tool, Cwd: "/home/demo/project", CurrentCommand: tc.tool,
				AgentTool: tc.tool, AgentToolConfirmed: true, CommandLine: tc.argv,
				HistoryBase64: base64.StdEncoding.EncodeToString([]byte("agent screen")),
			}
			options := createWindowOptionsForRestore(state, true)
			if options.command != tc.command {
				t.Fatalf("command = %q\nwant      %q", options.command, tc.command)
			}
			if options.agentTool != tc.tool || options.cwd != "/home/demo/project" {
				t.Fatalf("restored as tool %q in %q", options.agentTool, options.cwd)
			}
			if len(options.history) != 0 {
				t.Fatal("TUI history replayed under a relaunched agent")
			}
		})
	}
}

// The command line is read from the agent's process while the outgoing helper
// still runs it, only for agents without a launch entry, and only when that
// process is still the agent.
func TestRestoreRecordsCommandLinesOfAgentsWithoutLaunchEntry(t *testing.T) {
	original := processCommandLineForRestore
	t.Cleanup(func() { processCommandLineForRestore = original })
	processes := map[int][]string{
		10: {"/venv/bin/python3", "/home/demo/.local/bin/hermes", "-p", "alfred"},
		11: {"-zsh"},
		12: {"claude", "--resume", "abc"},
		// OpenClaw renamed its process; its arguments are gone.
		13: {"openclaw", "", "", ""},
	}
	processCommandLineForRestore = func(pid int) []string { return processes[pid] }
	restore := &serverRestore{Windows: []restoreWindowState{
		{ID: "@1", AgentTool: "hermes", AgentToolConfirmed: true, CurrentCommand: "hermes", PanePid: 10},
		// The agent has exited and the shell is back in the foreground.
		{ID: "@2", AgentTool: "hermes", AgentToolConfirmed: true, CurrentCommand: "hermes", PanePid: 11},
		// Claude restarts from its launch entry and session id instead.
		{ID: "@3", AgentTool: "claude", AgentToolConfirmed: true, CurrentCommand: "claude", PanePid: 12},
		{ID: "@4", AgentTool: "openclaw", AgentToolConfirmed: true, CurrentCommand: "openclaw", PanePid: 13},
	}}
	enrichRestoreWithAgentCommandLines(restore)
	if got := restore.Windows[0].CommandLine; len(got) != 4 || got[3] != "alfred" {
		t.Fatalf("hermes command line = %q", got)
	}
	if got := restore.Windows[1].CommandLine; got != nil {
		t.Fatalf("recorded a shell as the agent: %q", got)
	}
	if got := restore.Windows[2].CommandLine; got != nil {
		t.Fatalf("recorded a command line for an agent with a launch entry: %q", got)
	}
	if got := restore.Windows[3].CommandLine; got != nil {
		t.Fatalf("recorded a process title as a command line: %q", got)
	}
	if options := createWindowOptionsForRestore(restore.Windows[3], true); options.command != "" {
		t.Fatalf("relaunched openclaw from its process title: %q", options.command)
	}
}

func TestProcessTitleOnly(t *testing.T) {
	for _, tc := range []struct {
		argv  []string
		title bool
	}{
		{nil, true},
		{[]string{"openclaw"}, true},
		{[]string{"openclaw", "", ""}, true},
		{[]string{"openclaw", "tui"}, false},
		{[]string{"/usr/local/bin/openclaw"}, false},
		{[]string{"/venv/bin/python3", "/home/demo/.local/bin/hermes"}, false},
	} {
		if got := processTitleOnly(tc.argv); got != tc.title {
			t.Errorf("processTitleOnly(%q) = %v, want %v", tc.argv, got, tc.title)
		}
	}
}

// The command line comes back with its argument boundaries, so an argument
// with spaces or an empty one is passed on unchanged.
func TestProcessCommandLineKeepsArgumentBoundaries(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("argv is not read on " + runtime.GOOS)
	}
	// The shell stays in the foreground: a lone command would replace it.
	cmd := exec.Command("/bin/sh", "-c", "sleep 30; exit 0", "two words", "", "--profile=Team Alpha")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	want := []string{"/bin/sh", "-c", "sleep 30; exit 0", "two words", "", "--profile=Team Alpha"}
	var got []string
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if got = processCommandLine(cmd.Process.Pid); slices.Equal(got, want) {
			return
		}
	}
	t.Fatalf("processCommandLine = %q, want %q", got, want)
}

// A window the app launched keeps the commands it was launched with, so an
// upgrade can start its program again: OpenClaw, whose renamed process leaves
// no arguments to read, a program the helper does not know as an agent, such
// as Grok Build, and Hermes where its command line cannot be read. The app's
// restore command continues the latest session, falling back to the launch
// command.
func TestLaunchedWindowRestartsFromItsLaunchCommand(t *testing.T) {
	history := base64.StdEncoding.EncodeToString([]byte("agent screen"))
	for _, tc := range []struct {
		name    string
		state   restoreWindowState
		command string
		tool    string
	}{
		{
			name: "openclaw",
			state: restoreWindowState{
				Name: "OpenClaw · Work", CurrentCommand: "openclaw", AgentTool: "openclaw", AgentToolConfirmed: true,
				LaunchCommand: "openclaw --profile 'work' tui",
			},
			command: "openclaw --profile 'work' tui",
			tool:    "openclaw",
		},
		{
			name: "grok",
			state: restoreWindowState{
				Name: "grok", CurrentCommand: "grok",
				LaunchCommand: "grok --yolo", RestoreCommand: "grok --yolo --resume",
			},
			command: "grok --yolo --resume || grok --yolo",
		},
		{
			name: "hermes without a command line",
			state: restoreWindowState{
				Name: "hermes", CurrentCommand: "hermes", AgentTool: "hermes", AgentToolConfirmed: true,
				LaunchCommand: "hermes --profile 'alfred'", RestoreCommand: "hermes --profile 'alfred' --continue",
			},
			command: "hermes --profile 'alfred' --continue || hermes --profile 'alfred'",
			tool:    "hermes",
		},
		{
			// What runs now beats how the window was started.
			name: "hermes command line first",
			state: restoreWindowState{
				Name: "hermes", CurrentCommand: "hermes", AgentTool: "hermes", AgentToolConfirmed: true,
				CommandLine:   []string{"/venv/bin/python3", "/home/demo/.local/bin/hermes", "-p", "other"},
				LaunchCommand: "hermes --profile 'alfred'", RestoreCommand: "hermes --profile 'alfred' --continue",
			},
			command: "'/venv/bin/python3' '/home/demo/.local/bin/hermes' '-p' 'other' --continue || '/venv/bin/python3' '/home/demo/.local/bin/hermes' '-p' 'other'",
			tool:    "hermes",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.state.Cwd = "/home/demo/project"
			tc.state.HistoryBase64 = history
			options := createWindowOptionsForRestore(tc.state, true)
			if options.command != tc.command {
				t.Fatalf("command = %q\nwant      %q", options.command, tc.command)
			}
			if options.agentTool != tc.tool || len(options.history) != 0 {
				t.Fatalf("restored as tool %q with %d history bytes", options.agentTool, len(options.history))
			}
			// The restored window keeps them for the next upgrade.
			if options.launchCommand != tc.state.LaunchCommand || options.restoreCommand != tc.state.RestoreCommand {
				t.Fatalf("carried %q / %q", options.launchCommand, options.restoreCommand)
			}
		})
	}
}

// Once the launched program is no longer in the foreground, the window
// restores as the shell it now is.
func TestLaunchedWindowRunningSomethingElseRestoresAsShell(t *testing.T) {
	history := base64.StdEncoding.EncodeToString([]byte("$ "))
	for name, state := range map[string]restoreWindowState{
		"grok exited":         {CurrentCommand: "-zsh", LaunchCommand: "grok --yolo", RestoreCommand: "grok --yolo --resume"},
		"vim instead of grok": {CurrentCommand: "vim", LaunchCommand: "grok"},
		"openclaw exited": {
			CurrentCommand: "zsh", AgentTool: "", AgentToolConfirmed: true,
			LaunchCommand: "openclaw tui",
		},
		// A failed launch leaves the agent's metadata on its recovery shell.
		"openclaw failed at launch": {
			CurrentCommand: "zsh", AgentTool: "openclaw", AgentToolConfirmed: true,
			LaunchCommand: "openclaw tui",
		},
		"a different agent": {
			CurrentCommand: "hermes", AgentTool: "hermes", AgentToolConfirmed: true,
			LaunchCommand: "openclaw tui",
		},
	} {
		t.Run(name, func(t *testing.T) {
			state.HistoryBase64 = history
			state.HistoryStartsAtGround = true
			options := createWindowOptionsForRestore(state, true)
			if options.command != "" || options.agentTool != "" {
				t.Fatalf("relaunched %q as %q", options.command, options.agentTool)
			}
			// A shell keeps its history; another program starts afresh.
			atShell := isShellCommandName(cleanProcessCommandName(state.CurrentCommand))
			if got := string(options.history); (got == "$ ") != atShell {
				t.Fatalf("history = %q with %q in the foreground", got, state.CurrentCommand)
			}
		})
	}
}

// create_window records the app's commands, and the restore snapshot the
// outgoing helper hands over carries them.
func TestCreateWindowRecordsLaunchCommandsForRestore(t *testing.T) {
	server := newMuxServer("launch-commands")
	t.Cleanup(server.close)
	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:           "create_window",
		Command:        "sleep 30",
		RestoreCommand: "sleep 31",
	})
	server.handleControlRequest(newControlClient(nil), controlMessage{Type: "create_window"})
	restore := server.restoreSnapshot()
	if len(restore.Windows) != 2 {
		t.Fatalf("windows = %d", len(restore.Windows))
	}
	if got := restore.Windows[0]; got.LaunchCommand != "sleep 30" || got.RestoreCommand != "sleep 31" {
		t.Fatalf("launched window carried %q / %q", got.LaunchCommand, got.RestoreCommand)
	}
	if got := restore.Windows[1]; got.LaunchCommand != "" || got.RestoreCommand != "" {
		t.Fatalf("shell window carried %q / %q", got.LaunchCommand, got.RestoreCommand)
	}
}
