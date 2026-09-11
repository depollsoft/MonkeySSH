package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var bindingTestIDs = []string{"11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"}

// Exercise the real parsers, including the SQLite reader, under a fake home.
func bindingTestStore(t *testing.T, tool string) (string, func(string, string, time.Time) string) {
	t.Helper()
	originalTable := processTableForMetadata
	processTableForMetadata = func() map[int]processInfo { return map[int]processInfo{} }
	t.Cleanup(func() { processTableForMetadata = originalTable })
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	cwd := filepath.Join(home, "project")
	if err := os.MkdirAll(cwd, 0700); err != nil {
		t.Fatal(err)
	}
	write := func(path, data string, at time.Time) string {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, at, at); err != nil {
			t.Fatal(err)
		}
		return path
	}
	var sqlite, db string
	if tool == "opencode" {
		var err error
		sqlite, err = exec.LookPath("sqlite3")
		if err != nil {
			t.Skip("sqlite3 unavailable")
		}
		db = filepath.Join(home, ".local", "share", "opencode", "opencode.db")
		if err := os.MkdirAll(filepath.Dir(db), 0700); err != nil {
			t.Fatal(err)
		}
		out, err := exec.Command(sqlite, db, "CREATE TABLE session (id TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER, parent_id TEXT, time_archived INTEGER);").CombinedOutput()
		if err != nil {
			t.Fatalf("create database: %v: %s", err, out)
		}
	}
	return cwd, func(id, directory string, at time.Time) string {
		t.Helper()
		switch tool {
		case "codex":
			path := filepath.Join(home, ".codex", "sessions", "2026", "09", "10", "rollout-2026-09-10T00-00-00-"+id+".jsonl")
			return write(path, fmt.Sprintf("{\"type\":\"session_meta\",\"payload\":{\"id\":%q,\"cwd\":%q}}\n", id, directory), at)
		case "claude":
			path := filepath.Join(home, ".claude", "projects", claudeEncodedProjectDirName(directory), id+".jsonl")
			return write(path, fmt.Sprintf("{\"sessionId\":%q,\"cwd\":%q}\n", id, directory), at)
		case "opencode":
			quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
			query := fmt.Sprintf("INSERT INTO session VALUES (%s, %s, %d, %d, NULL, NULL);", quote(id), quote(directory), at.UnixMilli(), at.UnixMilli())
			out, err := exec.Command(sqlite, db, query).CombinedOutput()
			if err != nil {
				t.Fatalf("insert session: %v: %s", err, out)
			}
			return ""
		case "cursor-agent":
			path := filepath.Join(home, ".cursor", "chats", "workspace", id, "meta.json")
			return write(path, fmt.Sprintf("{\"cwd\":%q,\"createdAtMs\":%d,\"updatedAtMs\":%d}", directory, at.UnixMilli(), at.UnixMilli()), at)
		case "antigravity":
			path := filepath.Join(home, ".gemini", "antigravity-cli", "history.jsonl")
			data, _ := os.ReadFile(path)
			return write(path, string(data)+fmt.Sprintf("{\"conversationId\":%q,\"workspace\":%q,\"timestamp\":%d}\n", id, directory, at.UnixMilli()), at)
		}
		t.Fatalf("unknown tool %s", tool)
		return ""
	}
}

func bindingTestWindow(tool, cwd, id string, started time.Time) *muxWindow {
	return &muxWindow{id: id, cwd: cwd, command: tool, agentTool: tool, agentToolConfirmed: true,
		agentSessionWatch: newAgentSessionWatch(tool, cwd, started, readAgentSessionCandidates(tool))}
}

func pollBindingTest(s *muxServer, w *muxWindow, at time.Time, args string, paths ...string) {
	candidates := agentSessionCandidatesForDirectory(w.agentTool, w.cwd, readAgentSessionCandidates(w.agentTool))
	s.mu.Lock()
	defer s.mu.Unlock()
	s.bindAgentSessionCandidatesLocked(w, w.agentSessionWatch, candidates, args, paths, at)
}

func TestAgentSessionBindingSequentialWindowsAndResume(t *testing.T) {
	for _, tool := range []string{"codex", "claude", "opencode", "cursor-agent", "antigravity"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Truncate(time.Second)
			s := &muxServer{}
			for i, id := range bindingTestIDs {
				at := started.Add(time.Duration(i*2) * time.Second)
				w := bindingTestWindow(tool, cwd, fmt.Sprintf("@%d", i), at)
				s.windows = append(s.windows, w)
				path := write(id, cwd, at.Add(time.Second))
				pollBindingTest(s, w, at.Add(time.Second), "")
				if w.agentSessionID != id || !w.agentSessionIdentityExact {
					t.Fatalf("window %d identity = %q exact=%v", i, w.agentSessionID, w.agentSessionIdentityExact)
				}
				if (tool == "codex" || tool == "claude" || tool == "cursor-agent") && (w.agentSessionPath != path || w.agentSessionDir != filepath.Dir(path)) {
					t.Fatalf("missing session path: %+v", w)
				}
			}
			snapshot := s.restoreSnapshot()
			// No live processes are needed to retain an exact binding at enrichment.
			original := processTableForMetadata
			processTableForMetadata = func() map[int]processInfo { return nil }
			t.Cleanup(func() { processTableForMetadata = original })
			enrichRestoreWithAgentSessionIDs(snapshot)
			prefixes := map[string]string{"codex": "codex resume", "claude": "claude --resume", "opencode": "opencode --session", "cursor-agent": "cursor-agent --resume", "antigravity": "agy --conversation"}
			for i, state := range snapshot.Windows {
				if state.AgentSessionID != bindingTestIDs[i] || !state.AgentSessionIdentityExact {
					t.Fatalf("snapshot lost exact binding: %+v", state)
				}
				want := prefixes[tool] + " '" + bindingTestIDs[i] + "'"
				if got := agentResumeCommand(tool, state.AgentSessionID, false); got != want {
					t.Fatalf("resume = %q, want %q", got, want)
				}
				options := createWindowOptionsForRestore(state, false)
				if !strings.Contains(options.command, want) || options.agentSessionID != state.AgentSessionID {
					t.Fatalf("restore options lost resume: %+v", options)
				}
			}
		})
	}
}

