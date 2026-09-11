package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
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

const identityTestID = "01234567-89ab-cdef-0123-456789abcdef"
const identityTestOtherID = "fedcba98-7654-3210-fedc-ba9876543210"

func identityTestPayload(identity agentIdentity) string {
	return strings.TrimSuffix(strings.TrimPrefix(encodeAgentIdentityMarker(identity), "\x1b]1337;"), "\x07")
}

func TestAgentSessionIDValid(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "copilot", "cursor-agent", "antigravity"} {
		for _, id := range []string{identityTestID, strings.ToUpper(identityTestID)} {
			if !agentSessionIDValid(tool, id) {
				t.Errorf("rejected %s %q", tool, id)
			}
		}
		for _, id := range []string{"", "x", identityTestID + "\n", " " + identityTestID, strings.ReplaceAll(identityTestID, "-", ""), "g" + identityTestID[1:], "../" + identityTestID} {
			if agentSessionIDValid(tool, id) {
				t.Errorf("accepted %s %q", tool, id)
			}
		}
	}
	for _, tc := range []struct {
		tool, id string
		valid    bool
	}{
		{"opencode", "ses_Abc123", true}, {"opencode", "ses_" + strings.Repeat("a", 60), true},
		{"opencode", "ses_" + strings.Repeat("a", 61), false}, {"opencode", "ses_", false},
		{"opencode", "ses_a-b", false}, {"opencode", "ses_a\n", false}, {"opencode", identityTestID, false},
		{"pi", "session_1.A-b", true}, {"pi", strings.Repeat("a", 256), true},
		{"pi", strings.Repeat("a", 257), false}, {"pi", ".hidden", false}, {"pi", "a/b", false},
		{"unknown", identityTestID, false}, {"Claude", identityTestID, false},
	} {
		if got := agentSessionIDValid(tc.tool, tc.id); got != tc.valid {
			t.Errorf("%s %q = %v", tc.tool, tc.id, got)
		}
	}
}

func TestAgentIdentityMarkerRoundTrip(t *testing.T) {
	file := filepath.Join(t.TempDir(), "not-created.jsonl")
	for _, identity := range []agentIdentity{
		{Tool: "claude", ID: identityTestID, File: file, Source: "fork"},
		{Tool: "codex", ID: identityTestID}, {Tool: "copilot", ID: identityTestID, Source: "assigned"},
		{Tool: "cursor-agent", ID: identityTestID}, {Tool: "antigravity", ID: identityTestID},
		{Tool: "opencode", ID: "ses_Abc123"}, {Tool: "pi", ID: "pi-session_1"},
	} {
		marker := encodeAgentIdentityMarker(identity)
		if !strings.HasPrefix(marker, "\x1b]1337;MonkeyMuxAgent=") || !strings.HasSuffix(marker, "\x07") {
			t.Fatalf("bad framing %q", marker)
		}
		got, ok := decodeAgentIdentityPayload(identityTestPayload(identity))
		if !ok || got != identity {
			t.Fatalf("round trip = %+v, %v; want %+v", got, ok, identity)
		}
	}
	for _, file := range []string{"relative.jsonl", filepath.Dir(file) + string(os.PathSeparator) + ".." + string(os.PathSeparator) + "session.jsonl", file + "\x00"} {
		if _, ok := decodeAgentIdentityPayload(identityTestPayload(agentIdentity{Tool: "claude", ID: identityTestID, File: file})); ok {
			t.Errorf("accepted path %q", file)
		}
	}
	for _, value := range []string{"", "MonkeyMuxPi=e30", "1337;MonkeyMuxAgent=e30", "MonkeyMuxAgent=!!!", "MonkeyMuxAgent=e30", "MonkeyMuxAgent=" + base64.RawURLEncoding.EncodeToString([]byte(`{"tool":"claude","id":123}`)), "MonkeyMuxAgent=" + strings.Repeat("a", oscBufferLimitBytes)} {
		if _, ok := decodeAgentIdentityPayload(value); ok {
			t.Errorf("accepted invalid payload of length %d", len(value))
		}
	}
}

