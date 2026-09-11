package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// These fixtures exercise discovery through the restore snapshot, with no live
// processes or open files. OpenCode uses its actual SQLite reader when the CLI
// is installed, and its existing reader seam on hosts without SQLite.
func TestEnrichRestoreSharedCwdSessions(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "opencode", "antigravity", "cursor-agent"} {
		for _, evidence := range []string{"fresh", "argv", "open-file", "exact"} {
			if evidence == "open-file" && tool != "claude" && tool != "codex" {
				continue
			}
			t.Run(tool+"/"+evidence, func(t *testing.T) {
				home, cwd, now, processes, restore := sharedCwdRestoreFixture(t, tool)
				ids := []string{sharedCwdSessionID(1), sharedCwdSessionID(2), sharedCwdSessionID(3)}
				paths := make([]string, 3)
				for i, id := range ids {
					paths[i] = writeSharedCwdSession(t, tool, home, cwd, id, now.Add(time.Duration(i-3)*time.Minute))
				}
				// Neither newer activity elsewhere nor stale project history may win.
				writeSharedCwdSession(t, tool, home, cwd+"-other", sharedCwdSessionID(4), now)
				writeSharedCwdSession(t, tool, home, cwd, sharedCwdSessionID(5), now.Add(-time.Hour))
				want := map[int]string{100: "", 101: "", 102: ""}
				if evidence != "fresh" {
					// The oldest process owns the newest session. Reserve it before any
					// fallback, even when its process is visited last in the map.
					p := processes[200]
					if evidence == "argv" {
						flag := " --resume "
						switch tool {
						case "codex":
							flag = " resume "
						case "opencode":
							flag = " --session "
						case "antigravity":
							flag = " --conversation "
						}
						p.args += flag + ids[2]
						processes[200] = p
						p = processes[201]
						p.args += flag + ids[0]
						processes[201] = p
					} else if evidence == "open-file" {
						processOpenFilePathsForMetadata = func(pid int) []string {
							if pid == 200 {
								return []string{paths[2]}
							}
							if pid == 201 {
								return []string{paths[0]}
							}
							return nil
						}
					}
					if evidence == "exact" {
						for i := range restore.Windows {
							if restore.Windows[i].PanePid == 100 || restore.Windows[i].PanePid == 101 {
								id := ids[2]
								if restore.Windows[i].PanePid == 101 {
									id = ids[0]
								}
								restore.Windows[i].AgentSessionID = id
								restore.Windows[i].AgentSessionIdentityExact = true
							}
						}
					}
					// Remaining candidates satisfy the unresolved process lifetime.
					processStartedAtForMetadata = func(pid int) time.Time { return now.Add(time.Duration(pid-206) * time.Minute) }
					want = map[int]string{100: ids[2], 101: ids[0], 102: ids[1]}
				}
				for range 5 { // Map iteration must not change the pairing.
					enrichRestoreWithAgentSessionIDs(restore)
					got := map[int]string{}
					used := map[string]bool{}
					for _, window := range restore.Windows {
						got[window.PanePid] = window.AgentSessionID
						if window.AgentSessionID != "" && used[window.AgentSessionID] {
							t.Fatalf("duplicate session %q", window.AgentSessionID)
						}
						used[window.AgentSessionID] = true
						if window.AgentSessionID != "" {
							command := createWindowOptionsForRestore(window, false).command
							if !strings.Contains(command, window.AgentSessionID) {
								t.Fatalf("restore command %q omits session %q", command, window.AgentSessionID)
							}
						}
					}
					if !reflect.DeepEqual(got, want) {
						t.Fatalf("sessions = %v, want %v", got, want)
					}
				}
			})
		}
	}
}

func TestEnrichRestoreSharedCwdInsufficientSessions(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "opencode", "antigravity", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			home, cwd, now, _, restore := sharedCwdRestoreFixture(t, tool)
			id := sharedCwdSessionID(1)
			// Too old for the newest process, valid for the middle and oldest.
			writeSharedCwdSession(t, tool, home, cwd, id, now.Add(-3*time.Minute))
			writeSharedCwdSession(t, tool, home, cwd, sharedCwdSessionID(2), now.Add(-time.Hour))
			enrichRestoreWithAgentSessionIDs(restore)
			got := map[int]string{}
			for _, window := range restore.Windows {
				got[window.PanePid] = window.AgentSessionID
			}
			want := map[int]string{100: "", 101: "", 102: ""}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("sessions = %v, want %v", got, want)
			}
		})
	}
}