func TestAgentSessionBindingOverlappingWindows(t *testing.T) {
	for _, tool := range []string{"codex", "claude", "opencode", "cursor-agent", "antigravity"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Truncate(time.Second)
			first := bindingTestWindow(tool, cwd, "@1", started)
			second := bindingTestWindow(tool, cwd, "@2", started)
			s := &muxServer{windows: []*muxWindow{first, second}}
			firstPath := write(bindingTestIDs[0], cwd, started.Add(time.Second))
			// Poll the wrong pane first while only the first pane's file exists.
			pollBindingTest(s, second, started.Add(time.Second), "")
			pollBindingTest(s, first, started.Add(time.Second), "")
			if first.agentSessionID != "" || second.agentSessionID != "" {
				t.Fatal("one fresh candidate was guessed across overlapping watches")
			}
			secondPath := write(bindingTestIDs[1], cwd, started.Add(2*time.Second))
			pollBindingTest(s, first, started.Add(2*time.Second), "")
			if first.agentSessionID != "" {
				t.Fatal("multiple candidates were guessed")
			}
			if tool == "codex" || tool == "claude" {
				pollBindingTest(s, second, started.Add(2*time.Second), "", secondPath)
				pollBindingTest(s, first, started.Add(2*time.Second), "", firstPath)
			} else {
				// A shared database/history handle cannot distinguish these panes;
				// explicit process arguments can.
				pollBindingTest(s, second, started.Add(2*time.Second), "", secondPath)
				if second.agentSessionID != "" {
					t.Fatal("shared store handle established ownership")
				}
				pollBindingTest(s, second, started.Add(2*time.Second), bindingTestIDs[1])
				pollBindingTest(s, first, started.Add(2*time.Second), bindingTestIDs[0])
			}
			if first.agentSessionID != bindingTestIDs[0] || second.agentSessionID != bindingTestIDs[1] {
				t.Fatalf("cross-bound sessions: %q, %q", first.agentSessionID, second.agentSessionID)
			}
		})
	}
}

func TestAgentSessionBindingRejectsUnsafeCandidates(t *testing.T) {
	for _, tc := range []string{"no-file", "before-spawn", "baseline-updated", "wrong-directory", "already-bound", "exited", "closed", "ambiguous", "pending-launch", "old-first-mtime"} {
		t.Run(tc, func(t *testing.T) {
			cwd, write := bindingTestStore(t, "codex")
			started := time.Now().Truncate(time.Second)
			if tc == "baseline-updated" {
				write(bindingTestIDs[0], cwd, started.Add(-time.Hour))
			}
			w := bindingTestWindow("codex", cwd, "@1", started)
			s := &muxServer{windows: []*muxWindow{w}}
			at := started.Add(time.Second)
			directory := cwd
			switch tc {
			case "before-spawn", "old-first-mtime":
				at = started.Add(-time.Second)
			case "wrong-directory":
				directory = filepath.Join(cwd, "other")
			case "already-bound":
				s.windows = append(s.windows, &muxWindow{id: "@2", agentTool: "codex", agentSessionID: bindingTestIDs[0], agentSessionIdentityExact: true})
			case "pending-launch":
				s.agentSessionBindings.pending = 1
			}
			if tc != "no-file" {
				write(bindingTestIDs[0], directory, at)
			}
			if tc == "ambiguous" {
				write(bindingTestIDs[1], cwd, at)
			}
			now := started.Add(2 * time.Second)
			if tc == "exited" {
				w.agentSessionWatch.exited = true
			}
			if tc == "closed" {
				w.closed = true
			}
			pollBindingTest(s, w, now, "")
			if tc == "old-first-mtime" {
				write(bindingTestIDs[0], cwd, started.Add(time.Second))
				pollBindingTest(s, w, now, "")
			}
			if w.agentSessionID != "" || w.agentSessionIdentityExact {
				t.Fatalf("unsafe binding: %q", w.agentSessionID)
			}
		})
	}
}

func TestAgentSessionBindingFallbackAndExclusivity(t *testing.T) {
	cwd, write := bindingTestStore(t, "codex")
	started := time.Now().Truncate(time.Second)
	w := bindingTestWindow("codex", cwd, "@1", started)
	s := &muxServer{windows: []*muxWindow{w}}
	pollBindingTest(s, w, started.Add(time.Second), "")
	if w.agentSessionID != "" {
		t.Fatal("empty store bound a session")
	}
	write(bindingTestIDs[0], cwd, started.Add(2*time.Second))
	w.agentSessionWatch.done, w.agentSessionWatch.exited = true, true
	pollBindingTest(s, w, started.Add(10*time.Minute), "")
	if w.agentSessionID != "" {
		t.Fatal("exited watch bound a session")
	}
	originalTable, originalStart, originalCwd, originalFiles := processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata
	t.Cleanup(func() {
		processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata = originalTable, originalStart, originalCwd, originalFiles
	})
	processTableForMetadata = func() map[int]processInfo { return map[int]processInfo{123: {pid: 123, comm: "codex", args: "codex"}} }
	processStartedAtForMetadata = func(int) time.Time { return started }
	processWorkingDirectoryForMetadata = func(int) string { return cwd }
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	restore := &serverRestore{Windows: []restoreWindowState{{ID: "@1", AgentTool: "codex", AgentToolConfirmed: true, CurrentCommand: "codex", PanePid: 123, Cwd: cwd}}}
	enrichRestoreWithAgentSessionIDs(restore)
	if restore.Windows[0].AgentSessionID != bindingTestIDs[0] {
		t.Fatalf("fallback no longer works: %+v", restore.Windows)
	}
	// The same process-args fallback must not steal another live pane's exact ID.
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{123: {pid: 123, comm: "codex", args: "codex resume " + bindingTestIDs[0]}}
	}
	restore.Windows = append(restore.Windows, restoreWindowState{ID: "@2", AgentTool: "codex", AgentToolConfirmed: true, CurrentCommand: "codex", AgentSessionID: bindingTestIDs[0], AgentSessionIdentityExact: true, Cwd: cwd})
	enrichRestoreWithAgentSessionIDs(restore)
	if restore.Windows[0].AgentSessionID != "" || restore.Windows[1].AgentSessionID != bindingTestIDs[0] {
		t.Fatalf("fallback reused exact binding: %+v", restore.Windows)
	}
	owner := &muxWindow{id: "@2", agentTool: "codex", agentSessionID: bindingTestIDs[0], agentSessionIdentityExact: true}
	s.windows = append(s.windows, owner)
	if s.allowAgentSessionFallbackLocked(w, "codex", bindingTestIDs[0]) {
		t.Fatal("live fallback reused exact ID")
	}
	owner.closed = true
	if s.allowAgentSessionFallbackLocked(w, "codex", bindingTestIDs[0]) {
		t.Fatal("exited agent can still receive a fallback session")
	}
}

type bindingTestProcess struct {
	muxProcess
	pid int
}

func (p bindingTestProcess) Pid() int { return p.pid }

