//go:build linux

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"syscall"
	"testing"
	"time"
)

// Hermes's Python CLI loads ~/.hermes/.env and then starts the TUI as a Node
// child, so the child's environment can hold a speed the group leader's
// never did.
func TestHermesTUIEnvironmentReadsNodeChild(t *testing.T) {
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("no sleep binary")
	}
	node := filepath.Join(t.TempDir(), "node")
	if err := os.Symlink(sleep, node); err != nil {
		t.Skipf("cannot link a stand-in node: %v", err)
	}
	// The trailing command keeps sh from replacing itself with the child.
	leader := exec.Command("/bin/sh", "-c", `HERMES_TUI_SCROLL_SPEED=3 "$0" 30; :`, node)
	leader.Env = []string{"PATH=/usr/bin:/bin", "HERMES_TUI_SCROLL_SPEED=2"}
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
	for len(processGroupMembers(group)) < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("process group %d members = %v, want the leader and its child", group, processGroupMembers(group))
		}
		time.Sleep(10 * time.Millisecond)
	}
	if members := processGroupMembers(group); members[0] != group {
		t.Fatalf("members = %v, want the leader %d first", members, group)
	}
	if environment := processEnvironment(group); !slices.Contains(environment, "HERMES_TUI_SCROLL_SPEED=2") {
		t.Fatalf("leader environment = %q", environment)
	}
	if got := hermesScrollSpeedBase(hermesTUIEnvironmentForGroup(group)); got != 3 {
		t.Fatalf("base speed = %v, want the Node child's 3", got)
	}
}
