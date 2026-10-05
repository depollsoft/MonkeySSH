package main

import (
	"regexp"
	"slices"
	"strings"
	"time"
)

// agentDescriptor is everything MonkeyMux knows about one supported agent CLI.
// Each field feeds one lookup; a nil or empty field means the agent is
// deliberately outside that feature, so the lookups below read absence as
// "not supported" rather than consulting a second table.
type agentDescriptor struct {
	// commandNames are the lowercase process basenames (without .exe or .js)
	// that identify the agent; commandNamePattern matches generated names.
	commandNames       []string
	commandNamePattern *regexp.Regexp
	// titles and titlePrefixes classify a normalized terminal title: an exact
	// match or a prefix (which ends in the separator that follows the name).
	titles        []string
	titlePrefixes []string
	// launch is how a restore relaunches or resumes the agent. An empty
	// executable means the window restores as a plain shell instead.
	launch agentLaunchSpec
	// sessionIDPattern validates ids in the agent's session store.
	sessionIDPattern *regexp.Regexp
	// resumeArgPatterns extract a session id from a running process's argv.
	resumeArgPatterns []*regexp.Regexp
	// fileBacked agents write sessions as files MonkeyMux watches and binds.
	fileBacked bool
	// wrappedLaunch agents start through `monkeymux agent-launch <tool>`.
	wrappedLaunch bool
	// hookIdentity accepts or rejects one agent-identity-hook payload and
	// fills in the id and file the hook reports; nil means no hook.
	hookIdentity func(hook agentHookPayload, identity *agentIdentity) bool
	// hookNotifyArgument agents also report a turn through a JSON argument.
	hookNotifyArgument bool
	// acpProviderIDs are the built-in ACP provider ids that host the agent.
	acpProviderIDs []string
	// nativeTitle reads a native window's label from the agent's own session
	// store; nil means the native window keeps its ACP name.
	nativeTitle func(state *nativeAgentTitleState, home, sessionID string, now time.Time) string
	// wheelProfile governs wheel acceleration for a TUI that ramps scroll
	// speed itself. It is keyed on the agent only because that is how the
	// window learns which TUI it runs.
	wheelProfile *wheelAccelerationProfile
}

type agentLaunchSpec struct {
	executable       string
	permissionFlags  string
	resumeArgument   string
	supportsContinue bool
}