func TestAgentSessionBindingRefreshUsesAgentPID(t *testing.T) {
	cwd, write := bindingTestStore(t, "codex")
	originalTable, originalStart, originalCwd, originalFiles := processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata
	t.Cleanup(func() {
		processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata = originalTable, originalStart, originalCwd, originalFiles
	})
	started := time.Now().Add(-time.Second)
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			100: {pid: 100, comm: "zsh", args: "zsh"}, 101: {pid: 101, ppid: 100, comm: "codex", args: "codex"},
			200: {pid: 200, comm: "zsh", args: "zsh"}, 201: {pid: 201, ppid: 200, comm: "codex", args: "codex"},
		}
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid != 101 && pid != 201 {
			t.Fatalf("probed shell PID %d", pid)
		}
		return started
	}
	processWorkingDirectoryForMetadata = func(int) string { return cwd }
	first := bindingTestWindow("codex", cwd, "@1", started)
	second := bindingTestWindow("codex", cwd, "@2", started)
	first.proc, second.proc = bindingTestProcess{pid: 100}, bindingTestProcess{pid: 200}
	s := &muxServer{windows: []*muxWindow{first, second}}
	paths := map[int]string{101: write(bindingTestIDs[0], cwd, started.Add(time.Second)), 201: write(bindingTestIDs[1], cwd, started.Add(time.Second))}
	processOpenFilePathsForMetadata = func(pid int) []string { return []string{paths[pid]} }
	s.refreshAgentSessionBinding(second.id)
	s.refreshAgentSessionBinding(first.id)
	if first.agentSessionID != bindingTestIDs[0] || second.agentSessionID != bindingTestIDs[1] {
		t.Fatalf("refresh mixed up descendant processes: %q, %q", first.agentSessionID, second.agentSessionID)
	}
	if first.agentSessionWatch.pid != 101 || second.agentSessionWatch.pid != 201 {
		t.Fatal("watch tracked pane shells instead of agents")
	}
}

func TestAgentSessionBindingLaunchBaselineAndPending(t *testing.T) {
	cwd, write := bindingTestStore(t, "claude")
	s := &muxServer{}
	oldPath := write(bindingTestIDs[0], cwd, time.Now().Add(-time.Hour))
	watch, finish := s.prepareAgentSessionWatch("claude", cwd, createWindowOptions{})
	if watch == nil || !watch.baseline[oldPath] || s.agentSessionBindings.pending != 1 {
		t.Fatal("launch baseline/pending registration missing")
	}
	w := &muxWindow{id: "@1", cwd: cwd, agentTool: "claude", agentSessionWatch: watch}
	s.windows = append(s.windows, w)
	write(bindingTestIDs[1], cwd, watch.started.Add(time.Second))
	pollBindingTest(s, w, watch.started.Add(time.Second), "")
	if w.agentSessionID != "" {
		t.Fatal("bound during a pending launch")
	}
	finish()
	pollBindingTest(s, w, watch.started.Add(time.Second), "")
	if w.agentSessionID != bindingTestIDs[1] || s.agentSessionBindings.pending != 0 {
		t.Fatal("finished launch failed to bind new session")
	}
	restored, finishRestored := s.prepareAgentSessionWatch("claude", cwd, createWindowOptions{agentSessionID: bindingTestIDs[0], agentSessionIdentityExact: true})
	finishRestored()
	if restored != nil {
		t.Fatal("restored session acquired a fresh-launch baseline")
	}
}

func TestAgentSessionBindingOldWorkspaceSession(t *testing.T) {
	for _, tool := range []string{"opencode", "cursor-agent", "antigravity"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Truncate(time.Second)
			w := bindingTestWindow(tool, cwd, "@1", started)
			s := &muxServer{windows: []*muxWindow{w}}
			path := write(bindingTestIDs[0], cwd, started.Add(-time.Hour))
			home, _ := os.UserHomeDir()
			switch tool {
			case "opencode":
				sqlite, _ := exec.LookPath("sqlite3")
				db := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
				if out, err := exec.Command(sqlite, db, fmt.Sprintf("UPDATE session SET time_updated = %d;", started.Add(time.Second).UnixMilli())).CombinedOutput(); err != nil {
					t.Fatalf("update: %v: %s", err, out)
				}
			case "cursor-agent":
				data := fmt.Sprintf("{\"cwd\":%q,\"createdAtMs\":%d,\"updatedAtMs\":%d}", cwd, started.Add(-time.Hour).UnixMilli(), started.Add(time.Second).UnixMilli())
				if err := os.WriteFile(path, []byte(data), 0600); err != nil {
					t.Fatal(err)
				}
			case "antigravity":
				write(bindingTestIDs[0], cwd, started.Add(time.Second))
			}
			pollBindingTest(s, w, started.Add(2*time.Second), "")
			if w.agentSessionID != "" {
				t.Fatal("old conversation's recent activity was mistaken for creation")
			}
		})
	}
}

func TestAgentSessionBindingLateAgentAndReplacement(t *testing.T) {
	cwd, write := bindingTestStore(t, "codex")
	originalTable, originalStart, originalCwd, originalFiles := processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata
	t.Cleanup(func() {
		processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata = originalTable, originalStart, originalCwd, originalFiles
	})
	started := time.Now().Add(-time.Second)
	pid := 101
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			100: {pid: 100, comm: "zsh", args: "zsh"}, pid: {pid: pid, ppid: 100, comm: "codex", args: "codex"},
		}
	}
	processStartedAtForMetadata = func(int) time.Time { return started }
	processWorkingDirectoryForMetadata = func(int) string { return cwd }
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	// This pane began as a shell, so there is no launch baseline yet.
	w := &muxWindow{id: "@1", cwd: cwd, foregroundCommand: "codex", proc: bindingTestProcess{pid: 100}}
	s := &muxServer{windows: []*muxWindow{w}}
	write(bindingTestIDs[0], cwd, started)
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionWatch == nil || w.agentSessionID != "" {
		t.Fatal("late agent should baseline existing files for fallback")
	}
	oldWatch := w.agentSessionWatch
	oldWatch.started = time.Now().Add(-10 * time.Minute)
	oldWatch.lastPoll = time.Time{}
	s.refreshAgentSessionBinding(w.id)
	if oldWatch.done {
		t.Fatal("live watch expired")
	}
	pid = 102
	oldWatch.lastPoll = time.Time{}
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionWatch == oldWatch || w.agentSessionWatch.pid != 102 || w.agentSessionWatch.done {
		t.Fatal("new agent inherited previous process's watch")
	}
	path := write(bindingTestIDs[1], cwd, time.Now())
	processOpenFilePathsForMetadata = func(candidatePID int) []string {
		if candidatePID == pid {
			return []string{path}
		}
		return nil
	}
	s.agentSessionBindings.stores = nil
	w.agentSessionWatch.lastPoll = time.Time{}
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionID != bindingTestIDs[1] {
		t.Fatalf("new process failed to bind its own file: %q", w.agentSessionID)
	}
}

