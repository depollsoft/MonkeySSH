//go:build !windows && !linux && !darwin

package main

const supportsWindowExitObservation = false

func awaitWindowProcessExit(int) {}
