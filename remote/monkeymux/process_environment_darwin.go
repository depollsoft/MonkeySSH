//go:build darwin

package main

// processEnvironment is not implemented on macOS: kern.procargs2 and ps
// return a process's environment only to root, even for the user's own
// processes, so a TUI whose wheel speed its environment sets is governed at
// its default speed here.
func processEnvironment(pid int) []string {
	return nil
}

// processGroupMembers is not needed without processEnvironment.
func processGroupMembers(group int) []int {
	return nil
}
