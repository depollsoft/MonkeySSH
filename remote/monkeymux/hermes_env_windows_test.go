//go:build windows

package main

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// A pip install runs Hermes through a hermes.exe launcher in the window's
// shell, and its command line names the profile.
func TestHermesLaunchArgumentsFindsDescendant(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Skipf("cannot find the test binary: %v", err)
	}
	root := t.TempDir()
	hermes := filepath.Join(root, "hermes.exe")
	copyTestBinary(t, self, hermes)
	writeHermesTestFile(t, filepath.Join(root, "profiles", "work", ".env"), "HERMES_TUI_SCROLL_SPEED=3\n")
	t.Setenv("HERMES_HOME", root)
	t.Setenv("HERMES_MANAGED_DIR", filepath.Join(root, "no-managed-scope"))
	t.Setenv("HERMES_TUI_SCROLL_SPEED", "")
	t.Setenv("CLAUDE_CODE_SCROLL_SPEED", "")

	// The test binary plays hermes.exe (see TestMain); this process plays
	// the window's shell.
	child := exec.Command(hermes, "--tui", "-p", "work")
	child.Env = append(os.Environ(), "MONKEYMUX_TEST_STAND_IN=1")
	if err := child.Start(); err != nil {
		t.Skipf("cannot start helper process: %v", err)
	}
	t.Cleanup(func() {
		_ = child.Process.Kill()
		_ = child.Wait()
	})
	shell := os.Getpid()
	var argv []string
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		if argv = hermesLaunchArguments(shell); argv != nil || time.Now().After(deadline) {
			break
		}
	}
	if len(argv) == 0 || !slices.Equal(argv[1:], []string{"--tui", "-p", "work"}) {
		t.Fatalf("launch arguments = %q", argv)
	}
	if got := hermesScrollSpeedBase(hermesTUIEnvironmentForGroup(shell)); got != 3 {
		t.Fatalf("base speed = %v, want the work profile's 3", got)
	}
}

func copyTestBinary(t *testing.T, from, to string) {
	t.Helper()
	source, err := os.Open(from)
	if err != nil {
		t.Skipf("cannot read the test binary: %v", err)
	}
	defer source.Close()
	target, err := os.Create(to)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		target.Close()
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}
