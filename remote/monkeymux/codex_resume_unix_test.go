//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestCodexSessionGateWaitsForHeldFile(t *testing.T) {
	for _, customHome := range []bool{false, true} {
		t.Run(map[bool]string{false: "default-home", true: "custom-home"}[customHome], func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("CODEX_HOME", "")
			codexHome := filepath.Join(home, ".codex")
			if customHome {
				codexHome = filepath.Join(home, "custom")
				t.Setenv("CODEX_HOME", codexHome)
			}
			path := codexSessionLockPath(codexHome, "session-id")
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
				t.Fatal(err)
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
			if err := unix.Flock(int(file.Fd()), unix.LOCK_UN); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("gate did not notice released lock")
			}
		})
	}
}
