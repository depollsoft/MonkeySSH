package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Pane restore tests launch os.Executable(), which is this test binary. Dispatch
// the wrapper just as main does instead of recursively running the test suite.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "agent-launch" {
		runAgentLaunchWrapper(os.Args[2:])
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestAgentLaunchCommandRewriting(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	invocation, ok := shellExecutableCommand(executable)
	if !ok {
		t.Fatal("test executable cannot be shell quoted")
	}
	for _, tool := range []string{"claude", "codex", "opencode", "copilot", "cursor-agent"} {
		for _, prefix := range []string{"", "  ", "A=1 B='two words' ", "cd '/some project' && ", `cd "/project" && OPENCODE_PERMISSION='{"*":"allow"}' `} {
			for _, suffix := range []string{"", " --resume X", " --continue", " --dangerously-skip-permissions --resume 'a b'  ", "\t--flag='x y' > /tmp/output"} {
				command := prefix + tool + suffix
				want := prefix + invocation + " agent-launch " + tool + suffix
				if got := monkeyMuxAgentLaunchCommand(command); got != want {
					t.Errorf("rewrite %q = %q; want %q", command, got, want)
				}
				if got := monkeyMuxAgentLaunchCommand(want); got != want {
					t.Errorf("rewrapped %q as %q", want, got)
				}
			}
		}
	}
	for _, tc := range []struct{ command, want string }{
		{"codex resume 'id'", invocation + " agent-launch codex resume 'id'"},
		{`OPENCODE_PERMISSION='{"*":"allow"}' opencode`, `OPENCODE_PERMISSION='{"*":"allow"}' ` + invocation + " agent-launch opencode"},
		{"'/opt/agent tools/claude' --resume X", invocation + " agent-launch claude --executable " + shellQuote("/opt/agent tools/claude") + " --resume X"},
		{"/opt/bin/codex --yolo", invocation + " agent-launch codex --executable " + shellQuote("/opt/bin/codex") + " --yolo"},
		{"claude-code --resume X", invocation + " agent-launch claude --executable " + shellQuote("claude-code") + " --resume X"},
		{"./bin/codex --yolo", invocation + " agent-launch codex --executable " + shellQuote("./bin/codex") + " --yolo"},
		{"pi --session saved", invocation + " pi-agent --session saved"},
		{"pi", invocation + " pi-agent"},
	} {
		if got := monkeyMuxAgentLaunchCommand(tc.command); got != tc.want {
			t.Errorf("rewrite %q = %q; want %q", tc.command, got, tc.want)
		}
	}
	for _, command := range []string{"", "  ", "agy --conversation X", "unknown --resume X", "echo claude", "A=claude unknown", "cd /tmp && unknown codex", "monkeymux pi-agent --session X", "A=1 pi", "'unterminated claude"} {
		if got := monkeyMuxAgentLaunchCommand(command); got != command {
			t.Errorf("changed unsupported command %q to %q", command, got)
		}
	}
}

func TestAgentLaunchWrapperDetection(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "opencode", "copilot", "cursor-agent"} {
		for _, prefix := range []string{"", "monkeymux ", "/opt/bin/monkeymux ", "'/opt/with spaces/monkeymux' ", "cd /tmp && A=1 monkeymux "} {
			for _, args := range []string{" --resume X", " --executable '/opt/agent tools/" + tool + "' --resume X"} {
				command := prefix + "agent-launch " + tool + args
				for name, detect := range map[string]func(string) string{
					"wrapper": agentLaunchToolFromCommand, "name": agentToolFromCommandName, "process": agentCommandNameFromProcessArgs,
					"text": agentToolFromCommandText, "first word": firstShellWord,
				} {
					if got := detect(command); got != tool {
						t.Errorf("%s(%q) = %q; want %q", name, command, got, tool)
					}
				}
			}
		}
	}
	for _, command := range []string{"agent-launch", "monkeymux agent-launch", "monkeymux agent-launch unknown", "monkeymux pi-agent"} {
		if got := agentLaunchToolFromCommand(command); got != "" {
			t.Errorf("detected unsupported wrapper %q as %q", command, got)
		}
	}
}

