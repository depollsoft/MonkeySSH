package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"
)

const monkeyMuxAgentIdentityOSCPrefix = "MonkeyMuxAgent="
const agentIdentityHookInputLimit = 64 * 1024

type agentIdentity struct {
	Tool   string `json:"tool"`
	ID     string `json:"id"`
	File   string `json:"file,omitempty"`
	Source string `json:"source,omitempty"`
}

var agentIdentityUUIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var agentIdentityOpenCodePattern = regexp.MustCompile(`^ses_[A-Za-z0-9]+$`)

func agentSessionIDValid(tool, id string) bool {
	switch tool {
	case "claude", "codex", "copilot", "cursor-agent", "antigravity":
		return agentIdentityUUIDPattern.MatchString(id)
	case "opencode":
		return len(id) <= 64 && agentIdentityOpenCodePattern.MatchString(id)
	case "pi":
		return safePiSessionIDPattern.MatchString(id)
	default:
		return false
	}
}

func agentIdentityValid(identity agentIdentity) bool {
	return agentSessionIDValid(identity.Tool, identity.ID) &&
		(identity.File == "" || (filepath.IsAbs(identity.File) &&
			filepath.Clean(identity.File) == identity.File && !strings.ContainsRune(identity.File, '\x00')))
}

func encodeAgentIdentityMarker(identity agentIdentity) string {
	data, _ := json.Marshal(identity)
	return "\x1b]1337;" + monkeyMuxAgentIdentityOSCPrefix + base64.RawURLEncoding.EncodeToString(data) + "\x07"
}

func decodeAgentIdentityPayload(value string) (agentIdentity, bool) {
	var identity agentIdentity
	if !strings.HasPrefix(value, monkeyMuxAgentIdentityOSCPrefix) || len(value) > oscBufferLimitBytes {
		return identity, false
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(value, monkeyMuxAgentIdentityOSCPrefix))
	if err != nil || json.Unmarshal(data, &identity) != nil || !agentIdentityValid(identity) {
		return agentIdentity{}, false
	}
	return identity, true
}

// The OSC parser is window-local. Supply its server while processing output so
// identity markers can check other live windows under the same server lock.
func (s *muxServer) observeAgentIdentityMetadataLocked(w *muxWindow, chunk []byte) []string {
	previous := w.agentIdentityServer
	w.agentIdentityServer = s
	defer func() { w.agentIdentityServer = previous }()
	return w.observeTerminalMetadataLocked(chunk)
}

// Exact hooks and launch-assigned IDs both reserve a session while its pane
// is live. Keep this independent of the store watcher's ownership policy.
func (s *muxServer) agentSessionIDTakenLocked(tool, id string, except *muxWindow) bool {
	if id == "" {
		return false
	}
	if s.exactAgentSessionOwnerLocked(tool, id, except) {
		return true
	}
	for _, other := range s.windows {
		if other == except || other.closed || (other.agentSessionWatch != nil && other.agentSessionWatch.exited) {
			continue
		}
		if other.agentSessionAssigned &&
			other.agentToolLocked() == tool && other.agentSessionID == id {
			return true
		}
	}
	return false
}

func (w *muxWindow) applyAgentIdentityPayloadLocked(value string) {
	identity, ok := decodeAgentIdentityPayload(value)
	if !ok || w.closed {
		return
	}
	// Only a pane known to run this tool may bind its identity: the foreground
	// command is the tool, or the window was created for it. Arbitrary output
	// in a shell pane (a file containing a marker being printed) must never
	// turn that pane into a restorable agent session.
	commandTool := agentToolFromCommandName(w.currentCommandLocked())
	confirmedTool := ""
	if w.agentToolConfirmed {
		confirmedTool = strings.TrimSpace(w.agentTool)
	}
	if commandTool != identity.Tool && confirmedTool != identity.Tool {
		return
	}
	assigned := identity.Source == "assigned"
	if assigned && w.agentSessionIdentityExact {
		return
	}
	if s := w.agentIdentityServer; s != nil && s.agentSessionIDTakenLocked(identity.Tool, identity.ID, w) {
		return
	}
	if w.agentSessionID != identity.ID || w.agentToolLocked() != identity.Tool {
		w.agentSessionPath, w.agentSessionDir = "", ""
	}
	w.agentTool, w.agentToolConfirmed = identity.Tool, true
	w.agentSessionID = identity.ID
	w.agentSessionIdentityExact, w.agentSessionAssigned = !assigned, assigned
	if !assigned && w.agentSessionWatch != nil {
		w.agentSessionWatch.done = true
	}
	if !assigned && identity.File != "" {
		w.agentSessionPath, w.agentSessionDir = identity.File, filepath.Dir(identity.File)
	}
}

