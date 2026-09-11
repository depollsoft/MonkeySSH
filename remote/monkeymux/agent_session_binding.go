package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const agentSessionStorePollInterval = 2 * time.Second

// All binding state is owned by muxServer.mu. Store reads and process probes
// happen outside that lock; their results are checked against the live watch.
type agentSessionWatch struct {
	tool, cwd                           string
	pid, registryPID                    int
	started, lastPoll                   time.Time
	baseline                            map[string]bool
	firstSeen                           map[string]time.Time
	processPIDs, claudePIDs, windowPIDs map[int]bool
	done, exited                        bool
}

type agentSessionCandidate struct {
	id, path, cwd string
	created       time.Time
	ownerPID      int
	ownershipPath string
	registry      bool
}

type agentSessionStoreSnapshot struct {
	at         time.Time
	candidates []agentSessionCandidate
	loading    chan struct{}
}

type agentSessionBindingState struct {
	pending int
	stores  map[string]agentSessionStoreSnapshot
}

func fileBackedAgent(tool string) bool {
	switch tool {
	case "copilot", "claude", "codex", "opencode", "antigravity", "cursor-agent":
		return true
	}
	return false
}

func newAgentSessionWatch(tool, cwd string, started time.Time, baseline []agentSessionCandidate) *agentSessionWatch {
	if !fileBackedAgent(tool) {
		return nil
	}
	watch := &agentSessionWatch{tool: tool, cwd: normalizedMetadataPath(cwd), started: started,
		baseline: map[string]bool{}, firstSeen: map[string]time.Time{}}
	for _, candidate := range baseline {
		watch.baseline[candidate.id] = true
		if candidate.path != "" {
			watch.baseline[candidate.path] = true
		}
	}
	return watch
}

// Register the pending launch before taking the baseline. A concurrent launch
// cannot claim its file while this process is starting but is not yet a window.
func (s *muxServer) prepareAgentSessionWatch(tool, cwd string, options createWindowOptions) (*agentSessionWatch, func()) {
	if !fileBackedAgent(tool) || options.agentSessionIdentityExact {
		return nil, func() {}
	}
	s.mu.Lock()
	s.agentSessionBindings.pending++
	s.mu.Unlock()
	baseline := s.agentSessionStore(tool, time.Now())
	watch := newAgentSessionWatch(tool, cwd, time.Now(), baseline)
	return watch, func() {
		s.mu.Lock()
		s.agentSessionBindings.pending--
		s.mu.Unlock()
	}
}

// agentSessionOwnedElsewhere uses the process snapshot as the liveness check.
// OpenCode's database is shared: a foreign handle excludes all inferred rows,
// since a database handle alone cannot establish ownership of a particular ID.
func agentSessionOwnedElsewhere(tool, id string, windowPids map[int]struct{}) bool {
	if id == "" {
		return false
	}
	processes := processTableForMetadata()
	if processes == nil {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return true
	}
	foreign := func(pid int) bool {
		_, alive := processes[pid]
		_, own := windowPids[pid]
		return alive && !own
	}
	switch tool {
	case "claude":
		for _, candidate := range readClaudeSessionRegistry(home) {
			if candidate.id == id && foreign(candidate.ownerPID) {
				return true
			}
		}
		return false
	case "copilot":
		locks, _ := filepath.Glob(filepath.Join(home, ".copilot", "session-state", id, "inuse.*.lock"))
		for _, lock := range locks {
			if foreign(pidFromCopilotLockPath(lock)) {
				return true
			}
		}
		return false
	case "codex", "antigravity", "opencode", "cursor-agent":
	default:
		return false
	}
	for pid, info := range processes {
		// Only the tool's own processes can hold its session files, and listing
		// open files costs one lsof per process: never scan the whole machine.
		if !foreign(pid) || (agentToolFromCommandName(info.comm) != tool &&
			agentToolFromCommandName(agentCommandNameFromProcessArgs(info.args)) != tool) {
			continue
		}
		for _, path := range processOpenFilePathsForMetadata(pid) {
			path = normalizedMetadataPath(path)
			switch tool {
			case "codex":
				if codexSessionIDFromRolloutFile(path) == id {
					return true
				}
			case "antigravity":
				root := filepath.Join(home, ".gemini", "antigravity-cli")
				db := normalizedMetadataPath(filepath.Join(root, "conversations", id+".db"))
				if path == db || path == db+"-wal" || path == db+"-shm" ||
					path == normalizedMetadataPath(filepath.Join(root, "presence", id+".lock")) {
					return true
				}
			case "opencode":
				db := normalizedMetadataPath(filepath.Join(home, ".local", "share", "opencode", "opencode.db"))
				if path == db || path == db+"-wal" || path == db+"-shm" {
					return true
				}
			case "cursor-agent":
				root := normalizedMetadataPath(filepath.Join(home, ".cursor", "chats"))
				rel, err := filepath.Rel(root, path)
				parts := strings.Split(filepath.ToSlash(rel), "/")
				if err == nil && len(parts) >= 3 && parts[0] != ".." && parts[1] == id {
					return true
				}
			}
		}
	}
	return false
}

