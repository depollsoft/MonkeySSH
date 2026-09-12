//go:build darwin

package main

import (
	"time"

	"golang.org/x/sys/unix"
)

// ps lstart drops subsecond precision. Forced process-group cleanup must use
// the kernel start timeval and fail closed if that identity is unavailable.
func inspectReplacementProcess(pid int) processSnapshot {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || info == nil || int(info.Proc.P_pid) != pid {
		return processSnapshot{}
	}
	const zombie = 5 // SZOMB in sys/proc.h.
	started := info.Proc.P_starttime
	if started.Sec <= 0 {
		return processSnapshot{}
	}
	return processSnapshot{
		known: true, running: info.Proc.P_stat != zombie,
		started: time.Unix(started.Sec, int64(started.Usec)*int64(time.Microsecond)),
	}
}
