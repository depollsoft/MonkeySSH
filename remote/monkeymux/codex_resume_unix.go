//go:build !windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

func codexSessionLockHeld(path string) bool {
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false // Missing/inaccessible locks fall through to Codex.
	}
	defer file.Close()
	// Rust File::try_lock uses flock on Unix. Do not create, unlink, or hold
	// the file across launch; this is only a best-effort observation.
	err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	return errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN)
}

func codexResumeGateCommand(sessionID, resume string) string {
	if gate := codexResumeGateInvocation(sessionID); gate != "" {
		return gate + "; " + resume
	}
	return resume
}
