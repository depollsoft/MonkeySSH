//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"
)

// Keep the leader reserved even on a failing test, so fallback cleanup cannot
// signal a recycled PID/PGID or race another Wait.
type rejectedReapGate struct {
	muxProcess
	reap <-chan struct{}
}

func (p rejectedReapGate) Wait() error {
	<-p.reap
	return p.muxProcess.Wait()
}

func TestRejectedWindowCleanupTerminatesProcessGroup(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("live process-group inspection requires Darwin or Linux")
	}
	for _, tc := range []struct {
		name   string
		script string
		child  bool
		exited bool
	}{
		{
			name: "hangup-ignoring-tree",
			script: `trap '' HUP
/bin/sh -c 'echo ready > "$1"; while :; do sleep 1; done' sh "$1" &
wait`,
			child: true,
		},
		{
			name: "exited-leader-with-hangup-ignoring-child",
			script: `trap '' HUP
/bin/sh -c 'echo ready > "$1"; while :; do sleep 1; done' sh "$1" &
exit 0`,
			child: true, exited: true,
		},
		{name: "fast-exit", script: "exit 0", exited: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ready := filepath.Join(t.TempDir(), "ready")
			cmd := exec.Command("/bin/sh", "-c", tc.script, "sh", ready)
			windowPty, proc, err := startWindow(cmd, 80, 24)
			if err != nil {
				t.Fatal(err)
			}
			reap := make(chan struct{})
			done := make(chan struct{})
			started := false
			reapReleased := false
			t.Cleanup(func() {
				select {
				case <-done:
					return
				default:
				}
				if !reapReleased {
					proc.Kill()
					_ = windowPty.Close()
					close(reap)
				}
				if !started {
					_ = proc.Wait()
					return
				}
				select {
				case <-done:
				case <-time.After(3 * time.Second):
					t.Error("cleanup goroutine did not finish")
				}
			})
			if tc.child {
				waitRejectedCondition(t, "HUP-ignoring child readiness", func() bool {
					_, err := os.Stat(ready)
					return err == nil
				})
				// The child inherited SIG_IGN before publishing readiness. This
				// hangup cannot win a race with installation of its disposition.
				proc.Hangup()
				if live, err := acpProviderProcessGroupHasLiveMember(cmd); err != nil || !live {
					t.Fatalf("ready group did not survive SIGHUP: live=%v, err=%v", live, err)
				}
			}
			if tc.exited {
				waitRejectedCondition(t, "unreaped leader exit", func() bool {
					snapshot := inspectProcess(proc.Pid())
					return snapshot.known && !snapshot.running && processIDAlive(proc.Pid())
				})
			}

			started = true
			go func() {
				cleanupRejectedWindow(windowPty, rejectedReapGate{muxProcess: proc, reap: reap})
				close(done)
			}()
			waitRejectedCondition(t, "forced process-group termination before reap", func() bool {
				live, err := acpProviderProcessGroupHasLiveMember(cmd)
				return err == nil && !live
			})
			// No further test signals after opening the gate. Wait owns the
			// process now and may release its PID at any time.
			reapReleased = true
			close(reap)
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("cleanup did not reap the child and return")
			}
			if !errors.Is(cmd.Process.Signal(syscall.Signal(0)), os.ErrProcessDone) {
				t.Error("child process was not reaped")
			}
			if _, err := windowPty.(*unixPty).file.Stat(); !errors.Is(err, os.ErrClosed) {
				t.Errorf("PTY descriptor was not closed: %v", err)
			}
		})
	}
}

func waitRejectedCondition(t *testing.T, description string, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ready() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
