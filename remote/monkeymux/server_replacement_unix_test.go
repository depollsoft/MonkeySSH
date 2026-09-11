//go:build !windows

package main

import (
	"os"
	"os/exec"
	"reflect"
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
	if len(panes) != 1 || panes[0].pid != pid || panes[0].started.IsZero() {
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
	reapReplacementPaneGroups([]replacementPaneGroup{
		{0, time.Now()}, {-1, time.Now()}, {99999999, time.Now()},
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
	reapReplacementPaneGroups([]replacementPaneGroup{
		{pid, snapshot.started.Add(-time.Hour)},
		{0, snapshot.started},
		{-1, snapshot.started},
		{99999999, snapshot.started},
	})
	reapReplacementPaneGroups([]replacementPaneGroup{{pid: pid}})
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

// Model an interactive job beneath an intermediate process and a wrapper shell
// in its own group. Fake OS operations make kill ordering and PID reuse exact.
func TestReplacementPaneGroupsWrapperOrderingAndGuards(t *testing.T) {
	const owner, wrapper, intermediate, pane = 10, 20, 25, 30
	started := time.Unix(100, 0)
	for _, tc := range []struct {
		name          string
		mutateCapture func(map[int]processInfo, map[int]processSnapshot, map[int]int)
		mutateReap    func(map[int]processSnapshot, map[int]int)
		wantCapture   []int
		wantKilled    []int
	}{
		{name: "wrapper before foreground", wantCapture: []int{wrapper, pane}, wantKilled: []int{wrapper, pane}},
		{name: "wrapper identity unknown", mutateCapture: func(_ map[int]processInfo, snapshots map[int]processSnapshot, _ map[int]int) {
			delete(snapshots, wrapper)
		}, wantCapture: []int{pane}, wantKilled: []int{pane}},
		{name: "wrapper is not group leader", mutateCapture: func(_ map[int]processInfo, _ map[int]processSnapshot, groups map[int]int) {
			groups[wrapper] = owner
		}, wantCapture: []int{pane}, wantKilled: []int{pane}},
		{name: "pane is direct child", mutateCapture: func(processes map[int]processInfo, _ map[int]processSnapshot, _ map[int]int) {
			processes[pane] = processInfo{pid: pane, ppid: owner}
		}, wantCapture: []int{pane}, wantKilled: []int{pane}},
		{name: "unknown ancestry", mutateCapture: func(processes map[int]processInfo, _ map[int]processSnapshot, _ map[int]int) {
			delete(processes, intermediate)
		}},
		{name: "cyclic ancestry", mutateCapture: func(processes map[int]processInfo, _ map[int]processSnapshot, _ map[int]int) {
			processes[wrapper] = processInfo{pid: wrapper, ppid: pane}
		}},
		{name: "recycled wrapper", mutateReap: func(snapshots map[int]processSnapshot, _ map[int]int) {
			snapshot := snapshots[wrapper]
			snapshot.started = started.Add(time.Hour)
			snapshots[wrapper] = snapshot
		}, wantCapture: []int{wrapper, pane}, wantKilled: []int{pane}},
		{name: "recycled foreground", mutateReap: func(snapshots map[int]processSnapshot, _ map[int]int) {
			snapshot := snapshots[pane]
			snapshot.started = started.Add(time.Hour)
			snapshots[pane] = snapshot
		}, wantCapture: []int{wrapper, pane}, wantKilled: []int{wrapper}},
		{name: "wrapper changed group", mutateReap: func(_ map[int]processSnapshot, groups map[int]int) {
			groups[wrapper] = owner
		}, wantCapture: []int{wrapper, pane}, wantKilled: []int{pane}},
		{name: "foreground changed group", mutateReap: func(_ map[int]processSnapshot, groups map[int]int) {
			groups[pane] = wrapper
		}, wantCapture: []int{wrapper, pane}, wantKilled: []int{wrapper}},
		{name: "wrapper gone", mutateReap: func(snapshots map[int]processSnapshot, _ map[int]int) {
			delete(snapshots, wrapper)
		}, wantCapture: []int{wrapper, pane}, wantKilled: []int{pane}},
		{name: "foreground no longer running", mutateReap: func(snapshots map[int]processSnapshot, _ map[int]int) {
			snapshot := snapshots[pane]
			snapshot.running = false
			snapshots[pane] = snapshot
		}, wantCapture: []int{wrapper, pane}, wantKilled: []int{wrapper}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			processes := map[int]processInfo{
				wrapper:      {pid: wrapper, ppid: owner},
				intermediate: {pid: intermediate, ppid: wrapper},
				pane:         {pid: pane, ppid: intermediate},
			}
			snapshots := map[int]processSnapshot{
				wrapper: {known: true, running: true, started: started},
				pane:    {known: true, running: true, started: started},
			}
			groups := map[int]int{wrapper: wrapper, pane: pane}
			var killed []int
			system := replacementPaneGroupSystem{
				alive:   func(pid int) bool { _, ok := snapshots[pid]; return ok },
				inspect: func(pid int) processSnapshot { return snapshots[pid] },
				pgid:    func(pid int) (int, error) { return groups[pid], nil },
				kill: func(pid int, signal syscall.Signal) error {
					if pid >= 0 || signal != syscall.SIGKILL {
						t.Fatalf("signal = (%d, %v), want group SIGKILL", pid, signal)
					}
					killed = append(killed, -pid)
					return nil
				},
			}
			if tc.mutateCapture != nil {
				tc.mutateCapture(processes, snapshots, groups)
			}
			// Duplicate windows must not cause duplicate signals.
			captured := system.capture(&serverRestore{Windows: []restoreWindowState{{PanePid: pane}, {PanePid: pane}}}, owner, processes)
			var pids []int
			for _, identity := range captured {
				pids = append(pids, identity.pid)
				if !identity.started.Equal(started) {
					t.Fatalf("lost start time: %v", identity)
				}
			}
			if !reflect.DeepEqual(pids, tc.wantCapture) {
				t.Fatalf("capture = %v, want %v", pids, tc.wantCapture)
			}
			if tc.mutateReap != nil {
				tc.mutateReap(snapshots, groups)
			}
			// The old owner is gone by this point; captured ancestry survives orphaning.
			delete(processes, wrapper)
			system.reap(captured)
			if !reflect.DeepEqual(killed, tc.wantKilled) {
				t.Fatalf("killed = %v, want %v", killed, tc.wantKilled)
			}
		})
	}
}