func TestAgentIdentityFromHookPayload(t *testing.T) {
	file := filepath.Join(t.TempDir(), "future.jsonl")
	cases := []struct {
		name, tool, payload, notify string
		want                        agentIdentity
		valid                       bool
	}{
		{name: "claude startup", tool: "claude", payload: `{"hook_event_name":"SessionStart","session_id":"ID","transcript_path":FILE,"source":"startup"}`, want: agentIdentity{Tool: "claude", ID: identityTestID, File: file, Source: "startup"}, valid: true},
		{name: "claude clear", tool: "claude", payload: `{"hook_event_name":"SessionStart","session_id":"ID","source":"clear"}`, want: agentIdentity{Tool: "claude", ID: identityTestID, Source: "clear"}, valid: true},
		{name: "claude subagent", tool: "claude", payload: `{"hook_event_name":"SessionStart","session_id":"ID","agent_id":"child"}`},
		{name: "claude wrong event", tool: "claude", payload: `{"hook_event_name":"Stop","session_id":"ID"}`},
		{name: "codex null transcript", tool: "codex", payload: `{"hook_event_name":"SessionStart","session_id":"ID","transcript_path":null,"source":"startup"}`, want: agentIdentity{Tool: "codex", ID: identityTestID, Source: "startup"}, valid: true},
		{name: "codex resume", tool: "codex", payload: `{"hook_event_name":"SessionStart","session_id":"ID","source":"resume"}`, want: agentIdentity{Tool: "codex", ID: identityTestID, Source: "resume"}, valid: true},
		{name: "codex wrong source", tool: "codex", payload: `{"hook_event_name":"SessionStart","session_id":"ID","source":"clear"}`},
		{name: "codex missing source", tool: "codex", payload: `{"hook_event_name":"SessionStart","session_id":"ID"}`},
		{name: "codex wrong event", tool: "codex", payload: `{"hook_event_name":"Stop","session_id":"ID","source":"startup"}`},
		{name: "codex notify", tool: "codex", payload: `bad stdin ignored`, notify: `{"type":"agent-turn-complete","thread-id":"ID"}`, want: agentIdentity{Tool: "codex", ID: identityTestID, Source: "turn"}, valid: true},
		{name: "codex notify ignores oversized stdin", tool: "codex", payload: strings.Repeat("x", agentIdentityHookInputLimit+1), notify: `{"type":"agent-turn-complete","thread-id":"ID"}`, want: agentIdentity{Tool: "codex", ID: identityTestID, Source: "turn"}, valid: true},
		{name: "codex wrong notify", tool: "codex", notify: `{"type":"other","thread-id":"ID"}`},
		{name: "codex invalid notify", tool: "codex", notify: `{`},
		{name: "copilot new", tool: "copilot", payload: `{"sessionId":"ID","source":"new","cwd":"/work"}`, want: agentIdentity{Tool: "copilot", ID: identityTestID, Source: "new"}, valid: true},
		{name: "copilot startup", tool: "copilot", payload: `{"sessionId":"ID","source":"startup","cwd":"/work"}`, want: agentIdentity{Tool: "copilot", ID: identityTestID, Source: "startup"}, valid: true},
		{name: "copilot resume", tool: "copilot", payload: `{"sessionId":"ID","source":"resume","cwd":"/work"}`, want: agentIdentity{Tool: "copilot", ID: identityTestID, Source: "resume"}, valid: true},
		{name: "copilot wrong source", tool: "copilot", payload: `{"sessionId":"ID","source":"clear"}`},
		{name: "cursor foreground", tool: "cursor-agent", payload: `{"hook_event_name":"sessionStart","session_id":"ID","is_background_agent":false,"transcript_path":FILE}`, want: agentIdentity{Tool: "cursor-agent", ID: identityTestID, File: file}, valid: true},
		{name: "cursor conversation", tool: "cursor-agent", payload: `{"hook_event_name":"sessionStart","conversation_id":"ID"}`, want: agentIdentity{Tool: "cursor-agent", ID: identityTestID}, valid: true},
		{name: "cursor id precedence", tool: "cursor-agent", payload: `{"hook_event_name":"sessionStart","session_id":"ID","conversation_id":"other"}`, want: agentIdentity{Tool: "cursor-agent", ID: identityTestID}, valid: true},
		{name: "cursor background", tool: "cursor-agent", payload: `{"hook_event_name":"sessionStart","session_id":"ID","is_background_agent":true}`},
		{name: "cursor null background", tool: "cursor-agent", payload: `{"hook_event_name":"sessionStart","session_id":"ID","is_background_agent":null}`},
		{name: "cursor wrong event", tool: "cursor-agent", payload: `{"hook_event_name":"SessionStart","session_id":"ID"}`},
		{name: "cursor malformed bool", tool: "cursor-agent", payload: `{"hook_event_name":"sessionStart","session_id":"ID","is_background_agent":"false"}`},
		{name: "invalid id", tool: "claude", payload: `{"hook_event_name":"SessionStart","session_id":"../bad"}`},
		{name: "relative path", tool: "claude", payload: `{"hook_event_name":"SessionStart","session_id":"ID","transcript_path":"relative.jsonl"}`},
		{name: "missing id", tool: "claude", payload: `{"hook_event_name":"SessionStart"}`},
		{name: "empty", tool: "claude"}, {name: "malformed", tool: "claude", payload: `{`},
		{name: "array", tool: "claude", payload: `[]`}, {name: "null", tool: "claude", payload: `null`},
		{name: "unknown", tool: "other", payload: `{"session_id":"ID"}`},
		{name: "too large", tool: "claude", payload: strings.Repeat(" ", agentIdentityHookInputLimit+1)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			quotedFile, _ := json.Marshal(file)
			payload := strings.ReplaceAll(strings.ReplaceAll(tc.payload, "ID", identityTestID), "FILE", string(quotedFile))
			got, ok := agentIdentityFromHookPayload(tc.tool, []byte(payload), strings.ReplaceAll(tc.notify, "ID", identityTestID))
			if ok != tc.valid || ok && got != tc.want {
				t.Fatalf("got %+v, %v; want %+v, %v", got, ok, tc.want, tc.valid)
			}
		})
	}
}