func agentProcessTree(processes map[int]processInfo, pid int) map[int]struct{} {
	pids := map[int]struct{}{}
	if _, alive := processes[pid]; !alive || pid <= 0 {
		return pids
	}
	for child := range processes {
		if processDepthFromAncestor(processes, child, pid) >= 0 {
			pids[child] = struct{}{}
		}
	}
	return pids
}

func agentSessionWindowPIDs(windows []map[int]struct{}) map[int]struct{} {
	if len(windows) > 0 {
		return windows[0]
	}
	return nil
}

// Probe before taking the server lock; process open-file queries can block.
func excludeForeignAgentSessions(tool string, candidates []agentSessionCandidate, pids map[int]struct{}, watch *agentSessionWatch, assignedID string) []agentSessionCandidate {
	checked, excluded := map[string]bool{}, map[string]bool{}
	result := make([]agentSessionCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		// Only inferred or provisionally assigned identities need an exclusion
		// probe. Do not scan every process for old, unrelated baseline files.
		fallback := watch != nil && !candidate.registry && candidate.ownerPID == 0 &&
			watch.cwd != "" && normalizedMetadataPath(candidate.cwd) == watch.cwd &&
			!watch.started.IsZero() && !candidate.created.IsZero() && !candidate.created.Before(watch.started) &&
			!watch.baseline[candidate.id] && !watch.baseline[candidate.path]
		if !fallback && (assignedID == "" || candidate.id != assignedID) {
			result = append(result, candidate)
			continue
		}
		if !checked[candidate.id] {
			excluded[candidate.id] = agentSessionOwnedElsewhere(tool, candidate.id, pids)
			checked[candidate.id] = true
		}
		if !excluded[candidate.id] {
			result = append(result, candidate)
		}
	}
	return result
}

// Snapshot discovery shares the watcher's exact-signal precedence and parsers.
// Seeding every candidate into the baseline disables its creation-time fallback.
func exactAgentSessionForProcess(tool, cwd string, process processInfo, processes map[int]processInfo) *muxWindow {
	var candidates []agentSessionCandidate
	home, _ := os.UserHomeDir()
	switch tool {
	case "claude":
		candidates = readClaudeSessionRegistry(home)
	case "copilot":
		candidates = readAgentSessionCandidates(tool)
	case "antigravity":
		candidates = readAntigravityConversationCandidates(home)
	}
	pids := agentProcessTree(processes, process.pid)
	watch := newAgentSessionWatch(tool, cwd, processStartedAtForMetadata(process.pid), candidates)
	w := &muxWindow{agentTool: tool, cwd: cwd, agentSessionWatch: watch}
	if watch == nil || len(pids) == 0 {
		return w
	}
	watch.pid = process.pid
	watch.processPIDs, watch.claudePIDs = map[int]bool{}, map[int]bool{}
	var openPaths []string
	for pid := range pids {
		watch.processPIDs[pid] = true
		if pid == process.pid || agentToolFromCommandName(commandNameFromProcessFields(processes[pid].comm, processes[pid].args)) == "claude" {
			watch.claudePIDs[pid] = true
		}
		if tool == "codex" || tool == "claude" || tool == "antigravity" {
			openPaths = append(openPaths, processOpenFilePathsForMetadata(pid)...)
		}
	}
	s := &muxServer{windows: []*muxWindow{w}}
	s.bindAgentSessionCandidatesLocked(w, watch, candidates, agentSessionIDFromArgs(tool, process.args), openPaths, time.Now())
	return w
}

