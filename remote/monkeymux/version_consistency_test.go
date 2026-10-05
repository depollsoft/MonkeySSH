//go:build !windows

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The helper only restarts a running server when the running version differs
// from monkeyMuxVersion, while MonkeySSH decides whether to offer the update
// from the packaged manifest version. If the two disagree the app offers an
// "update and restore" that the helper then treats as a no-op, so the prompt
// reappears on every connect. These tests pin every packaging surface to the
// compiled constant.

func TestVersionScriptMatchesCompiledVersion(t *testing.T) {
	output, err := exec.Command("sh", "monkeymux-version.sh").Output()
	if err != nil {
		t.Fatalf("monkeymux-version.sh failed: %v", err)
	}
	if got := strings.TrimSpace(string(output)); got != monkeyMuxVersion {
		t.Fatalf(
			"monkeymux-version.sh = %q, want monkeyMuxVersion %q; bump monkeyMuxVersion in main.go instead of the script",
			got,
			monkeyMuxVersion,
		)
	}
}

func TestBundledManifestMatchesCompiledVersion(t *testing.T) {
	path := filepath.Join("..", "..", "assets", "monkeymux", "manifest.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var manifest struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	if manifest.Version != monkeyMuxVersion {
		t.Fatalf(
			"manifest version = %q, want monkeyMuxVersion %q; rebuild with scripts/build_monkeymux_assets.sh",
			manifest.Version,
			monkeyMuxVersion,
		)
	}
}
