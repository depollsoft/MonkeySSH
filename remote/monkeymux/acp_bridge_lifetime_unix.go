//go:build !windows

package main

import "os"

func createAcpBridgeLifetimeStaging(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
}

func openAcpBridgeLifetimeForProbe(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDWR, 0)
}
