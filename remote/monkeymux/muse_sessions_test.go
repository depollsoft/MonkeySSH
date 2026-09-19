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
	for _, command := range []string{"muse", "muse.cmd", "muse-bin-1.3.0-R3233.1", "muse-bin-1.3.0-R3233.1.exe", "muse-code-acp", "muse-code-acp.cmd"} {
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
	// The candidate cache is keyed on size, mode and mtime. Rewrites below
	// keep the size, so give every write a distinct mtime instead of relying
	// on the filesystem's timestamp resolution (coarse on Windows CI).
	writes := 0
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
		writes++
		stamp := time.Now().Add(time.Duration(writes) * time.Second)
		if err := os.Chtimes(path, stamp, stamp); err != nil {
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
	// A direct process-open-file signal must validate the same metadata even
	// when no candidate-store entry exists (for example during helper recovery).
	for _, valid := range []bool{false, true} {
		if valid {
			write(path, id)
		}
		for _, cachedCandidates := range [][]agentSessionCandidate{nil, candidates} {
			for _, argsID := range []string{"", id, nestedID} {
				watch := newAgentSessionWatch("muse", cwd, time.Now(), nil)
				w := &muxWindow{agentTool: "muse", agentToolConfirmed: true, cwd: cwd, agentSessionWatch: watch}
				s := &muxServer{windows: []*muxWindow{w}}
				s.bindAgentSessionCandidatesLocked(w, watch, cachedCandidates, argsID, []string{path}, time.Now())
				if w.agentSessionIdentityExact != valid || (valid && w.agentSessionID != id) {
					t.Fatalf("valid=%v args=%q: identity=%q exact=%v", valid, argsID, w.agentSessionID, w.agentSessionIdentityExact)
				}
			}
		}
	}

}

func TestMuseMetadataCacheTracksChangesWithoutReopeningHistory(t *testing.T) {
	root := t.TempDir()
	cache := museSessionCache{}
	reads := 0
	read := func(path, id string) (agentSessionCandidate, bool) {
		reads++
		return readMuseSessionMetadata(path, id)
	}
	write := func(id, cwd string) string {
		t.Helper()
		path := filepath.Join(root, "2026", "09", "16", id, "session.jsonl")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(map[string]any{
			"payload_type": "runtime.session.metadata", "stream": map[string]string{"id": id},
			"payload": map[string]any{"record": map[string]string{"workspace_root": cwd}},
		})
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	const id = "01a0ac67-804e-7f22-8d0d-9a4e2ea626c9"
	const secondID = "01a0ac67-804e-7f22-8d0d-9a4e2ea626c0"
	path := write(id, "/project")
	for i := 0; i < 3; i++ {
		if got := cache.read(root, read); len(got) != 1 || got[0].cwd != normalizedMetadataPath("/project") {
			t.Fatalf("%+v", got)
		}
	}
	if reads != 1 {
		t.Fatalf("unchanged log read %d times", reads)
	}
	write(id, "/updated-project")
	write(secondID, "/other")
	if got := cache.read(root, read); len(got) != 2 || reads != 3 {
		t.Fatalf("reads=%d candidates=%+v", reads, got)
	}
	if cache.entries[path].candidate.cwd != normalizedMetadataPath("/updated-project") {
		t.Fatal("changed metadata not refreshed")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if got := cache.read(root, read); len(got) != 1 || reads != 3 {
		t.Fatalf("reads=%d candidates=%+v", reads, got)
	}
	if _, ok := cache.entries[path]; ok {
		t.Fatal("deleted entry retained")
	}
	if got := cache.read(t.TempDir(), read); len(got) != 0 || len(cache.entries) != 0 {
		t.Fatal("old root retained")
	}
}
