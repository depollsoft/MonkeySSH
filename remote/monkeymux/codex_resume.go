package main

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

const codexResumeLockWait = 2 * time.Second
const codexResumeLockPoll = 50 * time.Millisecond

// This is deliberately Codex-specific: its shared app-server owns a thread
// writer lock beyond the lifetime of the CLI. Other agents have no equivalent
// lock contract. Never delete the lock or terminate its owner.
func waitForCodexSession(sessionID string) {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return
		}
		home = filepath.Join(userHome, ".codex")
	}
	path := codexSessionLockPath(home, sessionID)
	if path == "" {
		return
	}
	waitForCodexSessionLock(func() bool { return codexSessionLockHeld(path) },
		codexResumeLockWait, time.Now, time.Sleep)
}

func codexSessionLockPath(home, sessionID string) string {
	// Session IDs arrive from restore metadata. Do not let them escape the lock
	// directory, including when a Unix snapshot is restored on Windows.
	if sessionID == "" || sessionID == "." || sessionID == ".." ||
		strings.ContainsAny(sessionID, "/\\\x00:") {
		return ""
	}
	return filepath.Join(home, "thread-writer-locks", sessionID+".lock")
}

func waitForCodexSessionLock(held func() bool, timeout time.Duration,
	now func() time.Time, sleep func(time.Duration)) {
	deadline := now().Add(timeout)
	for held() {
		remaining := deadline.Sub(now())
		if remaining <= 0 {
			return // A real competing writer remains Codex's interactive decision.
		}
		sleep(min(codexResumeLockPoll, remaining))
	}
}

func codexResumeGateInvocation(sessionID string) string {
	// Internal to the installed helper: no client capability/version change is
	// needed. Run in the window shell so gates for different windows overlap and
	// inherit that shell's CODEX_HOME instead of blocking server startup.
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	invocation, ok := shellExecutableCommand(executable)
	if !ok {
		return ""
	}
	argument, ok := shellArgument(sessionID)
	if !ok {
		return ""
	}
	return invocation + " wait-codex-session " + argument
}
