//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

func startReplacementTestPane(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("sleep", "120")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start pane: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	return cmd
}

func TestReapReplacementPaneGroupsKillsCapturedPane(t *testing.T) {
	cmd := startReplacementTestPane(t)
	pid := cmd.Process.Pid
	panes := captureReplacementPaneGroups(&serverRestore{
		Windows: []restoreWindowState{{PanePid: pid}, {PanePid: 0}, {PanePid: 99999999}},
	}, os.Getpid())
	if len(panes) != 1 || panes[pid].IsZero() {
		t.Fatalf("captured panes = %v, want only live pane %d", panes, pid)
	}
	reapReplacementPaneGroups(panes)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
		status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus)
		if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
			t.Fatalf("pane exit = %v, want SIGKILL", cmd.ProcessState)
		}
	case <-time.After(3 * time.Second):
		_ = cmd.Process.Kill()
		<-done
		t.Fatal("captured pane survived group reaping")
	}
}

func TestReapReplacementPaneGroupsSkipsMissingPIDs(t *testing.T) {
	reapReplacementPaneGroups(nil)
	reapReplacementPaneGroups(map[int]time.Time{
		0: time.Now(), -1: time.Now(), 99999999: time.Now(),
	})
}

func TestReapReplacementPaneGroupsSkipsUnconfirmedPIDs(t *testing.T) {
	cmd := startReplacementTestPane(t)
	pid := cmd.Process.Pid
	snapshot := inspectProcess(pid)
	if !snapshot.known || snapshot.started.IsZero() {
		t.Fatal("cannot inspect test pane identity")
	}
	// Model a recycled pid by presenting an older process's start time.
	reapReplacementPaneGroups(map[int]time.Time{
		pid:      snapshot.started.Add(-time.Hour),
		0:        snapshot.started,
		-1:       snapshot.started,
		99999999: snapshot.started,
	})
	reapReplacementPaneGroups(map[int]time.Time{pid: {}})
	if !processIDAlive(pid) {
		t.Fatal("reaper killed an unconfirmed pane")
	}
	// A live group leader from outside the outgoing server's process tree
	// must not become eligible merely because a stale snapshot names its pid.
	panes := captureReplacementPaneGroups(&serverRestore{
		Windows: []restoreWindowState{{PanePid: pid}},
	}, 99999999)
	if len(panes) != 0 {
		t.Fatalf("captured unrelated panes: %v", panes)
	}
}
