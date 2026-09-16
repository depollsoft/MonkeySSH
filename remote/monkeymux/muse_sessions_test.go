package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMuseCommandsAndIdentity(t *testing.T) {
	const id = "01a0ac67-804e-7f22-8d0d-9a4e2ea626c9"
	for _, command := range []string{"muse", "muse-bin-1.3.0-R3233.1", "muse-code-acp"} {
		if got := agentToolFromCommandName(command); got != "muse" {
			t.Fatalf("%s: %q", command, got)
		}
	}
	if got := agentToolFromCommandName("muse-bin-unrelated"); got != "" {
		t.Fatal(got)
	}
	if got := agentToolFromTerminalTitle("Muse Code · task"); got != "muse" {
		t.Fatal(got)
	}
	if got := agentResumeCommand("muse", id, true); got != "muse --yolo resume '"+id+"'" {
		t.Fatal(got)
	}
	if got := agentResumeCommand("muse", "_continue", false); got != "muse resume --last" {
		t.Fatal(got)
	}
	if got := agentSessionIDFromArgs("muse", "muse resume '"+id+"'"); got != id {
		t.Fatal(got)
	}
	if got := agentSessionIDFromArgs("muse", "muse resume --last"); got != "" {
		t.Fatal(got)
	}
	if !agentSessionIDValid("muse", id) || agentSessionIDValid("muse", "--last") {
		t.Fatal("invalid session validation")
	}
}

func TestMuseSessionStoreAndExactBinding(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	const id = "01a0ac67-804e-7f22-8d0d-9a4e2ea626c9"
	const nestedID = "01a0ac67-804e-7f22-8d0d-9a4e2ea626c0"
	cwd := t.TempDir()
	path := filepath.Join(museSessionsRoot(), "2026", "09", "16", id, "session.jsonl")
	nested := filepath.Join(filepath.Dir(path), "subagent", nestedID, "session.jsonl")
	write := func(path, sessionID string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(map[string]any{
			"payload_type": "runtime.session.metadata", "stream": map[string]string{"id": sessionID},
			"payload": map[string]any{"record": map[string]string{"workspace_root": cwd}},
		})
		data = append([]byte("{\"retained_frame\":\"session_permission_transaction\"}\n"), data...)
		data = append(data, []byte("\n{\"truncated\":")...)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(path, id)
	write(nested, nestedID)
	if museSessionIDFromPath(nested) != "" {
		t.Fatal("nested worker must not bind parent window")
	}
	candidates := readAgentSessionCandidates("muse")
	if len(candidates) != 1 || candidates[0].id != id || candidates[0].cwd != normalizedMetadataPath(cwd) {
		t.Fatalf("%+v", candidates)
	}
	watch := newAgentSessionWatch("muse", cwd, time.Now(), candidates)
	w := &muxWindow{agentTool: "muse", agentToolConfirmed: true, cwd: cwd, agentSessionWatch: watch}
	s := &muxServer{windows: []*muxWindow{w}}
	s.bindAgentSessionCandidatesLocked(w, watch, candidates, "", []string{path}, time.Now())
	if w.agentSessionID != id || !w.agentSessionIdentityExact {
		t.Fatalf("identity: %q exact=%v", w.agentSessionID, w.agentSessionIdentityExact)
	}
	// A copied/mismatched log must not become another resumable root.
	write(path, nestedID)
	if got := readMuseSessionCandidates(); len(got) != 0 {
		t.Fatalf("mismatched stream accepted: %+v", got)
	}
}
