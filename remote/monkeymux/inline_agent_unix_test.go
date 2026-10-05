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
