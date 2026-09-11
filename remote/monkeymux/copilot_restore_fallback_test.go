package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// writeCopilotSession creates a fake ~/.copilot/session-state/<id> dir with a
// session.start events log recording cwd and, optionally, an inuse.<pid>.lock.
// The events log mtime (session recency) and the lock mtime are set to modTime.
func writeCopilotSession(
	t *testing.T,
	stateDir string,
	id string,
	cwd string,
	lockPid int,
	modTime time.Time,
) {
	t.Helper()
	dir := filepath.Join(stateDir, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Marshal rather than concatenate: a Windows cwd such as
	// C:\Users\...\project is full of backslashes that would otherwise become
	// invalid JSON escapes, so the events log would not parse at all.
	event := map[string]any{
		"type": "session.start",
		"data": map[string]any{
			"sessionId": id,
			"context":   map[string]any{"cwd": cwd},
		},
	}
	encoded, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	events := string(encoded) + "\n"
	eventsPath := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(eventsPath, []byte(events), 0o600); err != nil {
		t.Fatal(err)
	}
	if !modTime.IsZero() {
		if err := os.Chtimes(eventsPath, modTime, modTime); err != nil {
			t.Fatal(err)
		}
	}
	if lockPid > 0 {
		lock := filepath.Join(dir, "inuse."+strconv.Itoa(lockPid)+".lock")
		if err := os.WriteFile(lock, []byte(strconv.Itoa(lockPid)), 0o644); err != nil {
			t.Fatal(err)
		}
		if !modTime.IsZero() {
			if err := os.Chtimes(lock, modTime, modTime); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// TestDiscoverCopilotSessionIDsPrefersFreshSessionOnStaleLock reproduces the
// stale-lock overwrite: a stale inuse lock whose PID was reused by a live
// copilot must not shadow the live session just because its dir name sorts
// later. Discovery keeps the freshest (most recently locked) session for a
// pane.
func TestDiscoverCopilotSessionIDsPrefersFreshSessionOnStaleLock(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() { processStartedAtForMetadata = originalProcessStart })
	home := t.TempDir()
	setTestHomeDir(t, home)
	stateDir := filepath.Join(home, ".copilot", "session-state")

	now := time.Now()
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	// The live session was locked seconds ago; the stale dir (whose lock PID
	// 201 was reused) was locked long ago but sorts AFTER the live one.
	writeCopilotSession(t, stateDir, "aaa-live", "/work", 201, now)
	writeCopilotSession(t, stateDir, "zzz-stale", "/work", 201, now.Add(-72*time.Hour))

	processes := map[int]processInfo{
		200: {pid: 200, ppid: 1, comm: "copilot", args: "copilot"},
		201: {pid: 201, ppid: 200, comm: "copilot", args: "/opt/copilot"},
	}
	got := discoverCopilotSessionIDs(processes, map[int]struct{}{200: {}})
	if got[200] != "aaa-live" {
		t.Fatalf("pane 200 -> %q, want fresh session aaa-live (not the stale-lock dir)", got[200])
	}
}

// TestEnrichRestoreCopilotFallsBackToCwd covers the core regression: when the
// live process table no longer maps a restored copilot window to its session
// (here: an empty process table, as after a slow ps or a reaped process), the
// window still resumes the most recent copilot session recorded for its cwd
// instead of relaunching blank.
func TestEnrichRestoreCopilotFallsBackToCwd(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	originalProcessTable := processTableForMetadata
	t.Cleanup(func() {
		processStartedAtForMetadata = originalProcessStart
		processTableForMetadata = originalProcessTable
	})
	home := t.TempDir()
	setTestHomeDir(t, home)
	stateDir := filepath.Join(home, ".copilot", "session-state")
	project := filepath.Join(home, "project")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			200: {pid: 200, ppid: 1, comm: "cmd.exe", args: "cmd.exe"},
			201: {pid: 201, ppid: 200, comm: "copilot", args: "copilot"},
		}
	}
	writeCopilotSession(t, stateDir, "old-session", project, 0, now.Add(-48*time.Hour))
	writeCopilotSession(t, stateDir, "recent-session", project, 0, now)
	writeCopilotSession(t, stateDir, "other-dir", filepath.Join(home, "elsewhere"), 0, now)

	restore := &serverRestore{
		Windows: []restoreWindowState{
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project, PanePid: 200},
		},
	}
	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "recent-session" {
		t.Fatalf("session id = %q, want most-recent session for cwd (recent-session)", got)
	}
	options := createWindowOptionsForRestore(restore.Windows[0], false)
	want := agentResumeCommandWithFreshFallback(
		monkeyMuxAgentLaunchCommand(agentResumeCommand("copilot", "recent-session", false)),
		monkeyMuxAgentLaunchCommand(agentLaunchCommand("copilot", false)),
	)
	if options.command != want {
		t.Fatalf("command = %q, want %q", options.command, want)
	}
}

