//go:build !windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// tryLockPushStateFile takes a non-blocking exclusive flock on file. It
// reports false, nil when another process holds the lock.
func tryLockPushStateFile(file *os.File) (bool, error) {
	err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
		return false, nil
	}
	return err == nil, err
}

func unlockPushStateFile(file *os.File) {
	_ = unix.Flock(int(file.Fd()), unix.LOCK_UN)
}
