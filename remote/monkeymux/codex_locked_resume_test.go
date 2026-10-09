package main

import (
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const codexLockedPromptFixture = "\x1b[2J\x1b[H" +
	"This conversation is open in another app\r\n" +
	"Close it there and press R to continue here.\r\n\r\n" +
	"r to retry"

func TestCodexLockedPromptShown(t *testing.T) {
	render := func(width int, output string) []string {
		screen := newTerminalScreen(width, 12)
		screen.Write([]byte(output))
		return screen.TextRows()
	}
	for _, tc := range []struct {
		name string
		rows []string
		want bool
	}{
		{"codex prompt", render(80, codexLockedPromptFixture), true},
		{"wrapped mid-word", render(13, "This conversation is open in another app. "+
			"Close it there and press R to continue here."), true},
		{"boxed", []string{
			"╭─────────────────────────────────────╮",
			"│ This conversation is open in        │",
			"│ another app — Close it there and    │",
			"│ press R to continue here.           │",
			"╰─────────────────────────────────────╯",
		}, true},
		{"title only", render(80, "This conversation is open in another app"), false},
		{"other retry prompt", render(80, "Request interrupted. Press R to retry."), false},
		{"empty", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := codexLockedPromptShown(tc.rows); got != tc.want {
				t.Fatalf("shown = %v, want %v for %q", got, tc.want, tc.rows)
			}
		})
	}
}

type codexLockedResumeFrame struct {
	prompt     bool
	foreground int
	held       bool
}

// runCodexLockedResumeRetry steps the default policy once per poll on a fake
// clock and returns when R was pressed and when watching ended.
func runCodexLockedResumeRetry(
	t *testing.T,
	frame func(elapsed time.Duration) codexLockedResumeFrame,
) (presses []time.Duration, end time.Duration) {
	t.Helper()
	policy := defaultCodexLockedResumePolicy
	start := time.Unix(0, 0)
	retry := newCodexLockedResumeRetry(policy, start)
	for elapsed := policy.poll; elapsed <= 2*policy.limit; elapsed += policy.poll {
		current := frame(elapsed)
		press, done := retry.step(start.Add(elapsed), current.prompt, current.foreground,
			func() bool {
				if !current.prompt {
					t.Fatalf("probed the lock at %v without a prompt", elapsed)
				}
				return current.held
			})
		if press {
			presses = append(presses, elapsed)
		}
		if done {
			return presses, elapsed
		}
	}
	t.Fatal("retry never finished")
	return nil, 0
}

func TestCodexLockedResumeRetry(t *testing.T) {
	policy := defaultCodexLockedResumePolicy
	release := 3 * time.Minute
	for _, tc := range []struct {
		name        string
		frame       func(time.Duration) codexLockedResumeFrame
		wantPresses []time.Duration
		wantEnd     time.Duration
	}{
		{
			name:    "resume succeeded",
			frame:   func(time.Duration) codexLockedResumeFrame { return codexLockedResumeFrame{} },
			wantEnd: policy.promptWait,
		},
		{
			// Nothing proves another holder: a CODEX_HOME the server cannot see,
			// or a lease that ended before the first look. Codex's prompt stays.
			name: "lock never seen held",
			frame: func(time.Duration) codexLockedResumeFrame {
				return codexLockedResumeFrame{prompt: true, foreground: 41}
			},
			wantEnd: policy.limit,
		},
		{
			name: "holder releases and the first press resumes",
			frame: func(elapsed time.Duration) codexLockedResumeFrame {
				return codexLockedResumeFrame{
					prompt:     elapsed <= release,
					foreground: 41,
					held:       elapsed < release,
				}
			},
			wantPresses: []time.Duration{release},
			wantEnd:     release + policy.settle,
		},
		{
			name: "prompt persists after release",
			frame: func(elapsed time.Duration) codexLockedResumeFrame {
				return codexLockedResumeFrame{prompt: true, foreground: 41, held: elapsed < release}
			},
			wantPresses: []time.Duration{
				release,
				release + time.Second,
				release + 3*time.Second,
				release + 7*time.Second,
			},
			wantEnd: release + 7*time.Second + policy.poll,
		},
		{
			name: "holder seen behind another program",
			frame: func(elapsed time.Duration) codexLockedResumeFrame {
				if elapsed < release {
					return codexLockedResumeFrame{prompt: true, foreground: 41, held: true}
				}
				return codexLockedResumeFrame{prompt: true, foreground: 42}
			},
			wantEnd: policy.limit,
		},
		{
			name: "holder outlasts the bound",
			frame: func(time.Duration) codexLockedResumeFrame {
				return codexLockedResumeFrame{prompt: true, foreground: 41, held: true}
			},
			wantEnd: policy.limit,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			presses, end := runCodexLockedResumeRetry(t, tc.frame)
			if len(presses) != len(tc.wantPresses) {
				t.Fatalf("presses = %v, want %v", presses, tc.wantPresses)
			}
			for i := range presses {
				if presses[i] != tc.wantPresses[i] {
					t.Fatalf("presses = %v, want %v", presses, tc.wantPresses)
				}
			}
			if end != tc.wantEnd {
				t.Fatalf("finished at %v, want %v", end, tc.wantEnd)
			}
		})
	}
}