func TestEnrichRestoreSharedCwdDuplicateArgv(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "opencode", "antigravity", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			home, cwd, now, processes, restore := sharedCwdRestoreFixture(t, tool)
			id := sharedCwdSessionID(1)
			otherID := sharedCwdSessionID(2)
			writeSharedCwdSession(t, tool, home, cwd, id, now)
			writeSharedCwdSession(t, tool, home, cwd, otherID, now.Add(-time.Minute))
			flag := " --resume "
			switch tool {
			case "codex":
				flag = " resume "
			case "opencode":
				flag = " --session "
			case "antigravity":
				flag = " --conversation "
			}
			for _, pid := range []int{200, 201} {
				p := processes[pid]
				p.args += flag + id
				processes[pid] = p
			}
			enrichRestoreWithAgentSessionIDs(restore)
			counts := map[string]int{}
			for _, window := range restore.Windows {
				counts[window.AgentSessionID]++
				if window.PanePid == 102 && window.AgentSessionID != otherID {
					t.Fatalf("unresolved sibling = %q, want %q", window.AgentSessionID, otherID)
				}
			}
			if counts[id] != 1 || counts[otherID] != 1 || counts[""] != 1 {
				t.Fatalf("session counts = %v, want one claimed, one fallback, one unresolved", counts)
			}
		})
	}
}

// A foreign newest session must not consume a pairing slot and leave a local
// pane unresolved after the final ownership guard removes it.
func TestEnrichRestoreSharedCwdSkipsForeignSession(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "antigravity", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			home, cwd, now, processes, restore := sharedCwdRestoreFixture(t, tool)
			for i := 1; i <= 3; i++ {
				writeSharedCwdSession(t, tool, home, cwd, sharedCwdSessionID(i), now.Add(time.Duration(i-4)*time.Minute))
			}
			for i := range restore.Windows {
				if restore.Windows[i].PanePid != 102 {
					restore.Windows[i].AgentSessionID = sharedCwdSessionID(restore.Windows[i].PanePid - 99)
					restore.Windows[i].AgentSessionIdentityExact = true
				}
			}
			foreignID := sharedCwdSessionID(4)
			path := writeSharedCwdSession(t, tool, home, cwd, foreignID, now)
			command := tool
			if tool == "antigravity" {
				command = "agy"
				path = filepath.Join(home, ".gemini", "antigravity-cli", "conversations", foreignID+".db")
			}
			processes[300] = processInfo{pid: 300, ppid: 1, comm: command, args: command}
			if tool == "claude" {
				bindingTestRegistry(t, 300, foreignID, cwd, now.Add(-time.Minute))
			}
			processOpenFilePathsForMetadata = func(pid int) []string {
				if pid == 300 {
					return []string{path}
				}
				return nil
			}
			bindingTestExpireForeignOwnership()
			enrichRestoreWithAgentSessionIDs(restore)
			for _, window := range restore.Windows {
				want := sharedCwdSessionID(window.PanePid - 99)
				if window.AgentSessionID != want {
					t.Fatalf("pane %d session = %q, want %q", window.PanePid, window.AgentSessionID, want)
				}
			}
		})
	}
}

func TestEnrichRestoreSharedCwdReservesClaudeRegistry(t *testing.T) {
	home, cwd, now, _, restore := sharedCwdRestoreFixture(t, "claude")
	for i := 1; i <= 3; i++ {
		writeSharedCwdSession(t, "claude", home, cwd, sharedCwdSessionID(i), now.Add(time.Duration(i-4)*time.Minute))
	}
	processStartedAtForMetadata = func(pid int) time.Time { return now.Add(time.Duration(pid-206) * time.Minute) }
	bindingTestRegistry(t, 200, sharedCwdSessionID(3), cwd, processStartedAtForMetadata(200))
	bindingTestRegistry(t, 201, sharedCwdSessionID(1), cwd, processStartedAtForMetadata(201))
	bindingTestExpireForeignOwnership()
	enrichRestoreWithAgentSessionIDs(restore)
	want := map[int]string{100: sharedCwdSessionID(3), 101: sharedCwdSessionID(1), 102: sharedCwdSessionID(2)}
	for _, window := range restore.Windows {
		if window.AgentSessionID != want[window.PanePid] {
			t.Fatalf("pane %d session = %q, want %q", window.PanePid, window.AgentSessionID, want[window.PanePid])
		}
	}
}

func TestEnrichRestoreSharedCwdActivityDoesNotProveOwnership(t *testing.T) {
	for _, tool := range []string{"claude", "codex", "opencode", "antigravity", "cursor-agent"} {
		t.Run(tool, func(t *testing.T) {
			home, cwd, now, processes, restore := sharedCwdRestoreFixture(t, tool)
			restore.Windows = restore.Windows[:2]
			delete(processes, 102)
			delete(processes, 202)
			// A started before B, then A's activity became newer than B's.
			// Activity-based pairing would give A's conversation to B.
			writeSharedCwdSession(t, tool, home, cwd, sharedCwdSessionID(1), now)
			writeSharedCwdSession(t, tool, home, cwd, sharedCwdSessionID(2), now.Add(-time.Minute))
			enrichRestoreWithAgentSessionIDs(restore)
			for _, window := range restore.Windows {
				if window.AgentSessionID != "" {
					t.Fatalf("activity guessed pane %d owns %q", window.PanePid, window.AgentSessionID)
				}
			}
		})
	}
}