func TestAgentLaunchSessionIDArguments(t *testing.T) {
	for _, tc := range []struct {
		tool, flag string
		blockers   []string
	}{
		{"claude", "--session-id", []string{"--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"}},
		{"copilot", "--session-id", []string{"--resume", "--continue", "--session-id"}},
		{"cursor-agent", "--new-session-id", []string{"--resume", "--continue", "--new-session-id"}},
	} {
		for _, args := range [][]string{nil, {"--yolo"}, {"--", "--resume"}, {"--resume-other"}} {
			if got := agentLaunchSessionIDFlag(tc.tool, args); got != tc.flag {
				t.Errorf("fresh %s %q = %q; want %q", tc.tool, args, got, tc.flag)
			}
		}
		for _, blocker := range tc.blockers {
			for _, args := range [][]string{{blocker}, {"--yolo", blocker, "id"}, {blocker + "=id"}} {
				if got := agentLaunchSessionIDFlag(tc.tool, args); got != "" {
					t.Errorf("resume %s %q got assignment flag %q", tc.tool, args, got)
				}
			}
		}
	}
	for _, args := range [][]string{{"-rid"}, {"-cfoo"}} {
		if got := agentLaunchSessionIDFlag("claude", args); got != "" {
			t.Errorf("attached short option %q assigned ID", args)
		}
	}
	for _, tool := range []string{"codex", "opencode", "agy", "pi", "unknown"} {
		if got := agentLaunchSessionIDFlag(tool, nil); got != "" {
			t.Errorf("%s got assignment flag %q", tool, got)
		}
	}
}

func TestPrepareAgentLaunch(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	directory, err := runtimeDirectory()
	if err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(t.TempDir(), `monkey mux's "binary"`)
	for _, tool := range []string{"claude", "codex", "opencode", "copilot", "cursor-agent", "unknown", "agy", "pi"} {
		for _, resume := range []bool{false, true} {
			args := []string{"--user-option", "unchanged value"}
			if resume {
				if tool == "codex" {
					args = append(args, "resume", "saved")
				} else {
					args = append(args, "--resume", "saved")
				}
			}
			env := []string{"A=1", "OPENCODE_TUI_CONFIG=custom", "OPENCODE_TUI_CONFIG=duplicate"}
			originalArgs, originalEnv := append([]string(nil), args...), append([]string(nil), env...)
			launch, err := prepareAgentLaunch(tool, args, env, executable)
			if err != nil {
				t.Fatal(err)
			}
			var prefix []string
			switch tool {
			case "claude":
				prefix = []string{"--settings", filepath.Join(directory, "monkeymux-claude-hooks.json")}
			case "copilot":
				prefix = []string{"--plugin-dir", filepath.Join(directory, "monkeymux-copilot-plugin")}
			case "cursor-agent":
				prefix = []string{"--plugin-dir", filepath.Join(directory, "monkeymux-cursor-plugin")}
			case "codex":
				prefix = []string{"-c", codexIdentityHookConfig(shellQuote(executable) + " agent-identity-hook --tool codex")}
			}
			assignFlag := agentLaunchSessionIDFlag(tool, args)
			if assignFlag != "" {
				id := launch.assigned.ID
				if !agentSessionIDValid(tool, id) || id[14] != '4' || !strings.ContainsRune("89ab", rune(id[19])) {
					t.Fatalf("not a UUIDv4: %q", id)
				}
				if launch.assigned.Tool != tool || launch.assigned.Source != "assigned" || launch.assigned.File != "" {
					t.Fatalf("bad assignment: %+v", launch.assigned)
				}
				marker := encodeAgentIdentityMarker(launch.assigned)
				payload := strings.TrimSuffix(strings.TrimPrefix(marker, "\x1b]1337;"), "\x07")
				if got, ok := decodeAgentIdentityPayload(payload); !ok || got != launch.assigned {
					t.Fatalf("assignment marker did not decode: %q", marker)
				}
				prefix = append(prefix, assignFlag, id)
			} else if launch.assigned != (agentIdentity{}) {
				t.Fatalf("unexpected assignment for %s %q: %+v", tool, args, launch.assigned)
			}
			if want := append(prefix, args...); !reflect.DeepEqual(launch.args, want) {
				t.Errorf("%s args = %q; want %q", tool, launch.args, want)
			}
			wantEnv := env
			if tool == "opencode" {
				wantEnv = []string{"A=1", "OPENCODE_TUI_CONFIG=" + filepath.Join(directory, "monkeymux-opencode-tui.json")}
			}
			if !reflect.DeepEqual(launch.env, wantEnv) || launch.replacedTUIConfig != (tool == "opencode") {
				t.Errorf("%s environment = %q, replacement = %v", tool, launch.env, launch.replacedTUIConfig)
			}
			if !reflect.DeepEqual(args, originalArgs) || !reflect.DeepEqual(env, originalEnv) {
				t.Fatal("preparation mutated caller input")
			}
		}
	}
	launch, err := prepareAgentLaunch("opencode", nil, []string{"A=1"}, executable)
	if err != nil || launch.replacedTUIConfig {
		t.Fatalf("reported nonexistent TUI config replacement: %+v, %v", launch, err)
	}
}

