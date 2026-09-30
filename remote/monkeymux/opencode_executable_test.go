//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestOpenCodeWrapperSelectsInstalledExecutable(t *testing.T) {
	bin := t.TempDir()
	t.Setenv("PATH", bin)
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	for _, name := range []string{"opencode", "opencode2", "open-code"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\nprintf '%s' \"$0\"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name string
		args []string
	}{
		{"opencode2", nil},
		{"opencode", []string{"--executable", "opencode"}},
		{"open-code", []string{"--executable", "open-code"}},
	} {
		command := exec.Command(os.Args[0], append([]string{"agent-launch", "opencode"}, tc.args...)...)
		output, err := command.Output()
		if err != nil || string(output) != filepath.Join(bin, tc.name) {
			t.Fatalf("launch %v = %q, %v; want %s", tc.args, output, err, tc.name)
		}
	}
	for _, name := range []string{"opencode2", "opencode", "open-code"} {
		selected, path, err := resolveOpenCodeExecutable()
		if err != nil || selected != name || path != filepath.Join(bin, name) {
			t.Fatalf("resolve = %q, %q, %v; want %s", selected, path, err, name)
		}
		if err := os.Remove(filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := resolveOpenCodeExecutable(); err == nil {
		t.Fatal("missing OpenCode should fail resolution")
	}
}

func TestOpenCodeAliasSurvivesSnapshotAndRestoreFallback(t *testing.T) {
	bin := t.TempDir()
	t.Setenv("PATH", bin)
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	log := filepath.Join(t.TempDir(), "launches")
	t.Setenv("TEST_OPENCODE_LAUNCHES", log)
	stub := "#!/bin/sh\nprintf '%s %s\\n' \"$0\" \"$*\" >> \"$TEST_OPENCODE_LAUNCHES\"\n" +
		"if [ \"$1\" = '--session' ]; then exit 42; fi\n"
	if err := os.WriteFile(filepath.Join(bin, "opencode2"), []byte(stub), 0o700); err != nil {
		t.Fatal(err)
	}
	current := commandNameFromProcessFields("opencode2", filepath.Join(bin, "opencode2")+" --session saved")
	if current != "opencode2" {
		t.Fatalf("process metadata lost alias: %q", current)
	}
	restore := restoreFromWindowSnapshots([]windowSnapshot{{CurrentCommand: current, AgentTool: "opencode", AgentSessionID: "saved"}})
	options := createWindowOptionsForRestore(restore.Windows[0], false)
	command := exec.Command("/bin/sh", "-c", options.command)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("restore = %v: %s", err, output)
	}
	launches, err := os.ReadFile(log)
	want := filepath.Join(bin, "opencode2") + " --session saved\n" + filepath.Join(bin, "opencode2") + " \n"
	if err != nil || string(launches) != want {
		t.Fatalf("restored launches = %q, %v; want %q", launches, err, want)
	}
}
