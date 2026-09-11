//go:build !windows

package main

import (
	"testing"
	"time"
)

// Same scenario as TestCloseKillsForegroundGroupThatIgnoresHangup, but through
// the real server: a window created with the production starter and closed
// through muxServer.close, which is what a helper replacement runs.
func TestServerCloseKillsForegroundGroupThatIgnoresHangup(t *testing.T) {
	server := newMuxServer("shutdown-fg-group")
	window, err := server.createWindowWithStarter(
		createWindowOptions{args: []string{"/bin/sh", "-c", `set -m; trap "" HUP; sleep 30`}},
		startWindow,
	)
	if err != nil {
		t.Fatal(err)
	}
	shell := window.proc.Pid()
	var group int
	for start := time.Now(); time.Since(start) < 3*time.Second; time.Sleep(20 * time.Millisecond) {
		server.mu.Lock()
		group = foregroundProcessGroupForWindow(window)
		server.mu.Unlock()
		if group > 0 && group != shell {
			break
		}
	}
	if group <= 0 || group == shell {
		t.Fatalf("job did not become its own foreground group (group %d, shell %d)", group, shell)
	}
	t.Cleanup(func() { killProcessGroup(group) })
	time.Sleep(100 * time.Millisecond)

	start := time.Now()
	server.close()
	elapsed := time.Since(start)
	deadline := time.Now().Add(2 * time.Second)
	for processIDAlive(group) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if processIDAlive(group) {
		t.Fatalf("foreground job %d survived server close", group)
	}
	if elapsed > 1800*time.Millisecond {
		t.Fatalf("server close took %v, want under the replacement's exit wait", elapsed)
	}
}