func TestApplyAgentIdentityPayloadLocked(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	w := &muxWindow{agentTool: "claude", agentToolConfirmed: true, agentSessionWatch: &agentSessionWatch{tool: "claude"}}
	server := &muxServer{windows: []*muxWindow{w}}
	apply := func(id, source, file string) {
		server.observeAgentIdentityMetadataLocked(w, []byte(encodeAgentIdentityMarker(agentIdentity{Tool: "claude", ID: id, Source: source, File: file})))
	}
	apply(identityTestID, "assigned", path)
	if w.agentSessionID != identityTestID || w.agentSessionIdentityExact || !w.agentSessionAssigned || w.agentSessionPath != "" {
		t.Fatalf("assigned = %+v", w)
	}
	apply(identityTestOtherID, "startup", path)
	if w.agentSessionID != identityTestOtherID || !w.agentSessionIdentityExact || w.agentSessionAssigned || w.agentSessionPath != path || w.agentSessionDir != filepath.Dir(path) {
		t.Fatalf("exact = %+v", w)
	}
	if !w.agentSessionWatch.done {
		t.Fatal("hook did not finish the provisional watcher")
	}
	apply(identityTestID, "assigned", "")
	if w.agentSessionID != identityTestOtherID || !w.agentSessionIdentityExact || w.agentSessionAssigned {
		t.Fatal("assigned replaced exact")
	}
	apply(identityTestID, "clear", "")
	if w.agentSessionID != identityTestID || !w.agentSessionIdentityExact || w.agentSessionPath != "" || w.agentSessionDir != "" {
		t.Fatal("clear did not replace exact identity and clear old path")
	}
	if w.agentIdentityServer != nil {
		t.Fatal("parser retained transient server")
	}
	for _, tc := range []struct {
		name     string
		window   *muxWindow
		tool     string
		accepted bool
	}{
		{"command matches", &muxWindow{command: "claude"}, "claude", true},
		{"confirmed mismatch", &muxWindow{agentTool: "codex", agentToolConfirmed: true}, "claude", false},
		{"command mismatch", &muxWindow{command: "codex", agentTool: "claude"}, "claude", false},
		{"confirmed match", &muxWindow{command: "zsh", agentTool: "claude", agentToolConfirmed: true}, "claude", true},
		// Only positive evidence binds: a guessed or unknown tool must not let
		// printed output (a file containing a marker) create an agent session.
		{"unconfirmed guess", &muxWindow{command: "zsh", agentTool: "codex"}, "claude", false},
		{"unconfirmed same guess", &muxWindow{command: "zsh", agentTool: "claude"}, "claude", false},
		{"empty tool", &muxWindow{command: "zsh"}, "claude", false},
		{"shell printing a marker", &muxWindow{command: "cat", name: "claude"}, "claude", false},
		{"closed", &muxWindow{agentTool: "claude", closed: true}, "claude", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.window.applyAgentIdentityPayloadLocked(identityTestPayload(agentIdentity{Tool: tc.tool, ID: identityTestID}))
			if got := tc.window.agentSessionID != ""; got != tc.accepted {
				t.Fatalf("accepted = %v", got)
			}
			if tc.accepted && (!tc.window.agentToolConfirmed || tc.window.agentTool != tc.tool) {
				t.Fatal("tool not confirmed")
			}
		})
	}
}