func bindingTestWriteFile(t *testing.T, path, data string, at time.Time) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, at, at); err != nil {
		t.Fatal(err)
	}
	return path
}

func bindingTestRegistry(t *testing.T, pid int, id, cwd string, started time.Time) {
	t.Helper()
	home, _ := os.UserHomeDir()
	bindingTestWriteFile(t, filepath.Join(home, ".claude", "sessions", fmt.Sprintf("%d.json", pid)),
		fmt.Sprintf(`{"pid":%d,"sessionId":%q,"cwd":%q,"startedAt":%d}`, pid, id, cwd, started.UnixMilli()), started)
}

func bindingTestProcesses(t *testing.T, cwd string, started time.Time, processes map[int]processInfo, files map[int][]string) {
	t.Helper()
	originalTable, originalStart, originalCwd, originalFiles := processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata
	t.Cleanup(func() {
		processTableForMetadata, processStartedAtForMetadata, processWorkingDirectoryForMetadata, processOpenFilePathsForMetadata = originalTable, originalStart, originalCwd, originalFiles
	})
	processTableForMetadata = func() map[int]processInfo { return processes }
	processStartedAtForMetadata = func(int) time.Time { return started }
	processWorkingDirectoryForMetadata = func(int) string { return cwd }
	processOpenFilePathsForMetadata = func(pid int) []string { return files[pid] }
}

// Advance the poll/cache clocks without sleeping or changing process lifetime.
func bindingTestNextPoll(s *muxServer, w *muxWindow) {
	w.agentSessionWatch.lastPoll = time.Time{}
	for tool, cached := range s.agentSessionBindings.stores {
		cached.at = time.Now().Add(-agentSessionStorePollInterval)
		s.agentSessionBindings.stores[tool] = cached
	}
}

func TestAgentSessionBindingPIDOwnership(t *testing.T) {
	for _, tool := range []string{"claude", "copilot"} {
		for _, descendant := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/descendant=%v", tool, descendant), func(t *testing.T) {
				cwd, _ := bindingTestStore(t, tool)
				started := time.Now().Add(-time.Second)
				processes := map[int]processInfo{}
				s := &muxServer{}
				for i, id := range bindingTestIDs {
					pane, agent := 100+i*100, 101+i*100
					processes[pane] = processInfo{pid: pane, comm: "zsh", args: "zsh"}
					processes[agent] = processInfo{pid: agent, ppid: pane, comm: tool, args: tool}
					w := bindingTestWindow(tool, cwd, fmt.Sprintf("@%d", i), started)
					w.proc = bindingTestProcess{pid: pane}
					s.windows = append(s.windows, w)
					owner := agent
					if descendant {
						owner++
						processes[owner] = processInfo{pid: owner, ppid: agent, comm: tool, args: tool}
					}
					if tool == "claude" {
						bindingTestRegistry(t, owner, id, cwd, started)
					} else {
						home, _ := os.UserHomeDir()
						bindingTestWriteFile(t, filepath.Join(home, ".copilot", "session-state", id, fmt.Sprintf("inuse.%d.lock", owner)), fmt.Sprint(owner), started)
					}
				}
				bindingTestProcesses(t, cwd, started, processes, nil)
				s.refreshAgentSessionBinding(s.windows[1].id)
				s.refreshAgentSessionBinding(s.windows[0].id)
				for i, w := range s.windows {
					if w.agentSessionID != bindingTestIDs[i] || !w.agentSessionIdentityExact {
						t.Fatalf("wrong PID binding: %q exact=%v", w.agentSessionID, w.agentSessionIdentityExact)
					}
				}
			})
		}
	}
}

func TestAgentSessionBindingClaudeRegistryChanges(t *testing.T) {
	cwd, _ := bindingTestStore(t, "claude")
	started := time.Now().Add(-time.Second)
	w := bindingTestWindow("claude", cwd, "@1", started)
	w.proc = bindingTestProcess{pid: 100}
	s := &muxServer{windows: []*muxWindow{w}}
	processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: "claude", args: "claude --resume " + bindingTestIDs[0]}}
	bindingTestProcesses(t, cwd, started, processes, nil)
	bindingTestRegistry(t, 101, bindingTestIDs[0], cwd, started)
	s.refreshAgentSessionBinding(w.id)
	bindingTestRegistry(t, 101, bindingTestIDs[1], cwd, started)
	bindingTestNextPoll(s, w)
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionID != bindingTestIDs[1] || !w.agentSessionIdentityExact || w.agentSessionWatch.done {
		t.Fatalf("registry change was lost: id=%q exact=%v", w.agentSessionID, w.agentSessionIdentityExact)
	}
	if s.exactAgentSessionOwnerLocked("claude", bindingTestIDs[0], nil) {
		t.Fatal("previous registry ID remains reserved")
	}
	delete(processes, 101)
	// Process discovery for another window retires exited exact owners.
	other := bindingTestWindow("claude", cwd, "@2", started)
	other.proc = bindingTestProcess{pid: 200}
	s.windows = append(s.windows, other)
	s.refreshAgentSessionBinding(other.id)
	if !w.agentSessionWatch.exited || s.exactAgentSessionOwnerLocked("claude", bindingTestIDs[1], nil) {
		t.Fatal("exited agent still reserves ID")
	}
}

func TestAgentSessionBindingExactClaudeHookFollowsRegistry(t *testing.T) {
	for _, registryPID := range []int{0, 102} {
		t.Run(fmt.Sprint(registryPID), func(t *testing.T) {
			cwd, _ := bindingTestStore(t, "claude")
			started := time.Now().Add(-time.Second)
			w := bindingTestWindow("claude", cwd, "@1", started)
			w.proc = bindingTestProcess{pid: 100}
			watch := w.agentSessionWatch
			watch.pid, watch.registryPID = 101, registryPID
			w.applyAgentIdentityPayloadLocked(identityTestPayload(agentIdentity{Tool: "claude", ID: bindingTestIDs[0], Source: "hook"}))
			if !watch.done || !w.agentSessionIdentityExact {
				t.Fatal("hook did not finish exact binding")
			}
			s := &muxServer{windows: []*muxWindow{w}}
			bindingTestProcesses(t, cwd, started, nil, nil)
			processTableForMetadata = func() map[int]processInfo {
				t.Fatal("exact Claude refresh scanned processes")
				return nil
			}
			processStartedAtForMetadata = func(int) time.Time {
				t.Fatal("exact Claude refresh probed process start")
				return time.Time{}
			}
			processWorkingDirectoryForMetadata = func(int) string {
				t.Fatal("exact Claude refresh probed working directory")
				return ""
			}
			calls := 0
			processOpenFilePathsForMetadata = func(int) []string { calls++; return nil }
			pid := watch.pid
			if registryPID != 0 {
				pid = registryPID
				bindingTestRegistry(t, watch.pid, bindingTestIDs[0], cwd, started)
			}
			bindingTestRegistry(t, pid, bindingTestIDs[0], cwd, started)
			s.refreshAgentSessionBinding(w.id)
			bindingTestRegistry(t, pid, bindingTestIDs[1], cwd, started)
			bindingTestNextPoll(s, w)
			s.refreshAgentSessionBinding(w.id)
			if w.agentSessionID != bindingTestIDs[1] || !w.agentSessionIdentityExact || !watch.done || watch.registryPID != pid {
				t.Fatalf("hook-bound registry change lost: id=%q exact=%v done=%v pid=%d", w.agentSessionID, w.agentSessionIdentityExact, watch.done, watch.registryPID)
			}
			if calls != 0 || len(s.agentSessionBindings.stores) != 0 {
				t.Fatalf("exact refresh scanned files: probes=%d stores=%d", calls, len(s.agentSessionBindings.stores))
			}
		})
	}
}