func sharedCwdSessionID(index int) string { return fmt.Sprintf("123e4567-e89b-12d3-a456-%012d", index) }

func sharedCwdRestoreFixture(t *testing.T, tool string) (string, string, time.Time, map[int]processInfo, *serverRestore) {
	t.Helper()
	home := t.TempDir()
	setTestHomeDir(t, home)
	cwd := filepath.Join(home, "project")
	now := time.Now().UTC().Truncate(time.Second)
	oldTable, oldFiles := processTableForMetadata, processOpenFilePathsForMetadata
	oldCwd, oldStart := processWorkingDirectoryForMetadata, processStartedAtForMetadata
	oldOpenCodeReader := openCodeSessionEntriesReader
	t.Cleanup(func() {
		processTableForMetadata, processOpenFilePathsForMetadata = oldTable, oldFiles
		processWorkingDirectoryForMetadata, processStartedAtForMetadata = oldCwd, oldStart
		openCodeSessionEntriesReader = oldOpenCodeReader
	})
	command := tool
	if tool == "antigravity" {
		command = "agy"
	}
	processes := map[int]processInfo{}
	restore := &serverRestore{}
	// Deliberately put windows in neither start-time nor PID order.
	for _, i := range []int{1, 0, 2} {
		processes[100+i] = processInfo{pid: 100 + i, ppid: 1, comm: "zsh", args: "zsh"}
		processes[200+i] = processInfo{pid: 200 + i, ppid: 100 + i, comm: command, args: command}
		restore.Windows = append(restore.Windows, restoreWindowState{Name: tool, AgentTool: tool, CurrentCommand: command, Cwd: cwd, PanePid: 100 + i})
	}
	processTableForMetadata = func() map[int]processInfo { return processes }
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(int) string { return cwd }
	processStartedAtForMetadata = func(pid int) time.Time { return now.Add(time.Duration(pid-204) * time.Minute) }
	return home, cwd, now, processes, restore
}

func writeSharedCwdSession(t *testing.T, tool, home, cwd, id string, updated time.Time) string {
	t.Helper()
	var path string
	var record any
	switch tool {
	case "claude":
		path = filepath.Join(home, ".claude", "projects", claudeEncodedProjectDirName(cwd), id+".jsonl")
		record = map[string]any{"cwd": cwd, "sessionId": id}
	case "codex":
		path = filepath.Join(home, ".codex", "sessions", "2026", "09", "rollout-2026-09-10T00-00-00-"+id+".jsonl")
		record = map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd, "id": id}}
	case "antigravity":
		path = filepath.Join(home, ".gemini", "antigravity-cli", "history.jsonl")
		record = map[string]any{"workspace": cwd, "conversationId": id, "timestamp": updated.UnixMilli()}
	case "cursor-agent":
		path = filepath.Join(home, ".cursor", "chats", "workspace", id, "meta.json")
		record = map[string]any{"cwd": cwd, "updatedAtMs": updated.UnixMilli()}
	case "opencode":
		sqlite, err := exec.LookPath("sqlite3")
		if err != nil {
			// Discovery itself must remain covered on Windows and other hosts
			// where the optional SQLite CLI is absent.
			entries := append(readOpenCodeSessionEntries(), openCodeSessionEntry{
				sessionID: id, directory: normalizedMetadataPath(cwd), updatedAt: updated,
			})
			openCodeSessionEntriesReader = func() []openCodeSessionEntry { return entries }
			return ""
		}
		path = filepath.Join(home, ".local", "share", "opencode", "opencode.db")
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
		query := "CREATE TABLE IF NOT EXISTS session (id TEXT, directory TEXT, time_updated INTEGER, parent_id TEXT, time_archived INTEGER);"
		query += fmt.Sprintf("INSERT INTO session VALUES (%s, %s, %d, NULL, NULL);", quote(id), quote(cwd), updated.UnixMilli())
		if output, err := exec.Command(sqlite, path, query).CombinedOutput(); err != nil {
			t.Fatalf("sqlite fixture: %v: %s", err, output)
		}
		return path
	default:
		t.Fatalf("unsupported fixture tool %q", tool)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, writeErr := file.Write(append(data, '\n'))
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		t.Fatalf("write fixture: %v, %v", writeErr, closeErr)
	}
	if err := os.Chtimes(path, updated, updated); err != nil {
		t.Fatal(err)
	}
	return path
}
