//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestReapReplacementPaneGroupsKillsWrapperBeforeFallback(t *testing.T) {
	dir := t.TempDir()
	ready := filepath.Join(dir, "ready")
	fallback := filepath.Join(dir, "fallback")
	// Interactive job control puts the foreground job in a separate group.
	// Killing only that job lets this wrapper run its fresh-launch fallback.
	resume := "/bin/sh -c " + shellQuote("echo $$ > "+shellQuote(ready)+"; exec sleep 120")
	cmd := exec.Command("/bin/sh", "-i", "-c", resume+" || echo fresh > "+shellQuote(fallback))
	windowPty, proc, err := startWindow(cmd, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-done
		_ = windowPty.Close()
	})
	var panePID int
	waitRejectedCondition(t, "foreground job readiness", func() bool {
		data, err := os.ReadFile(ready)
		if err != nil {
			return false
		}
		panePID, err = strconv.Atoi(strings.TrimSpace(string(data)))
		return err == nil && panePID > 0
	})
	if identity, ok := replacementPaneGroupsSystem().identity(panePID); ok {
		t.Cleanup(func() { reapReplacementPaneGroups([]replacementPaneGroup{identity}) })
	}
	groups := captureReplacementPaneGroups(&serverRestore{
		Windows: []restoreWindowState{{PanePid: panePID}},
	}, os.Getpid())
	if len(groups) != 2 || groups[0].pid != proc.Pid() || groups[1].pid != panePID {
		t.Fatalf("captured groups = %v, want wrapper %d then foreground %d", groups, proc.Pid(), panePID)
	}
	reapReplacementPaneGroups(groups)
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("wrapper survived group reaping")
	}
	status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("wrapper exit = %v, want SIGKILL", cmd.ProcessState)
	}
	waitRejectedCondition(t, "foreground job exit", func() bool {
		// A reaped process disappears from the table entirely, so treat an
		// unknown or dead pid as exited rather than requiring a known zombie.
		if !processIDAlive(panePID) {
			return true
		}
		snapshot := inspectProcess(panePID)
		return !snapshot.known || !snapshot.running
	})
	if _, err := os.Stat(fallback); !os.IsNotExist(err) {
		t.Fatalf("wrapper ran fresh fallback: %v", err)
	}
}
