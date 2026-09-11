//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestResolveStartupDirectoryFallsBackToNearestAncestor(t *testing.T) {
	base := t.TempDir()
	missing := filepath.Join(base, "removed", "child")

	if got := resolveStartupDirectory(base); got != base {
		t.Fatalf("resolveStartupDirectory(existing) = %q, want %q", got, base)
	}
	if got := resolveStartupDirectory(missing); got != base {
		t.Fatalf("resolveStartupDirectory(missing) = %q, want nearest ancestor %q", got, base)
	}

	// A blank request falls back to a directory that exists rather than "".
	if got := resolveStartupDirectory("  "); !directoryExists(got) {
		t.Fatalf("resolveStartupDirectory(blank) = %q, want an existing directory", got)
	}
}

// TestRestoreKeepsWindowsWithMissingCwd reproduces the "does not restore all my
// windows" regression: a restored window whose saved working directory no
// longer exists must still be recreated (falling back to an existing directory)
// instead of being silently dropped.
func TestRestoreKeepsWindowsWithMissingCwd(t *testing.T) {
	base := t.TempDir()
	missing := filepath.Join(base, "worktree-removed-after-upgrade")

	server := newMuxServerWithSize("restore-cwd", 100, 30)
	t.Cleanup(server.close)

	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows: []restoreWindowState{
			{ID: "@1", Index: 0, Name: "kept", Cwd: base, Active: true},
			{ID: "@2", Index: 1, Name: "missing", Cwd: missing},
			{ID: "@3", Index: 2, Name: "blank", Cwd: ""},
		},
	}
	if err := server.restoreOrCreateInitialWindow(restore, createWindowOptions{}); err != nil {
		t.Fatalf("restoreOrCreateInitialWindow: %v", err)
	}

	snaps := server.snapshots()
	if len(snaps) != 3 {
		t.Fatalf("restored %d windows, want 3: %+v", len(snaps), snaps)
	}

	byName := map[string]windowSnapshot{}
	for _, snap := range snaps {
		byName[snap.Name] = snap
	}
	missingWindow, ok := byName["missing"]
	if !ok {
		t.Fatalf("window with missing cwd was dropped: %+v", snaps)
	}
	if missingWindow.CurrentPath != base {
		t.Fatalf("missing-cwd window path = %q, want fallback to %q", missingWindow.CurrentPath, base)
	}
	if _, ok := byName["kept"]; !ok {
		t.Fatalf("kept window missing from restore: %+v", snaps)
	}
	if _, ok := byName["blank"]; !ok {
		t.Fatalf("blank-cwd window missing from restore: %+v", snaps)
	}
}

func withStubbedRestoreRedraw(t *testing.T) *[]func() {
	t.Helper()
	var mu sync.Mutex
	actions := &[]func(){}
	originalSchedule := scheduleRestoreRedraw
	originalSimulate := simulateForegroundResize
	originalSignal := signalForegroundResize
	originalPgrp := foregroundProcessGroupForWindow
	t.Cleanup(func() {
		scheduleRestoreRedraw = originalSchedule
		simulateForegroundResize = originalSimulate
		signalForegroundResize = originalSignal
		foregroundProcessGroupForWindow = originalPgrp
	})
	scheduleRestoreRedraw = func(_ time.Duration, action func()) {
		mu.Lock()
		*actions = append(*actions, action)
		mu.Unlock()
	}
	// Keep redraw side effects inert and off real PTYs/process groups.
	simulateForegroundResize = func(*muxWindow, int, int) {}
	signalForegroundResize = func(int) {}
	foregroundProcessGroupForWindow = func(*muxWindow) int { return 0 }
	return actions
}

// TestRestoreArmsForegroundRedrawFollowUps covers the "restored windows don't
// render until resized" regression: a restored agent window that becomes
// visible schedules follow-up redraws (so a slow-to-start agent is repainted
// without the user resizing), and each follow-up forces a redraw.
func TestRestoreArmsForegroundRedrawFollowUps(t *testing.T) {
	actions := withStubbedRestoreRedraw(t)

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(simulated, window.id)
	}

	server := newMuxServer("restore-redraw")
	server.width = 120
	server.height = 40
	window := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "claude",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		window,
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	server.markRestoreRedrawPending([]string{"@2"})

	if err := server.selectWindow("@2"); err != nil {
		t.Fatalf("selectWindow: %v", err)
	}
	if len(*actions) != len(restoreRedrawFollowUpDelays) {
		t.Fatalf("scheduled %d follow-ups, want %d", len(*actions), len(restoreRedrawFollowUpDelays))
	}

	before := len(simulated)
	(*actions)[0]()
	if len(simulated) != before+1 || simulated[len(simulated)-1] != "@2" {
		t.Fatalf("follow-up did not force a redraw of @2: %#v", simulated)
	}

	// Follow-ups are armed only once per restored window.
	*actions = (*actions)[:0]
	if err := server.selectWindow("@2"); err != nil {
		t.Fatalf("selectWindow (second): %v", err)
	}
	if len(*actions) != 0 {
		t.Fatalf("re-armed %d follow-ups on second select, want 0", len(*actions))
	}
}

