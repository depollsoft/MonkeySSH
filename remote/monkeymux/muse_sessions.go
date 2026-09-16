package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var museBinaryNamePattern = regexp.MustCompile(`^muse-bin-\d+\.\d+\.\d+-r\d+(?:\.\d+)?$`)

func museSessionsRoot() string {
	data := os.Getenv("XDG_DATA_HOME")
	if data == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		data = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(data, "muse", "sessions")
}

func museSessionIDFromPath(path string) string {
	root := museSessionsRoot()
	if root == "" {
		return ""
	}
	rel, err := filepath.Rel(root, path)
	parts := strings.Split(filepath.ToSlash(rel), "/")
	// Root sessions only: YYYY/MM/DD/<uuid>/session.jsonl. In particular,
	// nested subagents must never become the parent pane's identity.
	if err != nil || len(parts) != 5 || parts[0] == ".." || parts[4] != "session.jsonl" || !agentSessionIDValid("muse", parts[3]) {
		return ""
	}
	return parts[3]
}

func readMuseSessionCandidates() []agentSessionCandidate {
	root := museSessionsRoot()
	if root == "" {
		return nil
	}
	var candidates []agentSessionCandidate
	for _, path := range recentAgentSessionFiles(root, int(^uint(0)>>1), func(path string) bool { return museSessionIDFromPath(path) != "" }) {
		file, err := os.Open(path)
		if err != nil {
			continue
		}
		info, err := file.Stat()
		if err != nil || !info.Mode().IsRegular() {
			file.Close()
			continue
		}
		scanner := bufio.NewScanner(io.LimitReader(file, 64*1024))
		scanner.Buffer(make([]byte, 4096), 64*1024)
		for scanner.Scan() {
			var record struct {
				PayloadType string `json:"payload_type"`
				Stream      struct {
					ID string `json:"id"`
				} `json:"stream"`
				Payload struct {
					Record struct {
						WorkspaceRoot string `json:"workspace_root"`
					} `json:"record"`
				} `json:"payload"`
			}
			if json.Unmarshal(scanner.Bytes(), &record) != nil || record.PayloadType != "runtime.session.metadata" {
				continue
			}
			id := museSessionIDFromPath(path)
			if record.Stream.ID == id && record.Payload.Record.WorkspaceRoot != "" {
				candidates = append(candidates, agentSessionCandidate{id: id, path: path, cwd: normalizedMetadataPath(record.Payload.Record.WorkspaceRoot), created: info.ModTime()})
			}
			break
		}
		file.Close()
	}
	return candidates
}
