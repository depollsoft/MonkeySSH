package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// nativeAgentSessionLookupInterval bounds how often a native window asks
	// its ACP bridge which session it hosts and looks for that session's file.
	nativeAgentSessionLookupInterval = 5 * time.Second
	// nativeAgentTitleRecordLimitBytes skips oversized records (images, tool
	// payloads) without parsing them; titles and prompts are far smaller.
	nativeAgentTitleRecordLimitBytes = 1024 * 1024
	// copilotWorkspaceLimitBytes bounds the workspace.yaml read for a title.
	copilotWorkspaceLimitBytes = 64 * 1024
)

// nativeAgentTitleTools are the agents whose native windows MonkeyMux labels
// from the agent's own session store. Their ACP adapters host the CLI's own
// session id, which is how the client resumes a CLI session natively, so the
// bridge's session id names the same file the terminal window probe reads.
// Pi has its own reader (see piSessionTitle).
var nativeAgentTitleTools = map[string]bool{
	"claude":  true,
	"codex":   true,
	"copilot": true,
}

// nativeAgentToolForProvider maps a built-in ACP provider id to its agent when
// the window name (a display label such as "Cursor Agent") does not.
func nativeAgentToolForProvider(providerID string) string {
	switch strings.TrimPrefix(strings.TrimSpace(providerID), "builtin:") {
	case "claude-agent-acp":
		return "claude"
	case "codex-acp":
		return "codex"
	case "copilot-cli":
		return "copilot"
	case "pi-acp":
		return "pi"
	case "opencode":
		return "opencode"
	case "cursor-agent-acp":
		return "cursor-agent"
	case "antigravity-acp":
		return "antigravity"
	default:
		return ""
	}
}

// nativeAgentSessionTitle holds one native window's title lookup. It
// serializes on its own lock because snapshots and the quiet title refresh
// both read it.
type nativeAgentSessionTitle struct {
	mu    sync.Mutex
	state nativeAgentTitleState
}

// nativeAgentTitleState is which session a native window's bridge hosts,
// where that session's files are, and the incremental reads of them.
type nativeAgentTitleState struct {
	bridgeID  string
	tool      string
	sessionID string
	checkedAt time.Time
	claude    claudeSessionTitleScan
	codex     codexSessionTitleScan
	copilot   copilotWorkspaceTitle
}

// title returns the label of the session hosted by a native window's bridge,
// or "" when the agent has no file-backed title or the file is not written yet.
func (lookup *nativeAgentSessionTitle) title(tool, bridgeID string, now time.Time) string {
	if !nativeAgentTitleTools[tool] || !validAcpBridgeID(bridgeID) {
		return ""
	}
	lookup.mu.Lock()
	defer lookup.mu.Unlock()
	state := &lookup.state
	if state.bridgeID != bridgeID || state.tool != tool {
		*state = nativeAgentTitleState{bridgeID: bridgeID, tool: tool}
	}
	if state.sessionID == "" || now.Sub(state.checkedAt) >= nativeAgentSessionLookupInterval {
		// A bridge can load another session, and an agent may write a new
		// session's file only after its first prompt, so both are rechecked.
		state.checkedAt = now
		if info, err := acpBridgeStatusForMetadata(bridgeID); err == nil {
			sessionID := strings.TrimSpace(info.SessionID)
			if !safePiSessionIDPattern.MatchString(sessionID) {
				sessionID = ""
			}
			if sessionID != state.sessionID {
				state.sessionID = sessionID
				state.claude = claudeSessionTitleScan{}
				state.codex = codexSessionTitleScan{}
				state.copilot = copilotWorkspaceTitle{}
			}
		}
	}
	if state.sessionID == "" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	switch tool {
	case "claude":
		return state.claude.title(home, state.sessionID, now)
	case "codex":
		return state.codex.title(codexHomeDirectory(home), state.sessionID, now)
	case "copilot":
		return state.copilot.title(home, state.sessionID)
	}
	return ""
}

func codexHomeDirectory(home string) string {
	if configured := strings.TrimSpace(os.Getenv("CODEX_HOME")); configured != "" {
		return configured
	}
	return filepath.Join(home, ".codex")
}

// jsonlTail reads an append-only JSON Lines file incrementally: each call
// passes only the complete records written since the previous one. A shorter
// file or a different path starts over, calling reset before any record so
// the caller can drop what it learned from the old contents.
type jsonlTail struct {
	path   string
	offset int64
}

