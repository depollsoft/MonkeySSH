//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// A pane's interactive shell runs its jobs under job control, so the agent
// sits in its own process group as the terminal's foreground group. An agent
// that ignores SIGHUP (cursor-agent does) then survives both the terminal
// hangup and a kill of the shell's group, its watcher never finishes, close
// runs out its whole bound, and the replacement helper's exit wait times out:
// no helper update can ever replace the server (seen live during a forced
// reload). Shutdown must kill the foreground group too.
func TestCloseKillsForegroundGroupThatIgnoresHangup(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", `set -m; trap "" HUP; sleep 30`)
	windowPty, proc, err := startWindow(cmd, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	window := &muxWindow{proc: proc, pty: windowPty}
	t.Cleanup(func() {
		if group := foregroundProcessGroupForWindow(window); group > 0 {
			killProcessGroup(group)
		}
		proc.Kill()
		_ = windowPty.Close()
	})
	// Mirror the server: one goroutine reads the pty, another reaps the child.
	go func() {
		buf := make([]byte, 1024)
		for {
			if _, err := windowPty.Read(buf); err != nil {
				return
			}
		}
	}()
	waited := make(chan struct{})
	go func() { _ = proc.Wait(); close(waited) }()
	// Let the shell install its trap and start the job in its own group.
	var group int
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(20 * time.Millisecond) {
		if group = foregroundProcessGroupForWindow(window); group > 0 && group != proc.Pid() {
			break
		}
	}
	if group <= 0 || group == proc.Pid() {
		t.Fatalf("job did not become its own foreground group (group %d, shell %d)", group, proc.Pid())
	}
	time.Sleep(100 * time.Millisecond)

	start := time.Now()
	groups := shutdownForegroundGroups([]*muxWindow{window})
	proc.Hangup()
	if err := windowPty.Close(); err != nil {
		t.Fatal(err)
	}
	killSurvivingWindowProcesses([]*muxWindow{window}, groups, 300*time.Millisecond)
	select {
	case <-waited:
	case <-time.After(2 * time.Second):
		t.Fatal("shell survived hangup and kill escalation")
	}
	deadline := time.Now().Add(2 * time.Second)
	for processIDAlive(group) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if processIDAlive(group) {
		t.Fatalf("foreground job %d survived shutdown", group)
	}
	if elapsed := time.Since(start); elapsed > 1500*time.Millisecond {
		t.Fatalf("shutdown took %v, want under the exit wait budget", elapsed)
	}
}

func TestKillSurvivingWindowProcessesSkipsExitedChildren(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "exit 0")
	windowPty, proc, err := startWindow(cmd, 80, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = windowPty.Close() })
	if err := proc.Wait(); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	killSurvivingWindowProcesses([]*muxWindow{{proc: proc}, {}}, nil, time.Second)
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("waited %v for an already-exited child", elapsed)
	}
}

func TestKillSurvivingWindowProcessesAfterGroupLeaderExits(t *testing.T) {
	for _, ownGroup := range []bool{false, true} {
		t.Run(fmt.Sprint("own-group-", ownGroup), func(t *testing.T) {
			ready := filepath.Join(t.TempDir(), "ready")
			cmd := exec.Command("/bin/sh", "-c", `(trap "" HUP; echo ready > "$1"; exec sleep 30) &
while [ ! -s "$1" ]; do sleep 0.01; done`, "sh", ready)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			group := cmd.Process.Pid
			t.Cleanup(func() { killProcessGroup(group) })
			if err := cmd.Wait(); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(ready); err != nil {
				t.Fatal(err)
			}
			if processIDAlive(group) || !processGroupAlive(group) {
				t.Fatal("expected exited group leader and a surviving group member")
			}
			_ = syscall.Kill(-group, syscall.SIGHUP)
			time.Sleep(20 * time.Millisecond)
			if !processGroupAlive(group) {
				t.Fatal("group did not survive SIGHUP")
			}
			window := &muxWindow{}
			if ownGroup {
				window.proc = &unixProcess{cmd: cmd}
			}
			killSurvivingWindowProcesses([]*muxWindow{window}, map[*muxWindow]int{window: group}, 20*time.Millisecond)
			deadline := time.Now().Add(2 * time.Second)
			for processGroupAlive(group) && time.Now().Before(deadline) {
				time.Sleep(20 * time.Millisecond)
			}
			if processGroupAlive(group) {
				t.Fatalf("group %d survived shutdown after its leader exited", group)
			}
		})
	}
}