func TestAgentSessionBindingCodexDescendantFileBeatsTiming(t *testing.T) {
	cwd, write := bindingTestStore(t, "codex")
	started := time.Now().Add(-10 * time.Minute)
	w := bindingTestWindow("codex", cwd, "@1", started)
	w.proc = bindingTestProcess{pid: 100}
	s := &muxServer{windows: []*muxWindow{w}}
	write(bindingTestIDs[0], cwd, time.Now())
	owned := write(bindingTestIDs[1], cwd, time.Now())
	processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: "codex", args: "codex"}, 102: {pid: 102, ppid: 101, comm: "worker"}}
	bindingTestProcesses(t, cwd, started, processes, map[int][]string{102: {owned}})
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionID != bindingTestIDs[1] || !w.agentSessionIdentityExact {
		t.Fatalf("file ownership lost: %q", w.agentSessionID)
	}
	delete(processes, 101)
	bindingTestNextPoll(s, w)
	s.refreshAgentSessionBinding(w.id)
	if s.exactAgentSessionOwnerLocked("codex", bindingTestIDs[1], nil) {
		t.Fatal("bound exited process still reserves ID")
	}
}

func TestAgentSessionBindingProvisional(t *testing.T) {
	for _, tool := range []string{"claude", "copilot", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Truncate(time.Second)
			w := bindingTestWindow(tool, cwd, "@1", started)
			w.agentSessionAssigned, w.agentSessionID = true, bindingTestIDs[0]
			s := &muxServer{windows: []*muxWindow{w}}
			writeSession := func(id string) {
				if tool != "copilot" {
					write(id, cwd, started.Add(time.Second))
					return
				}
				home, _ := os.UserHomeDir()
				if err := os.MkdirAll(filepath.Join(home, ".copilot", "session-state", id), 0700); err != nil {
					t.Fatal(err)
				}
			}
			writeSession(bindingTestIDs[1])
			pollBindingTest(s, w, started.Add(time.Second), "")
			if w.agentSessionID != bindingTestIDs[0] || w.agentSessionIdentityExact {
				t.Fatal("timing candidate replaced provisional identity")
			}
			if s.allowAgentSessionFallbackLocked(w, tool, bindingTestIDs[1]) {
				t.Fatal("fallback can replace provisional identity")
			}
			writeSession(bindingTestIDs[0])
			pollBindingTest(s, w, started.Add(2*time.Second), "")
			if w.agentSessionID != bindingTestIDs[0] || !w.agentSessionIdentityExact {
				t.Fatal("store did not confirm provisional identity")
			}
		})
	}
}

func TestAgentSessionBindingRejectsSubagents(t *testing.T) {
	for _, tool := range []string{"claude", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Truncate(time.Second)
			w := bindingTestWindow(tool, cwd, "@1", started)
			s := &muxServer{windows: []*muxWindow{w}}
			if tool == "cursor-agent" {
				path := write(bindingTestIDs[0], cwd, started.Add(time.Second))
				bindingTestWriteFile(t, path, fmt.Sprintf(`{"cwd":%q,"createdAtMs":%d,"isSubagent":true}`, cwd, started.Add(time.Second).UnixMilli()), started)
			} else {
				home, _ := os.UserHomeDir()
				path := filepath.Join(home, ".claude", "projects", claudeEncodedProjectDirName(cwd), bindingTestIDs[0], "subagents", "agent-"+bindingTestIDs[1]+".jsonl")
				bindingTestWriteFile(t, path, fmt.Sprintf(`{"sessionId":%q,"cwd":%q}`, bindingTestIDs[1], cwd), started.Add(time.Second))
			}
			pollBindingTest(s, w, started.Add(2*time.Second), "")
			if len(readAgentSessionCandidates(tool)) != 0 || w.agentSessionIdentityExact {
				t.Fatal("subagent accepted as a session")
			}
		})
	}
}

func TestAgentSessionBindingWatchLivesUntilProcessExit(t *testing.T) {
	for _, tool := range []string{"codex", "opencode"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Add(-10 * time.Minute)
			w := bindingTestWindow(tool, cwd, "@1", started)
			w.proc = bindingTestProcess{pid: 100}
			s := &muxServer{windows: []*muxWindow{w}}
			processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: tool, args: tool}}
			bindingTestProcesses(t, cwd, started, processes, nil)
			s.refreshAgentSessionBinding(w.id)
			if w.agentSessionWatch.done {
				t.Fatal("idle prompt expired")
			}
			// A second call in the same interval must not even probe processes.
			processTableForMetadata = func() map[int]processInfo { t.Fatal("polled too frequently"); return nil }
			s.refreshAgentSessionBinding(w.id)
			processTableForMetadata = func() map[int]processInfo { return processes }
			write(bindingTestIDs[0], cwd, time.Now())
			bindingTestNextPoll(s, w)
			s.refreshAgentSessionBinding(w.id)
			if w.agentSessionID != bindingTestIDs[0] || !w.agentSessionIdentityExact {
				t.Fatal("first prompt after ten minutes did not bind")
			}
			delete(processes, 101)
			bindingTestNextPoll(s, w)
			s.refreshAgentSessionBinding(w.id)
			if !w.agentSessionWatch.exited || !w.agentSessionWatch.done {
				t.Fatal("exited process kept watching")
			}
			cached := s.agentSessionBindings.stores[tool].at
			bindingTestNextPoll(s, w)
			expected := s.agentSessionBindings.stores[tool].at
			s.refreshAgentSessionBinding(w.id)
			if s.agentSessionBindings.stores[tool].at != expected || cached.IsZero() {
				t.Fatal("exited watch read the store")
			}
		})
	}
}