func readAgentSessionCandidates(tool string) []agentSessionCandidate {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	var candidates []agentSessionCandidate
	switch tool {
	case "codex", "claude":
		root, match, decode := filepath.Join(home, ".codex", "sessions"), isCodexRolloutPath, codexSessionIDFromRolloutFile
		if tool == "claude" {
			root, match, decode = filepath.Join(home, ".claude", "projects"), isClaudeProjectSessionPath, claudeSessionIDFromProjectFile
		}
		// The baseline must include old files too, even if they later gain a new
		// mtime. Unlike the recent-session fallback, it must not have a top-N limit.
		for _, path := range recentAgentSessionFiles(root, int(^uint(0)>>1), match) {
			if tool == "claude" && filepath.Dir(filepath.Dir(path)) != root {
				// Only project/<session>.jsonl, never nested subagent transcripts.
				continue
			}
			info, err := os.Stat(path)
			if err != nil {
				continue
			}
			cwd := ""
			if tool == "codex" {
				cwd = normalizedMetadataPath(codexRolloutWorkingDirectory(path))
			}
			candidates = append(candidates, agentSessionCandidate{id: decode(path), path: path, cwd: cwd, created: info.ModTime()})
		}
		if tool == "claude" {
			candidates = append(candidates, readClaudeSessionRegistry(home)...)
		}
	case "copilot":
		dirs, _ := filepath.Glob(filepath.Join(home, ".copilot", "session-state", "*"))
		for _, dir := range dirs {
			info, err := os.Stat(dir)
			if err != nil || !info.IsDir() {
				continue
			}
			candidate := agentSessionCandidate{id: filepath.Base(dir), path: filepath.Join(dir, "events.jsonl"),
				cwd: copilotSessionWorkingDirectory(filepath.Join(dir, "events.jsonl"))}
			// A directory alone confirms a wrapper-assigned ID. PID locks work
			// even before workspace.yaml/events.jsonl have been flushed.
			candidates = append(candidates, candidate)
			locks, _ := filepath.Glob(filepath.Join(dir, "inuse.*.lock"))
			for _, lock := range locks {
				pid := pidFromCopilotLockPath(lock)
				if pid <= 0 {
					continue
				}
				owned := candidate
				owned.ownerPID, owned.created = pid, copilotLockModTime(lock)
				candidates = append(candidates, owned)
			}
		}
	case "opencode":
		// The existing reader intentionally exposes update time, not creation time.
		// Read creation times separately so an old row outside its 200-row limit
		// cannot become a 'new' session merely by being updated.
		created := openCodeSessionCreationTimes(filepath.Join(home, ".local", "share", "opencode", "opencode.db"))
		for _, entry := range readOpenCodeSessionEntries() {
			candidates = append(candidates, agentSessionCandidate{id: entry.sessionID, cwd: entry.directory, created: created[entry.sessionID]})
		}
	case "cursor-agent":
		dirs, _ := filepath.Glob(filepath.Join(home, ".cursor", "chats", "*", "*"))
		for _, dir := range dirs {
			info, err := os.Stat(dir)
			if err != nil || !info.IsDir() {
				continue
			}
			path := filepath.Join(dir, "meta.json")
			data, err := os.ReadFile(path)
			if os.IsNotExist(err) {
				// Directory creation can precede metadata. It can confirm an
				// assigned ID, but provides no timing/cwd fallback evidence.
				candidates = append(candidates, agentSessionCandidate{id: filepath.Base(dir), path: path})
				continue
			}
			var raw struct {
				Cwd         string `json:"cwd"`
				CreatedAtMs int64  `json:"createdAtMs"`
				IsSubagent  bool   `json:"isSubagent"`
			}
			if err != nil || json.Unmarshal(data, &raw) != nil || raw.IsSubagent {
				continue
			}
			created := time.Time{}
			if raw.CreatedAtMs > 0 {
				created = time.UnixMilli(raw.CreatedAtMs)
			}
			candidates = append(candidates, agentSessionCandidate{id: filepath.Base(dir), path: path,
				cwd: normalizedMetadataPath(normalizedAgentWorkspacePath(raw.Cwd)), created: created})
		}
	case "antigravity":
		candidates = append(candidates, readAntigravityConversationCandidates(home)...)
		// history.jsonl contains repeated records. Use the earliest record for each
		// conversation, never its most recent activity as a creation timestamp.
		byID := map[string]agentSessionCandidate{}
		dbs, _ := filepath.Glob(filepath.Join(home, ".gemini", "antigravity-cli", "conversations", "*.db"))
		onDisk := map[string]bool{}
		for _, path := range dbs {
			onDisk[strings.TrimSuffix(filepath.Base(path), ".db")] = true
		}
		for _, entry := range readAntigravityHistoryEntries() {
			if onDisk[entry.conversationID] {
				continue
			}
			prior, ok := byID[entry.conversationID]
			if !ok || entry.updatedAt.Before(prior.created) {
				byID[entry.conversationID] = agentSessionCandidate{id: entry.conversationID, cwd: entry.workspace, created: entry.updatedAt}
			}
		}
		for _, candidate := range byID {
			candidates = append(candidates, candidate)
		}
	}
	return candidates
}

