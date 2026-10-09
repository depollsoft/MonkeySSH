//go:build windows

package main

import (
	"errors"

	"golang.org/x/sys/windows"
)

func codexSessionLockHeld(path string) bool {
	handle, err := openCodexSessionLockForProbe(path)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(handle)
	var overlapped windows.Overlapped
	err = windows.LockFileEx(handle,
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, ^uint32(0), ^uint32(0), &overlapped)
	if err == nil {
		// Closing a handle releases its locks only eventually. Unlock now so
		// Codex can take the lock as soon as it retries.
		_ = windows.UnlockFileEx(handle, 0, ^uint32(0), ^uint32(0), &overlapped)
		return false
	}
	return errors.Is(err, windows.ERROR_LOCK_VIOLATION)
}

// openCodexSessionLockForProbe shares delete access, unlike os.OpenFile, so
// Codex can remove a released lock while a probe has it open.
func openCodexSessionLockForProbe(path string) (windows.Handle, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return windows.InvalidHandle, err
	}
	return windows.CreateFile(name,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
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