func TestAgentSessionBindingAntigravityConversations(t *testing.T) {
	for _, mode := range []string{"workspace", "presence", "missing-summaries", "subagent"} {
		t.Run(mode, func(t *testing.T) {
			cwd, _ := bindingTestStore(t, "antigravity")
			home, _ := os.UserHomeDir()
			root := filepath.Join(home, ".gemini", "antigravity-cli")
			started := time.Now().Add(-time.Second)
			w := bindingTestWindow("antigravity", cwd, "@1", started)
			s := &muxServer{windows: []*muxWindow{w}}
			path := bindingTestWriteFile(t, filepath.Join(root, "conversations", bindingTestIDs[0]+".db"), "", time.Now())
			if mode != "missing-summaries" {
				sqlite, err := exec.LookPath("sqlite3")
				if err != nil {
					t.Skip("sqlite3 unavailable")
				}
				parent, depth := "", 0
				if mode == "subagent" {
					parent, depth = bindingTestIDs[1], 1
				}
				workspaces := fmt.Sprintf(`["file://%s"]`, filepath.ToSlash(cwd))
				quote := func(v string) string { return "'" + strings.ReplaceAll(v, "'", "''") + "'" }
				query := fmt.Sprintf("PRAGMA journal_mode=WAL; CREATE TABLE conversation_summaries (conversation_id TEXT, workspace_uris TEXT, parent_conversation_id TEXT, nesting_depth INTEGER); INSERT INTO conversation_summaries VALUES (%s, %s, %s, %d);", quote(bindingTestIDs[0]), quote(workspaces), quote(parent), depth)
				if out, err := exec.Command(sqlite, filepath.Join(root, "conversation_summaries.db"), query).CombinedOutput(); err != nil {
					t.Fatalf("create summary: %v: %s", err, out)
				}
			}
			var open []string
			if mode == "presence" || mode == "missing-summaries" {
				bindingTestWriteFile(t, filepath.Join(root, "conversations", bindingTestIDs[1]+".db"), "", time.Now())
				open = []string{filepath.Join(root, "presence", bindingTestIDs[0]+".lock")}
			}
			pollBindingTest(s, w, time.Now(), "", open...)
			if mode == "subagent" {
				if w.agentSessionIdentityExact {
					t.Fatal("nested conversation bound")
				}
			} else if w.agentSessionID != bindingTestIDs[0] || !w.agentSessionIdentityExact || w.agentSessionPath != path {
				t.Fatalf("conversation not bound: %q", w.agentSessionID)
			}
		})
	}
}

func TestAgentSessionBindingSharedStorePoll(t *testing.T) {
	cwd, write := bindingTestStore(t, "codex")
	now := time.Now()
	write(bindingTestIDs[0], cwd, now)
	s := &muxServer{}
	var results [8][]agentSessionCandidate
	var group sync.WaitGroup
	for i := range results {
		group.Add(1)
		go func(i int) { defer group.Done(); results[i] = s.agentSessionStore("codex", now) }(i)
	}
	group.Wait()
	for _, result := range results {
		if len(result) != 1 || &result[0] != &results[0][0] {
			t.Fatal("concurrent windows did not share one store snapshot")
		}
	}
	write(bindingTestIDs[1], cwd, now)
	if got := s.agentSessionStore("codex", now.Add(time.Second)); len(got) != 1 {
		t.Fatal("store reread before poll interval")
	}
	if got := s.agentSessionStore("codex", now.Add(agentSessionStorePollInterval)); len(got) != 2 {
		t.Fatal("store did not refresh at next interval")
	}
}

func TestAgentSessionBindingProvisionalRegistryConfirmation(t *testing.T) {
	cwd, _ := bindingTestStore(t, "claude")
	started := time.Now()
	w := bindingTestWindow("claude", cwd, "@1", started)
	w.agentSessionAssigned, w.agentSessionID = true, bindingTestIDs[0]
	s := &muxServer{windows: []*muxWindow{w}}
	bindingTestRegistry(t, 101, bindingTestIDs[0], cwd, started)
	pollBindingTest(s, w, started, "")
	if !w.agentSessionIdentityExact {
		t.Fatal("registry alone did not confirm assigned ID")
	}
}

func TestAgentSessionBindingExitBeforeFirstPromptAndClose(t *testing.T) {
	for _, mode := range []string{"exit", "close", "probe-failure"} {
		t.Run(mode, func(t *testing.T) {
			cwd, write := bindingTestStore(t, "codex")
			started := time.Now().Add(-10 * time.Minute)
			w := bindingTestWindow("codex", cwd, "@1", started)
			w.proc = bindingTestProcess{pid: 100}
			s := &muxServer{windows: []*muxWindow{w}}
			processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: "codex", args: "codex"}}
			bindingTestProcesses(t, cwd, started, processes, nil)
			s.refreshAgentSessionBinding(w.id)
			bindingTestNextPoll(s, w)
			write(bindingTestIDs[0], cwd, time.Now())
			switch mode {
			case "exit":
				delete(processes, 101)
			case "close":
				w.closed = true
			case "probe-failure":
				processTableForMetadata = func() map[int]processInfo { return nil }
			}
			cachedAt := s.agentSessionBindings.stores["codex"].at
			s.refreshAgentSessionBinding(w.id)
			if w.agentSessionIdentityExact || s.agentSessionBindings.stores["codex"].at != cachedAt {
				t.Fatal("inactive watch bound/read store")
			}
			if mode == "exit" && !w.agentSessionWatch.exited {
				t.Fatal("exit was not recorded")
			}
			if mode == "probe-failure" && w.agentSessionWatch.exited {
				t.Fatal("failed probe mistaken for exit")
			}
		})
	}
}

func TestAgentSessionBindingReplacementDoesNotInheritExactID(t *testing.T) {
	cwd, write := bindingTestStore(t, "codex")
	started := time.Now().Add(-time.Second)
	w := bindingTestWindow("codex", cwd, "@1", started)
	w.proc = bindingTestProcess{pid: 100}
	s := &muxServer{windows: []*muxWindow{w}}
	processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: "codex", args: "codex"}}
	files := map[int][]string{101: {write(bindingTestIDs[0], cwd, time.Now())}}
	bindingTestProcesses(t, cwd, started, processes, files)
	s.refreshAgentSessionBinding(w.id)
	if !w.agentSessionIdentityExact {
		t.Fatal("initial process did not bind")
	}
	delete(processes, 101)
	processes[102] = processInfo{pid: 102, ppid: 100, comm: "codex", args: "codex"}
	files[102] = []string{write(bindingTestIDs[1], cwd, time.Now())}
	bindingTestNextPoll(s, w)
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionID != bindingTestIDs[1] || !w.agentSessionIdentityExact {
		t.Fatalf("replacement inherited old identity: %q", w.agentSessionID)
	}
}