func readClaudeSessionRegistry(home string) []agentSessionCandidate {
	paths, _ := filepath.Glob(filepath.Join(home, ".claude", "sessions", "*.json"))
	var candidates []agentSessionCandidate
	for _, path := range paths {
		if candidate := readClaudeSessionRegistryEntry(path); candidate.id != "" {
			candidates = append(candidates, candidate)
		}
	}
	return candidates
}

func readClaudeSessionRegistryEntry(path string) agentSessionCandidate {
	var raw struct {
		PID       int    `json:"pid"`
		SessionID string `json:"sessionId"`
		Cwd       string `json:"cwd"`
		StartedAt int64  `json:"startedAt"`
	}
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &raw) != nil || raw.PID <= 0 || raw.SessionID == "" ||
		strconv.Itoa(raw.PID) != strings.TrimSuffix(filepath.Base(path), ".json") {
		return agentSessionCandidate{}
	}
	return agentSessionCandidate{id: raw.SessionID, cwd: normalizedMetadataPath(raw.Cwd),
		created: unixDatabaseTime(strconv.FormatInt(raw.StartedAt, 10)), ownerPID: raw.PID, registry: true}
}

func readAntigravityConversationCandidates(home string) []agentSessionCandidate {
	root := filepath.Join(home, ".gemini", "antigravity-cli")
	// Read the live database in place, as OpenCode discovery does, so SQLite
	// includes committed WAL rows. Never copy or modify the user's database.
	type summary struct {
		ID         string `json:"conversation_id"`
		Workspaces string `json:"workspace_uris"`
		Parent     string `json:"parent_conversation_id"`
		Depth      int    `json:"nesting_depth"`
	}
	summaries := map[string]summary{}
	db := filepath.Join(root, "conversation_summaries.db")
	if _, err := os.Stat(db); err == nil {
		if sqlite, err := exec.LookPath("sqlite3"); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
			output, err := exec.CommandContext(ctx, sqlite, "-readonly", "-json", db,
				"SELECT conversation_id, workspace_uris, parent_conversation_id, nesting_depth FROM conversation_summaries;").Output()
			cancel()
			var rows []summary
			if err == nil && json.Unmarshal(output, &rows) == nil {
				for _, row := range rows {
					summaries[row.ID] = row
				}
			}
		}
	}
	paths, _ := filepath.Glob(filepath.Join(root, "conversations", "*.db"))
	var candidates []agentSessionCandidate
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		id := strings.TrimSuffix(filepath.Base(path), ".db")
		row := summaries[id]
		if row.Parent != "" || row.Depth > 0 {
			continue
		}
		candidate := agentSessionCandidate{id: id, path: path, created: info.ModTime(),
			ownershipPath: filepath.Join(root, "presence", id+".lock")}
		var workspaces []string
		if json.Unmarshal([]byte(row.Workspaces), &workspaces) != nil && row.Workspaces != "" {
			workspaces = []string{row.Workspaces}
		}
		if len(workspaces) == 0 {
			candidates = append(candidates, candidate)
		}
		for _, workspace := range workspaces {
			candidate.cwd = normalizedMetadataPath(normalizedAgentWorkspacePath(workspace))
			candidates = append(candidates, candidate)
		}
	}
	return candidates
}

func openCodeSessionCreationTimes(path string) map[string]time.Time {
	result := map[string]time.Time{}
	if _, err := os.Stat(path); err != nil {
		return result
	}
	sqlite, err := exec.LookPath("sqlite3")
	if err != nil {
		return result
	}
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, sqlite, "-readonly", "-separator", "\x1f", path,
		"SELECT id, time_created FROM session WHERE parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT 200;").Output()
	if err != nil {
		return result
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Split(line, "\x1f")
		if len(fields) == 2 {
			result[fields[0]] = unixDatabaseTime(fields[1])
		}
	}
	return result
}