func TestAgentLaunchGeneratedFiles(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	directory, err := runtimeDirectory()
	if err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(t.TempDir(), `monkey mux's "binary"`)
	for _, tool := range []string{"claude", "copilot", "cursor-agent", "opencode"} {
		if _, err := prepareAgentLaunch(tool, nil, nil, executable); err != nil {
			t.Fatal(err)
		}
	}
	commandJSON := func(tool string) string {
		data, _ := json.Marshal(shellQuote(executable) + " agent-identity-hook --tool " + tool)
		return string(data)
	}
	pluginURL := (&url.URL{Scheme: "file", Path: filepath.ToSlash(filepath.Join(directory, "monkeymux-opencode-identity.mjs"))}).String()
	urlJSON, _ := json.Marshal(pluginURL)
	for relative, want := range map[string]string{
		"monkeymux-claude-hooks.json":                        `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":` + commandJSON("claude") + `,"timeout":5}]}]}}`,
		"monkeymux-copilot-plugin/plugin.json":               `{"name":"monkeymux-identity","version":"1.0.0"}`,
		"monkeymux-copilot-plugin/hooks/hooks.json":          `{"hooks":{"sessionStart":[{"type":"command","bash":` + commandJSON("copilot") + `,"powershell":"exit 0","timeoutSec":5}]}}`,
		"monkeymux-cursor-plugin/.cursor-plugin/plugin.json": `{"name":"monkeymux-identity","version":"1.0.0"}`,
		"monkeymux-cursor-plugin/hooks/hooks.json":           `{"version":1,"hooks":{"sessionStart":[{"command":` + commandJSON("cursor-agent") + `,"timeout":5}]}}`,
		"monkeymux-opencode-tui.json":                        `{"plugin":[` + string(urlJSON) + `]}`,
	} {
		data, err := os.ReadFile(filepath.Join(directory, filepath.FromSlash(relative)))
		if err != nil {
			t.Fatal(err)
		}
		var gotValue, wantValue any
		if err := json.Unmarshal(data, &gotValue); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(gotValue, wantValue) {
			t.Errorf("%s = %s; want %s", relative, data, want)
		}
	}
	plugin, err := os.ReadFile(filepath.Join(directory, "monkeymux-opencode-identity.mjs"))
	if err != nil || string(plugin) != openCodeIdentityPluginSource {
		t.Fatalf("OpenCode source differs, error %v", err)
	}
	old := time.Unix(1000000000, 0)
	err = filepath.Walk(directory, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		wantMode := os.FileMode(0o600)
		if info.IsDir() {
			wantMode = 0o700
		}
		if runtime.GOOS != "windows" && info.Mode().Perm() != wantMode {
			t.Errorf("%s mode = %o; want %o", path, info.Mode().Perm(), wantMode)
		}
		if !info.IsDir() {
			return os.Chtimes(path, old, old)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range []string{"claude", "copilot", "cursor-agent", "opencode"} {
		if _, err := prepareAgentLaunch(tool, nil, nil, executable); err != nil {
			t.Fatal(err)
		}
	}
	if err := filepath.Walk(directory, func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && !info.ModTime().Equal(old) {
			t.Errorf("unchanged file rewritten: %s", path)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "monkeymux-claude-hooks.json")
	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareAgentLaunch("claude", nil, nil, executable); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(path); err != nil || !json.Valid(data) {
		t.Fatalf("stale file not replaced: %s, %v", data, err)
	}
}

func TestCodexIdentityHookConfig(t *testing.T) {
	for _, command := range []string{"'/opt/monkeymux' agent-identity-hook --tool codex", shellQuote(`/path/with spaces/quote'and"slash\monkeymux`) + " agent-identity-hook --tool codex"} {
		value := codexIdentityHookConfig(command)
		const prefix = `hooks.SessionStart=[{hooks=[{type="command",command=`
		const suffix = `,timeout=5}]}]`
		if !strings.HasPrefix(value, prefix) || !strings.HasSuffix(value, suffix) {
			t.Fatalf("wrong TOML shape: %s", value)
		}
		quoted := strings.TrimSuffix(strings.TrimPrefix(value, prefix), suffix)
		if got, err := strconv.Unquote(quoted); err != nil || got != command {
			t.Errorf("TOML string %s decodes to %q, %v; want %q", quoted, got, err, command)
		}
		if strings.Contains(value, "dangerously-bypass-hook-trust") || strings.Contains(value, "notify=") {
			t.Fatalf("unexpected trust override or notify hook: %s", value)
		}
	}
}

func TestWithAgentLaunchEnvironment(t *testing.T) {
	for _, key := range []string{"MONKEYMUX_AGENT_PID", "OPENCODE_TUI_CONFIG"} {
		for _, env := range [][]string{nil, {"A=a=b"}, {key + "=old", "A=1", key + "=duplicate", key + "_OTHER=keep"}} {
			original := append([]string(nil), env...)
			got := withAgentLaunchEnvironment(env, key, "new")
			count := 0
			for _, entry := range got {
				if strings.HasPrefix(entry, key+"=") {
					count++
					if entry != key+"=new" {
						t.Errorf("stale environment entry %q", entry)
					}
				}
			}
			if count != 1 || !reflect.DeepEqual(env, original) {
				t.Fatalf("bad environment result %q, original %q", got, env)
			}
			for _, entry := range original {
				if !strings.HasPrefix(entry, key+"=") {
					found := false
					for _, result := range got {
						found = found || result == entry
					}
					if !found {
						t.Errorf("lost environment entry %q", entry)
					}
				}
			}
		}
	}
}

func TestAgentLaunchPaneTTYOverride(t *testing.T) {
	t.Setenv("MONKEYMUX_PANE_TTY", "/dev/test-pane")
	if got := resolveAgentLaunchPaneTTY(); got != "/dev/test-pane" {
		t.Fatalf("pane tty = %q", got)
	}
}

func TestAgentLaunchPreparationErrors(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "not-a-directory")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_RUNTIME_DIR", file)
	if _, err := prepareAgentLaunch("claude", nil, nil, "/monkeymux"); err == nil {
		t.Fatal("ignored runtime directory error")
	}
	for _, tool := range []string{"unknown", "codex"} {
		if _, err := prepareAgentLaunch(tool, nil, nil, "/monkeymux"); err != nil {
			t.Errorf("%s unnecessarily required runtime files: %v", tool, err)
		}
	}
}

func TestAgentLaunchWrapperExec(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix exec and shell stub")
	}
	bin := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("MONKEYMUX_PANE_TTY", "/dev/test-pane")
	t.Setenv("MONKEYMUX_AGENT_PID", "stale")
	t.Setenv("OPENCODE_TUI_CONFIG", "custom")
	stub := "#!/bin/sh\n" +
		"printf '%s\\n' \"$$\" \"$MONKEYMUX_AGENT_PID\" \"$MONKEYMUX_PANE_TTY\" \"$OPENCODE_TUI_CONFIG\" \"$@\"\n" +
		"cat\nexit 23\n"
	for _, tool := range []string{"claude", "codex", "opencode", "copilot", "cursor-agent", "unknown"} {
		if err := os.WriteFile(filepath.Join(bin, tool), []byte(stub), 0o700); err != nil {
			t.Fatal(err)
		}
		for _, resume := range []bool{false, true} {
			args := []string{"agent-launch", tool}
			if resume {
				args = append(args, "--resume", "existing")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			cmd := exec.CommandContext(ctx, os.Args[0], args...)
			cmd.Stdin = strings.NewReader("inherited stdin\n")
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			err := cmd.Run()
			cancel()
			if exitError, ok := err.(*exec.ExitError); !ok || exitError.ExitCode() != 23 {
				t.Fatalf("%s exit = %v, stderr %q", tool, err, stderr.String())
			}
			output := stdout.String()
			if agentLaunchSessionIDFlag(tool, args[2:]) != "" {
				end := strings.IndexByte(output, '\x07')
				if end < 0 || !strings.HasPrefix(output, "\x1b]1337;") {
					t.Fatalf("missing assigned marker: %q", output)
				}
				identity, ok := decodeAgentIdentityPayload(strings.TrimPrefix(output[:end], "\x1b]1337;"))
				if !ok || identity.Tool != tool || identity.Source != "assigned" || !strings.Contains(output[end+1:], "\n"+identity.ID+"\n") {
					t.Fatalf("assigned marker disagrees with argv: %q", output)
				}
				output = output[end+1:]
			}
			lines := strings.Split(output, "\n")
			pid := strconv.Itoa(cmd.Process.Pid)
			if len(lines) < 6 || lines[0] != pid || lines[1] != pid || lines[2] != "/dev/test-pane" || !strings.HasSuffix(output, "inherited stdin\n") {
				t.Fatalf("%s failed to inherit PID, environment, or stdio: %q", tool, output)
			}
			if tool == "opencode" {
				if !strings.HasSuffix(lines[3], "monkeymux-opencode-tui.json") || !strings.Contains(stderr.String(), "replaced OPENCODE_TUI_CONFIG") || strings.Count(stderr.String(), "\n") != 1 {
					t.Fatalf("OpenCode config replacement: stdout %q, stderr %q", output, stderr.String())
				}
			} else if lines[3] != "custom" || stderr.Len() != 0 {
				t.Fatalf("%s changed TUI config or wrote stderr: %q, %q", tool, output, stderr.String())
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "agent-launch", "missing-agent")
	output, err := cmd.CombinedOutput()
	if exitError, ok := err.(*exec.ExitError); !ok || exitError.ExitCode() != 127 || len(output) == 0 {
		t.Fatalf("missing executable exit = %v, output %q", err, output)
	}
}

func TestPrepareOpenCodeTUIConfig(t *testing.T) {
	for _, tc := range []struct {
		name, source string
		set, merged  bool
	}{
		{name: "unset"},
		{name: "merged", set: true, merged: true, source: `{"theme":"custom","keybinds":{"leader":"ctrl+a"},"large":9007199254740993,"plugin":["user-plugin",["configured-plugin",{"enabled":true}]]}`},
		{name: "unreadable", set: true},
		{name: "array", set: true, source: `[]`},
		{name: "null", set: true, source: `null`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
			var env []string
			source := filepath.Join(t.TempDir(), "custom.json")
			if tc.source != "" {
				if err := os.WriteFile(source, []byte(tc.source), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if tc.set {
				env = []string{"OPENCODE_TUI_CONFIG=" + source}
			}
			launch, err := prepareAgentLaunch("opencode", nil, env, "/monkeymux")
			if err != nil {
				t.Fatal(err)
			}
			if launch.replacedTUIConfig != (tc.set && !tc.merged) {
				t.Fatalf("replacement notice = %v", launch.replacedTUIConfig)
			}
			path := strings.TrimPrefix(launch.env[0], "OPENCODE_TUI_CONFIG=")
			if filepath.Base(path) != "monkeymux-opencode-tui.json" {
				t.Fatalf("unexpected config path: %q", path)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var config map[string]json.RawMessage
			if err := json.Unmarshal(data, &config); err != nil {
				t.Fatal(err)
			}
			var plugins []json.RawMessage
			if err := json.Unmarshal(config["plugin"], &plugins); err != nil {
				t.Fatal(err)
			}
			wantCount := 1
			if tc.merged {
				wantCount = 3
				var original map[string]json.RawMessage
				_ = json.Unmarshal([]byte(tc.source), &original)
				for key, value := range original {
					if key != "plugin" && !bytes.Equal(config[key], value) {
						t.Errorf("changed %s: got %s, want %s", key, config[key], value)
					}
				}
				var originalPlugins []json.RawMessage
				_ = json.Unmarshal(original["plugin"], &originalPlugins)
				if len(plugins) < 2 || !reflect.DeepEqual(plugins[:2], originalPlugins) {
					t.Fatalf("lost caller plugins: %s", config["plugin"])
				}
			}
			if len(plugins) != wantCount {
				t.Fatalf("plugin count = %d, want %d", len(plugins), wantCount)
			}
			var pluginURL string
			_ = json.Unmarshal(plugins[len(plugins)-1], &pluginURL)
			if want := (&url.URL{Scheme: "file", Path: filepath.ToSlash(filepath.Join(filepath.Dir(path), "monkeymux-opencode-identity.mjs"))}).String(); pluginURL != want {
				t.Fatalf("plugin URL = %q, want %q", pluginURL, want)
			}
			// Reusing the merged config must not add the plugin a second time.
			again, err := prepareAgentLaunch("opencode", nil, launch.env, "/monkeymux")
			if err != nil || again.replacedTUIConfig {
				t.Fatalf("repeated merge: %v, notice=%v", err, again.replacedTUIConfig)
			}
			repeated, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(data, repeated) {
				t.Fatalf("repeated merge changed config: %s, %v", repeated, err)
			}
			if tc.source != "" {
				original, err := os.ReadFile(source)
				if err != nil || string(original) != tc.source {
					t.Fatal("modified caller's config file")
				}
			}
		})
	}
}

func TestAgentLaunchWrapperExecutable(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix exec and shell stub")
	}
	bin := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	stub := filepath.Join(bin, "claude-code")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	// A different canonical executable must never be selected.
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte("#!/bin/sh\nexit 99\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, executable := range []string{"claude-code", stub, "./claude-code"} {
		t.Run(executable, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "agent-launch", "claude", "--executable", executable, "--resume", "saved", "--executable", "agent-argument")
			cmd.Dir = bin
			output, err := cmd.CombinedOutput()
			if err != nil || !strings.HasPrefix(string(output), "--settings\n") || !strings.HasSuffix(string(output), "--resume\nsaved\n--executable\nagent-argument\n") {
				t.Fatalf("wrapper executable/args: %v, %q", err, output)
			}
		})
	}
	for _, args := range [][]string{{"--executable"}, {"--executable", ""}} {
		cmd := exec.Command(os.Args[0], append([]string{"agent-launch", "claude"}, args...)...)
		output, err := cmd.CombinedOutput()
		if exitErr, ok := err.(*exec.ExitError); !ok || exitErr.ExitCode() != 2 || !strings.Contains(string(output), "requires a command") {
			t.Fatalf("invalid executable flag: %v, %q", err, output)
		}
	}
}