// TestAssignCopilotSessionsByWorkingDirectoryDedups verifies two copilot
// windows sharing a directory receive distinct sessions (most recent first) and
// that a session already claimed elsewhere is never reused.
func TestAssignCopilotSessionsByWorkingDirectoryDedups(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() { processStartedAtForMetadata = originalProcessStart })
	home := t.TempDir()
	setTestHomeDir(t, home)
	stateDir := filepath.Join(home, ".copilot", "session-state")
	project := filepath.Join(home, "shared")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	processStartedAtForMetadata = func(pid int) time.Time {
		switch pid {
		case 201:
			return now.Add(-10 * time.Minute)
		case 202:
			return now.Add(-3 * time.Hour)
		default:
			return time.Time{}
		}
	}
	writeCopilotSession(t, stateDir, "sess-newest", project, 0, now)
	writeCopilotSession(t, stateDir, "sess-middle", project, 0, now.Add(-time.Hour))
	writeCopilotSession(t, stateDir, "sess-oldest", project, 0, now.Add(-2*time.Hour))

	restore := &serverRestore{
		Windows: []restoreWindowState{
			// Already resolved by the process table — must be left untouched and
			// not reused for the other windows.
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project, AgentSessionID: "sess-middle"},
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project, PanePid: 201, LastActivityEpochSeconds: now.Unix()},
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project, PanePid: 202, LastActivityEpochSeconds: now.Add(-2 * time.Hour).Unix()},
		},
	}
	processes := map[int]processInfo{
		201: {pid: 201, ppid: 1, comm: "copilot", args: "copilot"},
		202: {pid: 202, ppid: 1, comm: "copilot", args: "copilot"},
	}
	processTableForMetadata = func() map[int]processInfo { return processes }
	assignCopilotSessionsByWorkingDirectory(
		restore,
		processes,
		map[int]struct{}{201: {}, 202: {}},
	)

	if restore.Windows[0].AgentSessionID != "sess-middle" {
		t.Fatalf("window 0 changed to %q, want untouched sess-middle", restore.Windows[0].AgentSessionID)
	}
	if restore.Windows[1].AgentSessionID != "sess-newest" {
		t.Fatalf("window 1 = %q, want sess-newest", restore.Windows[1].AgentSessionID)
	}
	if restore.Windows[2].AgentSessionID != "sess-oldest" {
		t.Fatalf("window 2 = %q, want sess-oldest (sess-middle already used)", restore.Windows[2].AgentSessionID)
	}
}

// TestAssignCopilotSessionsByWorkingDirectoryNormalizesPaths confirms a window
// cwd and a session cwd match through ~ expansion and symlink resolution.

func TestCopilotActivityAssignmentsRejectPartialOverlap(t *testing.T) {
	now := time.Now()
	a := copilotSessionEntry{id: "a", updatedAt: now}
	b := copilotSessionEntry{id: "b", updatedAt: now.Add(10 * time.Second)}
	got := uniqueCopilotSessionAssignments(map[int][]copilotSessionEntry{
		0: {a},
		1: {a, b},
	})
	if len(got) != 0 {
		t.Fatalf("partial-overlap Copilot assignments = %#v, want none", got)
	}
}

func TestCopilotCwdFallbackDoesNotResumeSessionFromBeforeFreshProcess(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() { processStartedAtForMetadata = originalProcessStart })
	home := t.TempDir()
	setTestHomeDir(t, home)
	project := filepath.Join(home, "project")
	stateDir := filepath.Join(home, ".copilot", "session-state")
	processStarted := time.Now().UTC().Truncate(time.Second)
	writeCopilotSession(t, stateDir, "stale-session", project, 0, processStarted.Add(-time.Hour))
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return processStarted
		}
		return time.Time{}
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		Name: "Copilot CLI", AgentTool: "copilot", Cwd: project, PanePid: 200,
	}}}

	assignCopilotSessionsByWorkingDirectory(
		restore,
		map[int]processInfo{200: {pid: 200, ppid: 1, comm: "copilot", args: "copilot"}},
		map[int]struct{}{200: {}},
	)

	if got := restore.Windows[0].AgentSessionID; got != "" {
		t.Fatalf("fresh Copilot process inherited stale session %q", got)
	}
}

func TestAssignCopilotSessionsByWorkingDirectoryNormalizesPaths(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() { processStartedAtForMetadata = originalProcessStart })
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return time.Now().Add(-time.Minute)
		}
		return time.Time{}
	}
	home := t.TempDir()
	setTestHomeDir(t, home)
	stateDir := filepath.Join(home, ".copilot", "session-state")

	realDir := filepath.Join(home, "real-project")
	if err := os.MkdirAll(realDir, 0o755); err != nil {
		t.Fatal(err)
	}
	linkDir := filepath.Join(home, "linked-project")
	if err := os.Symlink(realDir, linkDir); err != nil {
		t.Skipf("symlinks unsupported: %v", err)
	}
	// Session recorded under the real path; window remembers the symlinked path.
	writeCopilotSession(t, stateDir, "linked-session", realDir, 0, time.Now())

	restore := &serverRestore{
		Windows: []restoreWindowState{
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: linkDir, PanePid: 200},
		},
	}
	processes := map[int]processInfo{200: {pid: 200, ppid: 1, comm: "copilot", args: "copilot"}}
	processTableForMetadata = func() map[int]processInfo { return processes }
	assignCopilotSessionsByWorkingDirectory(
		restore,
		processes,
		map[int]struct{}{200: {}},
	)
	if got := restore.Windows[0].AgentSessionID; got != "linked-session" {
		t.Fatalf("session id = %q, want linked-session via symlink normalization", got)
	}
}
