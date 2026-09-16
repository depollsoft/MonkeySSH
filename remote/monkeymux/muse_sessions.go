package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
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

// Keep every historical identity in the launch baseline, but avoid reopening
// unchanged transcript heads on each store poll. Entries disappear with their
// files, and switching data roots discards the previous root's cache.
var museSessionMetadataCache = struct {
	sync.Mutex
	museSessionCache
}{}

type museSessionCacheEntry struct {
	info      os.FileInfo
	candidate agentSessionCandidate
}

type museSessionCache struct {
	root    string
	entries map[string]museSessionCacheEntry
}

func readMuseSessionCandidates() []agentSessionCandidate {
	museSessionMetadataCache.Lock()
	defer museSessionMetadataCache.Unlock()
	return museSessionMetadataCache.read(museSessionsRoot(), readMuseSessionMetadata)
}

func (cache *museSessionCache) read(root string, readMetadata func(string, string) (agentSessionCandidate, bool)) []agentSessionCandidate {
	if cache.root != root {
		cache.root, cache.entries = root, nil
	}
	next := map[string]museSessionCacheEntry{}
	var candidates []agentSessionCandidate
	if root == "" {
		cache.entries = next
		return nil
	}
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry == nil || !entry.IsDir() || path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return filepath.SkipDir
		}
		parts := strings.Split(filepath.ToSlash(rel), "/")
		if len(parts) < 4 {
			return nil
		}
		// Read only YYYY/MM/DD/<uuid>/session.jsonl. Do not traverse the
		// potentially large worker/artifact trees beneath a session directory.
		id := parts[3]
		if len(parts) != 4 || !agentSessionIDValid("muse", id) {
			return filepath.SkipDir
		}
		logPath := filepath.Join(path, "session.jsonl")
		info, err := os.Stat(logPath)
		if err != nil || !info.Mode().IsRegular() {
			return filepath.SkipDir
		}
		cached, ok := cache.entries[logPath]
		if !ok || !os.SameFile(cached.info, info) || cached.info.Size() != info.Size() ||
			!cached.info.ModTime().Equal(info.ModTime()) || cached.info.Mode() != info.Mode() {
			candidate, valid := readMetadata(logPath, id)
			if !valid {
				return filepath.SkipDir
			}
			candidate.created = info.ModTime()
			cached = museSessionCacheEntry{info: info, candidate: candidate}
		}
		next[logPath] = cached
		candidates = append(candidates, cached.candidate)
		return filepath.SkipDir
	})
	cache.entries = next
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].created.After(candidates[j].created) })
	return candidates
}

func readMuseSessionMetadata(path, id string) (agentSessionCandidate, bool) {
	file, err := os.Open(path)
	if err != nil {
		return agentSessionCandidate{}, false
	}
	defer file.Close()
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
		if record.Stream.ID == id && record.Payload.Record.WorkspaceRoot != "" {
			return agentSessionCandidate{id: id, path: path, cwd: normalizedMetadataPath(record.Payload.Record.WorkspaceRoot)}, true
		}
		break
	}
	return agentSessionCandidate{}, false
}
