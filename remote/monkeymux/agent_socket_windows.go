//go:build windows

package main

// Windows OpenSSH forwards the agent over a named pipe that a symlink cannot
// stand in for, so the stable agent link is POSIX-only.

func linkForwardedAgent() {}

func withForwardedAgentSocket(env []string) []string { return env }