// os.UserHomeDir honors HOME (USERPROFILE on Windows), matching the existing
// discovery tests' setTestHomeDir override. A transcript need not exist at hook
// time; only provisional identities require this proof before restore.
func agentSessionExistsInStore(tool, id string) bool {
	if !agentSessionIDValid(tool, id) {
		return false
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return false
	}
	regularFile := func(path string) bool {
		info, err := os.Stat(path)
		return err == nil && info.Mode().IsRegular()
	}
	// ReadDir avoids treating metacharacters in the home directory as globs.
	childFileExists := func(root, relative string) bool {
		entries, _ := os.ReadDir(root)
		for _, entry := range entries {
			if regularFile(filepath.Join(root, entry.Name(), relative)) {
				return true
			}
		}
		return false
	}
	switch tool {
	case "claude":
		if childFileExists(filepath.Join(home, ".claude", "projects"), id+".jsonl") {
			return true
		}
		root := filepath.Join(home, ".claude", "sessions")
		entries, _ := os.ReadDir(root)
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
				continue
			}
			var session struct {
				SessionID string `json:"sessionId"`
			}
			data, err := os.ReadFile(filepath.Join(root, entry.Name()))
			if err == nil && json.Unmarshal(data, &session) == nil && session.SessionID == id {
				return true
			}
		}
	case "copilot":
		info, err := os.Stat(filepath.Join(home, ".copilot", "session-state", id))
		return err == nil && info.IsDir()
	case "cursor-agent":
		return childFileExists(filepath.Join(home, ".cursor", "chats"), filepath.Join(id, "meta.json"))
	}
	return false
}

func (s *muxServer) snapshotAgentIdentityLocked(w *muxWindow, state *restoreWindowState) {
	state.AgentSessionAssigned = w.agentSessionAssigned && !w.agentSessionIdentityExact
	if state.AgentSessionAssigned && (!agentSessionExistsInStore(state.AgentTool, state.AgentSessionID) ||
		s.agentSessionIDTakenLocked(state.AgentTool, state.AgentSessionID, w)) {
		state.AgentSessionID, state.AgentSessionPath, state.AgentSessionDir = "", "", ""
	}
}

// Run after exact-binding protection. Inference can replace a provisional ID,
// but cannot resurrect an uncreated --session-id or duplicate another owner.
func protectProvisionalAgentSessionBindings(restore *serverRestore) func() {
	originals := append([]restoreWindowState(nil), restore.Windows...)
	return func() {
		for i := range restore.Windows {
			w, original := &restore.Windows[i], originals[i]
			if !original.AgentSessionAssigned || original.AgentSessionIdentityExact || w.AgentSessionIdentityExact {
				continue
			}
			if w.AgentSessionID == "" {
				w.AgentSessionID = original.AgentSessionID
			}
			if !agentSessionExistsInStore(agentToolCandidateForRestore(*w), w.AgentSessionID) {
				w.AgentSessionID, w.AgentSessionPath, w.AgentSessionDir = "", "", ""
			}
		}
		owners := map[string]int{}
		// Exact identities take precedence, then assigned IDs, then inference.
		for _, priority := range []int{0, 1, 2} {
			for i := range restore.Windows {
				w := &restore.Windows[i]
				rank := 2
				if w.AgentSessionIdentityExact {
					rank = 0
				} else if w.AgentSessionAssigned {
					rank = 1
				}
				if rank != priority || w.AgentSessionID == "" {
					continue
				}
				key := agentToolCandidateForRestore(*w) + "\x00" + w.AgentSessionID
				if _, exists := owners[key]; exists {
					w.AgentSessionID, w.AgentSessionPath, w.AgentSessionDir = "", "", ""
					w.AgentSessionIdentityExact = false
				} else {
					owners[key] = i
				}
			}
		}
	}
}