// Concurrent window refreshes share one read, including the first cache miss.
func (s *muxServer) agentSessionStore(tool string, now time.Time) []agentSessionCandidate {
	for {
		s.mu.Lock()
		cached := s.agentSessionBindings.stores[tool]
		if cached.loading != nil {
			s.mu.Unlock()
			<-cached.loading
			continue
		}
		if !cached.at.IsZero() && now.Sub(cached.at) < agentSessionStorePollInterval {
			s.mu.Unlock()
			return cached.candidates
		}
		if s.agentSessionBindings.stores == nil {
			s.agentSessionBindings.stores = map[string]agentSessionStoreSnapshot{}
		}
		loading := make(chan struct{})
		s.agentSessionBindings.stores[tool] = agentSessionStoreSnapshot{loading: loading}
		s.mu.Unlock()
		candidates := readAgentSessionCandidates(tool)
		s.mu.Lock()
		s.agentSessionBindings.stores[tool] = agentSessionStoreSnapshot{at: now, candidates: candidates}
		close(loading)
		s.mu.Unlock()
		return candidates
	}
}

func (s *muxServer) refreshAgentSessionBinding(windowID string) {
	now := time.Now()
	s.mu.Lock()
	w := s.windowByIDLocked(windowID)
	if w == nil || w.closed {
		s.mu.Unlock()
		return
	}
	tool, cwd, panePID := w.agentToolLocked(), w.cwd, w.processID()
	exact := w.agentSessionIdentityExact
	assignedID := ""
	if w.agentSessionAssigned {
		assignedID = w.agentSessionID
	}
	watch := w.agentSessionWatch
	if !fileBackedAgent(tool) && watch == nil {
		s.mu.Unlock()
		return
	}
	if watch != nil {
		if !watch.lastPoll.IsZero() && now.Sub(watch.lastPoll) < agentSessionStorePollInterval {
			s.mu.Unlock()
			return
		}
		watch.lastPoll = now
	}
	if exact && tool == "claude" {
		pid := 0
		if watch != nil && !watch.exited {
			pid = watch.registryPID
			if pid == 0 {
				pid = watch.pid
			}
		}
		s.mu.Unlock()
		if pid <= 0 {
			return
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return
		}
		candidate := readClaudeSessionRegistryEntry(filepath.Join(home, ".claude", "sessions", strconv.Itoa(pid)+".json"))
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.windowByIDLocked(windowID) != w || w.closed || w.agentSessionWatch != watch || watch.exited ||
			!w.agentSessionIdentityExact || w.agentToolLocked() != tool || candidate.id == "" ||
			(!candidate.created.IsZero() && !watch.started.IsZero() && !sessionUpdatedDuringProcess(candidate.created, watch.started)) ||
			s.exactAgentSessionOwnerLocked(tool, candidate.id, w) {
			return
		}
		if w.agentSessionID != candidate.id {
			w.agentSessionID = candidate.id
			w.agentSessionPath, w.agentSessionDir = "", ""
		}
		watch.registryPID = candidate.ownerPID
		return
	}
	panePIDs := map[int]struct{}{}
	for _, window := range s.windows {
		if !window.closed && window.processID() > 0 {
			panePIDs[window.processID()] = struct{}{}
		}
	}
	s.mu.Unlock()
	processes := processTableForMetadata()
	// A failed process-table probe is not evidence that an agent exited.
	if processes == nil {
		return
	}
	process, ok := agentProcessesByPane(processes, panePIDs, tool)[panePID]
	s.mu.Lock()
	if s.windowByIDLocked(windowID) != w || w.closed || w.agentSessionWatch != watch {
		s.mu.Unlock()
		return
	}
	// Release all watched owners whose processes disappeared, even if another
	// window is polled first. Keep their IDs for restore, but not exclusivity.
	for _, other := range s.windows {
		if prior := other.agentSessionWatch; prior != nil && prior.pid > 0 {
			if _, alive := processes[prior.pid]; !alive {
				prior.exited, prior.done = true, true
				prior.baseline, prior.firstSeen = nil, nil
			}
		}
	}
	if !ok {
		s.mu.Unlock()
		return
	}
	needsBaseline := watch == nil || watch.tool != tool || (watch.pid != 0 && watch.pid != process.pid) || watch.exited
	if !needsBaseline && w.agentSessionIdentityExact && tool != "claude" {
		s.mu.Unlock()
		return
	}
	var fallbackWatch *agentSessionWatch
	if !needsBaseline {
		// Baseline contents are immutable after construction. Copy the watch
		// fields under the lock because another refresh can retire this watch.
		copy := *watch
		fallbackWatch = &copy
	}
	s.mu.Unlock()
	started := processStartedAtForMetadata(process.pid)
	if directory := processWorkingDirectoryForMetadata(process.pid); directory != "" {
		cwd = directory
	}
	candidates := s.agentSessionStore(tool, now)
	baseline := candidates
	matchCwd := cwd
	if fallbackWatch != nil {
		matchCwd = fallbackWatch.cwd
	}
	candidates = agentSessionCandidatesForDirectory(tool, matchCwd, candidates)
	processPIDs, claudePIDs, windowPIDs := map[int]bool{}, map[int]bool{}, map[int]bool{}
	var openPaths []string
	for pid, child := range processes {
		if ancestorPanePID(processes, pid, panePIDs) != panePID {
			continue
		}
		windowPIDs[pid] = true
		if processDepthFromAncestor(processes, pid, process.pid) < 0 {
			continue
		}
		processPIDs[pid] = true
		if pid == process.pid || agentToolFromCommandName(commandNameFromProcessFields(child.comm, child.args)) == "claude" {
			claudePIDs[pid] = true
		}
		if tool == "codex" || tool == "antigravity" || (tool == "claude" && !exact) {
			openPaths = append(openPaths, processOpenFilePathsForMetadata(pid)...)
		}
	}
	candidates = excludeForeignAgentSessions(tool, candidates, agentProcessTree(processes, process.pid), fallbackWatch, assignedID)
	argsID := agentSessionIDFromArgs(tool, process.args)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.windowByIDLocked(windowID) != w || w.closed || w.agentSessionWatch != watch {
		return
	}
	if needsBaseline {
		if watch != nil && (watch.tool != tool || watch.pid != 0 && watch.pid != process.pid) {
			// A replacement process must not inherit the exited agent's ID.
			w.agentSessionID, w.agentSessionPath, w.agentSessionDir = "", "", ""
			w.agentSessionIdentityExact, w.agentSessionAssigned = false, false
		}
		// Late discovery must not mistake existing files for fresh sessions. Exact
		// process signals and wrapper-assigned IDs can still confirm baseline IDs.
		watch = newAgentSessionWatch(tool, cwd, started, baseline)
		if watch == nil {
			return
		}
		w.agentSessionWatch = watch
		if w.agentSessionIdentityExact && tool != "claude" {
			watch.done = true
		}
	}
	watch.pid, watch.lastPoll = process.pid, now
	watch.processPIDs, watch.claudePIDs, watch.windowPIDs = processPIDs, claudePIDs, windowPIDs
	s.bindAgentSessionCandidatesLocked(w, watch, candidates, argsID, openPaths, now)
}

