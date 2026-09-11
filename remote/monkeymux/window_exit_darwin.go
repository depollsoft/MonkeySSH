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
func awaitWindowProcessExit(pid int) bool {
	fd, err := unix.Kqueue()
	if err != nil {
		return false
	}
	defer unix.Close(fd)
	unix.CloseOnExec(fd)
	changes := []unix.Kevent_t{{Ident: uint64(pid), Filter: unix.EVFILT_PROC,
		Flags: unix.EV_ADD | unix.EV_ONESHOT, Fflags: unix.NOTE_EXIT}}
	events := make([]unix.Kevent_t, 1)
	for {
		n, err := unix.Kevent(fd, changes, events, nil)
		if err == unix.EINTR {
			continue
		}
		return err == nil && n > 0 && events[0].Ident == uint64(pid) &&
			events[0].Filter == unix.EVFILT_PROC && events[0].Flags&unix.EV_ERROR == 0 &&
			events[0].Fflags&unix.NOTE_EXIT != 0
	}
}