func agentIdentityFromHookPayload(tool string, payload []byte, notifyArgument string) (agentIdentity, bool) {
	identity := agentIdentity{Tool: tool}
	if len(notifyArgument) > agentIdentityHookInputLimit {
		return agentIdentity{}, false
	}
	if tool == "codex" && notifyArgument != "" {
		var notify struct {
			Type     string `json:"type"`
			ThreadID string `json:"thread-id"`
		}
		if json.Unmarshal([]byte(notifyArgument), &notify) != nil || notify.Type != "agent-turn-complete" {
			return agentIdentity{}, false
		}
		identity.ID, identity.Source = notify.ThreadID, "turn"
		return identity, agentIdentityValid(identity)
	}
	if len(payload) > agentIdentityHookInputLimit {
		return agentIdentity{}, false
	}
	var hook struct {
		Event            string          `json:"hook_event_name"`
		AgentID          string          `json:"agent_id"`
		SessionID        string          `json:"session_id"`
		ConversationID   string          `json:"conversation_id"`
		CopilotSessionID string          `json:"sessionId"`
		TranscriptPath   string          `json:"transcript_path"`
		Source           string          `json:"source"`
		Background       json.RawMessage `json:"is_background_agent"`
	}
	if json.Unmarshal(payload, &hook) != nil {
		return agentIdentity{}, false
	}
	identity.ID, identity.File, identity.Source = hook.SessionID, hook.TranscriptPath, hook.Source
	switch tool {
	case "claude":
		if hook.Event != "SessionStart" || hook.AgentID != "" {
			return agentIdentity{}, false
		}
	case "codex":
		if hook.Event != "SessionStart" || (hook.Source != "startup" && hook.Source != "resume") {
			return agentIdentity{}, false
		}
	case "copilot":
		if hook.Source != "startup" && hook.Source != "resume" && hook.Source != "new" {
			return agentIdentity{}, false
		}
		identity.ID, identity.File = hook.CopilotSessionID, ""
	case "cursor-agent":
		if hook.Event != "sessionStart" || (len(hook.Background) != 0 && string(hook.Background) != "false") {
			return agentIdentity{}, false
		}
		if identity.ID == "" {
			identity.ID = hook.ConversationID
		}
	default:
		return agentIdentity{}, false
	}
	return identity, agentIdentityValid(identity)
}

func agentIdentityHookAncestryMatches() bool {
	value, set := os.LookupEnv("MONKEYMUX_AGENT_PID")
	if !set {
		return true
	}
	pid, err := strconv.Atoi(value)
	if err != nil || pid <= 0 {
		return false
	}
	parent := os.Getppid()
	if pid == parent {
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "ps", "-o", "ppid=", "-p", strconv.Itoa(parent)).Output()
	if err != nil {
		return false
	}
	grandparent, err := strconv.Atoi(strings.TrimSpace(string(output)))
	return err == nil && pid == grandparent
}

func agentIdentityHookCommand(args []string) {
	defer fmt.Fprintln(os.Stdout, "{}")
	flags := flag.NewFlagSet("agent-identity-hook", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	tool := flags.String("tool", "", "agent tool")
	if flags.Parse(args) != nil {
		return
	}
	switch *tool {
	case "claude", "codex", "copilot", "cursor-agent":
	default:
		return
	}
	if !agentIdentityHookAncestryMatches() {
		return
	}
	notifyArgument := ""
	if flags.NArg() > 0 {
		notifyArgument = flags.Arg(0)
	}
	var payload []byte
	if !(*tool == "codex" && notifyArgument != "") && !term.IsTerminal(int(os.Stdin.Fd())) {
		var err error
		payload, err = io.ReadAll(io.LimitReader(os.Stdin, agentIdentityHookInputLimit))
		if err != nil {
			return
		}
	}
	identity, ok := agentIdentityFromHookPayload(*tool, payload, notifyArgument)
	if !ok {
		return
	}
	writeAgentIdentityMarker(encodeAgentIdentityMarker(identity))
}

// Always return a fresh slice; callers may share their inherited environment.
func withPaneTTYEnvironment(env []string, path string) []string {
	result := make([]string, 0, len(env)+1)
	for _, value := range env {
		if !strings.HasPrefix(value, "MONKEYMUX_PANE_TTY=") {
			result = append(result, value)
		}
	}
	return append(result, "MONKEYMUX_PANE_TTY="+path)
}