var (
	agentIdentityUUIDPattern        = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	agentIdentityOpenCodePattern    = regexp.MustCompile(`^ses_[A-Za-z0-9]{1,60}$`)
	resumeFlagArgumentPattern       = regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`)
	sessionFlagArgumentPattern      = regexp.MustCompile(`(?:^|\s)--session(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`)
	conversationFlagArgumentPattern = regexp.MustCompile(`(?:^|\s)--conversation(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`)
	resumeSubcommandArgumentPattern = regexp.MustCompile(`(?:^|\s)resume\s+(?:"([^"]+)"|'([^']+)'|(\S+))`)
	museResumeArgumentPattern       = regexp.MustCompile(`(?:^|\s)resume\s+(?:"([^"-][^"]*)"|'([^'-][^']*)'|([^-\s]\S*))`)
)

// agentTools orders the registry for lookups that scan it.
var agentTools = []string{
	"muse", "claude", "copilot", "codex", "opencode", "antigravity",
	"cursor-agent", "pi", "hermes", "openclaw",
}

var agentRegistry = map[string]agentDescriptor{
	"muse": {
		commandNames:       []string{"muse", "muse.cmd", "muse-code-acp", "muse-code-acp.cmd"},
		commandNamePattern: museBinaryNamePattern,
		titles:             []string{"muse", "muse code"},
		titlePrefixes:      []string{"muse code "},
		launch:             agentLaunchSpec{"muse", "--yolo", "resume", true},
		sessionIDPattern:   agentIdentityUUIDPattern,
		resumeArgPatterns:  []*regexp.Regexp{museResumeArgumentPattern},
		fileBacked:         true,
	},
	"claude": {
		commandNames:      []string{"claude", "claude-code"},
		titles:            []string{"claude", "claude code"},
		titlePrefixes:     []string{"claude code "},
		launch:            agentLaunchSpec{"claude", "--dangerously-skip-permissions", "--resume", false},
		sessionIDPattern:  agentIdentityUUIDPattern,
		resumeArgPatterns: []*regexp.Regexp{resumeFlagArgumentPattern},
		fileBacked:        true,
		wrappedLaunch:     true,
		hookIdentity: func(hook agentHookPayload, _ *agentIdentity) bool {
			return hook.Event == "SessionStart" && hook.AgentID == ""
		},
		acpProviderIDs: []string{"claude-agent-acp"},
		nativeTitle: func(state *nativeAgentTitleState, home, sessionID string, now time.Time) string {
			return state.claude.title(home, sessionID, now)
		},
	},
	"copilot": {
		commandNames:      []string{"copilot", "github-copilot"},
		titles:            []string{"copilot", "copilot cli"},
		titlePrefixes:     []string{"copilot cli "},
		launch:            agentLaunchSpec{"copilot", "--yolo", "--resume", false},
		sessionIDPattern:  agentIdentityUUIDPattern,
		resumeArgPatterns: []*regexp.Regexp{resumeFlagArgumentPattern},
		fileBacked:        true,
		wrappedLaunch:     true,
		hookIdentity: func(hook agentHookPayload, identity *agentIdentity) bool {
			if hook.Source != "startup" && hook.Source != "resume" && hook.Source != "new" {
				return false
			}
			identity.ID, identity.File = hook.CopilotSessionID, ""
			return true
		},
		acpProviderIDs: []string{"copilot-cli"},
		nativeTitle: func(state *nativeAgentTitleState, home, sessionID string, _ time.Time) string {
			return state.copilot.title(home, sessionID)
		},
	},
	"codex": {
		commandNames:      []string{"codex", "codex-cli"},
		titles:            []string{"codex"},
		titlePrefixes:     []string{"codex "},
		launch:            agentLaunchSpec{"codex", "--yolo", "resume", false},
		sessionIDPattern:  agentIdentityUUIDPattern,
		resumeArgPatterns: []*regexp.Regexp{resumeSubcommandArgumentPattern},
		fileBacked:        true,
		wrappedLaunch:     true,
		hookIdentity: func(hook agentHookPayload, _ *agentIdentity) bool {
			return hook.Event == "SessionStart" && (hook.Source == "startup" || hook.Source == "resume")
		},
		hookNotifyArgument: true,
		acpProviderIDs:     []string{"codex-acp"},
		nativeTitle: func(state *nativeAgentTitleState, home, sessionID string, now time.Time) string {
			return state.codex.title(codexHomeDirectory(home), sessionID, now)
		},
	},
	"opencode": {
		commandNames:      []string{"opencode", "opencode2", "open-code"},
		titles:            []string{"opencode", "open code"},
		titlePrefixes:     []string{"opencode "},
		launch:            agentLaunchSpec{"opencode", "--auto", "--session", true},
		sessionIDPattern:  agentIdentityOpenCodePattern,
		resumeArgPatterns: []*regexp.Regexp{sessionFlagArgumentPattern},
		fileBacked:        true,
		wrappedLaunch:     true,
		acpProviderIDs:    []string{"opencode"},
	},
	"antigravity": {
		commandNames:      []string{"agy", "antigravity", "antigravity-cli"},
		titles:            []string{"agy", "antigravity"},
		titlePrefixes:     []string{"agy ", "antigravity "},
		launch:            agentLaunchSpec{"agy", "--dangerously-skip-permissions", "--conversation", true},
		sessionIDPattern:  agentIdentityUUIDPattern,
		resumeArgPatterns: []*regexp.Regexp{conversationFlagArgumentPattern},
		fileBacked:        true,
		acpProviderIDs:    []string{"antigravity-acp"},
		wheelProfile: &wheelAccelerationProfile{
			window: 150 * time.Millisecond,
			speed: func(count int) int {
				// Integer square root, bounded by the TUI's maximum speed.
				speed := 1
				for speed < 12 && speed*speed <= count {
					speed++
				}
				return speed
			},
		},
	},
	"cursor-agent": {
		commandNames:      []string{"cursor-agent"},
		titles:            []string{"cursor agent", "cursor-agent", "cursor cli"},
		titlePrefixes:     []string{"cursor agent "},
		launch:            agentLaunchSpec{"cursor-agent", "--force", "--resume", true},
		sessionIDPattern:  agentIdentityUUIDPattern,
		resumeArgPatterns: []*regexp.Regexp{resumeFlagArgumentPattern},
		fileBacked:        true,
		wrappedLaunch:     true,
		hookIdentity: func(hook agentHookPayload, identity *agentIdentity) bool {
			if hook.Event != "sessionStart" || (len(hook.Background) != 0 && string(hook.Background) != "false") {
				return false
			}
			if identity.ID == "" {
				identity.ID = hook.ConversationID
			}
			return true
		},
		acpProviderIDs: []string{"cursor-agent-acp"},
	},
	"pi": {
		// Pi launches through `monkeymux pi-agent` (see agentLaunchCommand)
		// and labels its native windows through piSessionTitle.
		commandNames:      []string{"pi", "pi-agent"},
		titles:            []string{"pi", "π"},
		titlePrefixes:     []string{"pi - ", "π - "},
		sessionIDPattern:  safePiSessionIDPattern,
		resumeArgPatterns: []*regexp.Regexp{sessionFlagArgumentPattern},
		acpProviderIDs:    []string{"pi-acp"},
	},
	"hermes": {
		commandNames: []string{"hermes", "hermes-agent"},
	},
	"openclaw": {
		commandNames: []string{"openclaw"},
	},
}

var (
	agentToolByCommandName = map[string]string{}
	agentToolByProvider    = map[string]string{}
)

func init() {
	for _, tool := range agentTools {
		descriptor := agentRegistry[tool]
		for _, name := range descriptor.commandNames {
			agentToolByCommandName[name] = tool
		}
		for _, providerID := range descriptor.acpProviderIDs {
			agentToolByProvider[providerID] = tool
		}
	}
}

func agentToolFromCommandName(command string) string {
	if tool := agentLaunchToolFromCommand(command); tool != "" {
		return tool
	}
	normalized := strings.ToLower(cleanProcessCommandName(command))
	if tool, ok := agentToolByCommandName[normalized]; ok {
		return tool
	}
	for _, tool := range agentTools {
		if pattern := agentRegistry[tool].commandNamePattern; pattern != nil && pattern.MatchString(normalized) {
			return tool
		}
	}
	return ""
}

func agentToolFromTerminalTitle(title string) string {
	normalized := strings.ToLower(strings.Join(strings.Fields(title), " "))
	normalized = strings.Trim(normalized, "·-: ")
	for _, tool := range agentTools {
		descriptor := agentRegistry[tool]
		if slices.Contains(descriptor.titles, normalized) {
			return tool
		}
		for _, prefix := range descriptor.titlePrefixes {
			if strings.HasPrefix(normalized, prefix) {
				return tool
			}
		}
	}
	return ""
}

// nativeAgentToolForProvider maps a built-in ACP provider id to its agent when
// the window name (a display label such as "Cursor Agent") does not.
func nativeAgentToolForProvider(providerID string) string {
	return agentToolByProvider[strings.TrimPrefix(strings.TrimSpace(providerID), "builtin:")]
}

func agentSessionIDValid(tool, id string) bool {
	pattern := agentRegistry[tool].sessionIDPattern
	return pattern != nil && pattern.MatchString(id)
}

func fileBackedAgent(tool string) bool {
	return agentRegistry[tool].fileBacked
}

func agentLaunchToolSupported(tool string) bool {
	return agentRegistry[tool].wrappedLaunch
}
