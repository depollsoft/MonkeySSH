package main

import (
	"strings"
	"time"
	"unicode"
)

// A restored Codex window resumes its thread with `codex resume <id>`. While
// another client still holds that thread's writer lock, Codex does not exit:
// it shows "This conversation is open in another app. Close it there and
// press R to continue here." and waits for the key. After a reload the holder
// is usually Codex's shared app-server, still leasing the thread to the CLI
// the outgoing server tore down, and the lease can outlast the launch gate
// (waitForCodexSession) by minutes.
//
// watchCodexLockedResume presses R for the user once that holder lets go. It
// presses only while the prompt is on screen and only after it has seen the
// writer lock held and then free in front of the same foreground process
// group. It therefore never competes with a live holder, and it does nothing
// when it cannot observe the lock, for example under a CODEX_HOME that only
// the pane's shell sets. A transcript that merely quotes the prompt is safe
// too: the resumed session holds its own lock until it exits, and on Unix its
// exit also changes the foreground group. Presses and time are bounded: a
// thread that stays open elsewhere keeps Codex's prompt for the user.
//
// The prompt text and the lock file are Codex's, so this is Codex-specific.
// Graceful teardown on the outgoing side is in codex_shutdown_unix.go.

type codexLockedResumePolicy struct {
	poll       time.Duration // how often the screen and lock are checked
	promptWait time.Duration // stop if the prompt has not appeared by then
	settle     time.Duration // stop once a seen prompt has stayed gone this long
	limit      time.Duration // stop this long after launch regardless
	backoff    time.Duration // delay after the first press; doubles per press
	maxPresses int
}

var defaultCodexLockedResumePolicy = codexLockedResumePolicy{
	poll:       500 * time.Millisecond,
	promptWait: time.Minute,
	settle:     10 * time.Second,
	limit:      15 * time.Minute,
	backoff:    time.Second,
	maxPresses: 4,
}

// codexLockedResumeRetry decides, one poll at a time, when to press R.
type codexLockedResumeRetry struct {
	policy   codexLockedResumePolicy
	started  time.Time
	lastSeen time.Time // last poll that showed the prompt
	// held records that the lock was seen held behind the prompt while
	// holderForeground was the pane's foreground process group.
	held             bool
	holderForeground int
	nextPress        time.Time
	backoff          time.Duration
	presses          int
}

func newCodexLockedResumeRetry(policy codexLockedResumePolicy, started time.Time) *codexLockedResumeRetry {
	return &codexLockedResumeRetry{policy: policy, started: started, backoff: policy.backoff}
}

// step reports whether to press R now and whether watching is over. lockHeld
// is probed only while the prompt is up.
func (r *codexLockedResumeRetry) step(
	now time.Time,
	prompt bool,
	foreground int,
	lockHeld func() bool,
) (press bool, done bool) {
	if now.Sub(r.started) >= r.policy.limit {
		return false, true
	}
	if !prompt {
		if r.lastSeen.IsZero() {
			return false, now.Sub(r.started) >= r.policy.promptWait
		}
		return false, now.Sub(r.lastSeen) >= r.policy.settle
	}
	r.lastSeen = now
	if r.presses >= r.policy.maxPresses {
		return false, true // Leave Codex's prompt to the user.
	}
	if r.held && foreground != r.holderForeground {
		// Another program is in front: the lock seen earlier says nothing
		// about the prompt now on screen.
		r.held = false
	}
	if lockHeld() {
		r.held, r.holderForeground = true, foreground
		return false, false
	}
	if !r.held || now.Before(r.nextPress) {
		return false, false
	}
	r.presses++
	r.nextPress = now.Add(r.backoff)
	r.backoff *= 2
	return true, false
}

// watchRestoredCodexResume starts the locked-thread retry for a window that
// restore launched with `codex resume <id>`.
func (s *muxServer) watchRestoredCodexResume(window *muxWindow, options createWindowOptions) {
	path := restoredCodexResumeLockPath(options)
	if window == nil || path == "" {
		return
	}
	go s.watchCodexLockedResume(
		window,
		func() bool { return codexSessionLockHeld(path) },
		defaultCodexLockedResumePolicy,
	)
}

// restoredCodexResumeLockPath is the writer lock of the thread a restored CLI
// window resumes, or "" when the window does not resume a Codex thread.
func restoredCodexResumeLockPath(options createWindowOptions) string {
	if options.agentTool != "codex" || options.nativeAcpBridgeID != "" {
		return ""
	}
	return codexSessionLockPathFromEnvironment(strings.TrimSpace(options.agentSessionID))
}

func (s *muxServer) watchCodexLockedResume(
	window *muxWindow,
	lockHeld func() bool,
	policy codexLockedResumePolicy,
) {
	retry := newCodexLockedResumeRetry(policy, time.Now())
	ticker := time.NewTicker(policy.poll)
	defer ticker.Stop()
	var generation uint64
	prompt := false
	for range ticker.C {
		s.mu.Lock()
		if s.closed || window.closed || s.windowByIDLocked(window.id) != window {
			s.mu.Unlock()
			return
		}
		// Rescan only after new output; the screen cannot change otherwise.
		if window.outputGeneration != generation {
			generation = window.outputGeneration
			prompt = window.screen != nil && codexLockedPromptShown(window.screen.TextRows())
		}
		windowPty := window.pty
		s.mu.Unlock()
		press, done := retry.step(time.Now(), prompt, ptyForegroundProcessGroup(windowPty), lockHeld)
		if press {
			_ = s.writeWindowData(window.id, []byte("r"), false, false)
		}
		if done {
			return
		}
	}
}

// ptyForegroundProcessGroup reads the pane's foreground group from the pty
// itself, or 0 where there is none (Windows).
func ptyForegroundProcessGroup(windowPty muxPty) int {
	if terminal, ok := windowPty.(interface{ foregroundProcessGroup() int }); ok {
		return terminal.foregroundProcessGroup()
	}
	return 0
}

// codexLockedPromptShown reports whether Codex's locked-thread prompt is on
// screen. It compares letters only, so wrapping at any column, borders and
// punctuation do not matter.
func codexLockedPromptShown(rows []string) bool {
	var letters strings.Builder
	for _, row := range rows {
		for _, r := range row {
			if unicode.IsLetter(r) {
				letters.WriteRune(unicode.ToLower(r))
			}
		}
	}
	text := letters.String()
	return strings.Contains(text, "conversationisopeninanotherapp") &&
		strings.Contains(text, "pressrtocontinuehere")
}
