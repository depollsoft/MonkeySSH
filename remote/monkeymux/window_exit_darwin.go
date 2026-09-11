//go:build darwin

package main

import "golang.org/x/sys/unix"

const supportsWindowExitObservation = true

func windowProcessCommand(pid int) (string, bool) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || info == nil {
		return "", false
	}
	return unix.ByteSliceToString(info.Proc.P_comm[:]), true
}

// Kqueue observes exit without reaping, leaving the PID reserved for shutdown.
func awaitWindowProcessExit(pid int) {
	fd, err := unix.Kqueue()
	if err != nil {
		return
	}
	defer unix.Close(fd)
	unix.CloseOnExec(fd)
	changes := []unix.Kevent_t{{Ident: uint64(pid), Filter: unix.EVFILT_PROC,
		Flags: unix.EV_ADD | unix.EV_ONESHOT, Fflags: unix.NOTE_EXIT}}
	events := make([]unix.Kevent_t, 1)
	for {
		_, err = unix.Kevent(fd, changes, events, nil)
		if err != unix.EINTR {
			return
		}
	}
}
