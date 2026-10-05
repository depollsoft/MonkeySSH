//go:build !darwin

package main

func inspectReplacementProcess(pid int) processSnapshot {
	return inspectProcess(pid)
}
