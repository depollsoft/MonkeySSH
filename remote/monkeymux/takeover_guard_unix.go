//go:build !windows

package main

import (
	"errors"
	"os"
	"syscall"
)

// lockTakeoverGuardFile takes an exclusive flock on file without waiting,
// reporting false when another process holds it. The lock is released when
// the file is closed or the process exits.
func lockTakeoverGuardFile(file *os.File) (bool, error) {
	err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
		return false, nil
	}
	return false, err
}
