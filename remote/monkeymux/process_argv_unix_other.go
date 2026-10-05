//go:build !windows && !linux && !darwin

package main

// processCommandLine is not implemented here: the process table joins the
// arguments with spaces, so they cannot be told apart again. Agents without a
// launch entry restore as a shell.
func processCommandLine(pid int) []string {
	return nil
}
