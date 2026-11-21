//go:build !windows

package main

import (
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Where another process's environment is hidden, as it is on macOS, the
// speed comes from the .env of the profile the group leader's command line
// names.
func TestHermesTUIEnvironmentReadsProfileDotenv(t *testing.T) {
	root := t.TempDir()
	writeHermesTestFile(t, filepath.Join(root, "profiles", "work", ".env"), "HERMES_TUI_SCROLL_SPEED=3\n")
	environment := []string{
		"PATH=/usr/bin:/bin",
		"HOME=" + root,
		"HERMES_HOME=" + root,
		"HERMES_MANAGED_DIR=" + filepath.Join(root, "no-managed-scope"),
	}
	// MonkeyMux's own environment stands in for a hidden one.
	for _, entry := range environment[1:] {
		name, value, _ := strings.Cut(entry, "=")
		t.Setenv(name, value)
	}
	t.Setenv("HERMES_TUI_SCROLL_SPEED", "")
	t.Setenv("CLAUDE_CODE_SCROLL_SPEED", "")
	// sh names its extra arguments $0 and up, so the command line reads like
	// a Hermes run with -p work.
	leader := exec.Command("/bin/sh", "-c", "sleep 30; :", "hermes", "-p", "work")
	leader.Env = environment
	leader.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := leader.Start(); err != nil {
		t.Skipf("cannot start helper process: %v", err)
	}
	group := leader.Process.Pid
	t.Cleanup(func() {
		_ = syscall.Kill(-group, syscall.SIGKILL)
		_ = leader.Wait()
	})
	deadline := time.Now().Add(3 * time.Second)
	for len(processCommandLine(group)) < 4 {
		if time.Now().After(deadline) {
			t.Skip("this host cannot read the leader's command line")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := hermesScrollSpeedBase(hermesTUIEnvironmentForGroup(group)); got != 3 {
		t.Fatalf("base speed = %v, want the work profile's 3", got)
	}
}