func TestRestoreRedrawFollowUpSkipsInactiveOrDetachedWindow(t *testing.T) {
	withStubbedRestoreRedraw(t)

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(simulated, window.id)
	}

	server := newMuxServer("restore-redraw-skip")
	server.width = 100
	server.height = 30
	window := &muxWindow{id: "@1", index: 0, agentTool: "codex", lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	// Not the active window anymore.
	server.activeID = "@other"
	server.redrawRestoredWindow("@1")
	if len(simulated) != 0 {
		t.Fatalf("redraw fired for non-active window: %#v", simulated)
	}

	// Any attached client can keep the restored redraw alive.
	server.activeID = "@1"
	server.redrawRestoredWindow("@1")
	if !reflect.DeepEqual(simulated, []string{"@1"}) {
		t.Fatalf("redraw did not run for active attached window: %#v", simulated)
	}

	// No attached clients: skip.
	server.removeAttachClient(server.attachClients[attach])
	server.redrawRestoredWindow("@1")
	if !reflect.DeepEqual(simulated, []string{"@1"}) {
		t.Fatalf("redraw fired without an attached client: %#v", simulated)
	}
}

func TestScheduleRestoreRedrawFollowUpsIgnoresNilConn(t *testing.T) {
	actions := withStubbedRestoreRedraw(t)
	server := newMuxServer("restore-redraw-nil")
	server.markRestoreRedrawPending([]string{"@1"})

	server.scheduleRestoreRedrawFollowUps("@1")
	if len(*actions) != 0 {
		t.Fatalf("scheduled follow-ups without an attached client: %d", len(*actions))
	}
	// The pending entry is preserved for the next real attach.
	if !server.restoreRedrawPending["@1"] {
		t.Fatal("pending redraw entry was consumed without an attached client")
	}
}

func TestRestoreRedrawUsesCurrentPrimaryClientSize(t *testing.T) {
	withStubbedRestoreRedraw(t)

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}
	server := newMuxServerWithSize("restore-primary-size", 80, 24)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "codex",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"primary",
		132,
		43,
	)
	server.mu.Lock()
	server.width = 80
	server.height = 24
	server.mu.Unlock()

	server.redrawRestoredWindow("@1")

	server.mu.Lock()
	width, height := server.width, server.height
	server.mu.Unlock()
	if width != 132 || height != 43 {
		t.Fatalf("restored redraw size = %dx%d, want 132x43", width, height)
	}
	if !reflect.DeepEqual(simulated, []string{"@1:132x43"}) {
		t.Fatalf("restored redraw simulation = %#v", simulated)
	}
}

func TestAgentResumeCommandWithFreshFallback(t *testing.T) {
	tests := []struct {
		name   string
		resume string
		launch string
		want   string
	}{
		{
			name:   "resume falls back to fresh launch",
			resume: "copilot --resume 'abc'",
			launch: "copilot",
			want:   "copilot --resume 'abc' || copilot",
		},
		{
			name:   "yolo launch preserved in fallback",
			resume: "copilot --yolo --resume 'abc'",
			launch: "copilot --yolo",
			want:   "copilot --yolo --resume 'abc' || copilot --yolo",
		},
		{
			name:   "no launch keeps bare resume",
			resume: "copilot --resume 'abc'",
			launch: "",
			want:   "copilot --resume 'abc'",
		},
		{
			name:   "identical commands are not chained",
			resume: "opencode --continue",
			launch: "opencode --continue",
			want:   "opencode --continue",
		},
		{
			name:   "empty resume yields launch",
			resume: "",
			launch: "copilot",
			want:   "copilot",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := agentResumeCommandWithFreshFallback(tc.resume, tc.launch); got != tc.want {
				t.Fatalf("agentResumeCommandWithFreshFallback(%q, %q) = %q, want %q", tc.resume, tc.launch, got, tc.want)
			}
		})
	}
}

// TestRestoreAgentWindowSurvivesFailedResume reproduces the "Copilot CLI does
// not restore after a MonkeyMux upgrade" regression: when a restored agent
// window's --resume attempt exits immediately (the previous session can no
// longer be resumed), the window must fall back to a fresh launch and stay
// open instead of vanishing.
func TestRestoreAgentWindowSurvivesFailedResume(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	binDir := t.TempDir()
	marker := filepath.Join(binDir, "fresh-launched")
	// Fake agent: any --resume invocation fails (like Copilot CLI's "No
	// session ... matched" exit 1); a fresh launch records that it ran and
	// then blocks so the window stays alive.
	fake := "#!/bin/sh\n" +
		"for arg in \"$@\"; do\n" +
		"  if [ \"$arg\" = \"--resume\" ]; then\n" +
		"    echo 'No session, task, or name matched' 1>&2\n" +
		"    exit 1\n" +
		"  fi\n" +
		"done\n" +
		": > " + shellQuote(marker) + "\n" +
		"exec cat\n"
	if err := os.WriteFile(filepath.Join(binDir, "copilot"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	server := newMuxServerWithSize("restore-failed-resume", 80, 24)
	t.Cleanup(server.close)

	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows: []restoreWindowState{
			{
				ID:             "@1",
				Index:          0,
				Name:           "Copilot CLI",
				AgentTool:      "copilot",
				AgentSessionID: "dead-session",
				Cwd:            binDir,
				Active:         true,
			},
		},
	}
	if err := server.restoreOrCreateInitialWindow(restore, createWindowOptions{}); err != nil {
		t.Fatalf("restoreOrCreateInitialWindow: %v", err)
	}

	// The fresh fallback must run (the window would otherwise close on the
	// failed resume).
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("fresh fallback never launched; window closed after failed resume. snapshots=%+v", server.snapshots())
		}
		time.Sleep(20 * time.Millisecond)
	}

	// The window survives with exactly one open pane running the fresh agent.
	snaps := server.snapshots()
	if len(snaps) != 1 {
		t.Fatalf("restored windows = %d, want 1 (window vanished after failed resume): %+v", len(snaps), snaps)
	}
}
