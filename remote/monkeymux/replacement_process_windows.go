//go:build windows

package main

func inspectReplacementProcess(pid int) processSnapshot {
	return inspectProcess(pid)
}
