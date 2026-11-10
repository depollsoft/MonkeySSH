package main

import (
	"errors"
	"os"
	"strings"
)

// A bridge holds an exclusive lock on a lifetime file beside its socket for
// as long as it serves. The OS drops the lock when the process ends, however
// it ends, so a lifetime file whose lock is free proves its bridge exited,
// while a held one proves it is still running even when its socket refuses
// connections (macOS refuses them while a live listener's accept queue is
// full) or has been deleted. Bridges started before lifetime files existed,
// and file systems that cannot lock, leave no file; callers then fall back
// to judging the socket alone.
//
// The extension is not .lock: `monkeymux gc` treats every monkeymux-*.lock
// file as a pid record.
const acpBridgeLifetimeSuffix = ".alive"

type acpBridgeLifetime int

const (
	// acpBridgeLifetimeAbsent: no lifetime file, so the socket decides.
	acpBridgeLifetimeAbsent acpBridgeLifetime = iota
	// acpBridgeLifetimeHeld: the bridge process is still running.
	acpBridgeLifetimeHeld
	// acpBridgeLifetimeFree: the bridge process ended; its files are residue.
	acpBridgeLifetimeFree
	// acpBridgeLifetimeUnknown: the file exists but could not be checked.
	acpBridgeLifetimeUnknown
)

func acpBridgeLifetimePath(socket string) string {
	return strings.TrimSuffix(socket, ".sock") + acpBridgeLifetimeSuffix
}

// holdAcpBridgeLifetime creates and locks the lifetime file for the bridge
// listening at socket, returning the function that releases and removes it.
// It is best effort: where the file cannot be created or locked, no file is
// left behind and the bridge runs without one.
func holdAcpBridgeLifetime(socket string) func() {
	path := acpBridgeLifetimePath(socket)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return func() {}
	}
	locked, err := tryLockPushStateFile(file)
	if err != nil || !locked {
		_ = file.Close()
		if err != nil {
			_ = os.Remove(path)
		}
		return func() {}
	}
	return func() {
		// Windows cannot delete a file another handle keeps open, so close
		// before removing. A prober that finds the file in between sees a
		// free lock, which is true by then: the bridge is exiting.
		unlockPushStateFile(file)
		_ = file.Close()
		_ = os.Remove(path)
	}
}

// probeAcpBridgeLifetime reports whether the bridge listening at socket is
// still running, judged by its lifetime lock.
func probeAcpBridgeLifetime(socket string) acpBridgeLifetime {
	file, err := os.OpenFile(acpBridgeLifetimePath(socket), os.O_RDWR, 0)
	if errors.Is(err, os.ErrNotExist) {
		return acpBridgeLifetimeAbsent
	}
	if err != nil {
		return acpBridgeLifetimeUnknown
	}
	defer file.Close()
	locked, err := tryLockPushStateFile(file)
	switch {
	case err != nil:
		return acpBridgeLifetimeUnknown
	case !locked:
		return acpBridgeLifetimeHeld
	}
	unlockPushStateFile(file)
	return acpBridgeLifetimeFree
}

// removeAcpBridgeResidue deletes the socket and lifetime file a bridge that
// is known to have exited left behind.
func removeAcpBridgeResidue(socket string) {
	_ = os.Remove(socket)
	_ = os.Remove(acpBridgeLifetimePath(socket))
}
