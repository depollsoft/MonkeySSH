//go:build !windows

package main

import (
	"os/exec"
	"testing"
)

func TestUnixProcessWaitOnlyReapsAfterObservedExit(t *testing.T) {
	for _, observed := range []bool{false, true} {
		t.Run(map[bool]string{false: "observer failed", true: "exit observed"}[observed], func(t *testing.T) {
			cmd := exec.Command("sh", "-c", "exit 0")
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
			process := &unixProcess{cmd: cmd}
			called := false
			err := process.waitWithExitObserver(func(pid int) bool {
				called = true
				if pid != cmd.Process.Pid {
					t.Fatalf("observed PID = %d, want %d", pid, cmd.Process.Pid)
				}
				return observed
			})
			if err != nil || cmd.ProcessState == nil || !cmd.ProcessState.Success() {
				t.Fatalf("Wait = %v, state = %v; child must be reaped after either observer outcome", err, cmd.ProcessState)
			}
			if called != supportsWindowExitObservation {
				t.Fatalf("observer called = %v, supported = %v", called, supportsWindowExitObservation)
			}
			if want := observed && supportsWindowExitObservation; process.reaping != want {
				t.Fatalf("reaping = %v, want %v", process.reaping, want)
			}
		})
	}
}
