//go:build windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// tryLockPushStateFile takes a non-blocking exclusive LockFileEx on file. It
// reports false, nil when another process holds the lock.
func tryLockPushStateFile(file *os.File) (bool, error) {
	var overlapped windows.Overlapped
	err := windows.LockFileEx(windows.Handle(file.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, ^uint32(0), ^uint32(0), &overlapped)
	if errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
		return false, nil
	}
	return err == nil, err
}

func unlockPushStateFile(file *os.File) {
	var overlapped windows.Overlapped
	_ = windows.UnlockFileEx(windows.Handle(file.Fd()), 0, ^uint32(0), ^uint32(0), &overlapped)
}