func TestAgentSessionBindingResumeBeforeStoreCreation(t *testing.T) {
	cwd, _ := bindingTestStore(t, "codex")
	started := time.Now()
	w := bindingTestWindow("codex", cwd, "@1", started)
	s := &muxServer{windows: []*muxWindow{w}}
	pollBindingTest(s, w, started, bindingTestIDs[0])
	if w.agentSessionID != bindingTestIDs[0] || !w.agentSessionIdentityExact {
		t.Fatal("explicit resume waited for a lazy file")
	}
}

func TestAgentSessionBindingProvisionalCursorDirectory(t *testing.T) {
	cwd, _ := bindingTestStore(t, "cursor-agent")
	started := time.Now()
	w := bindingTestWindow("cursor-agent", cwd, "@1", started)
	w.agentSessionAssigned, w.agentSessionID = true, bindingTestIDs[0]
	s := &muxServer{windows: []*muxWindow{w}}
	home, _ := os.UserHomeDir()
	if err := os.MkdirAll(filepath.Join(home, ".cursor", "chats", "workspace", bindingTestIDs[0]), 0700); err != nil {
		t.Fatal(err)
	}
	pollBindingTest(s, w, started, "")
	if !w.agentSessionIdentityExact {
		t.Fatal("chat directory did not confirm assigned ID")
	}
}

func TestAgentSessionBindingCopilotUsesFreshestOwnedLock(t *testing.T) {
	cwd, _ := bindingTestStore(t, "copilot")
	started := time.Now().Add(-time.Minute)
	w := bindingTestWindow("copilot", cwd, "@1", started)
	w.agentSessionWatch.pid = 101
	s := &muxServer{windows: []*muxWindow{w}}
	home, _ := os.UserHomeDir()
	for i, id := range bindingTestIDs {
		bindingTestWriteFile(t, filepath.Join(home, ".copilot", "session-state", id, "inuse.101.lock"), "101", started.Add(time.Duration(i+1)*time.Second))
	}
	pollBindingTest(s, w, time.Now(), bindingTestIDs[0])
	if w.agentSessionID != bindingTestIDs[1] {
		t.Fatalf("did not prefer latest lock over stale resume args: %q", w.agentSessionID)
	}
}

func TestAgentSessionBindingOwnershipWithoutStartTime(t *testing.T) {
	cwd, _ := bindingTestStore(t, "claude")
	w := &muxWindow{id: "@1", cwd: cwd, agentTool: "claude", proc: bindingTestProcess{pid: 100}}
	s := &muxServer{windows: []*muxWindow{w}}
	processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: "claude", args: "claude"}}
	bindingTestProcesses(t, cwd, time.Time{}, processes, nil)
	bindingTestRegistry(t, 101, bindingTestIDs[0], cwd, time.Now())
	s.refreshAgentSessionBinding(w.id)
	if w.agentSessionID != bindingTestIDs[0] || !w.agentSessionIdentityExact {
		t.Fatal("exact registry ownership required a process start time")
	}
}

func TestRestoreAgentSessionRejectsLiveForeignOwner(t *testing.T) {
	for _, tool := range []string{"claude", "copilot", "codex"} {
		for _, ownEntry := range []bool{true, false} {
			for _, descendant := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/own=%v/descendant=%v", tool, ownEntry, descendant), func(t *testing.T) {
					cwd, write := bindingTestStore(t, tool)
					started := time.Now().Add(-time.Minute)
					processes := map[int]processInfo{
						100: {pid: 100, comm: "zsh"},
						101: {pid: 101, ppid: 100, comm: tool, args: tool},
						200: {pid: 200, comm: "zsh"},
						201: {pid: 201, ppid: 200, comm: tool, args: tool},
					}
					owner := 101
					if descendant {
						owner = 102
						processes[owner] = processInfo{pid: owner, ppid: 101, comm: tool, args: tool}
					}
					files := map[int][]string{}
					bindingTestProcesses(t, cwd, started, processes, files)
					home, _ := os.UserHomeDir()
					for i, id := range bindingTestIDs {
						pid := owner
						at := started.Add(time.Second)
						if i == 0 && !ownEntry {
							continue
						}
						if i == 1 {
							pid, at = 201, time.Now()
						}
						switch tool {
						case "claude":
							write(id, cwd, at)
							bindingTestRegistry(t, pid, id, cwd, started)
						case "copilot":
							writeCopilotSession(t, filepath.Join(home, ".copilot", "session-state"), id, cwd, pid, at)
						case "codex":
							files[pid] = []string{write(id, cwd, at)}
						}
					}
					// No watcher has polled: the force-update snapshot must resolve
					// ownership itself, even while the foreign transcript is newer.
					restore := &serverRestore{Windows: []restoreWindowState{{ID: "@1", AgentTool: tool, AgentToolConfirmed: true, CurrentCommand: tool, PanePid: 100, Cwd: cwd}}}
					enrichRestoreWithAgentSessionIDs(restore)
					want := ""
					if ownEntry {
						want = bindingTestIDs[0]
					}
					if got := restore.Windows[0].AgentSessionID; got != want {
						t.Fatalf("snapshot id = %q, want %q", got, want)
					}
				})
			}
		}
	}
}

func TestAgentSessionOwnershipExclusion(t *testing.T) {
	for _, tool := range []string{"claude", "copilot", "codex", "opencode", "antigravity", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			now := time.Now()
			home, _ := os.UserHomeDir()
			// Only the tool's own processes are inspected for open session files,
			// so the foreign owner runs the tool's executable too.
			executable := agentCommands[tool].executable
			processes := map[int]processInfo{101: {pid: 101, comm: tool}, 201: {pid: 201, comm: executable}}
			files := map[int][]string{}
			bindingTestProcesses(t, cwd, now.Add(-time.Minute), processes, files)
			id := bindingTestIDs[0]
			switch tool {
			case "claude":
				// startedAt is optional for exclusion; PID and session ID suffice.
				bindingTestWriteFile(t, filepath.Join(home, ".claude", "sessions", "201.json"), fmt.Sprintf(`{"pid":201,"sessionId":%q,"cwd":%q}`, id, cwd), now)
			case "copilot":
				writeCopilotSession(t, filepath.Join(home, ".copilot", "session-state"), id, cwd, 201, now)
			case "opencode":
				files[201] = []string{filepath.Join(home, ".local", "share", "opencode", "opencode.db-wal")}
			case "antigravity":
				files[201] = []string{filepath.Join(home, ".gemini", "antigravity-cli", "presence", id+".lock")}
			default:
				files[201] = []string{write(id, cwd, now)}
			}
			if !agentSessionOwnedElsewhere(tool, id, map[int]struct{}{101: {}}) {
				t.Fatal("foreign live owner was not excluded")
			}
			if agentSessionOwnedElsewhere(tool, id, map[int]struct{}{101: {}, 201: {}}) {
				t.Fatal("own descendant was excluded")
			}
			delete(processes, 201)
			if agentSessionOwnedElsewhere(tool, id, map[int]struct{}{101: {}}) {
				t.Fatal("dead owner was excluded")
			}
			processTableForMetadata = func() map[int]processInfo { return nil }
			if !agentSessionOwnedElsewhere(tool, id, map[int]struct{}{101: {}}) {
				t.Fatal("unknown ownership was not excluded")
			}
			watch := newAgentSessionWatch(tool, cwd, now.Add(-time.Minute), nil)
			candidates := []agentSessionCandidate{{id: id, cwd: cwd, created: now}}
			if got := excludeForeignAgentSessions(tool, candidates, nil, watch, ""); len(got) != 0 {
				t.Fatal("candidate with unknown ownership survived exclusion")
			}
		})
	}
}

