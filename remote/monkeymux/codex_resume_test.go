package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

type codexShutdownTestProcess struct {
	muxProcess
	started chan<- time.Time
	release <-chan struct{}
}

func (p codexShutdownTestProcess) shutdownCodex(_ *muxWindow, deadline time.Time) {
	p.started <- deadline
	<-p.release
}

func TestCodexShutdownWindowsShareBudget(t *testing.T) {
	started := make(chan time.Time, 8)
	release := make(chan struct{})
	server := &muxServer{}
	for i := 0; i < cap(started); i++ {
		server.windows = append(server.windows, &muxWindow{agentTool: "codex",
			proc: codexShutdownTestProcess{started: started, release: release}})
	}
	done := make(chan struct{})
	go func() { server.close(); close(done) }()
	t.Cleanup(func() { close(release); <-done })
	var deadline time.Time
	for range cap(started) {
		select {
		case current := <-started:
			if !deadline.IsZero() && !current.Equal(deadline) {
				t.Fatal("windows got separate teardown budgets")
			}
			deadline = current
		case <-time.After(time.Second):
			t.Fatal("teardown waited for one window before starting the next")
		}
	}
}

func TestCodexResumeLockGate(t *testing.T) {
	for _, tc := range []struct {
		name       string
		clearAfter time.Duration
		want       time.Duration
	}{
		{"absent", 0, 0},
		{"released", 150 * time.Millisecond, 150 * time.Millisecond},
		{"held", time.Hour, codexResumeLockWait},
	} {
		t.Run(tc.name, func(t *testing.T) {
			start := time.Unix(0, 0)
			now := start
			waitForCodexSessionLock(func() bool { return now.Sub(start) < tc.clearAfter },
				codexResumeLockWait, func() time.Time { return now },
				func(delay time.Duration) { now = now.Add(delay) })
			if elapsed := now.Sub(start); elapsed != tc.want {
				t.Fatalf("wait = %v, want %v", elapsed, tc.want)
			}
		})
	}
}

func TestCodexSessionLockPathRejectsTraversal(t *testing.T) {
	for _, id := range []string{"", ".", "..", "../outside", `..\outside`, "C:outside", "bad\x00id"} {
		if path := codexSessionLockPath(t.TempDir(), id); path != "" {
			t.Errorf("accepted session ID %q: %q", id, path)
		}
	}
}

func TestCodexSessionLockProbeDoesNotCreateOrRemoveFiles(t *testing.T) {
	path := codexSessionLockPath(t.TempDir(), "session-id")
	if codexSessionLockHeld(path) {
		t.Fatal("absent lock reported held")
	}
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatalf("probe created lock directory: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	if codexSessionLockHeld(path) {
		t.Fatal("unlocked leftover file reported held")
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "untouched" {
		t.Fatalf("probe modified lock: %q, %v", data, err)
	}
}
