//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
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
	startCodexLockedResumeWatch = func(_ *muxServer, window *muxWindow, sessionID string, lockPath string) {
		mu.Lock()
		defer mu.Unlock()
		armed = append(armed, window.name+" "+sessionID+" "+lockPath)
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
	want := "resumed saved-thread " + codexSessionLockPath(codexHome, "saved-thread")
	if len(armed) != 1 || armed[0] != want {
		t.Fatalf("armed = %q, want only %q", armed, want)
	}
}

// End to end through a real restore: the shell's job control gives the resume
// its own process group, its command line names the thread, and the writer
// lock is a real flock. The fake Codex shows the locked prompt and records the
// first key it reads.
func TestRestoredCodexResumePressesRWhenTheLockFrees(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("argv is not read on " + runtime.GOOS)
	}
	isolateTestRuntime(t)
	codexHome := t.TempDir()
	t.Setenv("CODEX_HOME", codexHome)
	binDir := t.TempDir()
	marker := filepath.Join(t.TempDir(), "key")
	script := "#!/bin/sh\n" +
		"stty -icanon -echo min 1\n" +
		"printf '\\033[2J\\033[H  This conversation is open in another app  r to retry\\r\\n" +
		"      Close it there and press R to continue here.\\r\\n'\n" +
		"key=$(dd bs=1 count=1 2>/dev/null)\n" +
		"printf '%s' \"$key\" > '" + marker + "'\n" +
		"printf '\\033[2J\\033[Hresumed\\r\\n'\n" +
		"exec sleep 30\n"
	if err := os.WriteFile(filepath.Join(binDir, "codex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	server := newMuxServerWithSize("restore-codex-locked-resume-e2e", 80, 24)
	t.Cleanup(server.close)
	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows: []restoreWindowState{
			{ID: "@1", Index: 0, Name: "resumed", AgentTool: "codex", AgentSessionID: "saved-thread", Cwd: binDir, Active: true},
		},
	}
	if err := server.restoreOrCreateInitialWindow(restore, createWindowOptions{}); err != nil {
		t.Fatalf("restoreOrCreateInitialWindow: %v", err)
	}
	server.mu.Lock()
	window := server.windows[0]
	server.mu.Unlock()
	promptShown := func() bool {
		server.mu.Lock()
		defer server.mu.Unlock()
		return window.screen != nil && codexLockedPromptShown(window.screen.TextRows())
	}
	deadline := time.Now().Add(15 * time.Second)
	for !promptShown() {
		if time.Now().After(deadline) {
			t.Fatal("the fake Codex never showed the locked prompt")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Another client holds the thread for a few polls, then lets go.
	lockPath := codexSessionLockPath(codexHome, "saved-thread")
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := os.OpenFile(lockPath, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * defaultCodexLockedResumePolicy.poll)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("pressed a key while another client held the thread")
	}
	_ = lock.Close()
	_ = os.Remove(lockPath)

	for deadline = time.Now().Add(15 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		if key, err := os.ReadFile(marker); err == nil {
			if string(key) != "r" {
				t.Fatalf("Codex read %q, want r", key)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("no R press after the lock freed")
		}
	}
}