func TestAgentIdentityExclusivity(t *testing.T) {
	for _, tc := range []struct {
		name                            string
		exact, assigned, closed, exited bool
		tool                            string
		taken                           bool
	}{
		{name: "exact", exact: true, tool: "claude", taken: true}, {name: "provisional", assigned: true, tool: "claude", taken: true},
		{name: "inferred", tool: "claude"}, {name: "closed", exact: true, closed: true, tool: "claude"},
		{name: "exited", exact: true, exited: true, tool: "claude"}, {name: "other tool", exact: true, tool: "copilot"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, source := range []string{"startup", "assigned"} {
				w := &muxWindow{agentTool: "claude", agentToolConfirmed: true}
				other := &muxWindow{agentTool: tc.tool, agentSessionID: identityTestID, agentSessionIdentityExact: tc.exact, agentSessionAssigned: tc.assigned, closed: tc.closed, agentSessionWatch: &agentSessionWatch{exited: tc.exited}}
				s := &muxServer{windows: []*muxWindow{other, w}}
				s.observeAgentIdentityMetadataLocked(w, []byte(encodeAgentIdentityMarker(agentIdentity{Tool: "claude", ID: identityTestID, Source: source})))
				if got := w.agentSessionID == ""; got != tc.taken {
					t.Fatalf("source %s refused = %v, want %v", source, got, tc.taken)
				}
				if s.agentSessionIDTakenLocked(tc.tool, identityTestID, other) && w.agentSessionID == "" {
					t.Fatal("owner conflicts with itself")
				}
			}
		})
	}
}

func writeIdentityTestStoreFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestAgentSessionExistsInStore(t *testing.T) {
	for _, tc := range []struct {
		name, tool, relative, contents string
		directory, exists              bool
	}{
		{name: "claude transcript", tool: "claude", relative: ".claude/projects/project/ID.jsonl", exists: true},
		{name: "claude registry", tool: "claude", relative: ".claude/sessions/process.json", contents: `{"sessionId":"ID"}`, exists: true},
		{name: "wrong registry id", tool: "claude", relative: ".claude/sessions/process.json", contents: `{"sessionId":"other"}`},
		{name: "bad registry", tool: "claude", relative: ".claude/sessions/process.json", contents: `{`},
		{name: "nested subagent", tool: "claude", relative: ".claude/projects/project/child/ID.jsonl"},
		{name: "transcript directory", tool: "claude", relative: ".claude/projects/project/ID.jsonl", directory: true},
		{name: "copilot directory", tool: "copilot", relative: ".copilot/session-state/ID", directory: true, exists: true},
		{name: "copilot file", tool: "copilot", relative: ".copilot/session-state/ID"},
		{name: "cursor metadata", tool: "cursor-agent", relative: ".cursor/chats/project/ID/meta.json", exists: true},
		{name: "cursor missing metadata", tool: "cursor-agent", relative: ".cursor/chats/project/ID", directory: true},
		{name: "unsupported", tool: "codex", relative: ".codex/sessions/ID.jsonl"},
		{name: "missing", tool: "claude"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := filepath.Join(t.TempDir(), "home[with]glob")
			setTestHomeDir(t, home)
			if tc.relative != "" {
				path := filepath.Join(home, filepath.FromSlash(strings.ReplaceAll(tc.relative, "ID", identityTestID)))
				if tc.directory {
					if err := os.MkdirAll(path, 0700); err != nil {
						t.Fatal(err)
					}
				} else {
					writeIdentityTestStoreFile(t, path, strings.ReplaceAll(tc.contents, "ID", identityTestID))
				}
			}
			if got := agentSessionExistsInStore(tc.tool, identityTestID); got != tc.exists {
				t.Fatalf("exists = %v", got)
			}
			if agentSessionExistsInStore(tc.tool, "../invalid") {
				t.Fatal("accepted unsafe id")
			}
		})
	}
}