func (s *muxServer) exactAgentSessionOwnerLocked(tool, id string, except *muxWindow) bool {
	if id == "" {
		return false
	}
	for _, other := range s.windows {
		if other != except && !other.closed && (other.agentSessionWatch == nil || !other.agentSessionWatch.exited) && other.agentSessionIdentityExact && other.agentToolLocked() == tool && other.agentSessionID == id {
			return true
		}
	}
	return false
}

// Resolve Claude's directory encoding/relocation fallback before taking s.mu:
// that fallback may read transcript ends. Never mutate the shared store cache.
func agentSessionCandidatesForDirectory(tool, cwd string, candidates []agentSessionCandidate) []agentSessionCandidate {
	cwd = normalizedMetadataPath(cwd)
	if tool != "claude" {
		return candidates
	}
	matched := make([]agentSessionCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.registry {
			matched = append(matched, candidate)
		} else if claudeSessionMatchesWorkingDirectory(candidate.path, cwd) {
			candidate.cwd = cwd
			matched = append(matched, candidate)
		}
	}
	return matched
}

func (s *muxServer) bindAgentSessionCandidatesLocked(w *muxWindow, watch *agentSessionWatch, candidates []agentSessionCandidate, argsID string, openPaths []string, now time.Time) {
	if watch.done || watch.exited || w.closed || (w.agentSessionIdentityExact && watch.tool != "claude") {
		return
	}
	open := map[string]bool{}
	for _, path := range openPaths {
		open[normalizedMetadataPath(path)] = true
	}
	eligible, direct, registries := map[string]agentSessionCandidate{}, map[string]agentSessionCandidate{}, map[string]agentSessionCandidate{}
	// An open path is exact even if it lives outside the default home or was
	// unlinked after opening. Decode it with the same readers as store entries.
	for _, path := range openPaths {
		id := ""
		switch watch.tool {
		case "codex":
			id = codexSessionIDFromRolloutFile(path)
		case "claude":
			id = claudeSessionIDFromProjectFile(path)
		}
		if id != "" && !s.exactAgentSessionOwnerLocked(watch.tool, id, w) {
			direct[id] = agentSessionCandidate{id: id, path: path}
		}
	}
	var confirmed, locked agentSessionCandidate
	lockAmbiguous := false
	argument := agentSessionCandidate{id: argsID}
	for _, candidate := range candidates {
		if candidate.id == "" || s.exactAgentSessionOwnerLocked(watch.tool, candidate.id, w) {
			continue
		}
		sameCwd := watch.cwd != "" && normalizedMetadataPath(candidate.cwd) == watch.cwd
		if candidate.registry {
			owns := candidate.ownerPID == watch.pid || watch.claudePIDs[candidate.ownerPID]
			// startedAt also rejects a stale registry whose PID has been reused.
			if owns && (candidate.created.IsZero() || watch.started.IsZero() || sessionUpdatedDuringProcess(candidate.created, watch.started)) && (watch.registryPID == 0 || watch.registryPID == candidate.ownerPID) {
				registries[candidate.id] = candidate
			}
		} else if watch.tool == "copilot" && (candidate.ownerPID == watch.pid || watch.processPIDs[candidate.ownerPID]) && candidate.ownerPID > 0 && (watch.started.IsZero() || sessionUpdatedDuringProcess(candidate.created, watch.started)) {
			if locked.id == "" || candidate.created.After(locked.created) {
				locked, lockAmbiguous = candidate, false
			} else if candidate.created.Equal(locked.created) && candidate.id != locked.id {
				lockAmbiguous = true
			}
		}
		if (watch.tool == "codex" || watch.tool == "claude") && candidate.path != "" && open[normalizedMetadataPath(candidate.path)] ||
			watch.tool == "antigravity" && ((candidate.ownershipPath != "" && open[normalizedMetadataPath(candidate.ownershipPath)]) || (candidate.path != "" && open[normalizedMetadataPath(candidate.path)])) {
			direct[candidate.id] = candidate
		}
		if candidate.id == argsID {
			argument = candidate
		}
		if w.agentSessionAssigned && candidate.id == w.agentSessionID {
			confirmed = candidate
		}
		if !sameCwd || candidate.registry || candidate.ownerPID > 0 {
			continue
		}
		first, seen := watch.firstSeen[candidate.id]
		if !seen {
			first = candidate.created
			watch.firstSeen[candidate.id] = first
		}
		if watch.started.IsZero() || watch.baseline[candidate.id] || watch.baseline[candidate.path] || first.IsZero() || first.Before(watch.started) {
			continue
		}
		eligible[candidate.id] = candidate
	}
	if locked.id != "" {
		if lockAmbiguous {
			return
		}
		direct[locked.id] = locked
	}
	// Resume arguments establish ownership before a lazy store file exists.
	// A wrapper-assigned ID still needs store confirmation.
	if len(direct) == 0 && argsID != "" && !w.agentSessionAssigned && !w.agentSessionIdentityExact && !s.exactAgentSessionOwnerLocked(watch.tool, argsID, w) {
		direct[argsID] = argument
	}
	var chosen agentSessionCandidate
	if len(registries) == 1 {
		for _, candidate := range registries {
			chosen = candidate
		}
	} else if len(registries) > 1 {
		// The launched Claude process takes precedence over nested Claude processes.
		for _, candidate := range registries {
			if candidate.ownerPID == watch.pid {
				chosen = candidate
			}
		}
	} else if !w.agentSessionIdentityExact {
		if len(direct) == 1 {
			for _, candidate := range direct {
				chosen = candidate
			}
		} else if confirmed.id != "" {
			chosen = confirmed
		} else if len(direct) == 0 && !w.agentSessionAssigned && len(eligible) == 1 && s.agentSessionBindings.pending == 0 {
			for _, other := range s.windows {
				if other != w && !other.closed && !other.agentSessionIdentityExact && (other.agentSessionWatch == nil || !other.agentSessionWatch.exited) && other.agentToolLocked() == watch.tool && normalizedMetadataPath(other.cwd) == watch.cwd {
					return
				}
			}
			for _, candidate := range eligible {
				chosen = candidate
			}
		}
	}
	if chosen.id == "" {
		return
	}
	w.agentSessionID = chosen.id
	w.agentSessionIdentityExact = true
	w.agentSessionPath, w.agentSessionDir = chosen.path, ""
	if chosen.path != "" {
		w.agentSessionDir = filepath.Dir(chosen.path)
	}
	if chosen.registry {
		watch.registryPID = chosen.ownerPID
	}
	// Claude registries remain authoritative after /clear and fork.
	watch.done = watch.tool != "claude"
}

