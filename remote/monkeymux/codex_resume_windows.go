//go:build windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

func codexSessionLockHeld(path string) bool {
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false
	}
	defer file.Close()
	var overlapped windows.Overlapped
	err = windows.LockFileEx(windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, ^uint32(0), ^uint32(0), &overlapped)
	return errors.Is(err, windows.ERROR_LOCK_VIOLATION)
}

func codexResumeGateCommand(sessionID, resume string) string {
	if gate := codexResumeGateInvocation(sessionID); gate != "" {
		if isCmdShell(defaultShellPath()) {
			return gate + " & " + resume
		}
		return gate + "; " + resume
	}
	return resume
}