func TestAgentIdentityRestoreSnapshot(t *testing.T) {
	for _, tc := range []struct {
		name                                string
		assigned, exact, exists, otherOwner bool
		keep                                bool
	}{
		{name: "missing provisional", assigned: true}, {name: "created provisional", assigned: true, exists: true, keep: true},
		{name: "exact without store", exact: true, keep: true}, {name: "inferred unchanged", keep: true},
		{name: "duplicate provisional", assigned: true, exists: true, otherOwner: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			setTestHomeDir(t, home)
			if tc.exists {
				writeIdentityTestStoreFile(t, filepath.Join(home, ".claude", "projects", "project", identityTestID+".jsonl"), "")
			}
			w := &muxWindow{id: "@1", agentTool: "claude", agentToolConfirmed: true, agentSessionID: identityTestID, agentSessionAssigned: tc.assigned, agentSessionIdentityExact: tc.exact, agentSessionPath: filepath.Join(home, "old.jsonl"), agentSessionDir: home}
			s := newMuxServer("test")
			s.windows = []*muxWindow{w}
			if tc.otherOwner {
				s.windows = append(s.windows, &muxWindow{id: "@2", agentTool: "claude", agentSessionID: identityTestID, agentSessionIdentityExact: true})
			}
			restore := s.restoreSnapshot()
			state := restore.Windows[0]
			if got := state.AgentSessionID != ""; got != tc.keep {
				t.Fatalf("kept = %v, state = %+v", got, state)
			}
			if !tc.keep && (state.AgentSessionPath != "" || state.AgentSessionDir != "") {
				t.Fatal("cleared id retained stale path")
			}
			if w.agentSessionID != identityTestID {
				t.Fatal("snapshot mutated live window")
			}
			if tc.assigned || tc.exact {
				enrichRestoreWithAgentSessionIDs(restore)
				if got := restore.Windows[0].AgentSessionID != ""; got != tc.keep {
					t.Fatalf("enrichment kept = %v, want %v", got, tc.keep)
				}
			}
		})
	}
}

func TestProtectProvisionalAgentSessionBindings(t *testing.T) {
	home := t.TempDir()
	setTestHomeDir(t, home)
	for _, id := range []string{identityTestID, identityTestOtherID} {
		writeIdentityTestStoreFile(t, filepath.Join(home, ".claude", "projects", "p", id+".jsonl"), "")
	}
	restore := &serverRestore{Windows: []restoreWindowState{
		{AgentTool: "claude", AgentSessionID: identityTestID, AgentSessionAssigned: true},
		{AgentTool: "claude"},
	}}
	protect := protectProvisionalAgentSessionBindings(restore)
	restore.Windows[0].AgentSessionID = identityTestOtherID
	restore.Windows[1].AgentSessionID = identityTestOtherID
	protect()
	if restore.Windows[0].AgentSessionID != identityTestOtherID {
		t.Fatal("inference could not replace provisional")
	}
	if restore.Windows[1].AgentSessionID != "" {
		t.Fatal("inference duplicated provisional")
	}
}

func TestAgentIdentityOSCFiltering(t *testing.T) {
	for _, end := range []string{"\x07", "\x1b\\"} {
		marker := strings.TrimSuffix(encodeAgentIdentityMarker(agentIdentity{Tool: "claude", ID: identityTestID}), "\x07") + end
		if !isReplayUnsafeOscNotification([]byte("1337;" + identityTestPayload(agentIdentity{Tool: "claude", ID: identityTestID}))) {
			t.Fatal("generic identity replayed")
		}
		if got := string(stripTerminalQueriesFromReplay([]byte("before" + marker + "after"))); got != "beforeafter" {
			t.Fatalf("replay = %q", got)
		}
		for split := 1; split < len(marker); split++ {
			w := &muxWindow{}
			first := w.stripLocallyAnsweredThemeQueriesLocked([]byte("before"+marker[:split]), nil)
			second := w.stripLocallyAnsweredThemeQueriesLocked([]byte(marker[split:]+"after"), nil)
			if got := string(first) + string(second); got != "beforeafter" {
				t.Fatalf("split %d output = %q", split, got)
			}
		}
	}
	if isReplayUnsafeOscNotification([]byte("1337;File=abc")) {
		t.Fatal("ordinary iTerm marker filtered")
	}
	w := &muxWindow{}
	if got := string(w.stripLocallyAnsweredThemeQueriesLocked([]byte("a\x1b]1337;MonkeyMuxAgent=invalid\x07b"), nil)); got != "ab" {
		t.Fatalf("invalid private marker leaked: %q", got)
	}
}