// Cursor's old periodic workspace fallback remains available after the watch,
// but must not defeat either an active ambiguous watch or an exact owner.
func (s *muxServer) allowAgentSessionFallbackLocked(w *muxWindow, tool, id string) bool {
	if s.exactAgentSessionOwnerLocked(tool, id, w) {
		return false
	}
	// Windows without a launch watch (the agent was typed into a shell pane)
	// still rely on the periodic fallback; a watch that is pending or whose
	// agent exited must not be second-guessed by it.
	watch := w.agentSessionWatch
	if w.agentSessionAssigned || (watch != nil && (!watch.done || watch.exited)) {
		return false
	}
	// The periodic Cursor path predates the multi-pane workspace guard used
	// during restore. Do not let it mark a shared-workspace guess as exact.
	for _, other := range s.windows {
		if other != w && !other.closed && other.agentToolLocked() == tool && normalizedMetadataPath(other.cwd) == normalizedMetadataPath(w.cwd) {
			return false
		}
	}
	return true
}

// Enrichment runs on a snapshot outside the server. Preserve exact file-backed
// identities and reserve every exact owner's ID before accepting fallback IDs.
func protectExactAgentSessionBindings(restore *serverRestore) func() {
	exact := map[int]restoreWindowState{}
	for i, window := range restore.Windows {
		if window.AgentSessionIdentityExact && window.AgentSessionID != "" {
			exact[i] = window
		}
	}
	return func() {
		owners := map[string]int{}
		for i, original := range exact {
			if fileBackedAgent(agentToolCandidateForRestore(original)) {
				restore.Windows[i].AgentSessionID = original.AgentSessionID
				restore.Windows[i].AgentSessionDir = original.AgentSessionDir
				restore.Windows[i].AgentSessionPath = original.AgentSessionPath
				restore.Windows[i].AgentSessionIdentityExact = true
			}
		}
		for i, window := range restore.Windows {
			if window.AgentSessionIdentityExact && window.AgentSessionID != "" {
				key := agentToolCandidateForRestore(window) + "\x00" + window.AgentSessionID
				if _, exists := owners[key]; !exists {
					owners[key] = i
				}
			}
		}
		for i := range restore.Windows {
			window := &restore.Windows[i]
			key := agentToolCandidateForRestore(*window) + "\x00" + window.AgentSessionID
			if owner, exists := owners[key]; exists && owner != i {
				window.AgentSessionID, window.AgentSessionDir, window.AgentSessionPath = "", "", ""
				window.AgentSessionIdentityExact = false
			}
		}
	}
}

