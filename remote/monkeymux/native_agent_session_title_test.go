package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const nativeTitleTestSessionID = "5f0c7d1e-2b3a-4c8d-9e6f-0a1b2c3d4e5f"

func TestClaudeSessionTitleScanFollowsClaudesTitlePrecedence(t *testing.T) {
	home := t.TempDir()
	project := filepath.Join(home, ".claude", "projects", "-work-repo")
	if err := os.MkdirAll(project, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(project, nativeTitleTestSessionID+".jsonl")
	var scan claudeSessionTitleScan
	now := time.Now()
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "" {
		t.Fatalf("title before the file exists = %q", got)
	}

	appendPiTitleTestRecords(t, path,
		`{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignored</local-command-caveat>"}}`+"\n",
		`{"type":"user","message":{"role":"user","content":"/model sonnet"}}`+"\n",
		`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the   flaky\nbuild"}]}}`+"\n",
		`{"type":"user","message":{"role":"user","content":"Second ask"}}`+"\n",
	)
	// The file is found once, then followed without another directory search.
	now = now.Add(nativeAgentSessionLookupInterval)
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "Fix the flaky build" {
		t.Fatalf("first prompt title = %q", got)
	}
	appendPiTitleTestRecords(t, path, `{"type":"last-prompt","lastPrompt":"Second ask","sessionId":"x"}`+"\n")
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "Second ask" {
		t.Fatalf("last prompt title = %q", got)
	}
	appendPiTitleTestRecords(t, path, `{"type":"ai-title","aiTitle":"Fixing the flaky build","sessionId":"x"}`+"\n")
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "Fixing the flaky build" {
		t.Fatalf("generated title = %q", got)
	}
	// A record still being written is read once its newline lands.
	appendPiTitleTestRecords(t, path, `{"type":"custom-title","customTitle":"Build`)
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "Fixing the flaky build" {
		t.Fatalf("title with a partial record = %q", got)
	}
	appendPiTitleTestRecords(t, path, ` fix","sessionId":"x"}`+"\n",
		`{"type":"ai-title","aiTitle":"A later generated title","sessionId":"x"}`+"\n")
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "Build fix" {
		t.Fatalf("renamed title = %q", got)
	}

	// A rewritten (shorter) file is read again from the start.
	if err := os.WriteFile(path, []byte(`{"type":"user","message":{"role":"user","content":"Fresh start"}}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := scan.title(home, nativeTitleTestSessionID, now); got != "Fresh start" {
		t.Fatalf("title after a rewrite = %q", got)
	}
	if got := claudeSessionFile(home, "../escape"); got != "" {
		t.Fatalf("unsafe session id path = %q", got)
	}
}

func TestCodexSessionTitleScanPrefersTheThreadName(t *testing.T) {
	codexHome := t.TempDir()
	day := filepath.Join(codexHome, "sessions", "2026", "10", "01")
	older := filepath.Join(codexHome, "sessions", "2026", "09", "30")
	for _, directory := range []string{day, older} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	appendPiTitleTestRecords(t, filepath.Join(older, "rollout-2026-09-30T08-00-00-other.jsonl"),
		`{"type":"event_msg","payload":{"type":"user_message","message":"Wrong session"}}`+"\n")
	rollout := filepath.Join(day, "rollout-2026-10-01T09-00-00-"+nativeTitleTestSessionID+".jsonl")
	var scan codexSessionTitleScan
	now := time.Now()
	if got := scan.title(codexHome, nativeTitleTestSessionID, now); got != "" {
		t.Fatalf("title before the first turn = %q", got)
	}

	// Codex writes the rollout on the first turn; the miss is retried.
	appendPiTitleTestRecords(t, rollout,
		`{"type":"session_meta","payload":{"id":"`+nativeTitleTestSessionID+`"}}`+"\n",
		`{"type":"event_msg","payload":{"type":"user_message","message":"Add a retry to the uploader"}}`+"\n",
		`{"type":"event_msg","payload":{"type":"user_message","message":"Then run the tests"}}`+"\n",
	)
	now = now.Add(nativeAgentSessionLookupInterval)
	if got := scan.title(codexHome, nativeTitleTestSessionID, now); got != "Add a retry to the uploader" {
		t.Fatalf("first message title = %q", got)
	}

	index := filepath.Join(codexHome, "session_index.jsonl")
	appendPiTitleTestRecords(t, index,
		`{"id":"other","thread_name":"Not this one","updated_at":"2026-10-01T09:00:00Z"}`+"\n",
		`{"id":"`+nativeTitleTestSessionID+`","thread_name":"Uploader retries","updated_at":"2026-10-01T09:01:00Z"}`+"\n",
	)
	if got := scan.title(codexHome, nativeTitleTestSessionID, now); got != "Uploader retries" {
		t.Fatalf("thread name title = %q", got)
	}
	appendPiTitleTestRecords(t, index,
		`{"id":"`+nativeTitleTestSessionID+`","thread_name":"Uploader backoff","updated_at":"2026-10-01T09:02:00Z"}`+"\n")
	if got := scan.title(codexHome, nativeTitleTestSessionID, now); got != "Uploader backoff" {
		t.Fatalf("renamed thread title = %q", got)
	}
}

func TestCodexSessionTitleScanSkipsInjectedContext(t *testing.T) {
	codexHome := t.TempDir()
	day := filepath.Join(codexHome, "sessions", "2026", "10", "01")
	if err := os.MkdirAll(day, 0o700); err != nil {
		t.Fatal(err)
	}
	// Codex 0.160 logs prompts only as response items, after the AGENTS.md
	// and environment context it sends as user messages.
	appendPiTitleTestRecords(t, filepath.Join(day, "rollout-2026-10-01T09-00-00-"+nativeTitleTestSessionID+".jsonl"),
		`{"type":"session_meta","payload":{"id":"`+nativeTitleTestSessionID+`","originator":"monkeyssh"}}`+"\n",
		`{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Developer text"}]}}`+"\n",
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[`+
			`{"type":"input_text","text":"# AGENTS.md instructions for /work"},`+
			`{"type":"input_text","text":"<environment_context>\\n<cwd>/work</cwd>"}]}}`+"\n",
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[`+
			`{"type":"input_text","text":"<image name=[Image #1]>"},`+
			`{"type":"input_image","image_url":"data:"},`+
			`{"type":"input_text","text":"</image>"},`+
			`{"type":"input_text","text":"  <div> breaks the layout  "}]}}`+"\n",
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Second prompt"}]}}`+"\n",
	)
	var scan codexSessionTitleScan
	// A prompt that starts with markup is still the user's.
	if got := scan.title(codexHome, nativeTitleTestSessionID, time.Now()); got != "<div> breaks the layout" {
		t.Fatalf("first prompt title = %q", got)
	}
}

func TestCodexHomeDirectoryHonorsCodexHome(t *testing.T) {
	t.Setenv("CODEX_HOME", "")
	if got := codexHomeDirectory("/home/me"); got != filepath.Join("/home/me", ".codex") {
		t.Fatalf("default codex home = %q", got)
	}
	t.Setenv("CODEX_HOME", "/srv/codex")
	if got := codexHomeDirectory("/home/me"); got != "/srv/codex" {
		t.Fatalf("configured codex home = %q", got)
	}
}

func TestCopilotWorkspaceTitleReadsTheSessionName(t *testing.T) {
	home := t.TempDir()
	directory := filepath.Join(home, ".copilot", "session-state", nativeTitleTestSessionID)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "workspace.yaml")
	var state copilotWorkspaceTitle
	if got := state.title(home, nativeTitleTestSessionID); got != "" {
		t.Fatalf("title before the workspace exists = %q", got)
	}
	if err := os.WriteFile(path, []byte("id: x\nsummary_count: 0\nname: \"Tidy the \\\"README\\\"\"\nuser_named: false\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := state.title(home, nativeTitleTestSessionID); got != `Tidy the "README"` {
		t.Fatalf("workspace name title = %q", got)
	}
	// Copilot rewrites the file in place when the session is renamed.
	if err := os.WriteFile(path, []byte("id: x\nname: 'Release notes'\nuser_named: true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Minute)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	if got := state.title(home, nativeTitleTestSessionID); got != "Release notes" {
		t.Fatalf("renamed workspace title = %q", got)
	}
	if got := state.title(home, "../escape"); got != "" {
		t.Fatalf("unsafe session id title = %q", got)
	}
}

func TestNativeAgentToolForProviderMapsBuiltinIDs(t *testing.T) {
	for providerID, want := range map[string]string{
		"builtin:claude-agent-acp": "claude",
		"builtin:codex-acp":        "codex",
		"builtin:copilot-cli":      "copilot",
		"builtin:pi-acp":           "pi",
		"custom:my-agent":          "",
		"":                         "",
	} {
		if got := nativeAgentToolForProvider(providerID); got != want {
			t.Errorf("nativeAgentToolForProvider(%q) = %q, want %q", providerID, got, want)
		}
	}
}

func TestQuietTitleRefreshTitlesNativeClaudeCodexAndCopilotWindows(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	claudeSession := "11111111-1111-4111-8111-111111111111"
	codexSession := "22222222-2222-4222-8222-222222222222"
	copilotSession := "33333333-3333-4333-8333-333333333333"
	claudeProject := filepath.Join(home, ".claude", "projects", "-work")
	codexDay := filepath.Join(home, ".codex", "sessions", "2026", "10", "01")
	copilotState := filepath.Join(home, ".copilot", "session-state", copilotSession)
	for _, directory := range []string{claudeProject, codexDay, copilotState} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	appendPiTitleTestRecords(t, filepath.Join(claudeProject, claudeSession+".jsonl"),
		`{"type":"ai-title","aiTitle":"Claude native title","sessionId":"x"}`+"\n")
	appendPiTitleTestRecords(t, filepath.Join(home, ".codex", "session_index.jsonl"),
		`{"id":"`+codexSession+`","thread_name":"Codex native title"}`+"\n")
	if err := os.WriteFile(filepath.Join(copilotState, "workspace.yaml"), []byte("name: Copilot native title\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	sessions := map[string]string{
		"11111111111111111111111111111111": claudeSession,
		"22222222222222222222222222222222": codexSession,
		"33333333333333333333333333333333": copilotSession,
	}
	stubPiTitleBridgeStatus(t, func(id string) (acpBridgeInfo, error) {
		sessionID, ok := sessions[id]
		if !ok {
			return acpBridgeInfo{}, errors.New("unknown bridge")
		}
		return acpBridgeInfo{ID: id, SessionID: sessionID, Cwd: "/work"}, nil
	})
	newNativeWindow := func(id, name, bridgeID, providerID string) *muxWindow {
		return &muxWindow{
			id:                  id,
			name:                name,
			command:             "monkeymux acp wait " + bridgeID,
			nativeAcpBridgeID:   bridgeID,
			nativeAcpProviderID: providerID,
		}
	}
	// Native windows carry the provider's display label, which the command
	// name detection does not recognize for Claude Agent or Copilot CLI.
	claude := newNativeWindow("@1", "Claude Agent", "11111111111111111111111111111111", "builtin:claude-agent-acp")
	codex := newNativeWindow("@2", "Codex", "22222222222222222222222222222222", "builtin:codex-acp")
	copilot := newNativeWindow("@3", "Copilot CLI", "33333333333333333333333333333333", "builtin:copilot-cli")
	server, control := newPiTitleTestServer(claude)
	server.windows = []*muxWindow{claude, codex, copilot}

	server.refreshQuietAgentSessionTitles()
	for _, want := range []string{"Claude native title", "Codex native title", "Copilot native title"} {
		if !strings.Contains(control.String(), `"agentSessionTitle":"`+want+`"`) {
			t.Fatalf("%q was not broadcast: %s", want, control.String())
		}
	}

	// A terminal window of the same agent is left to its own title sources.
	terminal := &muxWindow{id: "@4", name: "claude", foregroundCommand: "claude", agentTool: "claude", agentToolConfirmed: true}
	if got := terminal.readAgentSessionTitle("claude", "", "", time.Now()); got != "" {
		t.Fatalf("terminal window title = %q, want empty", got)
	}
}

func TestNativeAgentSessionTitleFollowsTheBridgeToAnotherSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, ".claude", "projects", "-work")
	if err := os.MkdirAll(project, 0o700); err != nil {
		t.Fatal(err)
	}
	first := "44444444-4444-4444-8444-444444444444"
	second := "55555555-5555-4555-8555-555555555555"
	appendPiTitleTestRecords(t, filepath.Join(project, first+".jsonl"),
		`{"type":"custom-title","customTitle":"First session"}`+"\n")
	appendPiTitleTestRecords(t, filepath.Join(project, second+".jsonl"),
		`{"type":"user","message":{"role":"user","content":"Second session"}}`+"\n")
	bridgeID := "66666666666666666666666666666666"
	hosted := first
	stubPiTitleBridgeStatus(t, func(id string) (acpBridgeInfo, error) {
		return acpBridgeInfo{ID: id, SessionID: hosted}, nil
	})
	var lookup nativeAgentSessionTitle
	now := time.Now()
	if got := lookup.title("claude", bridgeID, now); got != "First session" {
		t.Fatalf("first session title = %q", got)
	}
	// The bridge is asked again only after the lookup interval.
	hosted = second
	if got := lookup.title("claude", bridgeID, now.Add(time.Second)); got != "First session" {
		t.Fatalf("title within the lookup interval = %q", got)
	}
	if got := lookup.title("claude", bridgeID, now.Add(nativeAgentSessionLookupInterval)); got != "Second session" {
		t.Fatalf("loaded session title = %q", got)
	}
	hosted = "../escape"
	if got := lookup.title("claude", bridgeID, now.Add(2*nativeAgentSessionLookupInterval)); got != "" {
		t.Fatalf("unsafe session id title = %q", got)
	}
	if got := lookup.title("opencode", bridgeID, now); got != "" {
		t.Fatalf("agent without a file-backed title = %q", got)
	}
	if got := lookup.title("claude", "not-a-bridge", now); got != "" {
		t.Fatalf("invalid bridge title = %q", got)
	}
}
