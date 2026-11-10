package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// Runs on Windows too: bridges hosted in the MonkeyMux server are probed from
// that same process, so a second handle there must see the lock as held.
func TestAcpBridgeLifetimeLockLifecycle(t *testing.T) {
	dir := t.TempDir()
	socket := filepath.Join(dir, "monkeymux-acp-0123456789abcdef0123456789abcdef.sock")
	if got := probeAcpBridgeLifetime(socket); got != acpBridgeLifetimeAbsent {
		t.Fatalf("before hold = %v, want absent", got)
	}
	release := holdAcpBridgeLifetime(socket)
	if got := probeAcpBridgeLifetime(socket); got != acpBridgeLifetimeHeld {
		release()
		t.Fatalf("while held = %v, want held", got)
	}
	release()
	if got := probeAcpBridgeLifetime(socket); got != acpBridgeLifetimeAbsent {
		t.Fatalf("after release = %v, want absent", got)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		t.Fatalf("hold left %s behind", entry.Name())
	}

	// What a crashed bridge leaves: the file, with nobody holding its lock.
	if err := os.WriteFile(acpBridgeLifetimePath(socket), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := probeAcpBridgeLifetime(socket); got != acpBridgeLifetimeFree {
		t.Fatalf("crash residue = %v, want free", got)
	}
}

// `monkeymux gc` deletes staging files past a fixed age without asking who
// holds them. A bridge that stalls before renaming its staging file into place
// must publish a fresh one rather than run without a lifetime.
func TestAcpBridgeLifetimeSurvivesGCDeletingItsStagingFile(t *testing.T) {
	previousHook := beforeAcpBridgeLifetimeRename
	t.Cleanup(func() { beforeAcpBridgeLifetimeRename = previousHook })
	deletions := 0
	beforeAcpBridgeLifetimeRename = func(staging string) {
		if deletions == 0 {
			if err := os.Remove(staging); err != nil {
				t.Errorf("remove staging: %v", err)
			}
		}
		deletions++
	}

	socket := filepath.Join(t.TempDir(), "monkeymux-acp-fedcba9876543210fedcba9876543210.sock")
	release := holdAcpBridgeLifetime(socket)
	defer release()
	if deletions != 2 {
		t.Fatalf("publish attempts = %d, want a second after the staging file vanished", deletions)
	}
	if got := probeAcpBridgeLifetime(socket); got != acpBridgeLifetimeHeld {
		t.Fatalf("lifetime after a lost staging file = %v, want held", got)
	}
}

// A lifetime file that existed unlocked while its bridge started could be
// judged free and deleted by a concurrent gc, leaving the bridge locking a
// file nobody can see. A probe racing the hold must only ever find the file
// absent or held.
func TestAcpBridgeLifetimeIsNeverVisibleUnlockedWhileHeld(t *testing.T) {
	dir := t.TempDir()
	const rounds = 300
	var phase atomic.Int32 // 0 idle, 1 holding, 2 releasing
	var current atomic.Value
	current.Store("")
	stop := make(chan struct{})
	var violations atomic.Int32
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			socket, _ := current.Load().(string)
			if socket == "" {
				continue
			}
			before := phase.Load()
			state := probeAcpBridgeLifetime(socket)
			if state == acpBridgeLifetimeFree && before == 1 && phase.Load() == 1 &&
				current.Load().(string) == socket {
				violations.Add(1)
			}
		}
	}()
	for round := range rounds {
		// Bridge IDs never repeat, and Windows keeps a deleted name busy while
		// a probe still has it open, so every round uses its own name.
		socket := filepath.Join(dir, fmt.Sprintf("monkeymux-acp-%032x.sock", round))
		current.Store(socket)
		phase.Store(1)
		release := holdAcpBridgeLifetime(socket)
		if got := probeAcpBridgeLifetime(socket); got != acpBridgeLifetimeHeld {
			t.Errorf("round %d: hold not visible as held: %v", round, got)
		}
		phase.Store(2)
		release()
		phase.Store(0)
	}
	close(stop)
	wg.Wait()
	if n := violations.Load(); n != 0 {
		t.Fatalf("a probe found a held lifetime file unlocked %d times", n)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".staging") {
			t.Fatalf("hold left staging file %s", entry.Name())
		}
	}
}
