package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"sync/atomic"
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
// A running bridge whose socket was deleted (by an older helper's gc, for
// example) cannot be reached or stopped through it, so stopping it fails
// until it exits; dropping it would leak a provider nobody can reach.
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

var acpBridgeLifetimeStagingSequence atomic.Uint64

// holdAcpBridgeLifetime publishes the locked lifetime file for the bridge
// listening at socket, returning the function that releases and removes it.
// It is best effort: where the file cannot be created or locked, no file is
// left behind and the bridge runs without one.
func holdAcpBridgeLifetime(socket string) func() {
	path := acpBridgeLifetimePath(socket)
	file, err := publishLockedAcpBridgeLifetime(path)
	if err != nil {
		return func() {}
	}
	return func() {
		// Release before removing, as Windows needs. A prober that finds the
		// file in between sees a free lock, which is true by then: the
		// provider has stopped and the socket is gone.
		unlockPushStateFile(file)
		_ = file.Close()
		_ = os.Remove(path)
	}
}

// publishLockedAcpBridgeLifetime locks a private staging file and only then
// renames it to path, so the lifetime file never exists unlocked while its
// bridge runs. Created at path and locked afterwards, a probe in between
// would find it free and could delete it, leaving the bridge holding a lock
// nobody can see. The staging name ends in .staging, which `monkeymux gc`
// clears if a bridge dies before the rename.
func publishLockedAcpBridgeLifetime(path string) (*os.File, error) {
	staging := fmt.Sprintf("%s.%d.%d.staging", path, os.Getpid(),
		acpBridgeLifetimeStagingSequence.Add(1))
	file, err := createAcpBridgeLifetimeStaging(staging)
	if err != nil {
		return nil, err
	}
	locked, err := tryLockPushStateFile(file)
	if err == nil && !locked {
		err = errors.New("ACP bridge lifetime staging file is locked")
	}
	if err == nil {
		err = os.Rename(staging, path)
	}
	if err != nil {
		_ = file.Close()
		_ = os.Remove(staging)
		return nil, err
	}
	return file, nil
}

// probeAcpBridgeLifetime reports whether the bridge listening at socket is
// still running, judged by its lifetime lock.
func probeAcpBridgeLifetime(socket string) acpBridgeLifetime {
	file, err := openAcpBridgeLifetimeForProbe(acpBridgeLifetimePath(socket))
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
