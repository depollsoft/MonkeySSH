package main

import (
	"regexp"
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
// presses only while the prompt and its "r to retry" hint are on screen, and
// only after it has seen the writer lock held and then free. It never
// competes with a live holder, and it does nothing when it cannot observe the
// lock, for example under a CODEX_HOME that only the pane's shell sets.
//
// The watch belongs to the foreground process group that first showed the
// prompt and ends when another group takes the terminal: an interrupted
// resume can leave its prompt on screen while the old lease is still held,
// and the fresh fallback or recovery shell must not receive the press.
// ConPTY has no foreground group, so Windows windows are not watched; they
// keep the launch gate and Codex's own prompt. Presses and time are bounded:
// a thread that stays open elsewhere keeps Codex's prompt for the user.
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
	// promptForeground is the foreground process group that first showed
	// the prompt; the watch ends when another group takes the terminal.
	promptForeground int
	held             bool // the lock was seen held behind the prompt
	nextPress        time.Time
	backoff          time.Duration
	presses          int
}

func newCodexLockedResumeRetry(policy codexLockedResumePolicy, started time.Time) *codexLockedResumeRetry {
	return &codexLockedResumeRetry{policy: policy, started: started, backoff: policy.backoff}
}

// step reports whether to press R now and whether watching is over. lockHeld
// is probed only while the prompt is up. A foreground of 0 is unknown.
func (r *codexLockedResumeRetry) step(
	now time.Time,
	prompt bool,
	foreground int,
	lockHeld func() bool,
) (press bool, done bool) {
	if now.Sub(r.started) >= r.policy.limit {
		return false, true
	}
	if r.promptForeground > 0 && foreground > 0 && foreground != r.promptForeground {
		return false, true // The program that showed the prompt is gone.
	}
	if !prompt {
		if r.lastSeen.IsZero() {
			return false, now.Sub(r.started) >= r.policy.promptWait
		}
		return false, now.Sub(r.lastSeen) >= r.policy.settle
	}
	r.lastSeen = now
	if foreground <= 0 {
		return false, false // Nothing ties the lock to the program in front.
	}
	if r.promptForeground == 0 {
		r.promptForeground = foreground
	}
	if r.presses >= r.policy.maxPresses {
		return false, true // Leave Codex's prompt to the user.
	}
	if lockHeld() {
		r.held = true
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
// restore launched with `codex resume <id>`, on a pty that reports its
// foreground process group.
func (s *muxServer) watchRestoredCodexResume(window *muxWindow, options createWindowOptions) {
	path := restoredCodexResumeLockPath(options)
	if window == nil || path == "" {
		return
	}
	s.mu.Lock()
	windowPty := window.pty
	s.mu.Unlock()
	if _, ok := windowPty.(interface{ foregroundProcessGroup() int }); !ok {
		return
	}
	startCodexLockedResumeWatch(s, window, path)
}

// startCodexLockedResumeWatch runs the watcher; tests replace it to observe
// which windows restore arms.
var startCodexLockedResumeWatch = func(s *muxServer, window *muxWindow, lockPath string) {
	go s.watchCodexLockedResume(
		window,
		func() bool { return codexSessionLockHeld(lockPath) },
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
		foreground := ptyForegroundProcessGroup(windowPty)
		press, done := retry.step(time.Now(), prompt, foreground, lockHeld)
		if press {
			s.pressCodexLockedRetry(window, foreground)
		}
		if done {
			return
		}
	}
}

// pressCodexLockedRetry writes R only if the prompt is still on screen with
// the same foreground group once this window's input is serialized. A paste
// can hold that lock while the child is blocked, and the program in front can
// change during the wait.
func (s *muxServer) pressCodexLockedRetry(window *muxWindow, foreground int) {
	window.inputMu.Lock()
	var scheduleFlush func()
	defer func() {
		window.inputMu.Unlock()
		if scheduleFlush != nil {
			scheduleFlush()
		}
	}()
	// Replies the output reader queued before this write go first.
	if err := s.writeQueuedWindowRepliesLocked(window); err != nil {
		return
	}
	s.mu.Lock()
	current := !s.closed && !window.closed && s.windowByIDLocked(window.id) == window &&
		window.screen != nil && codexLockedPromptShown(window.screen.TextRows()) &&
		ptyForegroundProcessGroup(window.pty) == foreground
	s.mu.Unlock()
	if current {
		scheduleFlush, _ = s.writeWindowDataLocked(window, []byte("r"), false, false)
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

// codexLockedRetryHint is the key hint Codex shows with the prompt. A pasted
// quote of the error rarely includes it.
var codexLockedRetryHint = regexp.MustCompile(`(?i)(?:^|[^\p{L}])r[^\p{L}\s]*\s+to\s+retry`)

// codexLockedRetryHintShown matches the bare "r to retry" key hint, not the
// "Press R to retry." sentence Codex's other errors print.
func codexLockedRetryHintShown(row string) bool {
	for _, match := range codexLockedRetryHint.FindAllStringIndex(row, -1) {
		before := strings.TrimRightFunc(row[:match[0]], func(r rune) bool { return !unicode.IsLetter(r) })
		if !strings.HasSuffix(strings.ToLower(before), "press") {
			return true
		}
	}
	return false
}

// codexLockedPromptShown reports whether Codex's locked-thread prompt is on
// screen. The message compares letters only, so wrapping at any column,
// borders and punctuation do not matter. The short hint must sit on one row.
func codexLockedPromptShown(rows []string) bool {
	var letters strings.Builder
	hint := false
	for _, row := range rows {
		hint = hint || codexLockedRetryHintShown(row)
		for _, r := range row {
			if unicode.IsLetter(r) {
				letters.WriteRune(unicode.ToLower(r))
			}
		}
	}
	text := letters.String()
	return hint && strings.Contains(text, "conversationisopeninanotherapp") &&
		strings.Contains(text, "pressrtocontinuehere")
}