func TestRestoredCodexResumeLockPath(t *testing.T) {
	codexHome := t.TempDir()
	t.Setenv("CODEX_HOME", codexHome)
	resumed := createWindowOptionsForRestore(
		restoreWindowState{AgentTool: "codex", AgentSessionID: "saved-thread"}, false)
	if got, want := restoredCodexResumeLockPath(resumed), codexSessionLockPath(codexHome, "saved-thread"); got != want || got == "" {
		t.Fatalf("lock path = %q, want %q", got, want)
	}
	for name, options := range map[string]createWindowOptions{
		"fresh codex": createWindowOptionsForRestore(restoreWindowState{AgentTool: "codex"}, false),
		"other agent": createWindowOptionsForRestore(
			restoreWindowState{AgentTool: "claude", AgentSessionID: "saved-thread"}, false),
		"native acp": {agentTool: "codex", agentSessionID: "saved-thread", nativeAcpBridgeID: "bridge"},
		"traversal":  {agentTool: "codex", agentSessionID: "../saved-thread"},
	} {
		if got := restoredCodexResumeLockPath(options); got != "" {
			t.Errorf("%s: lock path = %q, want none", name, got)
		}
	}
}

type codexLockedResumeTestPty struct {
	recordingPty
	foreground atomic.Int64
}

func (p *codexLockedResumeTestPty) foregroundProcessGroup() int {
	return int(p.foreground.Load())
}

func TestWatchCodexLockedResumePressesROnceLockReleases(t *testing.T) {
	server := newMuxServer("codex-locked-resume")
	pty := &codexLockedResumeTestPty{}
	pty.foreground.Store(41)
	window := &muxWindow{id: "@1", agentTool: "codex", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	var held atomic.Bool
	held.Store(true)
	var heldProbes atomic.Int32
	lockHeld := func() bool {
		if held.Load() {
			heldProbes.Add(1)
			return true
		}
		return false
	}
	policy := codexLockedResumePolicy{
		poll:       5 * time.Millisecond,
		promptWait: time.Minute,
		settle:     50 * time.Millisecond,
		limit:      time.Minute,
		backoff:    time.Hour, // one press: the success path below needs no retry
		maxPresses: 4,
	}
	done := make(chan struct{})
	go func() {
		server.watchCodexLockedResume(window, lockHeld, policy)
		close(done)
	}()

	server.handleWindowOutput("@1", []byte(codexLockedPromptFixture))
	waitForCodexLockedResume(t, "held lock probes", func() bool { return heldProbes.Load() >= 3 })
	if got := pty.String(); got != "" {
		t.Fatalf("pressed %q while the lock was held", got)
	}

	held.Store(false)
	waitForCodexLockedResume(t, "R press", func() bool { return pty.String() == "r" })

	// Codex resumed: the prompt gives way to the session.
	server.handleWindowOutput("@1", []byte("\x1b[2J\x1b[H› Ask Codex to do anything"))
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("watcher did not finish after the prompt cleared")
	}
	if got := pty.String(); got != "r" {
		t.Fatalf("window input = %q, want one R press", got)
	}
}

func TestWatchCodexLockedResumeStopsWithWindow(t *testing.T) {
	server := newMuxServer("codex-locked-resume-close")
	pty := &codexLockedResumeTestPty{}
	window := &muxWindow{id: "@1", agentTool: "codex", pty: pty, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.handleWindowOutput("@1", []byte(codexLockedPromptFixture))

	var probes atomic.Int32
	done := make(chan struct{})
	go func() {
		server.watchCodexLockedResume(window, func() bool { probes.Add(1); return true },
			codexLockedResumePolicy{poll: 5 * time.Millisecond, promptWait: time.Minute,
				settle: time.Minute, limit: time.Minute, backoff: time.Second, maxPresses: 4})
		close(done)
	}()
	waitForCodexLockedResume(t, "lock probe", func() bool { return probes.Load() > 0 })
	server.mu.Lock()
	window.closed = true
	server.mu.Unlock()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("watcher outlived its window")
	}
	if got := pty.String(); strings.Contains(got, "r") {
		t.Fatalf("pressed %q for a held lock", got)
	}
}

// waitForCodexLockedResume polls ready. Untagged tests cannot use the Unix-only
// waitRejectedCondition.
func waitForCodexLockedResume(t *testing.T, description string, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ready() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
