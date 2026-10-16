//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// Mirrors the Unix held-lock test for the Windows LockFileEx path: a lock the
// shared app-server would hold must read as held, block the resume gate, and
// release it once the lock is dropped.
func TestCodexSessionGateWaitsForHeldFileWindows(t *testing.T) {
	for _, customHome := range []bool{false, true} {
		t.Run(map[bool]string{false: "default-home", true: "custom-home"}[customHome], func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("USERPROFILE", home)
			t.Setenv("CODEX_HOME", "")
			codexHome := filepath.Join(home, ".codex")
			if customHome {
				codexHome = filepath.Join(home, "custom")
				t.Setenv("CODEX_HOME", codexHome)
			}
			path := codexSessionLockPath(codexHome, "session-id")
			if path == "" {
				t.Fatal("empty lock path")
			}
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()

			var overlapped windows.Overlapped
			handle := windows.Handle(file.Fd())
			if err := windows.LockFileEx(handle,
				windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
				0, ^uint32(0), ^uint32(0), &overlapped); err != nil {
				t.Fatalf("acquire lock: %v", err)
			}
			if !codexSessionLockHeld(path) {
				t.Fatal("held lock reported free")
			}

			done := make(chan struct{})
			go func() { waitForCodexSession("session-id"); close(done) }()
			select {
			case <-done:
				t.Fatal("gate passed a held lock")
			case <-time.After(100 * time.Millisecond):
			}

			if err := windows.UnlockFileEx(handle, 0, ^uint32(0), ^uint32(0), &overlapped); err != nil {
				t.Fatalf("release lock: %v", err)
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("gate did not notice released lock")
			}
			if codexSessionLockHeld(path) {
				t.Fatal("released lock reported held")
			}
		})
	}
}

// Codex removes a released lock file. A probe that happens to have it open
// must not turn that removal into a sharing violation.
func TestCodexSessionLockProbeSharesDeleteWindows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-id.lock")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	handle, err := openCodexSessionLockForProbe(path)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	if err := os.Remove(path); err != nil {
		t.Fatalf("remove while probed: %v", err)
	}
}

// A probe of a free lock briefly takes it. Codex must be able to take it
// again straight away.
func TestCodexSessionLockProbeReleasesFreeLockWindows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-id.lock")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if codexSessionLockHeld(path) {
		t.Fatal("free lock reported held")
	}
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var overlapped windows.Overlapped
	if err := windows.LockFileEx(windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, ^uint32(0), ^uint32(0), &overlapped); err != nil {
		t.Fatalf("lock after probe: %v", err)
	}
}