func TestRestoreAgentExitedBeforeSnapshot(t *testing.T) {
	for _, tool := range []string{"claude", "copilot", "codex", "opencode", "antigravity", "cursor-agent"} {
		for _, identity := range []string{"none", "carried", "assigned", "exact", "explicit"} {
			t.Run(tool+"/"+identity, func(t *testing.T) {
				cwd, write := bindingTestStore(t, tool)
				started := time.Now().Add(-time.Minute)
				home, _ := os.UserHomeDir()
				id := bindingTestIDs[0]
				if tool == "copilot" {
					writeCopilotSession(t, filepath.Join(home, ".copilot", "session-state"), id, cwd, 201, time.Now())
				} else {
					write(id, cwd, time.Now())
				}
				// The pane shell lives on after its agent exited.
				bindingTestProcesses(t, cwd, started, map[int]processInfo{100: {pid: 100, comm: "zsh", args: "zsh"}}, nil)
				window := restoreWindowState{ID: "@1", AgentTool: tool, AgentToolConfirmed: true, CurrentCommand: tool, PanePid: 100, Cwd: cwd}
				want := ""
				switch identity {
				case "carried":
					window.AgentSessionID = id
				case "assigned":
					// A wrapper-assigned ID confirmed by the agent's store is as
					// strong as an exact report; only claude, copilot and cursor
					// stores can confirm one.
					window.AgentSessionID, window.AgentSessionAssigned = id, true
					if tool == "claude" || tool == "copilot" || tool == "cursor-agent" {
						want = id
					}
				case "exact":
					window.AgentSessionID, window.AgentSessionIdentityExact, want = id, true, id
				case "explicit":
					window.CurrentCommand, want = agentResumeCommand(tool, id, false), id
				}
				restore := &serverRestore{Windows: []restoreWindowState{window}}
				enrichRestoreWithAgentSessionIDs(restore)
				if got := restore.Windows[0].AgentSessionID; got != want {
					t.Fatalf("exited agent id = %q, want %q", got, want)
				}
			})
		}
	}
}

func TestAgentSessionFallbacksRejectForeignOwners(t *testing.T) {
	for _, tool := range []string{"claude", "copilot", "codex", "opencode", "antigravity", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			cwd, write := bindingTestStore(t, tool)
			started := time.Now().Add(-time.Minute)
			w := bindingTestWindow(tool, cwd, "@1", started)
			w.proc = bindingTestProcess{pid: 100}
			s := &muxServer{windows: []*muxWindow{w}}
			home, _ := os.UserHomeDir()
			id := bindingTestIDs[1]
			processes := map[int]processInfo{
				100: {pid: 100, comm: "zsh"},
				101: {pid: 101, ppid: 100, comm: tool, args: tool},
				201: {pid: 201, comm: tool, args: tool},
			}
			files := map[int][]string{}
			bindingTestProcesses(t, cwd, started, processes, files)
			switch tool {
			case "copilot":
				writeCopilotSession(t, filepath.Join(home, ".copilot", "session-state"), id, cwd, 201, time.Now())
			case "opencode":
				write(id, cwd, time.Now())
				files[201] = []string{filepath.Join(home, ".local", "share", "opencode", "opencode.db")}
			case "antigravity":
				write(id, cwd, time.Now())
				files[201] = []string{filepath.Join(home, ".gemini", "antigravity-cli", "conversations", id+".db")}
			default:
				files[201] = []string{write(id, cwd, time.Now())}
				if tool == "claude" {
					bindingTestRegistry(t, 201, id, cwd, started)
				}
			}
			s.refreshAgentSessionBinding(w.id)
			if w.agentSessionID != "" {
				t.Fatalf("watcher took foreign session %q", w.agentSessionID)
			}
			restore := &serverRestore{Windows: []restoreWindowState{{ID: w.id, AgentTool: tool, AgentToolConfirmed: true, CurrentCommand: tool, PanePid: 100, Cwd: cwd}}}
			enrichRestoreWithAgentSessionIDs(restore)
			if restore.Windows[0].AgentSessionID != "" {
				t.Fatalf("restore took foreign session %q", restore.Windows[0].AgentSessionID)
			}
			// A stale lock/registry or dead file holder must not permanently
			// reserve the session. The live window can now use cwd inference.
			delete(processes, 201)
			enrichRestoreWithAgentSessionIDs(restore)
			if restore.Windows[0].AgentSessionID != id {
				t.Fatalf("dead owner still excluded session: %q", restore.Windows[0].AgentSessionID)
			}
		})
	}
}

func TestRestoreAntigravityExactOwnershipBeforeHistory(t *testing.T) {
	for _, signal := range []string{"database", "presence"} {
		t.Run(signal, func(t *testing.T) {
			cwd, _ := bindingTestStore(t, "antigravity")
			home, _ := os.UserHomeDir()
			root := filepath.Join(home, ".gemini", "antigravity-cli")
			id := bindingTestIDs[0]
			db := bindingTestWriteFile(t, filepath.Join(root, "conversations", id+".db"), "", time.Now())
			path := db
			if signal == "presence" {
				path = filepath.Join(root, "presence", id+".lock")
			}
			processes := map[int]processInfo{100: {pid: 100, comm: "zsh"}, 101: {pid: 101, ppid: 100, comm: "agy", args: "agy"}, 102: {pid: 102, ppid: 101, comm: "worker"}}
			bindingTestProcesses(t, cwd, time.Now().Add(-time.Minute), processes, map[int][]string{102: {path}})
			restore := &serverRestore{Windows: []restoreWindowState{{ID: "@1", AgentTool: "antigravity", AgentToolConfirmed: true, CurrentCommand: "agy", PanePid: 100, Cwd: cwd}}}
			enrichRestoreWithAgentSessionIDs(restore)
			if got := restore.Windows[0].AgentSessionID; got != id {
				t.Fatalf("exact %s signal without history = %q, want %q", signal, got, id)
			}
		})
	}
}