func (tail *jsonlTail) read(path string, reset func(), observe func(line []byte, truncated bool)) {
	if path != tail.path {
		*tail = jsonlTail{path: path}
		reset()
	}
	if path == "" {
		return
	}
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return
	}
	if info.Size() < tail.offset {
		*tail = jsonlTail{path: path}
		reset()
	}
	if info.Size() == tail.offset {
		return
	}
	if _, err := file.Seek(tail.offset, io.SeekStart); err != nil {
		return
	}
	reader := bufio.NewReaderSize(io.LimitReader(file, info.Size()-tail.offset), 64*1024)
	for {
		line, truncated, bytesRead, readErr := readBoundedLine(reader, nativeAgentTitleRecordLimitBytes)
		if readErr != nil {
			break
		}
		if !truncated && bytesRead == len(line) {
			// The agent is still writing this record; read it once its
			// newline lands.
			break
		}
		tail.offset += int64(bytesRead)
		if line = bytes.TrimSpace(line); len(line) > 0 {
			observe(line, truncated)
		}
	}
}

// claudeSessionTitleScan labels a Claude Code session the way the client's
// terminal probe does: an explicit /rename title, else Claude's generated
// title (which its /resume picker shows), else the latest prompt, else the
// first prompt.
type claudeSessionTitleScan struct {
	tail        jsonlTail
	pathChecked time.Time
	customTitle string
	aiTitle     string
	lastPrompt  string
	firstPrompt string
}

func (scan *claudeSessionTitleScan) title(home, sessionID string, now time.Time) string {
	// Claude writes a new session's file only after its first prompt, so a
	// miss is retried. A session's file never moves once it exists.
	path := scan.tail.path
	if path == "" && (scan.pathChecked.IsZero() || now.Sub(scan.pathChecked) >= nativeAgentSessionLookupInterval) {
		scan.pathChecked = now
		path = claudeSessionFile(home, sessionID)
	}
	scan.tail.read(path, func() {
		scan.customTitle, scan.aiTitle, scan.lastPrompt, scan.firstPrompt = "", "", "", ""
	}, scan.observe)
	return summarizePiSessionTitle(firstNonEmptyString(
		scan.customTitle, scan.aiTitle, scan.lastPrompt, scan.firstPrompt,
	))
}

func (scan *claudeSessionTitleScan) observe(line []byte, truncated bool) {
	if truncated {
		return
	}
	wantsPrompt := scan.firstPrompt == "" && bytes.Contains(line, []byte(`"user"`))
	if !wantsPrompt &&
		!bytes.Contains(line, []byte(`"customTitle"`)) &&
		!bytes.Contains(line, []byte(`"aiTitle"`)) &&
		!bytes.Contains(line, []byte(`"lastPrompt"`)) {
		return
	}
	var record struct {
		Type        string  `json:"type"`
		CustomTitle *string `json:"customTitle"`
		AITitle     *string `json:"aiTitle"`
		LastPrompt  *string `json:"lastPrompt"`
		IsMeta      bool    `json:"isMeta"`
		Message     *struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &record) != nil {
		return
	}
	// The latest record of each kind wins.
	if record.CustomTitle != nil {
		scan.customTitle = strings.TrimSpace(*record.CustomTitle)
	}
	if record.AITitle != nil {
		scan.aiTitle = strings.TrimSpace(*record.AITitle)
	}
	if record.LastPrompt != nil {
		scan.lastPrompt = strings.TrimSpace(*record.LastPrompt)
	}
	if wantsPrompt && record.Type == "user" && !record.IsMeta &&
		record.Message != nil && record.Message.Role == "user" {
		text := strings.TrimSpace(piUserMessageText(record.Message.Content))
		// Slash commands and harness-injected tags are not what the user
		// asked; tool results carry no text parts.
		if text != "" && !strings.HasPrefix(text, "/") && !strings.HasPrefix(text, "<") {
			scan.firstPrompt = text
		}
	}
}

// claudeSessionFile finds `<id>.jsonl` under ~/.claude/projects: first in the
// directory for the session's usual project, then in any project directory.
func claudeSessionFile(home, sessionID string) string {
	if !safePiSessionIDPattern.MatchString(sessionID) {
		return ""
	}
	root := filepath.Join(home, ".claude", "projects")
	entries, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	name := sessionID + ".jsonl"
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		candidate := filepath.Join(root, entry.Name(), name)
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			return candidate
		}
	}
	return ""
}

// codexSessionTitleScan labels a Codex session by its thread name from
// session_index.jsonl, as the client's terminal probe does, else by its first
// prompt.
type codexSessionTitleScan struct {
	index        jsonlTail
	rollout      jsonlTail
	rolloutPath  string
	searchedAt   time.Time
	sessionID    string
	threadName   string
	firstMessage string
}

func (scan *codexSessionTitleScan) title(codexHome, sessionID string, now time.Time) string {
	if scan.sessionID != sessionID {
		*scan = codexSessionTitleScan{sessionID: sessionID}
	}
	scan.index.read(filepath.Join(codexHome, "session_index.jsonl"), func() {
		scan.threadName = ""
	}, scan.observeIndex)
	if scan.threadName == "" {
		// The rollout path never changes once found; a new session's file
		// may not exist until its first turn, so a miss is retried.
		if scan.rolloutPath == "" && now.Sub(scan.searchedAt) >= nativeAgentSessionLookupInterval {
			scan.searchedAt = now
			scan.rolloutPath = codexRolloutFile(codexHome, sessionID)
		}
		if scan.firstMessage == "" && scan.rolloutPath != "" {
			scan.rollout.read(scan.rolloutPath, func() { scan.firstMessage = "" }, scan.observeRollout)
		}
	}
	return summarizePiSessionTitle(firstNonEmptyString(scan.threadName, scan.firstMessage))
}

