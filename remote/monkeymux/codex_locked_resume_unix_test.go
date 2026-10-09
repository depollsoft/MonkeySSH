//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// Restore must arm the locked-resume watcher for a Codex window it resumes by
// thread ID, and only for that window.
func TestRestoreArmsCodexLockedResumeWatch(t *testing.T) {
	isolateTestRuntime(t)
	codexHome := t.TempDir()
	t.Setenv("CODEX_HOME", codexHome)
	binDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(binDir, "codex"), []byte("#!/bin/sh\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var mu sync.Mutex
	var armed []string
	original := startCodexLockedResumeWatch
	t.Cleanup(func() { startCodexLockedResumeWatch = original })
	startCodexLockedResumeWatch = func(_ *muxServer, window *muxWindow, lockPath string) {
		mu.Lock()
		defer mu.Unlock()
		armed = append(armed, window.name+" "+lockPath)
	}

	server := newMuxServerWithSize("restore-codex-locked-resume", 80, 24)
	t.Cleanup(server.close)
	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows: []restoreWindowState{
			{ID: "@1", Index: 0, Name: "resumed", AgentTool: "codex", AgentSessionID: "saved-thread", Cwd: binDir, Active: true},
			{ID: "@2", Index: 1, Name: "fresh", AgentTool: "codex", Cwd: binDir},
			{ID: "@3", Index: 2, Name: "shell", Cwd: binDir},
		},
	}
	if err := server.restoreOrCreateInitialWindow(restore, createWindowOptions{}); err != nil {
		t.Fatalf("restoreOrCreateInitialWindow: %v", err)
	}
	if got := len(server.snapshots()); got != 3 {
		t.Fatalf("restored %d windows, want 3", got)
	}
	mu.Lock()
	defer mu.Unlock()
	want := "resumed " + codexSessionLockPath(codexHome, "saved-thread")
	if len(armed) != 1 || armed[0] != want {
		t.Fatalf("armed = %q, want only %q", armed, want)
	}
}