func TestWithPaneTTYEnvironment(t *testing.T) {
	for _, tc := range []struct {
		name      string
		env, want []string
	}{
		{"nil", nil, []string{"MONKEYMUX_PANE_TTY=/dev/test"}},
		{"append", []string{"A=1"}, []string{"A=1", "MONKEYMUX_PANE_TTY=/dev/test"}},
		{"replace duplicates", []string{"MONKEYMUX_PANE_TTY=/dev/old", "A=1", "MONKEYMUX_PANE_TTY=/dev/stale"}, []string{"A=1", "MONKEYMUX_PANE_TTY=/dev/test"}},
		{"preserve other keys", []string{"MONKEYMUX_PANE_TTY_OTHER=x", "A=a=b"}, []string{"MONKEYMUX_PANE_TTY_OTHER=x", "A=a=b", "MONKEYMUX_PANE_TTY=/dev/test"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			original := append([]string(nil), tc.env...)
			if got := withPaneTTYEnvironment(tc.env, "/dev/test"); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
			if !reflect.DeepEqual(tc.env, original) {
				t.Fatal("mutated input")
			}
		})
	}
}

// Invoke the command in a separate process so stdin/stdout and environment
// handling are exercised without replacing the test runner's descriptors.
func TestAgentIdentityHookProcess(t *testing.T) {
	if os.Getenv("MONKEYMUX_IDENTITY_TEST_PROCESS") != "1" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			agentIdentityHookCommand(os.Args[i+1:])
			os.Exit(0)
		}
	}
	os.Exit(2)
}

func identityHookTestCommand(t *testing.T, args ...string) *exec.Cmd {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	cmd := exec.CommandContext(ctx, os.Args[0], append([]string{"-test.run=^TestAgentIdentityHookProcess$", "--"}, args...)...)
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "MONKEYMUX_AGENT_PID=") && !strings.HasPrefix(value, "MONKEYMUX_PANE_TTY=") {
			cmd.Env = append(cmd.Env, value)
		}
	}
	cmd.Env = append(cmd.Env, "MONKEYMUX_IDENTITY_TEST_PROCESS=1", "MONKEYMUX_PANE_TTY=/dev/monkeymux-nonexistent")
	return cmd
}

