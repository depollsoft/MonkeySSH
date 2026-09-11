//go:build windows

package main

import "testing"

func TestShellExecutableCommandUsesPowerShellCallOperator(t *testing.T) {
	t.Setenv("MONKEYMUX_SHELL", "powershell.exe")
	if got, ok := shellExecutableCommand(`C:\Program Files\MonkeyMux\monkeymux.exe`); !ok || got != `& 'C:\Program Files\MonkeyMux\monkeymux.exe'` {
		t.Fatalf("PowerShell executable command = %q, %v", got, ok)
	}

	t.Setenv("MONKEYMUX_SHELL", "cmd.exe")
	if got, ok := shellExecutableCommand(`C:\Program Files\MonkeyMux\monkeymux.exe`); !ok || got != `"C:\Program Files\MonkeyMux\monkeymux.exe"` {
		t.Fatalf("cmd executable command = %q, %v", got, ok)
	}
}

func TestPiRestoreTreatsWindowsShellsAsShells(t *testing.T) {
	for _, command := range []string{"cmd.exe", "powershell.exe", "pwsh.exe"} {
		state := restoreWindowState{
			CurrentCommand: command,
			PaneTitle:      "Pi - notes",
			AgentTool:      "pi",
		}
		if got := agentToolForRestore(state); got != "" {
			t.Fatalf("Windows shell %q classified as %q", command, got)
		}
		if got := createWindowOptionsForRestore(state, false).command; got != "" {
			t.Fatalf("Windows shell %q restore command = %q", command, got)
		}
		state.AgentToolConfirmed = true
		if got := agentToolForRestore(state); got != "pi" {
			t.Fatalf("confirmed Pi behind Windows shell %q classified as %q", command, got)
		}
		if got := createWindowOptionsForRestore(state, false).command; got != piLaunchCommand("") {
			t.Fatalf("confirmed Pi behind Windows shell %q restore command = %q", command, got)
		}
	}
}

func TestAgentRestoreCommandUsesWindowsShellSyntax(t *testing.T) {
	t.Setenv("ComSpec", "cmd.exe")
	t.Setenv("MONKEYMUX_SHELL", "cmd.exe")
	if got := agentResumeCommand("claude", "session id", false); got != `claude --resume "session id"` {
		t.Fatalf("cmd resume command = %q", got)
	}
	if got := agentResumeCommandWithFreshFallback(`claude --resume "session id"`, "claude"); got != `claude --resume "session id" || claude` {
		t.Fatalf("cmd fallback command = %q", got)
	}
	if got := agentResumeCommand("claude", "session%id", false); got != "" {
		t.Fatalf("unsafe cmd resume command = %q", got)
	}

	t.Setenv("MONKEYMUX_SHELL", "powershell.exe")
	if got := agentResumeCommand("claude", "session's id", false); got != `claude --resume 'session''s id'` {
		t.Fatalf("PowerShell resume command = %q", got)
	}
	if got := agentResumeCommandWithFreshFallback("claude --resume session-id", "claude"); got != "claude --resume session-id; if (-not $?) { claude }" {
		t.Fatalf("PowerShell fallback command = %q", got)
	}
}

func TestPiRestoreCommandIsSafeForCmd(t *testing.T) {
	t.Setenv("ComSpec", "cmd.exe")
	t.Setenv("MONKEYMUX_SHELL", "cmd.exe")
	if got := piResumeCommand("session-id", "", ""); got != piLaunchCommand("")+" --session session-id" {
		t.Fatalf("ordinary resume command = %q", got)
	}
	if got := piResumeCommandWithFreshFallback("pi --session session-id", "pi"); got != "pi --session session-id || pi" {
		t.Fatalf("cmd fallback command = %q", got)
	}
	t.Setenv("MONKEYMUX_SHELL", "powershell.exe")
	if got := piResumeCommandWithFreshFallback("pi --session session-id", "pi"); got != "pi --session session-id; if (-not $?) { pi }" {
		t.Fatalf("PowerShell fallback command = %q", got)
	}
	t.Setenv("MONKEYMUX_SHELL", "cmd.exe")
	if got := piResumeCommand("session&id", "", ""); got != "" {
		t.Fatalf("metacharacter resume command = %q, want refusal", got)
	}
	if got := piResumeCommand(
		"session-id",
		`C:\Program Files\Pi Sessions`,
		`C:\Program Files\Pi Sessions\session.jsonl`,
	); got != piLaunchCommand("")+` --session "C:\Program Files\Pi Sessions\session.jsonl"` {
		t.Fatalf("path resume command = %q", got)
	}
	if got, ok := shellArgument(`C:\Program Files\Pi Sessions`); !ok || got != `"C:\Program Files\Pi Sessions"` {
		t.Fatalf("cmd path argument = %q, %v", got, ok)
	}
	if got := piResumeCommand("session-id", `C:\%TEMP%\sessions`, ""); got != "" {
		t.Fatalf("expanding cmd session directory resumed in default directory: %q", got)
	}
	if got := piResumeCommand("session-id", `C:\%TEMP%\sessions`, `C:\safe\session.jsonl`); got != piLaunchCommand("")+` --session C:\safe\session.jsonl` {
		t.Fatalf("exact session path did not take priority over invalid directory: %q", got)
	}
	if got, ok := shellArgument(`C:\%TEMP%\sessions`); ok || got != "" {
		t.Fatalf("expanding cmd path argument = %q, %v, want refusal", got, ok)
	}
}