// Run last, after provisional-ID preservation, so an exited launch cannot
// regain a guessed or merely allocated ID from an older snapshot field.
func protectLiveAgentSessionInference(restore *serverRestore) func() {
	originals := append([]restoreWindowState(nil), restore.Windows...)
	return func() {
		panes := map[int]struct{}{}
		for _, window := range originals {
			if window.PanePid > 0 {
				panes[window.PanePid] = struct{}{}
			}
		}
		processes := processTableForMetadata()
		for i := range restore.Windows {
			window, original := &restore.Windows[i], originals[i]
			tool := agentToolCandidateForRestore(original)
			if !fileBackedAgent(tool) || (original.AgentSessionIdentityExact && original.AgentSessionID != "") {
				continue
			}
			// A wrapper-assigned ID that the agent's own store confirms is as
			// trustworthy as an exact hook report: the pane's agent ran it.
			if original.AgentSessionAssigned && original.AgentSessionID != "" &&
				agentSessionExistsInStore(tool, original.AgentSessionID) {
				continue
			}
			process, live := agentProcessesByPane(processes, panes, tool)[original.PanePid]
			if !live {
				window.AgentSessionID = agentSessionIDFromArgs(tool, original.CurrentCommand)
				window.AgentSessionDir, window.AgentSessionPath = "", ""
				window.AgentSessionIdentityExact = window.AgentSessionID != ""
			} else if window.AgentSessionID != "" &&
				window.AgentSessionID != agentSessionIDFromArgs(tool, process.args) &&
				agentSessionOwnedElsewhere(tool, window.AgentSessionID, agentProcessTree(processes, process.pid)) {
				window.AgentSessionID, window.AgentSessionDir, window.AgentSessionPath = "", "", ""
				window.AgentSessionIdentityExact = false
			}
		}
	}
}