func TestAgentIdentityHookAlwaysAcknowledges(t *testing.T) {
	for _, tc := range []struct {
		name  string
		args  []string
		stdin string
	}{
		{"unknown", []string{"--tool", "unknown"}, ""}, {"bad flag", []string{"--bad"}, ""},
		{"missing tool", []string{"--tool"}, ""}, {"malformed", []string{"--tool", "claude"}, "{"},
		{"oversized", []string{"--tool", "claude"}, strings.Repeat("a", agentIdentityHookInputLimit+1)},
		{"valid but unavailable tty", []string{"--tool", "claude"}, `{"hook_event_name":"SessionStart","session_id":"` + identityTestID + `"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := identityHookTestCommand(t, tc.args...)
			cmd.Stdin = strings.NewReader(tc.stdin)
			output, err := cmd.CombinedOutput()
			if err != nil || string(output) != "{}\n" {
				t.Fatalf("output %q, error %v", output, err)
			}
		})
	}
}

func TestAgentIdentityPaneTTYTransport(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix pane tty transport")
	}
	pane := exec.Command("/bin/sh", "-c", `exec cat`)
	pane.Env = withPaneTTYEnvironment(os.Environ(), "/dev/stale")
	master, process, err := startWindow(pane, 91, 37)
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer process.Wait()
	defer process.Kill()
	var ttyPath string
	for _, value := range pane.Env {
		if strings.HasPrefix(value, "MONKEYMUX_PANE_TTY=") {
			ttyPath = strings.TrimPrefix(value, "MONKEYMUX_PANE_TTY=")
		}
	}
	if ttyPath == "" || ttyPath == "/dev/stale" {
		t.Fatal("missing slave environment")
	}
	cmd := identityHookTestCommand(t, "--tool", "claude")
	cmd.Env = withPaneTTYEnvironment(cmd.Env, ttyPath)
	cmd.Env = append(cmd.Env, "MONKEYMUX_AGENT_PID="+strconv.Itoa(os.Getpid()))
	cmd.Stdin = strings.NewReader(`{"hook_event_name":"SessionStart","session_id":"` + identityTestID + `","source":"startup"}`)
	output, err := cmd.CombinedOutput()
	if err != nil || string(output) != "{}\n" {
		t.Fatalf("hook output %q, error %v", output, err)
	}
	want := encodeAgentIdentityMarker(agentIdentity{Tool: "claude", ID: identityTestID, Source: "startup"})
	result := make(chan string, 1)
	go func() { buf := make([]byte, len(want)); _, _ = io.ReadFull(master, buf); result <- string(buf) }()
	select {
	case got := <-result:
		if got != want {
			t.Fatalf("pane output = %q, want %q", got, want)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("detached hook did not write pane marker")
	}
	// A terminal stdin must never make the hook wait for input.
	slave, err := os.Open(ttyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer slave.Close()
	cmd = identityHookTestCommand(t, "--tool", "claude")
	cmd.Stdin = slave
	output, err = cmd.CombinedOutput()
	if err != nil || string(output) != "{}\n" {
		t.Fatalf("tty stdin output %q, error %v", output, err)
	}
}

func TestStartWindowPaneTTYAndSize(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix pane tty environment")
	}
	for _, inherit := range []bool{false, true} {
		t.Run(fmt.Sprint(inherit), func(t *testing.T) {
			t.Setenv("MONKEYMUX_PANE_TTY", "/dev/inherited")
			cmd := exec.Command("/bin/sh", "-c", `test "$MONKEYMUX_PANE_TTY" = "$(tty)" && stty size`)
			if !inherit {
				cmd.Env = []string{"PATH=/usr/bin:/bin", "MONKEYMUX_PANE_TTY=/dev/old"}
			}
			master, process, err := startWindow(cmd, 91, 37)
			if err != nil {
				t.Fatal(err)
			}
			defer master.Close()
			defer process.Kill()
			result := make(chan []byte, 1)
			go func() { data, _ := io.ReadAll(master); result <- data }()
			if err := process.Wait(); err != nil {
				t.Fatal(err)
			}
			select {
			case got := <-result:
				if !bytes.Contains(got, []byte("37 91")) {
					t.Fatalf("terminal dimensions = %q", got)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("pane output timed out")
			}
		})
	}
}

func TestAgentIdentityHookAncestryMatches(t *testing.T) {
	t.Setenv("MONKEYMUX_AGENT_PID", "")
	if err := os.Unsetenv("MONKEYMUX_AGENT_PID"); err != nil {
		t.Fatal(err)
	}
	if !agentIdentityHookAncestryMatches() {
		t.Fatal("unset guard rejected hook")
	}
	for _, value := range []string{"", "0", "-1", "not-a-pid"} {
		t.Setenv("MONKEYMUX_AGENT_PID", value)
		if agentIdentityHookAncestryMatches() {
			t.Fatalf("accepted invalid ancestor %q", value)
		}
	}
	if runtime.GOOS == "windows" {
		return
	}
	t.Setenv("MONKEYMUX_AGENT_PID", strconv.Itoa(os.Getppid()))
	if !agentIdentityHookAncestryMatches() {
		t.Fatal("parent rejected")
	}
	t.Setenv("MONKEYMUX_AGENT_PID", strconv.Itoa(os.Getpid()))
	if agentIdentityHookAncestryMatches() {
		t.Fatal("self accepted as ancestor")
	}
	output, err := exec.Command("ps", "-o", "ppid=", "-p", strconv.Itoa(os.Getppid())).Output()
	if err != nil {
		t.Skipf("grandparent lookup unavailable: %v", err)
	}
	grandparent, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil || grandparent <= 0 {
		t.Skip("no grandparent process")
	}
	t.Setenv("MONKEYMUX_AGENT_PID", strconv.Itoa(grandparent))
	if !agentIdentityHookAncestryMatches() {
		t.Fatal("grandparent rejected")
	}
}
