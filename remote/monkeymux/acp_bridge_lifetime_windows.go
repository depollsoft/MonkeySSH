//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// Both opens share delete access, unlike os.OpenFile: the bridge renames its
// staging file into place while holding it open, and removes the published
// file on exit even while a probe has it open.

func createAcpBridgeLifetimeStaging(path string) (*os.File, error) {
	return openAcpBridgeLifetimeFile(path, windows.CREATE_NEW)
}

func openAcpBridgeLifetimeForProbe(path string) (*os.File, error) {
	return openAcpBridgeLifetimeFile(path, windows.OPEN_EXISTING)
}

func openAcpBridgeLifetimeFile(path string, disposition uint32) (*os.File, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(name,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, disposition, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return os.NewFile(uintptr(handle), path), nil
}