func (scan *codexSessionTitleScan) observeIndex(line []byte, truncated bool) {
	if truncated || !bytes.Contains(line, []byte(scan.sessionID)) {
		return
	}
	var entry struct {
		ID         string `json:"id"`
		ThreadName string `json:"thread_name"`
	}
	if json.Unmarshal(line, &entry) == nil && entry.ID == scan.sessionID {
		// The index is appended to on every rename; the latest entry wins.
		scan.threadName = strings.TrimSpace(entry.ThreadName)
	}
}

func (scan *codexSessionTitleScan) observeRollout(line []byte, truncated bool) {
	if truncated || scan.firstMessage != "" || !bytes.Contains(line, []byte(`"user`)) {
		return
	}
	var record struct {
		Type    string `json:"type"`
		Payload struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &record) != nil {
		return
	}
	switch {
	case record.Type == "event_msg" && record.Payload.Type == "user_message":
		// Codex before 0.160 logged each prompt as an event.
		scan.firstMessage = strings.TrimSpace(record.Payload.Message)
	case record.Type == "response_item" && record.Payload.Type == "message" && record.Payload.Role == "user":
		// Codex sends AGENTS.md, the environment, and skills as user
		// messages ahead of the prompt.
		for _, part := range record.Payload.Content {
			text := strings.TrimSpace(part.Text)
			if part.Type != "input_text" || text == "" ||
				strings.HasPrefix(text, "<") || strings.HasPrefix(text, "# AGENTS.md instructions") {
				continue
			}
			scan.firstMessage = text
			return
		}
	}
}

// codexRolloutFile finds `rollout-*-<id>.jsonl` under sessions/YYYY/MM/DD,
// newest day first, since a live native session is usually recent.
func codexRolloutFile(codexHome, sessionID string) string {
	if !safePiSessionIDPattern.MatchString(sessionID) {
		return ""
	}
	suffix := "-" + sessionID + ".jsonl"
	var search func(directory string, depth int) string
	search = func(directory string, depth int) string {
		entries, err := os.ReadDir(directory)
		if err != nil {
			return ""
		}
		if depth == 3 {
			for _, entry := range entries {
				name := entry.Name()
				if !entry.IsDir() && strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, suffix) {
					return filepath.Join(directory, name)
				}
			}
			return ""
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() > entries[j].Name() })
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			if match := search(filepath.Join(directory, entry.Name()), depth+1); match != "" {
				return match
			}
		}
		return ""
	}
	return search(filepath.Join(codexHome, "sessions"), 0)
}

// copilotWorkspaceTitle labels a Copilot CLI session by the summary (else the
// name) in its workspace.yaml, as the client's terminal probe does. The file
// is small and rewritten in place, so it is reread whenever it changes.
type copilotWorkspaceTitle struct {
	modTime time.Time
	size    int64
	label   string
}

func (state *copilotWorkspaceTitle) title(home, sessionID string) string {
	if !safePiSessionIDPattern.MatchString(sessionID) {
		return ""
	}
	path := filepath.Join(home, ".copilot", "session-state", sessionID, "workspace.yaml")
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		*state = copilotWorkspaceTitle{}
		return ""
	}
	if info.ModTime().Equal(state.modTime) && info.Size() == state.size {
		return state.label
	}
	file, err := os.Open(path)
	if err != nil {
		return state.label
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, copilotWorkspaceLimitBytes))
	if err != nil {
		return state.label
	}
	state.modTime, state.size = info.ModTime(), info.Size()
	state.label = summarizePiSessionTitle(copilotWorkspaceLabel(data))
	return state.label
}

func copilotWorkspaceLabel(data []byte) string {
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		for _, key := range []string{"summary:", "name:"} {
			if value, ok := strings.CutPrefix(trimmed, key); ok {
				return unquoteYAMLScalar(strings.TrimSpace(value))
			}
		}
	}
	return ""
}

func unquoteYAMLScalar(value string) string {
	if len(value) >= 2 {
		switch {
		case value[0] == '"' && value[len(value)-1] == '"':
			var decoded string
			if json.Unmarshal([]byte(value), &decoded) == nil {
				return decoded
			}
			return value[1 : len(value)-1]
		case value[0] == '\'' && value[len(value)-1] == '\'':
			return strings.ReplaceAll(value[1:len(value)-1], "''", "'")
		}
	}
	return value
}
