//go:build !windows

package main

// hermesLaunchArguments returns the command line of the process group's
// leader, the Hermes CLI the shell started.
func hermesLaunchArguments(group int) []string {
	return processCommandLine(group)
}
