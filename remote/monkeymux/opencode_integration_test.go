package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenCodeV2ConfigPreservesUserPlugins(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	configDirectory := t.TempDir()
	global := []byte(`{
  // Keep the user's existing plugins, including configured packages.
  "plugins": ["https://example.com/plugin", {"package":"user-plugin","options":{"text":"/* literal */"}},],
  "scroll": {"speed": 5,},
}`)
	path := filepath.Join(configDirectory, "cli.json")
	if err := os.WriteFile(path, global, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, overlay string
		wantPlugins   []string
	}{
		{"global", `{}`, []string{"https://example.com/plugin", "user-plugin"}},
		{"inline", `{"plugins":["inline-plugin",],/* inline config also supports JSONC */"scroll":{"speed":3,"acceleration":true},"tabs":{"mode":"off"}}`, []string{"inline-plugin"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := []string{"OPENCODE_CONFIG_DIR=" + configDirectory, "OPENCODE_CLI_CONFIG_CONTENT=" + tc.overlay}
			launch, err := prepareAgentLaunch("opencode", nil, env, "/monkeymux")
			if err != nil {
				t.Fatal(err)
			}
			var config struct {
				Plugins []json.RawMessage `json:"plugins"`
				Scroll  struct {
					Speed        int  `json:"speed"`
					Acceleration bool `json:"acceleration"`
				} `json:"scroll"`
			}
			for _, entry := range launch.env {
				if content, ok := strings.CutPrefix(entry, "OPENCODE_CLI_CONFIG_CONTENT="); ok {
					if err := json.Unmarshal([]byte(content), &config); err != nil {
						t.Fatal(err)
					}
				}
			}
			if len(config.Plugins) != len(tc.wantPlugins)+1 || config.Scroll.Acceleration {
				t.Fatalf("bad merged config: %+v", config)
			}
			for i, want := range tc.wantPlugins {
				if !bytes.Contains(config.Plugins[i], []byte(want)) {
					t.Fatalf("lost user plugin: %s", config.Plugins[i])
				}
			}
			if tc.name == "inline" && config.Scroll.Speed != 3 {
				t.Fatal("lost explicit inline scroll speed")
			}
			again, err := prepareAgentLaunch("opencode", nil, launch.env, "/monkeymux")
			v2Environment := func(env []string) string {
				for _, entry := range env {
					if strings.HasPrefix(entry, "OPENCODE_CLI_CONFIG_CONTENT=") {
						return entry
					}
				}
				return ""
			}
			if err != nil || v2Environment(again.env) != v2Environment(launch.env) {
				t.Fatalf("repeated preparation changed environment: %v", err)
			}
		})
	}
	if after, err := os.ReadFile(path); err != nil || !bytes.Equal(after, global) {
		t.Fatal("changed the user's cli.json")
	}
}

func TestOpenCodeJSONCEscapedStrings(t *testing.T) {
	input := []byte(`{"plugins":[{"package":"file:///some/\"quoted\"/path","options":{"literal":"//not a comment,}",},},],/* comment */}`)
	var parsed map[string]any
	if err := json.Unmarshal(normalizeOpenCodeJSONC(input), &parsed); err != nil {
		t.Fatal(err)
	}
	plugin := parsed["plugins"].([]any)[0].(map[string]any)
	if plugin["package"] != `file:///some/"quoted"/path` || plugin["options"].(map[string]any)["literal"] != "//not a comment,}" {
		t.Fatalf("changed string contents: %#v", parsed)
	}
}

func TestOpenCodeSessionDatabaseVersions(t *testing.T) {
	sqlite, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Skip("SQLite CLI is unavailable")
	}
	for _, table := range []string{"session", "session_v2"} {
		t.Run(table, func(t *testing.T) {
			t.Setenv("XDG_DATA_HOME", t.TempDir())
			t.Setenv("OPENCODE_DB", "custom.db")
			db := filepath.Join(os.Getenv("XDG_DATA_HOME"), "opencode", "custom.db")
			if err := os.MkdirAll(filepath.Dir(db), 0o700); err != nil {
				t.Fatal(err)
			}
			query := "CREATE TABLE " + table + " (id TEXT, directory TEXT, time_updated INTEGER, parent_id TEXT, time_archived INTEGER);" +
				"INSERT INTO " + table + " VALUES ('ses_root','/project',1783405351000,NULL,NULL), ('ses_child','/project',1783405352000,'ses_root',NULL), ('ses_archived','/project',1783405353000,NULL,1);"
			if table == "session_v2" {
				query += "CREATE TABLE session (id TEXT, directory TEXT, time_updated INTEGER, parent_id TEXT, time_archived INTEGER);INSERT INTO session VALUES ('ses_stale','/project',1783405354000,NULL,NULL);"
			}
			if output, err := exec.Command(sqlite, db, query).CombinedOutput(); err != nil {
				t.Fatalf("fixture: %v, %s", err, output)
			}
			entries := defaultOpenCodeSessionEntries()
			if len(entries) != 1 || entries[0].sessionID != "ses_root" || entries[0].updatedAt.UnixMilli() != 1783405351000 {
				t.Fatalf("sessions = %+v", entries)
			}
			if table == "session_v2" {
				if _, err := exec.Command(sqlite, db, "DELETE FROM session_v2;").Output(); err != nil {
					t.Fatal(err)
				}
				if got := defaultOpenCodeSessionEntries(); len(got) != 0 {
					t.Fatalf("empty V2 database resurrected V1 sessions: %+v", got)
				}
			}
		})
	}
}
