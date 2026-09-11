package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"

	"golang.org/x/term"
)

// muxPty is the terminal endpoint of a running window's child process. On POSIX
// systems it wraps the pty master file; on Windows it wraps a ConPTY.
type muxPty interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
	Close() error
	// Resize sets the pseudo terminal size in character cells.
	Resize(cols int, rows int) error
	// Fd returns the underlying file descriptor on POSIX systems, or 0 when
	// there is no usable descriptor (Windows).
	Fd() uintptr
}

// muxProcess is the child process attached to a window's pty.
type muxProcess interface {
	// Pid returns the process identifier, or 0 when it is unavailable.
	Pid() int
	// Wait blocks until the process exits.
	Wait() error
	// Hangup asks the process (group) to terminate, as if the controlling
	// terminal went away (SIGHUP on POSIX).
	Hangup()
	// Kill terminates the process group immediately. The caller must own the
	// process exclusively and must not call Wait until Kill returns.
	Kill()
}

const (
	monkeyMuxVersion                  = "0.1.196"
	defaultColumns                    = 80
	defaultRows                       = 24
	maxTitleBytes                     = 160
	controlMaxFrameBytes              = 1024 * 1024
	piSessionMetadataRecordLimitBytes = 1024 * 1024
	piSessionHeaderScanLimitBytes     = 1024 * 1024
	piSessionActivityMatchTolerance   = 15 * time.Second
	agentSessionStartTolerance        = 2 * time.Second
	oscBufferLimitBytes               = 4096
	processMetadataTimeout            = 500 * time.Millisecond
	processMetadataInterval           = 500 * time.Millisecond
	runCommandOutputMaxBytes          = 8 * 1024 * 1024
	runCommandTimeout                 = 20 * time.Second
	socketTimeout                     = 2 * time.Second
	attachWriteTimeout                = time.Second
	attachTransitionTimeout           = 3 * time.Second
	terminalResponseMaxOutstanding    = 64
	attachWriteChunkBytes             = 32 * 1024
	terminalResponseFocusGrace        = 2 * time.Second
	focusInputCarryDelay              = 75 * time.Millisecond
	bracketedPasteStartCarryDelay     = 20 * time.Millisecond
	foregroundRedrawResizeDelay       = 40 * time.Millisecond
	foregroundRedrawForwardingPause   = foregroundRedrawResizeDelay + 80*time.Millisecond
	foregroundRedrawBufferLimitBytes  = 512 * 1024
	windowUpdateMinInterval           = 750 * time.Millisecond
	windowHistoryLimitBytes           = 128 * 1024
	windowFullReplayHistoryLimitBytes = 512 * 1024
	windowReplayLimitBytes            = 32 * 1024
	csiBufferLimitBytes               = 64
	pendingTerminalQueryLimitBytes    = 512
	terminalResponseCarryLimitBytes   = 64 * 1024
	themeHintLimitBytes               = 1024
	capabilityHintLimitBytes          = 1024
	restoreFileMode                   = 0o600
	restoreSchemaVersion              = 1
	attachWriteQueueLimitBytes        = 16 * 1024 * 1024
	// ensureServer serializes attach/create for a session and retries dials so a
	// transient socket blip cannot steal the path from a live server and replace
	// a multi-window workspace with a fresh single auto-connect window.
	ensureServerDialAttempts  = 8
	ensureServerDialInterval  = 50 * time.Millisecond
	ensureServerLockTimeout   = 5 * time.Second
	ensureServerLockRetryWait = 50 * time.Millisecond
	// How often a contended session lock re-checks whether its holder died, and
	// how many times a freed lock may be claimed before the wait deadline wins.
	sessionLockStaleCheckInterval = 250 * time.Millisecond
	ensureServerLockClearRetries  = 8
	// How long a session file that cannot be parsed at all must sit untouched
	// before it is treated as abandoned. Kept well under the lock timeout so a
	// waiter can still reclaim it, and well over the gap between creating a
	// lock file and writing the pid into it.
	abandonedPIDFileAge = 2 * time.Second
	// How far a process may appear to have started after the session file that
	// names it before the two are treated as different processes. Only a few
	// seconds of skew is plausible between a file timestamp and an operating
	// system's start time, and a small window means a pid would have to be
	// recycled almost immediately to be mistaken for its previous holder.
	pidRecordStartSlack = 5 * time.Second
	// How many times ownership is re-resolved when a reclaim loses a race with
	// another helper installing its own record.
	pidRecordResolveAttempts = 3
	// Cap on how much of a session file is read before it is called invalid.
	pidFileReadLimitBytes = 4096
	// How long an upgrade snapshot must sit unused before gc reclaims it.
	abandonedRestoreFileAge = time.Hour
	// How long an upgrade waits for the outgoing helper to leave its pid
	// behind. Dial failure is not enough: the old process can still be in
	// close() and later unlink the replacement's freshly rebound socket.
	serverExitWaitTimeout = windowWatcherShutdownTimeout + time.Second
	// A forced stop gets a separate, short exit confirmation. Keep the first
	// wait long enough for the outgoing helper's graceful window teardown.
	serverForcedExitWaitTimeout = time.Second
	// How often a live server checks that its socket path still names the
	// inode it is accepting on. An upgrade that unlinked by path leaves the
	// replacement listening on an orphaned inode; republishing heals that.
	socketRepublishInterval = 250 * time.Millisecond
	sessionPIDFileMode      = 0o600
	sessionLockFileMode     = 0o600
	// Per-window Kitty image retention, used to survive history eviction across
	// reattaches and to back placeholder cells the foreground app re-emits.
	// Sized for genuinely image-heavy windows (e.g. an agent CLI rendering many
	// screenshots); the byte cap is the binding limit and is per window, so peak
	// server memory is this times the number of image-heavy windows.
	maxRetainedKittyImages       = 128
	maxRetainedKittyImageNumbers = maxRetainedKittyImages
	maxRetainedKittyImageBytes   = 64 * 1024 * 1024
	// Initial attach/window-switch replay must stay small enough for a phone to
	// parse before SSH/terminal readiness deadlines. Long agent sessions can
	// retain dozens of screenshots; eagerly replaying the former 8 MiB budget
	// made the whole connection appear timed out. Replay only the newest likely-
	// visible roots here. Placeholder-driven missing-image requests repair other
	// visible images after the terminal is already connected.
	maxReplayedKittyImages     = 4
	maxReplayedKittyImageBytes = 2 * 1024 * 1024
	// On-demand repair and multipart capture retain the larger budget so an
	// ordinary screenshot above 2 MiB is not dropped or permanently blank; only
	// the synchronous initial replay is constrained to the attach-safe budget.
	maxKittyImageRepairBytes     = 8 * 1024 * 1024
	maxKittyGraphicsPendingBytes = maxKittyImageRepairBytes
)

const terminalParserResetSequence = "\x1b\\"

const terminalCharacterSetResetSequence = "\x0f\x1b(B\x1b)B"

// MonkeySSH-private DEC mode: parse a redraw normally but repaint only on reset.
const terminalSynchronizedOutputBegin = "\x1b[?9002h"

const terminalSynchronizedOutputEnd = "\x1b[?9002l"

const terminalScreenClearSequence = "\x1b[H\x1b[2J\x1b[3J"

const terminalAllScreensClearSequence = terminalScreenClearSequence + "\x1b[?1049h" + terminalScreenClearSequence + "\x1b[?1049l" + terminalScreenClearSequence

const activeWindowReplayPrefix = terminalParserResetSequence + "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?1007l\x1b[?2004l\x1b[?2031l\x1b[?1047l\x1b[?1049l\x1b[?1l\x1b[?6l\x1b[?7h\x1b[4l\x1b>\x1b[r" + terminalCharacterSetResetSequence + "\x1b[0m" + terminalAllScreensClearSequence

var (
	preReplayPrivateModes = []string{
		"1047",
		"1049",
		"6",
		"7",
		"1",
		"1000",
		"1002",
		"1003",
		"1006",
		"1004",
		"1007",
		"2004",
		"2031",
	}
	postReplayPrivateModes = []string{
		"7",
		"1",
		"1000",
		"1002",
		"1003",
		"1006",
		"1004",
		"1007",
		"2004",
		"2031",
	}
	groupedReplayPrivateModes = [][]string{
		{"1047", "1049"},
		{"1000", "1002", "1003"},
	}
	// conPtySwallowedThemeQueryKeys are the theme-query keys whose queries
	// ConPTY consumes inside conhost instead of forwarding out of the pty.
	conPtySwallowedThemeQueryKeys = []string{"10", "11"}
	trackedPrivateModes           = map[string]struct{}{
		"1":    {},
		"6":    {},
		"7":    {},
		"1000": {},
		"1002": {},
		"1003": {},
		"1004": {},
		"1006": {},
		"1007": {},
		"1047": {},
		"1049": {},
		"2004": {},
		"2031": {},
	}
)

var capabilities = []string{
	"attach",
	"attach-command",
	"control-json-v1",
	"direct-pass-through",
	"posix-pty",
	"window-list",
	"window-create",
	"window-select",
	"window-close",
	"active-context",
	"inject-input",
	"inject-input-bracketed-paste",
	"run-command",
	"client-scoped-run-command",
	"focus-hint",
	"theme-hint",
	"terminal-capability-hint",
	"shutdown",
	"attach-update-policy",
	"attach-state",
	"multi-client-attach",
	"tmux-prefix-keys",
	"client-scoped-resize",
	"client-focus",
	"client-viewport-clipping",
	"image-replay-ack",
	"upgrade-restore-v1",
	"acp-bridge-v1",
	"acp-bridge-replay-v1",
	"acp-bridge-control-start-v1",
	"acp-window-v1",
	"native-acp-upgrade-handoff-v1",
}

var (
	errRunCommandCanceled           = errors.New("command canceled")
	errRunCommandClientClosed       = errors.New("control client closed")
	errRunCommandOutputLimit        = errors.New("command output limit exceeded")
	errRunCommandTimeout            = errors.New("command timed out")
	errServerClosed                 = errors.New("server is closed")
	errServerUpdateNoSnapshot       = errors.New("MonkeyMux update could not snapshot the running workspace; the existing helper was kept")
	errServerUpdateNativeAcpHandoff = errors.New("MonkeyMux update could not preserve the running native agent windows; the existing helper was kept")
	errServerUpdateStillAlive       = errors.New("MonkeyMux update could not stop the running workspace; the existing helper was kept")
)

var stopNativeAcpBridgeForWindow = requestAcpBridgeStopAndWait

var nativeAcpWindowArguments = func(bridgeID string) ([]string, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	return []string{exe, "acp", "wait", bridgeID}, nil
}

var simulateForegroundResize = func(window *muxWindow, width int, height int) {
	if window == nil || window.pty == nil || width <= 0 || height <= 0 {
		return
	}
	generation := window.resizeGeneration.Add(1)
	temporaryWidth, temporaryHeight, ok := foregroundRedrawTemporarySize(
		width,
		height,
	)
	if ok {
		window.resizePtyIfCurrent(
			generation,
			temporaryWidth,
			temporaryHeight,
		)
		// Leave the PTY at a temporary size long enough for TUIs that ignore
		// same-size SIGWINCH events to observe a real resize before restoring.
		time.AfterFunc(foregroundRedrawResizeDelay, func() {
			window.resizePtyIfCurrent(generation, width, height)
		})
		return
	}
	window.resizePtyIfCurrent(generation, width, height)
}

// deliverForegroundGeometry gives a window's foreground app this geometry and
// makes sure it notices.
//
// A genuine size change is its own redraw notification, so it is applied
// directly. Manufacturing a temporary size on top of it would make the app lay
// out and emit an entire frame for a geometry that never existed, which the
// client paints before the real one replaces it. Only when the size is already
// current is there nothing for the app to notice, and the synthetic size is
// then the sole way left to ask for a repaint.
var deliverForegroundGeometry = func(
	window *muxWindow,
	width int,
	height int,
) {
	if window == nil || window.pty == nil || width <= 0 || height <= 0 {
		return
	}
	if !window.ptySizeIs(width, height) {
		window.resizePty(width, height)
		return
	}
	simulateForegroundResize(window, width, height)
}

func foregroundRedrawTemporarySize(width int, height int) (int, int, bool) {
	if width <= 0 || height <= 0 {
		return 0, 0, false
	}
	if prefersVerticalForegroundRedrawResize {
		if height > 1 {
			return width, height - 1, true
		}
		if width > 1 {
			return width - 1, height, true
		}
		return 2, 1, true
	}
	if width > 1 {
		return width - 1, height, true
	}
	if height > 1 {
		return width, height - 1, true
	}
	return 2, 1, true
}

func shouldSimulateForegroundRedraw(
	forceRedraw bool,
	syntheticRedraw bool,
	dimensionsChanged bool,
	supportsExplicitResizeSignal bool,
) bool {
	return syntheticRedraw ||
		(forceRedraw && !dimensionsChanged && !supportsExplicitResizeSignal)
}

func (w *muxWindow) resizePty(width int, height int) {
	if w == nil || w.pty == nil || width <= 0 || height <= 0 {
		return
	}
	w.resizeGeneration.Add(1)
	w.ptyResizeMu.Lock()
	if err := w.pty.Resize(width, height); err == nil {
		w.ptyWidth = width
		w.ptyHeight = height
	}
	w.ptyResizeMu.Unlock()
}

// ptySizeIs reports whether the PTY already holds this geometry, so callers can
// tell a genuine resize (which notifies the foreground app by itself) apart
// from a repeat that the app would ignore.
func (w *muxWindow) ptySizeIs(width int, height int) bool {
	if w == nil {
		return false
	}
	w.ptyResizeMu.Lock()
	defer w.ptyResizeMu.Unlock()
	return w.ptyWidth == width && w.ptyHeight == height
}

func (w *muxWindow) resizePtyIfCurrent(
	generation uint64,
	width int,
	height int,
) {
	if w == nil || w.pty == nil || width <= 0 || height <= 0 {
		return
	}
	w.ptyResizeMu.Lock()
	defer w.ptyResizeMu.Unlock()
	if w.resizeGeneration.Load() != generation {
		return
	}
	if err := w.pty.Resize(width, height); err == nil {
		w.ptyWidth = width
		w.ptyHeight = height
	}
}

func (w *muxWindow) closePty(ptyFile muxPty) error {
	if w == nil || ptyFile == nil {
		return nil
	}
	w.resizeGeneration.Add(1)
	w.ptyResizeMu.Lock()
	defer w.ptyResizeMu.Unlock()
	return ptyFile.Close()
}

// restoreRedrawFollowUpDelays are the delays after a restored foreground-redraw
// window first becomes visible at which we re-issue a forced redraw. A window
// restored from an upgrade snapshot relaunches its foreground process (for an
// agent, something like `claude --resume`), and that process can take a while
// to start listening for SIGWINCH. The immediate synthetic resize can therefore
// land before the process is ready, leaving the pane blank until the user
// manually resizes. Re-issuing the redraw a few times catches the process once
// it is up without waiting on a human.
var restoreRedrawFollowUpDelays = []time.Duration{
	250 * time.Millisecond,
	750 * time.Millisecond,
	1750 * time.Millisecond,
}

// scheduleRestoreRedraw runs a restore redraw follow-up after the given delay.
// It is a package variable so tests can invoke the action synchronously.
var scheduleRestoreRedraw = func(delay time.Duration, action func()) {
	time.AfterFunc(delay, action)
}

const (
	serverUpdatePolicyPrompt = "prompt"
	serverUpdatePolicyNever  = "never"
	serverUpdatePolicyAlways = "always"
)

var (
	leadingCdCommandPattern       = regexp.MustCompile(`^cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*&&\s*`)
	leadingEnvPattern             = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=(?:"(?:[^"\\]|\\.)*"|'[^']*'|\S+)\s+`)
	restoreFileNamePattern        = regexp.MustCompile(`^monkeymux-restore-[a-f0-9]{24}-[0-9]+\.json$`)
	codexSessionIDPattern         = regexp.MustCompile(`(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`)
	piSessionDirArgumentPattern   = regexp.MustCompile(`(?:^|\s)--session-dir(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`)
	safePiSessionIDPattern        = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$`)
	agentSessionIDArgumentPattern = map[string][]*regexp.Regexp{
		"claude": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"copilot": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"codex": {
			regexp.MustCompile(`(?:^|\s)resume\s+(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"opencode": {
			regexp.MustCompile(`(?:^|\s)--session(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"pi": {
			regexp.MustCompile(`(?:^|\s)--session(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"antigravity": {
			regexp.MustCompile(`(?:^|\s)--conversation(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"cursor-agent": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
	}
)

type controlMessage struct {
	Role           string   `json:"role,omitempty"`
	ID             string   `json:"id,omitempty"`
	Type           string   `json:"type,omitempty"`
	Session        string   `json:"session,omitempty"`
	ClientID       string   `json:"clientId,omitempty"`
	WindowID       string   `json:"windowId,omitempty"`
	WindowIndex    *int     `json:"windowIndex,omitempty"`
	Name           string   `json:"name,omitempty"`
	Cwd            string   `json:"cwd,omitempty"`
	Command        string   `json:"command,omitempty"`
	ProviderID     string   `json:"providerId,omitempty"`
	Provider       string   `json:"provider,omitempty"`
	Args           []string `json:"args,omitempty"`
	Data           string   `json:"data,omitempty"`
	BracketedPaste bool     `json:"bracketedPaste,omitempty"`
	// CapabilityHint carries the attaching client's static terminal capability
	// replies (see capabilityHintResponseMap) so the daemon can answer device
	// attribute/XTVERSION probes for windows the client is not showing.
	CapabilityHint string `json:"capabilityHint,omitempty"`
	Width          int    `json:"width,omitempty"`
	Height         int    `json:"height,omitempty"`
	PixelWidth     int    `json:"pixelWidth,omitempty"`
	PixelHeight    int    `json:"pixelHeight,omitempty"`
	Redraw         bool   `json:"redraw,omitempty"`
	NoPrefix       bool   `json:"noPrefix,omitempty"`
	ClipViewport   bool   `json:"clipViewport,omitempty"`
	// SuppressReplay selects a native ACP placeholder without redrawing it into
	// the attached terminal because the app replaces that viewport natively.
	SuppressReplay bool `json:"suppressReplay,omitempty"`
	// HaveImageSignatures maps a Kitty protocol image id (as a string) to the
	// FNV-1a-32 signature of the base64-decoded payload the client already
	// holds. Sent with select_window so the replay can skip re-transmitting
	// images the client can render from its own cache.
	HaveImageSignatures map[string]uint32 `json:"haveImageSignatures,omitempty"`
	// ImageIDs lists Kitty protocol image ids (as strings) the client is missing
	// for the active window: it has drawn placeholder cells that reference them
	// but never received (or has evicted) their bytes. Sent with request_images
	// so the server can replay exactly those retained transmissions.
	ImageIDs []string `json:"imageIds,omitempty"`
}

type controlResponse struct {
	ID                 string           `json:"id,omitempty"`
	Type               string           `json:"type"`
	Status             string           `json:"status,omitempty"`
	Error              string           `json:"error,omitempty"`
	Version            string           `json:"version,omitempty"`
	Session            string           `json:"session,omitempty"`
	Capabilities       []string         `json:"capabilities,omitempty"`
	Windows            []windowSnapshot `json:"windows,omitempty"`
	Window             *windowSnapshot  `json:"window,omitempty"`
	CurrentPath        string           `json:"currentPath,omitempty"`
	CurrentCommand     string           `json:"currentCommand,omitempty"`
	Data               string           `json:"data,omitempty"`
	ExitCode           int              `json:"exitCode,omitempty"`
	HasAttach          bool             `json:"hasForegroundClient,omitempty"`
	AttachCount        int              `json:"foregroundClientCount,omitempty"`
	ImageIDs           []string         `json:"imageIds,omitempty"`
	ImagesAcknowledged bool             `json:"imagesAcknowledged,omitempty"`
	FocusChanged       bool             `json:"focusChanged,omitempty"`
	Restore            *serverRestore   `json:"restore,omitempty"`
}

type windowSnapshot struct {
	ID                        string                    `json:"id"`
	Index                     int                       `json:"index"`
	Name                      string                    `json:"name"`
	Active                    bool                      `json:"active"`
	CurrentCommand            string                    `json:"currentCommand,omitempty"`
	CurrentPath               string                    `json:"currentPath,omitempty"`
	PanePid                   int                       `json:"panePid,omitempty"`
	Flags                     string                    `json:"flags,omitempty"`
	PaneTitle                 string                    `json:"paneTitle,omitempty"`
	AgentTool                 string                    `json:"agentTool,omitempty"`
	AgentToolConfirmed        bool                      `json:"agentToolConfirmed,omitempty"`
	AgentSessionID            string                    `json:"agentSessionId,omitempty"`
	AgentSessionDir           string                    `json:"agentSessionDir,omitempty"`
	AgentSessionPath          string                    `json:"agentSessionPath,omitempty"`
	AgentSessionIdentityExact bool                      `json:"agentSessionIdentityExact,omitempty"`
	NativeAcpBridgeID         string                    `json:"nativeAcpBridgeId,omitempty"`
	NativeAcpProviderID       string                    `json:"nativeAcpProviderId,omitempty"`
	LastActivityEpochSeconds  int64                     `json:"lastActivityEpochSeconds,omitempty"`
	TerminalReportsMouseWheel bool                      `json:"terminalReportsMouseWheel,omitempty"`
	TerminalMouseReportSgr    bool                      `json:"terminalMouseReportSgr,omitempty"`
	TerminalBracketedPaste    bool                      `json:"terminalBracketedPasteMode,omitempty"`
	PrivateModes              map[string]bool           `json:"privateModes,omitempty"`
	TerminalProgress          *terminalProgressSnapshot `json:"terminalProgress,omitempty"`
}

type terminalProgressSnapshot struct {
	State      int  `json:"state"`
	Percentage *int `json:"percentage,omitempty"`
}

type serverRestore struct {
	SchemaVersion   int                  `json:"schemaVersion"`
	Windows         []restoreWindowState `json:"windows,omitempty"`
	StartInYoloMode bool                 `json:"startInYoloMode,omitempty"`
}

type restoreWindowState struct {
	ID                        string                    `json:"id,omitempty"`
	Index                     int                       `json:"index,omitempty"`
	Name                      string                    `json:"name,omitempty"`
	Cwd                       string                    `json:"cwd,omitempty"`
	CurrentCommand            string                    `json:"currentCommand,omitempty"`
	PanePid                   int                       `json:"panePid,omitempty"`
	PaneTitle                 string                    `json:"paneTitle,omitempty"`
	AgentTool                 string                    `json:"agentTool,omitempty"`
	AgentToolConfirmed        bool                      `json:"agentToolConfirmed,omitempty"`
	AgentSessionID            string                    `json:"agentSessionId,omitempty"`
	AgentSessionDir           string                    `json:"agentSessionDir,omitempty"`
	AgentSessionPath          string                    `json:"agentSessionPath,omitempty"`
	AgentSessionIdentityExact bool                      `json:"agentSessionIdentityExact,omitempty"`
	NativeAcpBridgeID         string                    `json:"nativeAcpBridgeId,omitempty"`
	NativeAcpProviderID       string                    `json:"nativeAcpProviderId,omitempty"`
	LastActivityEpochSeconds  int64                     `json:"lastActivityEpochSeconds,omitempty"`
	HistoryBase64             string                    `json:"historyBase64,omitempty"`
	HistoryStartsAtGround     bool                      `json:"historyStartsAtGround,omitempty"`
	CursorVisible             bool                      `json:"cursorVisible,omitempty"`
	CursorVisibilityKnown     bool                      `json:"cursorVisibilityKnown,omitempty"`
	PrivateModes              map[string]bool           `json:"privateModes,omitempty"`
	InsertModeEnabled         bool                      `json:"insertModeEnabled,omitempty"`
	InsertModeKnown           bool                      `json:"insertModeKnown,omitempty"`
	ApplicationKeypadEnabled  bool                      `json:"applicationKeypadEnabled,omitempty"`
	ApplicationKeypadKnown    bool                      `json:"applicationKeypadKnown,omitempty"`
	TerminalProgress          *terminalProgressSnapshot `json:"terminalProgress,omitempty"`
	Active                    bool                      `json:"active,omitempty"`
}

type muxServer struct {
	session         string
	width           int
	height          int
	publishedWidth  int
	publishedHeight int

	mu                               sync.Mutex
	resizeMu                         sync.Mutex
	attachTransitionMu               sync.Mutex
	windows                          []*muxWindow
	activeID                         string
	lastActiveID                     string
	nextID                           int
	listener                         net.Listener
	socketPath                       string
	socketIdentity                   socketIdentity
	attachConn                       net.Conn
	attachMu                         sync.Mutex
	attachClients                    map[net.Conn]*attachClient
	nextAttachSequence               uint64
	nextFocusSequence                uint64
	pendingFocusRefreshConn          net.Conn
	attachViewportTransitionWindowID string
	pendingResizeWidth               int
	pendingResizeHeight              int
	pendingResizeRedraw              bool
	// pendingResizeSyntheticRedraw preserves, across a viewport-transition
	// deferral, whether a deferred forced redraw needs the synthetic one-cell
	// resize dance (e.g. a theme change, whose SIGWINCH at an unchanged size
	// would not otherwise repaint). Without it, refreshPendingViewportResize
	// would replay the deferred redraw with syntheticRedraw=false and silently
	// drop the repaint. Reset wherever pendingResizeRedraw is.
	pendingResizeSyntheticRedraw bool
	// pendingResizeThemeWindowID pins a deferred synthetic theme redraw to the
	// window that received the theme hint, so that when refreshPendingViewportResize
	// replays it a concurrent window switch cannot make the dance repaint a
	// different window. Empty when the deferred redraw is not a pinned theme
	// redraw. Reset wherever pendingResizeSyntheticRedraw is.
	pendingResizeThemeWindowID string
	controls                   map[*controlClient]struct{}
	themeHint                  []byte
	// capabilityHint holds the attached client's replies to static terminal
	// capability queries (device attributes, XTVERSION, DSR), keyed by query.
	// It lets the daemon answer those probes for windows no terminal is
	// currently showing — the upgrade-restore case, where relaunched agents
	// would otherwise time out and pick a less capable rendering mode.
	capabilityHint []byte
	closed         bool
	closeDone      chan struct{}

	// restoreRedrawPending tracks windows recreated from a restore snapshot
	// whose freshly-launched foreground process (an agent that was just
	// relaunched, for example) may not have been ready to repaint when it first
	// became visible. Such a window can miss the single synthetic resize that
	// drives its redraw and stay blank until the user manually resizes. The
	// first time each of these windows becomes the active/attached window we
	// schedule follow-up redraws and clear it from this set.
	restoreRedrawPending map[string]bool

	// windowWatchers tracks the per-window reader and process-exit goroutines
	// so close can wait for them. Without it those goroutines outlive the
	// server and keep mutating its state (markWindowClosed) after shutdown,
	// which races whatever runs next in the same process.
	windowWatchers sync.WaitGroup
	// pendingWindowStarts owns admitted launches until watcher registration or
	// rejected-process cleanup finishes. Add is guarded by s.mu and !s.closed.
	pendingWindowStarts sync.WaitGroup
	// socketRepublishers tracks the path-healing goroutine so close cannot
	// return while it still owns a replacement listener with unlink disabled.
	socketRepublishers sync.WaitGroup
	// beforeInstallRepublishedSocket is a test seam for the narrow interval
	// after a replacement is bound but before it is installed under s.mu.
	beforeInstallRepublishedSocket func()
}

type muxWindow struct {
	inputMu                     sync.Mutex
	nativePaste                 nativeConsolePasteFilter
	nativeResponse              nativeConsoleResponseFilter
	id                          string
	index                       int
	name                        string
	cwd                         string
	command                     string
	agentTool                   string
	agentToolConfirmed          bool
	agentSessionID              string
	agentSessionDir             string
	agentSessionPath            string
	agentSessionIdentityExact   bool
	nativeAcpBridgeID           string
	nativeAcpProviderID         string
	foregroundPid               int
	foregroundCommand           string
	paneTitle                   string
	pty                         muxPty
	ptyResizeMu                 sync.Mutex
	ptyWidth                    int
	ptyHeight                   int
	resizeGeneration            atomic.Uint64
	proc                        muxProcess
	history                     []byte
	oscBuffer                   []byte
	attachOscBuffer             []byte
	csiBuffer                   []byte
	terminalOutputState         terminalOutputParserState
	terminalOutputBytes         int
	terminalOutputUtf8Remaining int
	historyStartTerminalOutput  terminalOutputParserSnapshot
	terminalOutputForwarding    bool
	lastActivity                time.Time
	outputGeneration            uint64
	lastProcessMetadataRefresh  time.Time
	lastBroadcast               time.Time
	cursorVisible               bool
	cursorVisibilityKnown       bool
	// win32InputMode mirrors DEC private mode 9001, which ConPTY (conhost)
	// enables at startup on Windows to request that terminal input — including
	// escape-sequence replies — be delivered as win32-input-mode key events.
	// ConPTY's input parser drops raw OSC/DCS sequences, so synthetic replies
	// written into the window pty must be re-encoded while this mode is on.
	win32InputMode                       bool
	privateModes                         map[string]bool
	terminalProgress                     *terminalProgressSnapshot
	insertModeEnabled                    bool
	insertModeKnown                      bool
	applicationKeypadEnabled             bool
	applicationKeypadKnown               bool
	focusModeEnabled                     bool
	focusModeProcessID                   int
	mouseTrackingProcessID               int
	themeRefreshModeProcessID            int
	themeColorQueryPid                   int
	themeColorQueryKeys                  map[string]bool
	alert                                bool
	closed                               bool
	closing                              bool
	redrawForwardingPaused               bool
	redrawForwardingGeneration           int
	redrawForwardingReplay               []byte
	redrawForwardingFallbackHistory      []byte
	redrawForwardingBuffer               []byte
	redrawForwardingFailoverBuffer       []byte
	redrawForwardingSecondaryBuffer      []byte
	redrawForwardingQueryBuffer          []byte
	redrawForwardingPrimaryConn          net.Conn
	redrawForwardingPrimaryNeedsFailover bool
	// pendingTerminalQueries holds capability/status queries (device attributes,
	// DSR, XTVERSION) the child emitted while no terminal was showing this window
	// — e.g. an agent (Copilot CLI) relaunched during an upgrade restore, which
	// queries the terminal at startup before the client reattaches. They are
	// stored in history too, but foreground-redraw windows never replay history,
	// so without re-delivering them on attach the terminal never answers and the
	// agent times out into a less rich rendering mode. pendingTerminalQueryCarry
	// holds a query sequence split across pty reads until the rest arrives.
	pendingTerminalQueries         []byte
	pendingTerminalQueriesInFlight []byte
	pendingTerminalQueryCarry      []byte
	// capabilityAnswerBytes counts the replies synthesized from the client's
	// capability hint since a terminal last showed this window. It bounds how
	// much a window running unwatched can push into its own child's stdin: an
	// agent needs one short reply, while output being replayed into a
	// background window (ANSI art, a terminal recording) can carry an unbounded
	// stream of device attribute queries. Reset once the window is forwarded to
	// a terminal again.
	capabilityAnswerBytes        int
	secondaryQueryCarry          []byte
	secondaryQueryPrimary        net.Conn
	queryUtf8Remaining           int
	lastForwardedTerminalQueries []byte
	// Kitty graphics image transmissions retained for replay on reattach.
	// Placeholder-protocol clients (e.g. Copilot CLI) transmit an image once
	// and thereafter only re-emit placeholder cells, so the one-time image
	// bytes must survive independently of the rolling visible history (which
	// evicts them once enough newer output arrives) or reattached placeholders
	// render blank. Keyed by protocol image id; kittyImageOrder preserves root
	// transmission order so replay reproduces image-number mapping semantics.
	kittyImages          map[string][]byte
	kittyImageAnimations map[string][]byte
	kittyImageNumberToID map[string]string
	kittyImageNumberSeq  map[string]uint64
	kittyImageOrder      []string
	// kittyImageSeq records mutation recency independently of root order so local
	// replay selection and the machine-wide budget favor recently animated
	// images. Protected by the server lock, like the maps above.
	kittyImageSeq map[string]uint64
	// kittyImageToken holds the FNV-1a-32 signature of each retained image's
	// base64-decoded transmission payload, keyed by protocol image id. A client
	// reports the signatures of the images it still holds on a window switch so
	// the replay can omit re-sending — and the client re-parsing — several
	// megabytes of image data it already has. Kept in sync with kittyImages.
	kittyImageToken          map[string]uint32
	kittyGraphicsPending     []byte
	kittyGraphicsPendingScan int
	kittyGraphicsPendingTerm int
}

type terminalOutputParserState int

const (
	terminalOutputParserGround terminalOutputParserState = iota
	terminalOutputParserEscape
	terminalOutputParserEscapeIntermediate
	terminalOutputParserCsi
	terminalOutputParserOsc
	terminalOutputParserOscEscape
	terminalOutputParserString
	terminalOutputParserStringEscape
)

type terminalOutputParserSnapshot struct {
	state         terminalOutputParserState
	bytes         int
	utf8Remaining int
}

type windowBroadcastIdentity struct {
	name                  string
	cwd                   string
	command               string
	paneTitle             string
	agentTool             string
	panePid               int
	alert                 bool
	progressActive        bool
	progressState         int
	progressPercentage    int
	progressHasPercentage bool
}

type controlClient struct {
	conn net.Conn
	enc  *json.Encoder

	mu sync.Mutex

	commandsMu sync.Mutex
	commands   map[string]context.CancelFunc
	closed     bool
}

type attachFocusResult struct {
	focused        bool
	primaryChanged bool
}

type attachWrite struct {
	data             []byte
	complete         chan error
	responseWindowID string
	responseCount    int
	gate             *attachWriteGate
}

type attachWriteGate struct {
	done    chan struct{}
	deliver atomic.Bool
}

type attachInputAction struct {
	userInput      bool
	bracketedPaste bool
	windowID       string
	data           []byte
}

type attachInputRouting struct {
	claimsFocus bool
	actions     []attachInputAction
}

func (r *attachInputRouting) addResponse(windowID string, data []byte) {
	if len(data) == 0 {
		return
	}
	copied := append([]byte(nil), data...)
	r.actions = append(
		r.actions,
		attachInputAction{windowID: windowID, data: copied},
	)
}

func (r *attachInputRouting) addUserInput(data []byte, bracketedPaste bool) {
	if len(data) == 0 {
		return
	}
	copied := append([]byte(nil), data...)
	r.actions = append(
		r.actions,
		attachInputAction{
			userInput:      true,
			bracketedPaste: bracketedPaste,
			data:           copied,
		},
	)
}

type attachClient struct {
	conn         net.Conn
	id           string
	width        int
	height       int
	clipViewport bool
	// capabilityHint holds this client's replies to static terminal capability
	// queries. It is per client because the answer describes *this* terminal:
	// a client that sends no hint (an older helper, or a plain terminal running
	// `monkeymux attach`) must not have a previous client's identity advertised
	// on its behalf.
	capabilityHint                        []byte
	sequence                              uint64
	focusSequence                         atomic.Uint64
	prefixEnabled                         bool
	prefixPending                         bool
	confirmCloseID                        string
	inputMu                               sync.Mutex
	activityMu                            sync.Mutex
	terminalResponseUntil                 time.Time
	terminalResponseCarry                 []byte
	terminalResponseContinuation          byte
	terminalResponseContinuationEscape    bool
	terminalResponseContinuationUtf8      int
	terminalResponsePasteStartCarry       []byte
	terminalResponseWindows               []string
	terminalResponseActiveWindow          string
	terminalResponseCarryGeneration       uint64
	inputUtf8Remaining                    int
	inputBracketedPasteStartCarry         []byte
	inputBracketedPasteCarryGeneration    uint64
	inputBracketedPasteCarryFocusSequence uint64
	inputBracketedPasteActive             bool
	inputBracketedPasteEndCarry           []byte
	focusInputCarry                       []byte
	focusInputGeneration                  uint64
	focusSequenceSnapshot                 func() uint64
	focusClaim                            func(uint64)
	inputPassthrough                      func([]byte)
	inputDispatchMu                       sync.Mutex
	inputQueueMu                          sync.Mutex
	inputQueue                            []attachInputAction
	inputQueueReady                       chan struct{}
	inputQueuedBytes                      int
	inputQueueClosed                      bool
	replayMu                              sync.Mutex
	replayedWindowID                      string
	replayedOutputGeneration              uint64

	queue       []attachWrite
	queueReady  chan struct{}
	done        chan struct{}
	closeOnce   sync.Once
	queueMu     sync.Mutex
	queuedBytes int
	queueClosed bool
}

func main() {
	if len(os.Args) < 2 {
		attachCommand(nil)
		return
	}

	switch os.Args[1] {
	case "attach":
		attachCommand(os.Args[2:])
	case "attach-session", "a", "at":
		attachCommand(os.Args[2:])
	case "new-session", "new":
		newSessionCommand(os.Args[2:])
	case "list-sessions", "ls", "sessions":
		listSessionsCommand(os.Args[2:])
	case "kill-session":
		killSessionCommand(os.Args[2:])
	case "control":
		controlCommand(os.Args[2:])
	case "serve":
		serveCommand(os.Args[2:])
	case "gc":
		gcCommand()
	case "acp":
		acpCommand(os.Args[2:])
	case "pi-agent":
		piAgentCommand(os.Args[2:])
	case "wait-codex-session":
		if len(os.Args) == 3 {
			waitForCodexSession(os.Args[2])
		}
	case "cursor-agent-auth":
		cursorAgentAuthCommand(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println(monkeyMuxVersion)
	case "help", "--help", "-h":
		printUsage(os.Stdout)
	default:
		usageAndExit()
	}
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "MonkeyMux - persistent terminal windows for MonkeySSH")
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "Usage:")
	fmt.Fprintln(writer, "  monkeymux                              attach or choose a session")
	fmt.Fprintln(writer, "  monkeymux attach [--existing] [-t NAME] [NAME]")
	fmt.Fprintln(writer, "  monkeymux new-session [-d] [-s NAME] [COMMAND...]")
	fmt.Fprintln(writer, "  monkeymux list-sessions")
	fmt.Fprintln(writer, "  monkeymux kill-session -t NAME")
	fmt.Fprintln(writer, "  monkeymux acp start|attach|list|status|stop|gc")
	fmt.Fprintln(writer, "  monkeymux version")
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "Inside a session (prefix Ctrl-B):")
	fmt.Fprintln(writer, "  c       create window       n / p   next / previous window")
	fmt.Fprintln(writer, "  0..9    select window       l       last window")
	fmt.Fprintln(writer, "  &       close window        d       detach this client")
	fmt.Fprintln(writer, "  Ctrl-B  send a literal Ctrl-B")
}

func usageAndExit() {
	printUsage(os.Stderr)
	os.Exit(2)
}

const piIdentityExtensionSource = `export default function (pi) {
  const publish = (_event, ctx) => {
    const id = ctx.sessionManager.getSessionId();
    const file = ctx.sessionManager.getSessionFile();
    if (!id || !file) return;
    const payload = Buffer.from(JSON.stringify({ id, file }), "utf8")
      .toString("base64url");
    process.stdout.write("\u001b]1337;MonkeyMuxPi=" + payload + "\u0007");
  };
  pi.on("session_start", publish);
}
`

func piAgentCommand(args []string) {
	extensionPath, err := ensurePiIdentityExtension()
	if err != nil {
		fatal(fmt.Errorf("prepare Pi session integration: %w", err))
	}
	commandArgs := make([]string, 0, len(args)+2)
	commandArgs = append(commandArgs, "--extension", extensionPath)
	commandArgs = append(commandArgs, args...)
	command := exec.Command("pi", commandArgs...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Env = os.Environ()
	if err := command.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			os.Exit(exitError.ExitCode())
		}
		fatal(err)
	}
}

func cursorAgentAuthCommand(args []string) {
	if len(args) != 0 {
		usageAndExit()
	}
	var command *exec.Cmd
	if acpRuntimeGOOS == "darwin" {
		command = exec.Command("/usr/bin/security", "unlock-keychain")
	} else {
		command = exec.Command("cursor-agent", "login")
	}
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Env = inheritedEnvironment(os.Environ())
	if err := command.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			os.Exit(exitError.ExitCode())
		}
		fatal(err)
	}
}

func ensurePiIdentityExtension() (string, error) {
	directory, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	path := filepath.Join(directory, "monkeymux-pi-identity.ts")
	if data, readErr := os.ReadFile(path); readErr == nil && string(data) == piIdentityExtensionSource {
		return path, nil
	}
	if err := os.WriteFile(path, []byte(piIdentityExtensionSource), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

func attachCommand(args []string) {
	fs := flag.NewFlagSet("attach", flag.ExitOnError)
	cwd := fs.String("cwd", "", "initial working directory")
	name := fs.String("name", "", "initial window name")
	command := fs.String("command", "", "initial command")
	restoreYolo := fs.Bool("restore-yolo", false, "restore agent windows in YOLO mode")
	themeHintBase64 := fs.String("theme-hint-base64", "", "base64-encoded terminal theme reports")
	capabilityHintBase64 := fs.String("capability-hint-base64", "", "base64-encoded terminal capability reports")
	updatePolicy := fs.String("update-policy", serverUpdatePolicyPrompt, "running server update policy: prompt, never, or always")
	clientID := fs.String("client-id", "", "stable foreground client identifier")
	clipViewport := fs.Bool("clip-viewport", false, "clip a shared terminal grid to this client's viewport")
	existingOnly := fs.Bool("existing", false, "fail instead of creating a missing session")
	widthFlag := fs.Int("width", 0, "terminal columns when stdout has no PTY")
	heightFlag := fs.Int("height", 0, "terminal rows when stdout has no PTY")
	noPrefix := fs.Bool("no-prefix", false, "disable Ctrl-B window commands")
	quiet := fs.Bool("quiet", false, "suppress attach and detach messages")
	target := fs.String("t", "", "target session")
	_ = fs.Parse(args)
	if fs.NArg() > 1 || (*target != "" && fs.NArg() != 0) {
		usageAndExit()
	}
	policy, err := normalizeServerUpdatePolicy(*updatePolicy)
	if err != nil {
		fatal(err)
	}
	themeHint, err := decodeThemeHintBase64(*themeHintBase64)
	if err != nil {
		fatal(err)
	}
	capabilityHint, err := decodeCapabilityHintBase64(*capabilityHintBase64)
	if err != nil {
		fatal(err)
	}
	session := strings.TrimSpace(*target)
	if fs.NArg() == 1 {
		session = strings.TrimSpace(fs.Arg(0))
	}
	if session == "" {
		session, err = defaultAttachSession(os.Stdin, os.Stderr)
		if err != nil {
			fatal(err)
		}
	}
	if err := validateSessionName(session); err != nil {
		fatal(err)
	}
	resolvedClientID := strings.TrimSpace(*clientID)
	if resolvedClientID == "" {
		resolvedClientID = fmt.Sprintf(
			"cli-%d-%d",
			os.Getpid(),
			time.Now().UnixNano(),
		)
	}
	width, height := terminalSize()
	if *widthFlag > 0 {
		width = *widthFlag
	}
	if *heightFlag > 0 {
		height = *heightFlag
	}
	if err := ensureServer(
		session,
		createWindowOptions{
			cwd:            *cwd,
			name:           *name,
			command:        *command,
			themeHint:      themeHint,
			capabilityHint: capabilityHint,
		},
		policy,
		*restoreYolo,
		width,
		height,
		*existingOnly,
	); err != nil {
		fatal(err)
	}

	conn, err := dialSession(session)
	if err != nil {
		fatal(err)
	}
	defer conn.Close()

	hello := controlMessage{
		Role:           "attach",
		Session:        session,
		ClientID:       resolvedClientID,
		Width:          width,
		Height:         height,
		Data:           string(themeHint),
		CapabilityHint: string(capabilityHint),
		NoPrefix:       *noPrefix,
		ClipViewport:   *clipViewport,
	}
	if !*quiet {
		fmt.Fprintf(
			os.Stderr,
			"monkeymux: attached to %s (prefix Ctrl-B; run `monkeymux help` for keys)\r\n",
			session,
		)
	}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	restoreRawTerminal := makeTerminalRaw()
	terminalRestored := false
	restoreTerminal := func() {
		if terminalRestored {
			return
		}
		terminalRestored = true
		restoreRawTerminal()
	}
	defer restoreTerminal()

	stopResize := forwardResizeSignals(
		session,
		resolvedClientID,
		width,
		height,
		*widthFlag > 0 && *heightFlag > 0,
	)
	defer stopResize()

	// The attach lives for as long as the server keeps the connection open. The
	// input relay (client stdin -> server) is best-effort: a stdin EOF must not
	// end the attach. On POSIX the PTY stdin never EOFs during a live session,
	// but Windows OpenSSH delivers an immediate EOF on exec+PTY channels, and
	// tearing down on that first-finished copy would drop the terminal the
	// instant it opened. Driving the lifetime from the server->stdout copy ends
	// the attach only when the server closes the session or the local output
	// stream can no longer be written (the SSH channel went away).
	go func() {
		_, _ = io.Copy(conn, os.Stdin)
	}()

	attachOut := attachOutputWriter(os.Stdout)
	_, copyErr := io.Copy(attachOut, conn)
	// Flush any partial sequence the output filter buffered so trailing bytes are
	// not dropped when the session ends mid-sequence (no-op unless the writer
	// buffers, e.g. the Windows win32-input-mode request stripper).
	if flusher, ok := attachOut.(interface{ Flush() error }); ok {
		_ = flusher.Flush()
	}
	restoreTerminal()
	if copyErr != nil && !errors.Is(copyErr, io.EOF) {
		fatal(copyErr)
	}
	if !*quiet {
		if _, err := queryRunningServerStatus(session); err == nil {
			fmt.Fprintf(os.Stderr, "\r\nmonkeymux: detached from %s\r\n", session)
		} else {
			fmt.Fprintf(os.Stderr, "\r\nmonkeymux: session %s ended\r\n", session)
		}
	}
}

type runningSessionInfo struct {
	name        string
	version     string
	windows     []windowSnapshot
	attachCount int
	lastActive  int64
}

func newSessionCommand(args []string) {
	fs := flag.NewFlagSet("new-session", flag.ExitOnError)
	session := fs.String("s", "main", "session name")
	cwd := fs.String("c", "", "initial working directory")
	name := fs.String("n", "", "initial window name")
	detached := fs.Bool("d", false, "start without attaching")
	attachExisting := fs.Bool("A", false, "attach if the session already exists")
	noPrefix := fs.Bool("no-prefix", false, "disable Ctrl-B window commands")
	quiet := fs.Bool("quiet", false, "suppress attach and detach messages")
	_ = fs.Parse(args)

	target := strings.TrimSpace(*session)
	if err := validateSessionName(target); err != nil {
		fatal(err)
	}
	_, runningErr := queryRunningServerStatus(target)
	if runningErr == nil && !*attachExisting {
		fatal(fmt.Errorf(
			"session %q already exists; use new-session -A or attach",
			target,
		))
	}

	width, height := terminalSize()
	if err := ensureServer(
		target,
		createWindowOptions{
			cwd:  *cwd,
			name: *name,
			args: append([]string(nil), fs.Args()...),
		},
		serverUpdatePolicyPrompt,
		false,
		width,
		height,
		false,
	); err != nil {
		fatal(err)
	}
	if *detached {
		if !*quiet {
			fmt.Fprintf(os.Stdout, "monkeymux: session %s started\r\n", target)
		}
		return
	}

	attachArgs := make([]string, 0, 3)
	if *noPrefix {
		attachArgs = append(attachArgs, "--no-prefix")
	}
	if *quiet {
		attachArgs = append(attachArgs, "--quiet")
	}
	attachArgs = append(attachArgs, target)
	attachCommand(attachArgs)
}

func listSessionsCommand(args []string) {
	fs := flag.NewFlagSet("list-sessions", flag.ExitOnError)
	_ = fs.Parse(args)
	if fs.NArg() != 0 {
		usageAndExit()
	}
	sessions, err := listRunningSessions()
	if err != nil {
		fatal(err)
	}
	if len(sessions) == 0 {
		fmt.Fprintln(os.Stdout, "no MonkeyMux sessions")
		return
	}
	sort.Slice(sessions, func(i int, j int) bool {
		return sessions[i].name < sessions[j].name
	})
	for _, session := range sessions {
		active := ""
		for _, window := range session.windows {
			if window.Active {
				active = firstNonEmptyString(
					window.PaneTitle,
					window.Name,
					window.CurrentCommand,
				)
				break
			}
		}
		clientLabel := "clients"
		if session.attachCount == 1 {
			clientLabel = "client"
		}
		fmt.Fprintf(
			os.Stdout,
			"%s: %d windows (%d %s)",
			safeDisplayText(session.name),
			len(session.windows),
			session.attachCount,
			clientLabel,
		)
		if active != "" {
			fmt.Fprintf(os.Stdout, " [active: %s]", safeDisplayText(active))
		}
		fmt.Fprintln(os.Stdout)
	}
}

func killSessionCommand(args []string) {
	fs := flag.NewFlagSet("kill-session", flag.ExitOnError)
	target := fs.String("t", "", "target session")
	_ = fs.Parse(args)
	if fs.NArg() != 0 {
		usageAndExit()
	}
	session := strings.TrimSpace(*target)
	if session == "" {
		sessions, err := listRunningSessions()
		if err != nil {
			fatal(err)
		}
		if len(sessions) != 1 {
			fatal(errors.New("specify a session with -t"))
		}
		session = sessions[0].name
	}
	if err := validateSessionName(session); err != nil {
		fatal(err)
	}
	if _, err := queryRunningServerStatus(session); err != nil {
		fatal(fmt.Errorf("session %q is not running", session))
	}
	requestServerShutdown(session)
	if !waitForServerExit(session, serverExitWaitTimeout) {
		fatal(fmt.Errorf("session %q did not stop", session))
	}
	fmt.Fprintf(os.Stdout, "monkeymux: session %s stopped\r\n", safeDisplayText(session))
}

func defaultAttachSession(reader io.Reader, writer io.Writer) (string, error) {
	sessions, err := listRunningSessions()
	if err != nil {
		return "", err
	}
	if len(sessions) == 0 {
		return "main", nil
	}
	if len(sessions) == 1 {
		return sessions[0].name, nil
	}
	sort.Slice(sessions, func(i int, j int) bool {
		if sessions[i].lastActive == sessions[j].lastActive {
			return sessions[i].name < sessions[j].name
		}
		return sessions[i].lastActive > sessions[j].lastActive
	})
	if file, ok := reader.(*os.File); ok && !term.IsTerminal(int(file.Fd())) {
		return "", errors.New("multiple sessions are running; specify one with -t")
	}

	fmt.Fprintln(writer, "MonkeyMux sessions:")
	for index, session := range sessions {
		fmt.Fprintf(
			writer,
			"  %d. %s  %d windows, %d clients\r\n",
			index+1,
			safeDisplayText(session.name),
			len(session.windows),
			session.attachCount,
		)
	}
	fmt.Fprintf(writer, "Attach [1], or enter a new session name: ")
	line, err := bufio.NewReader(reader).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	selection := strings.TrimSpace(line)
	if selection == "" {
		return sessions[0].name, nil
	}
	if index, parseErr := strconv.Atoi(selection); parseErr == nil {
		if index < 1 || index > len(sessions) {
			return "", fmt.Errorf("session selection %d is out of range", index)
		}
		return sessions[index-1].name, nil
	}
	if err := validateSessionName(selection); err != nil {
		return "", err
	}
	return selection, nil
}

func listRunningSessions() ([]runningSessionInfo, error) {
	runDir, err := runtimeDirectory()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(runDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	sessions := make([]runningSessionInfo, 0)
	for _, entry := range entries {
		if entry.IsDir() ||
			!strings.HasPrefix(entry.Name(), "monkeymux-") ||
			!strings.HasSuffix(entry.Name(), ".sock") {
			continue
		}
		session, err := querySessionAtSocket(filepath.Join(runDir, entry.Name()))
		if err != nil || strings.TrimSpace(session.name) == "" {
			continue
		}
		sessions = append(sessions, session)
	}
	return sessions, nil
}

func querySessionAtSocket(path string) (runningSessionInfo, error) {
	conn, err := net.DialTimeout("unix", path, 150*time.Millisecond)
	if err != nil {
		return runningSessionInfo{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))
	if err := json.NewEncoder(conn).Encode(controlMessage{Role: "control"}); err != nil {
		return runningSessionInfo{}, err
	}

	decoder := json.NewDecoder(conn)
	info := runningSessionInfo{}
	for info.name == "" || info.windows == nil {
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			return runningSessionInfo{}, err
		}
		switch response.Type {
		case "hello":
			info.name = response.Session
			info.version = response.Version
			info.attachCount = response.AttachCount
		case "window_list":
			info.windows = response.Windows
			for _, window := range response.Windows {
				if window.LastActivityEpochSeconds > info.lastActive {
					info.lastActive = window.LastActivityEpochSeconds
				}
			}
		}
	}
	return info, nil
}

func validateSessionName(value string) error {
	if strings.TrimSpace(value) == "" {
		return errors.New("session name cannot be empty")
	}
	if len(value) > 128 {
		return errors.New("session name is too long")
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return errors.New("session name cannot contain control characters")
		}
	}
	return nil
}

func safeDisplayText(value string) string {
	return strings.Map(func(character rune) rune {
		if character < 0x20 || character == 0x7f {
			return -1
		}
		return character
	}, value)
}

func controlCommand(args []string) {
	fs := flag.NewFlagSet("control", flag.ExitOnError)
	jsonMode := fs.Bool("json", false, "use newline-delimited JSON")
	_ = fs.String("cwd", "", "ignored; only attach starts sessions")
	_ = fs.Parse(args)
	if fs.NArg() != 1 || !*jsonMode {
		usageAndExit()
	}
	session := fs.Arg(0)

	conn, err := dialSession(session)
	if err != nil {
		fatal(fmt.Errorf("monkeymux session %q is not running; attach before opening control", session))
	}
	defer conn.Close()

	hello := controlMessage{Role: "control", Session: session}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(os.Stdout, conn)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(conn, os.Stdin)
		errs <- err
	}()

	if err := <-errs; err != nil && !errors.Is(err, io.EOF) {
		fatal(err)
	}
}

func serveCommand(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	session := fs.String("session", "", "session name")
	// Accepted so the flag set does not reject it; the session name itself
	// remains authoritative. It exists to identify this process's session in
	// its command line.
	_ = fs.String("session-token", "", "session identity token")
	cwd := fs.String("cwd", "", "initial working directory")
	name := fs.String("name", "", "initial window name")
	command := fs.String("command", "", "initial command")
	restoreFile := fs.String("restore-file", "", "window restore snapshot")
	argsBase64 := fs.String("args-base64", "", "base64-encoded initial argv")
	width := fs.Int("width", defaultColumns, "initial terminal columns")
	height := fs.Int("height", defaultRows, "initial terminal rows")
	themeHintBase64 := fs.String("theme-hint-base64", "", "base64-encoded terminal theme reports")
	capabilityHintBase64 := fs.String("capability-hint-base64", "", "base64-encoded terminal capability reports")
	_ = fs.Parse(args)
	if strings.TrimSpace(*session) == "" {
		usageAndExit()
	}
	themeHint, err := decodeThemeHintBase64(*themeHintBase64)
	if err != nil {
		fatal(err)
	}
	capabilityHint, err := decodeCapabilityHintBase64(*capabilityHintBase64)
	if err != nil {
		fatal(err)
	}
	restore, err := readRestoreFile(*restoreFile)
	if err != nil {
		fatal(err)
	}
	initialArgs, err := decodeArgsBase64(*argsBase64)
	if err != nil {
		fatal(err)
	}
	if err := serveSession(*session, createWindowOptions{
		cwd:            *cwd,
		name:           *name,
		command:        *command,
		args:           initialArgs,
		themeHint:      themeHint,
		capabilityHint: capabilityHint,
	}, restore, *width, *height); err != nil {
		fatal(err)
	}
}

func decodeThemeHintBase64(encoded string) ([]byte, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("invalid theme hint: %w", err)
	}
	if len(decoded) > themeHintLimitBytes {
		return nil, fmt.Errorf("theme hint is too large")
	}
	return decoded, nil
}

func decodeCapabilityHintBase64(encoded string) ([]byte, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("invalid capability hint: %w", err)
	}
	if len(decoded) > capabilityHintLimitBytes {
		return nil, errors.New("capability hint is too large")
	}
	return decoded, nil
}

func decodeArgsBase64(encoded string) ([]string, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("invalid initial argv: %w", err)
	}
	if len(decoded) > 1024*1024 {
		return nil, errors.New("initial argv is too large")
	}
	var args []string
	if err := json.Unmarshal(decoded, &args); err != nil {
		return nil, fmt.Errorf("invalid initial argv: %w", err)
	}
	if len(args) > 4096 {
		return nil, errors.New("initial argv has too many arguments")
	}
	return args, nil
}

func gcCommand() {
	runDir, err := runtimeDirectory()
	if err != nil {
		fatal(err)
	}
	entries, err := os.ReadDir(runDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return
		}
		fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "monkeymux-") {
			continue
		}
		path := filepath.Join(runDir, entry.Name())
		// Only sockets are probed by dialling. The sibling .pid and .lock files
		// are never dialable, so probing them here would delete the bookkeeping
		// of a perfectly healthy server, and restore snapshots are deleted by
		// the helper that wrote them unless it died mid-upgrade.
		switch filepath.Ext(entry.Name()) {
		case ".pid", ".lock":
			clearStalePIDFile(path, "")
			continue
		case ".json":
			removeAbandonedRestoreFile(path)
			continue
		case ".staging":
			// Residue of a helper that died while installing a lock file.
			removeAbandonedStagingFile(path)
			continue
		case ".sock":
		default:
			continue
		}
		identity, _ := socketFileIdentity(path)
		conn, err := net.DialTimeout("unix", path, 150*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			continue
		}
		if isStaleUnixSocketError(err) {
			removeSocketPathIfUnchanged(path, identity)
		}
	}
	gcAcpArtifacts(runDir)
}

// removeAbandonedRestoreFile deletes an upgrade snapshot left behind by a
// helper that died mid-restart. Snapshots still being handed to a starting
// server are kept, otherwise gc would make that server come up empty.
func removeAbandonedRestoreFile(path string) {
	if !strings.HasPrefix(filepath.Base(path), "monkeymux-restore-") {
		return
	}
	info, err := os.Stat(path)
	if err != nil || time.Since(info.ModTime()) < abandonedRestoreFileAge {
		return
	}
	_ = os.Remove(path)
}

func removeAbandonedStagingFile(path string) {
	info, err := os.Stat(path)
	if err != nil || time.Since(info.ModTime()) < abandonedPIDFileAge {
		return
	}
	_ = os.Remove(path)
}

type ensureServerReplacement struct {
	restore        *serverRestore
	oldPID         pidRecord
	legacyHandoff  bool
	keepOldProcess bool
}

func ensureServer(
	session string,
	initialWindow createWindowOptions,
	updatePolicy string,
	startInYoloMode bool,
	width int,
	height int,
	existingOnly bool,
) error {
	unlock, err := acquireSessionLock(session)
	if err != nil {
		return err
	}
	defer unlock()

	var replacement *ensureServerReplacement
	status, statusErr := queryRunningServerStatusWithRetry(session)
	switch {
	case statusErr == nil:
		outcome, err := prepareRunningServerReplacement(
			session,
			status,
			updatePolicy,
			startInYoloMode,
		)
		if err != nil || outcome == nil {
			return err
		}
		replacement = outcome
	case existingOnly:
		return fmt.Errorf("MonkeyMux session %q is not running", session)
	default:
		owner, ownership := sessionServerOwner(session)
		if ownership != pidOwnershipGone {
			// A previous serve still owns the windows but the socket path is not
			// answering. Stealing the path would orphan those windows forever and
			// surface a brand-new one-window workspace to MonkeySSH.
			if recovered, recoverErr := queryRunningServerStatusWithRetry(session); recoverErr == nil {
				outcome, err := prepareRunningServerReplacement(
					session,
					recovered,
					updatePolicy,
					startInYoloMode,
				)
				if err != nil || outcome == nil {
					return err
				}
				replacement = outcome
			} else {
				return fmt.Errorf(
					"MonkeyMux session %q is running (%s) but not accepting connections",
					session,
					describeSessionOwner(owner, ownership),
				)
			}
		}
	}

	socket, err := socketPath(session)
	if err != nil {
		return err
	}
	// Final ownership check immediately before unlinking the path. On Windows
	// AF_UNIX, removing a live socket steals the name while the old process and
	// all of its ConPTY windows keep running unreachable.
	if current, err := queryRunningServerStatus(session); err == nil {
		if replacement == nil || current.version == monkeyMuxVersion {
			return nil
		}
	}
	if replacement != nil && replacement.legacyHandoff {
		// Helpers predating shutdown keep accepting until their path is
		// explicitly removed. The replacement's republish loop repairs the path
		// if that outgoing helper later unlinks it during close.
		_ = os.Remove(socket)
	} else {
		removeAbandonedSessionSocket(socket)
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	serveArgs := []string{
		"serve",
		// A whitespace-free identity for the session, so another helper can
		// tell from this command line which session is served no matter what
		// the name contains. It precedes the name deliberately: the name is
		// user supplied, and a name containing its own --session-token would
		// otherwise shadow this one. See processImageServesSession.
		"--session-token", sessionToken(session),
		"--session", session,
	}
	if width > 0 && height > 0 {
		serveArgs = append(serveArgs, "--width", strconv.Itoa(width), "--height", strconv.Itoa(height))
	}
	var restore *serverRestore
	var previousPID pidRecord
	if replacement != nil {
		restore = replacement.restore
		if !replacement.keepOldProcess {
			previousPID = replacement.oldPID
		}
	}
	if restore != nil && len(restore.Windows) > 0 {
		path, err := writeRestoreFile(session, restore)
		if err != nil {
			return fmt.Errorf(
				"monkeymux: could not write restore snapshot for session %q: %w",
				session,
				err,
			)
		}
		defer os.Remove(path)
		serveArgs = append(serveArgs, "--restore-file", path)
	}
	// When restoring an existing workspace, ignore the attach-time launch
	// command/name/cwd so auto-connect cannot collapse the session to one
	// fresh agent window.
	if restore == nil || len(restore.Windows) == 0 {
		if strings.TrimSpace(initialWindow.cwd) != "" {
			serveArgs = append(serveArgs, "--cwd", initialWindow.cwd)
		}
		if strings.TrimSpace(initialWindow.name) != "" {
			serveArgs = append(serveArgs, "--name", initialWindow.name)
		}
		if strings.TrimSpace(initialWindow.command) != "" {
			serveArgs = append(serveArgs, "--command", initialWindow.command)
		}
		if len(initialWindow.args) > 0 {
			encodedArgs, err := json.Marshal(initialWindow.args)
			if err != nil {
				return err
			}
			serveArgs = append(
				serveArgs,
				"--args-base64",
				base64.StdEncoding.EncodeToString(encodedArgs),
			)
		}
	}
	if len(initialWindow.themeHint) > 0 {
		serveArgs = append(serveArgs, "--theme-hint-base64", base64.StdEncoding.EncodeToString(initialWindow.themeHint))
	}
	if len(initialWindow.capabilityHint) > 0 {
		serveArgs = append(
			serveArgs,
			"--capability-hint-base64",
			base64.StdEncoding.EncodeToString(initialWindow.capabilityHint),
		)
	}
	daemonEnv := inheritedEnvironment(os.Environ())
	buildServeCmd := func() *exec.Cmd {
		c := exec.Command(exe, serveArgs...)
		c.Stdin = nil
		c.Stdout = nil
		c.Stderr = nil
		c.Env = daemonEnv
		return c
	}
	// Detach the server so it outlives the launching shell (the POSIX analog is
	// setsid). detachedDaemonSysProcAttrs returns the strategies to try in
	// order; on Windows the first requests a job-object breakaway that some
	// hosts disallow, so a fresh command is started for each fallback attempt.
	var cmd *exec.Cmd
	var startErr error
	for _, attr := range detachedDaemonSysProcAttrs() {
		candidate := buildServeCmd()
		candidate.SysProcAttr = attr
		if err := candidate.Start(); err != nil {
			startErr = err
			continue
		}
		cmd = candidate
		startErr = nil
		break
	}
	if startErr != nil {
		return startErr
	}
	startedPID := 0
	if cmd.Process != nil {
		startedPID = cmd.Process.Pid
	}
	_ = cmd.Process.Release()

	deadline := time.Now().Add(socketTimeout)
	for time.Now().Before(deadline) {
		status, err := queryRunningServerStatus(session)
		if err == nil && status.version == monkeyMuxVersion {
			// Only signal a process still proven to be the previous server.
			// The old pid may have been recycled while it shut down — possibly
			// onto the replacement that just answered this dial.
			if previousPID.pid != startedPID &&
				previousPID.confirmedOwner(session) {
				terminateProcessID(previousPID.pid)
			}
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("monkeymux server did not start for session %q", session)
}

// prepareRunningServerReplacement decides whether a running helper should be
// replaced. A nil outcome means the caller should keep using the existing
// server. A non-nil outcome means the caller may start a replacement server
// using the captured restore snapshot.
func prepareRunningServerReplacement(
	session string,
	status runningServerStatus,
	updatePolicy string,
	startInYoloMode bool,
) (*ensureServerReplacement, error) {
	if status.version == monkeyMuxVersion {
		return nil, nil
	}
	if !shouldUpdateRunningServer(
		os.Stdin,
		os.Stderr,
		session,
		status,
		updatePolicy,
	) {
		return nil, nil
	}
	restore := collectServerRestore(session, status)
	if restore != nil {
		restore.StartInYoloMode = startInYoloMode
	}
	// Never replace a live multi-window server with an empty/auto-connect
	// session just because the snapshot failed. That is how Windows hosts
	// "lose all windows" after a helper upgrade or reconnect race.
	if restore == nil || len(restore.Windows) == 0 {
		fmt.Fprintf(
			os.Stderr,
			"monkeymux: could not snapshot session %q; keeping helper %s\r\n",
			session,
			status.displayVersion(),
		)
		return nil, errServerUpdateNoSnapshot
	}
	oldPID, _ := sessionServerOwner(session)
	if restoreHasNativeAcpWindows(restore) {
		// Native ACP bridges live inside the outgoing helper. Keep that process
		// as a private bridge host, but close its terminal windows now that their
		// restore state is captured. The replacement recreates every window and
		// points native placeholders at the same live bridge sockets.
		if err := requestNativeAcpUpgradeHandoff(session, restore); err != nil {
			fmt.Fprintf(
				os.Stderr,
				"monkeymux: could not preserve native agent windows for session %q; keeping helper %s\r\n",
				session,
				status.displayVersion(),
			)
			return nil, fmt.Errorf("%w: %v", errServerUpdateNativeAcpHandoff, err)
		}
		fmt.Fprintf(
			os.Stderr,
			"monkeymux: handing live native agent windows from helper %s to helper %s\r\n",
			status.displayVersion(),
			monkeyMuxVersion,
		)
		return &ensureServerReplacement{
			restore:        restore,
			oldPID:         oldPID,
			legacyHandoff:  true,
			keepOldProcess: true,
		}, nil
	}
	if status.supportsCapability("shutdown") {
		// Capture pane identities while their ancestry still leads to the old
		// server. Shutdown can orphan them, and bare pids can be recycled before
		// escalation. An unconfirmed server never authorizes process signals.
		var panes map[int]time.Time
		if oldPID.confirmedOwner(session) {
			panes = captureReplacementPaneGroups(restore, oldPID.pid)
		}
		requestServerShutdown(session)
		forced, err := stopServerForReplacement(
			func(timeout time.Duration) bool {
				return waitForServerProcessExit(session, oldPID, timeout)
			},
			func() {
				// Resolve ownership again after the graceful wait; the pid may
				// now name an unrelated process or another session's helper.
				if oldPID.confirmedOwner(session) {
					terminateProcessID(oldPID.pid)
				}
			},
			func() { reapReplacementPaneGroups(panes) },
		)
		if err != nil {
			fmt.Fprintf(
				os.Stderr,
				"monkeymux: running session did not exit after forced stop; continuing with helper %s\r\n",
				status.displayVersion(),
			)
			return nil, err
		}
		if forced {
			fmt.Fprintf(
				os.Stderr,
				"monkeymux: force-stopped unresponsive helper %s; starting helper %s\r\n",
				status.displayVersion(),
				monkeyMuxVersion,
			)
		}
	} else {
		fmt.Fprintf(
			os.Stderr,
			"monkeymux: abandoning helper %s socket and starting helper %s\r\n",
			status.displayVersion(),
			monkeyMuxVersion,
		)
	}
	return &ensureServerReplacement{
		restore:       restore,
		oldPID:        oldPID,
		legacyHandoff: !status.supportsCapability("shutdown"),
	}, nil
}

// stopServerForReplacement escalates only after the full graceful wait. The
// caller supplies identity-checked signals; keeping the exit observer separate
// lets tests cover hung helpers without killing a real server. Reap captured
// panes even if termination made the server exit, since its children may still
// hold agent session locks after becoming orphans.
func stopServerForReplacement(
	confirmExit func(time.Duration) bool,
	terminate func(),
	reap func(),
) (bool, error) {
	if confirmExit(serverExitWaitTimeout) {
		return false, nil
	}
	terminate()
	reap()
	if !confirmExit(serverForcedExitWaitTimeout) {
		return true, errServerUpdateStillAlive
	}
	return true, nil
}

func queryRunningServerStatusWithRetry(
	session string,
) (runningServerStatus, error) {
	var lastErr error
	for attempt := 0; attempt < ensureServerDialAttempts; attempt++ {
		status, err := queryRunningServerStatus(session)
		if err == nil {
			return status, nil
		}
		lastErr = err
		if attempt+1 < ensureServerDialAttempts {
			time.Sleep(ensureServerDialInterval)
		}
	}
	if lastErr == nil {
		lastErr = errors.New("monkeymux server did not respond")
	}
	return runningServerStatus{}, lastErr
}

func sessionMetadataPath(session string, suffix string) (string, error) {
	socket, err := socketPath(session)
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(socket, ".sock") + suffix, nil
}

func sessionPIDPath(session string) (string, error) {
	return sessionMetadataPath(session, ".pid")
}

func sessionLockPath(session string) (string, error) {
	return sessionMetadataPath(session, ".lock")
}

func acquireSessionLock(session string) (func(), error) {
	path, err := sessionLockPath(session)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(ensureServerLockTimeout)
	var nextStaleCheck time.Time
	for clears := 0; ; {
		record, acquired, err := installSessionLockFile(path)
		if errors.Is(err, os.ErrNotExist) && time.Now().Before(deadline) {
			// A concurrent cleanup may remove the per-user runtime directory
			// after the initial MkdirAll. Recreate it and retry the same lock
			// generation instead of failing an otherwise valid contender.
			if mkdirErr := os.MkdirAll(filepath.Dir(path), 0o700); mkdirErr != nil {
				return nil, mkdirErr
			}
			continue
		}
		if err != nil {
			return nil, err
		}
		if acquired {
			var unlockOnce sync.Once
			return func() {
				// An unlock callback owns exactly one acquisition. Making it
				// idempotent prevents a stale second invocation from deleting a
				// later same-process holder, whose lock necessarily has the same pid.
				unlockOnce.Do(func() {
					_ = removePIDFileIfUnchanged(path, record)
				})
			}, nil
		}
		// Validating the holder can cost a process lookup, so throttle it
		// rather than repeating it on every retry. The holder of a lock is an
		// ordinary helper process rather than this session's server, so no
		// session is expected in its command line.
		if now := time.Now(); !now.Before(nextStaleCheck) {
			nextStaleCheck = now.Add(sessionLockStaleCheckInterval)
			if clearStalePIDFile(path, "") && clears < ensureServerLockClearRetries {
				// Claim the freed name immediately: the deadline may already
				// have passed, and failing now would report a timeout for a
				// lock nobody holds any more.
				clears++
				continue
			}
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf(
				"timeout waiting for MonkeyMux session %q lock",
				session,
			)
		}
		time.Sleep(ensureServerLockRetryWait)
	}
}

// sessionLockStagingSequence makes each lock installation attempt use a
// distinct staging file, even when several run concurrently in one process.
var sessionLockStagingSequence atomic.Uint64

// installSessionLockFile publishes a lock file that already names its holder.
// The file is written under a private name and hard linked into place, because
// link fails when the target exists just as an exclusive create does, but never
// exposes an empty file: a lock that was visible before its pid was written
// could be mistaken by another helper for the residue of a crash and reclaimed
// while its holder was still inside the critical section. Filesystems without
// hard links fall back to an exclusive create.
func installSessionLockFile(path string) (pidRecord, bool, error) {
	sequence := sessionLockStagingSequence.Add(1)
	// Keep the file as a bare pid so older helpers sharing this runtime
	// directory can parse it.
	contents := []byte(strconv.Itoa(os.Getpid()) + "\n")
	// The staging name is unique per attempt, not merely per process: two
	// goroutines in one helper can contend for the same session, and sharing a
	// staging path would make them delete or fail to open each other's file.
	staging := fmt.Sprintf(
		"%s.%d.%d.staging",
		path,
		os.Getpid(),
		sequence,
	)
	if err := os.WriteFile(staging, contents, sessionLockFileMode); err != nil {
		return pidRecord{}, false, err
	}
	defer os.Remove(staging)

	switch err := os.Link(staging, path); {
	case err == nil:
		record, readErr := readPIDRecord(path)
		if readErr != nil {
			_ = os.Remove(path)
			return pidRecord{}, false, readErr
		}
		return record, true, nil
	case errors.Is(err, os.ErrExist):
		return pidRecord{}, false, nil
	}

	file, err := os.OpenFile(
		path,
		os.O_CREATE|os.O_EXCL|os.O_WRONLY,
		sessionLockFileMode,
	)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return pidRecord{}, false, nil
		}
		return pidRecord{}, false, err
	}
	_, writeErr := file.Write(contents)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(path)
		return pidRecord{}, false, errors.Join(writeErr, closeErr)
	}
	record, readErr := readPIDRecord(path)
	if readErr != nil {
		_ = os.Remove(path)
		return pidRecord{}, false, readErr
	}
	return record, true, nil
}

func writeSessionPIDFile(session string, pid int) error {
	if pid <= 0 {
		return nil
	}
	path, err := sessionPIDPath(session)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(
		path,
		[]byte(strconv.Itoa(pid)+"\n"),
		sessionPIDFileMode,
	)
}

func removeSessionPIDFile(session string) {
	path, err := sessionPIDPath(session)
	if err != nil {
		return
	}
	current, err := readPIDFile(path)
	if err != nil || current != os.Getpid() {
		return
	}
	_ = os.Remove(path)
}

// A record is only
// discarded once its process is confirmed gone: a file left behind by a server
// that died without cleaning up (SIGKILL, crash, host reboot) names a pid the
// operating system later recycles for an unrelated process, and trusting that
// pid makes ensureServer believe the session is served forever, so MonkeyMux
// can never start again and every attach falls back to a plain login shell.
// sessionServerOwner resolves who owns session's server, reclaiming the record
// when its process is confirmed gone. A file left behind by a server that died
// without cleaning up (SIGKILL, crash, host reboot) names a pid the operating
// system later recycles for an unrelated process, and trusting that pid makes
// ensureServer believe the session is served forever, so MonkeyMux can never
// start again and every attach falls back to a plain login shell. Ownership is
// therefore proven rather than assumed, in both directions.
func sessionServerOwner(session string) (pidRecord, pidOwnership) {
	path, err := sessionPIDPath(session)
	if err != nil {
		return pidRecord{}, pidOwnershipUnknown
	}
	// A reclaim that loses a race against another helper is retried against
	// whatever that helper installed rather than reported as "no owner".
	for attempt := 0; attempt < pidRecordResolveAttempts; attempt++ {
		record, err := readPIDRecord(path)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return pidRecord{}, pidOwnershipGone
			}
			if clearAbandonedPIDFile(path) {
				return pidRecord{}, pidOwnershipGone
			}
			// Unreadable but too young to abandon: a transient read error must
			// not hand the session to a second server while the first one
			// still owns the windows.
			return pidRecord{}, pidOwnershipUnknown
		}
		ownership := pidRecordOwnership(record, session)
		if ownership != pidOwnershipGone {
			return record, ownership
		}
		if removePIDFileIfUnchanged(path, record) {
			return pidRecord{}, pidOwnershipGone
		}
	}
	return pidRecord{}, pidOwnershipUnknown
}

// describeSessionOwner renders the owner for an error message. An owner that
// could not be resolved has no pid worth quoting.
func describeSessionOwner(owner pidRecord, ownership pidOwnership) string {
	if owner.pid <= 0 {
		return "owner unknown"
	}
	if ownership == pidOwnershipUnknown {
		return fmt.Sprintf("pid %d, unconfirmed", owner.pid)
	}
	return fmt.Sprintf("pid %d", owner.pid)
}

// pidRecord identifies the process that owns a session file. writtenAt is the
// file's modification time, which bounds when the recorded process must have
// started: the writer always starts before it writes, so a process that
// started later cannot be the writer.
type pidRecord struct {
	pid       int
	writtenAt time.Time
}

// pidOwnership is the confidence with which a session file's owner could be
// resolved. Ownership is never inferred from a failed lookup: reclaiming a
// session needs proof that the owner is gone, and terminating or deferring to
// one needs proof that it is alive.
type pidOwnership int

const (
	pidOwnershipGone pidOwnership = iota
	pidOwnershipUnknown
	pidOwnershipLive
)

// processSnapshot is what a platform could learn about a pid. When known is
// false nothing could be determined and no ownership decision may be based on
// it. started and image are zero when only part of the answer was available,
// and arguments reports whether image is the full command line or only the
// executable, which is all some platforms expose.
type processSnapshot struct {
	known     bool
	running   bool
	arguments bool
	started   time.Time
	image     string
}

func (r pidRecord) confirmedOwner(session string) bool {
	return r.pid > 0 && pidRecordOwnership(r, session) == pidOwnershipLive
}

// pidRecordOwnership resolves whether the process named by a session file is
// still that file's owner. session is the session the file belongs to when the
// owner is expected to be a server for it; the empty string asks only whether
// the process is a MonkeyMux helper at all, which is all that can be said
// about the holder of a session lock.
func pidRecordOwnership(record pidRecord, session string) pidOwnership {
	if record.pid <= 0 || !processIDAlive(record.pid) {
		return pidOwnershipGone
	}
	snapshot := inspectProcess(record.pid)
	if !snapshot.known {
		return pidOwnershipUnknown
	}
	if !snapshot.running {
		// Exited, or a zombie still waiting to be reaped by its parent.
		return pidOwnershipGone
	}
	if snapshot.image == "" {
		return pidOwnershipUnknown
	}
	if !processImageIsMonkeyMux(snapshot.image) {
		return pidOwnershipGone
	}
	if session != "" && snapshot.arguments &&
		processImageServesSession(snapshot.image, session) {
		// The command line names this session, which identifies the process
		// itself rather than merely its kind. Nothing else is needed, and in
		// particular no clock is consulted, so a host whose wall clock moved
		// can never mistake a live server for a recycled pid.
		return pidOwnershipLive
	}
	if processStartedAfterRecord(snapshot, record) {
		// A MonkeyMux process that did not identify itself as this session's
		// server, and that started after the record was written, cannot be the
		// process that wrote it: it inherited a recycled pid.
		return pidOwnershipGone
	}
	if session == "" || !snapshot.arguments {
		// Only the kind of process could be checked: the caller asked about a
		// lock, whose holder is an ordinary helper rather than a server, or
		// this platform does not expose command lines.
		return pidOwnershipLive
	}
	return pidOwnershipUnknown
}

// processStartedAfterRecord reports whether a process demonstrably started
// after a session file was written. The writer always starts before it writes,
// so this can only be true of a different process.
func processStartedAfterRecord(snapshot processSnapshot, record pidRecord) bool {
	if snapshot.started.IsZero() || record.writtenAt.IsZero() {
		return false
	}
	return snapshot.started.After(record.writtenAt.Add(pidRecordStartSlack))
}

// processImageIsMonkeyMux matches on the executable the process is running,
// not on its whole command line, so an editor or a grep that merely mentions
// the helper is not mistaken for one.
func processImageIsMonkeyMux(image string) bool {
	_, _, _, ok := parseHelperCommandLine(image)
	return ok
}

// parseHelperCommandLine splits a MonkeyMux command line into its executable,
// subcommand and remaining arguments, reporting whether it is one at all.
//
// A command line reaches this function already flattened into a single string,
// so an install path containing spaces (a home directory such as
// "/Users/Jane Doe") is indistinguishable from several arguments. The
// executable is therefore allowed to span leading words, up to the first one
// that looks like a flag. Failing to recognise a helper here is not harmless:
// it is read as proof that a live server is gone, and its windows would be
// orphaned by the replacement that follows.
func parseHelperCommandLine(
	image string,
) (executable string, subcommand string, arguments []string, ok bool) {
	fields := strings.Fields(image)
	for k := 1; k <= len(fields); k++ {
		if k > 1 && strings.HasPrefix(fields[k-1], "-") {
			// The executable cannot extend across a flag.
			break
		}
		candidate := strings.Join(fields[:k], " ")
		if !isMonkeyMuxExecutable(candidate) {
			continue
		}
		if k < len(fields) {
			return candidate, fields[k], fields[k+1:], true
		}
		return candidate, "", nil, true
	}
	return "", "", nil, false
}

func isMonkeyMuxExecutable(path string) bool {
	base := strings.TrimSuffix(strings.ToLower(filepath.Base(path)), ".exe")
	if base == "" || base == "." || base == string(filepath.Separator) {
		return false
	}
	if base == "monkeymux" {
		return true
	}
	// Tolerate a helper installed under another name by comparing with this
	// process, which is that same binary.
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	self := strings.TrimSuffix(strings.ToLower(filepath.Base(exe)), ".exe")
	return self != "" && base == self
}

// processImageServesSession reports whether a command line is that of a
// MonkeyMux server for exactly this session. The helper installs under
// ~/.monkeyssh, so searching the command line for the name would match the
// install path for a session called "MonkeySSH"; and once a command line is
// flattened to a single string, argument boundaries are gone, so a name
// containing spaces or flag-like words cannot be recovered from it reliably.
// The server therefore also carries a whitespace-free token for its session,
// which is matched first. Servers predating that token fall back to the
// --session value, which is exact for every name that does not itself look
// like a flag.
func processImageServesSession(image string, session string) bool {
	session = strings.TrimSpace(session)
	if session == "" {
		return false
	}
	_, subcommand, arguments, ok := parseHelperCommandLine(image)
	if !ok || subcommand != "serve" {
		return false
	}
	if token, ok := flagArgumentValue(arguments, "session-token"); ok {
		return token == sessionToken(session)
	}
	value, ok := flagArgumentValue(arguments, "session")
	return ok && value == session
}

// flagArgumentValue returns the value of a flag in a command line that has
// already been flattened to a single string. A value is read up to the next
// flag-like argument, which recovers names containing spaces.
func flagArgumentValue(arguments []string, flag string) (string, bool) {
	for i, argument := range arguments {
		name, inline, hasInline := strings.Cut(argument, "=")
		if name != "--"+flag && name != "-"+flag {
			continue
		}
		if hasInline {
			return inline, inline != ""
		}
		value := arguments[i+1:]
		for end, word := range value {
			if strings.HasPrefix(word, "-") {
				value = value[:end]
				break
			}
		}
		joined := strings.Join(value, " ")
		return joined, joined != ""
	}
	return "", false
}

// clearStalePIDFile removes a session file whose owner is confirmed gone and
// reports whether it did. session may be empty; see pidRecordOwnership.
func clearStalePIDFile(path string, session string) bool {
	record, err := readPIDRecord(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false
		}
		return clearAbandonedPIDFile(path)
	}
	if pidRecordOwnership(record, session) != pidOwnershipGone {
		return false
	}
	return removePIDFileIfUnchanged(path, record)
}

// removePIDFileIfUnchanged deletes path only while it still holds the record
// that was validated. Resolving an owner can take a process lookup, and in that
// window another helper may have reclaimed the file and become its live owner;
// unlinking by name alone would delete that helper's file and let two helpers
// hold the same session at once.
func removePIDFileIfUnchanged(path string, record pidRecord) bool {
	current, err := readPIDRecord(path)
	if err != nil ||
		current.pid != record.pid ||
		!current.writtenAt.Equal(record.writtenAt) {
		return false
	}
	return os.Remove(path) == nil
}

// clearAbandonedPIDFile removes a session file that cannot be parsed at all,
// once it is old enough that no helper can still be writing it. Lock files are
// installed already populated, so an unparseable one is the residue of a
// crash; leaving it would block the session forever. The content is re-checked
// immediately before unlinking for the same reason as
// removePIDFileIfUnchanged: a helper that has since installed a valid record
// must not have its file deleted.
func clearAbandonedPIDFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil || time.Since(info.ModTime()) < abandonedPIDFileAge {
		return false
	}
	modTime := info.ModTime()
	if _, err := readPIDRecord(path); err == nil {
		return false
	}
	current, err := os.Stat(path)
	if err != nil || !current.ModTime().Equal(modTime) {
		return false
	}
	return os.Remove(path) == nil
}

func readPIDFile(path string) (int, error) {
	record, err := readPIDRecord(path)
	if err != nil {
		return 0, err
	}
	return record.pid, nil
}

// readPIDRecord parses a session file. The format is a bare pid so that older
// helpers sharing the same host still read these files correctly; everything
// needed to validate ownership is derived from the running process and the
// file's own modification time instead. Content and timestamp are taken from
// one open file so they always describe the same generation of the file.
func readPIDRecord(path string) (pidRecord, error) {
	file, err := os.Open(path)
	if err != nil {
		return pidRecord{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, pidFileReadLimitBytes))
	if err != nil {
		return pidRecord{}, err
	}
	info, err := file.Stat()
	if err != nil {
		return pidRecord{}, err
	}
	normalized := strings.ReplaceAll(string(data), "\r\n", "\n")
	line, _, _ := strings.Cut(normalized, "\n")
	text := strings.TrimSpace(line)
	if text == "" {
		return pidRecord{}, errors.New("empty pid file")
	}
	pid, err := strconv.Atoi(text)
	if err != nil || pid <= 0 {
		return pidRecord{}, fmt.Errorf("invalid pid file %q", path)
	}
	return pidRecord{pid: pid, writtenAt: info.ModTime()}, nil
}

func collectServerRestore(session string, status runningServerStatus) *serverRestore {
	var restore *serverRestore
	if status.supportsCapability("upgrade-restore-v1") {
		if snapshot, err := requestServerRestore(session); err == nil && len(snapshot.Windows) > 0 {
			restore = snapshot
		}
	}
	if restore == nil {
		windows, err := queryServerWindows(session)
		if err != nil || len(windows) == 0 {
			return nil
		}
		restore = restoreFromWindowSnapshots(windows)
		enrichRestoreWithCapturedShellHistory(session, restore)
	}
	if restore != nil && restoreNeedsWindowActivity(restore) {
		if windows, err := queryServerWindows(session); err == nil {
			enrichRestoreWithWindowActivity(restore, windows)
		}
	}
	enrichRestoreWithAgentSessionIDs(restore)
	return restore
}

func restoreNeedsWindowActivity(restore *serverRestore) bool {
	if restore == nil {
		return false
	}
	for _, window := range restore.Windows {
		if agentToolCandidateForRestore(window) == "pi" &&
			strings.TrimSpace(window.AgentSessionPath) == "" &&
			window.LastActivityEpochSeconds <= 0 {
			return true
		}
	}
	return false
}

func enrichRestoreWithWindowActivity(
	restore *serverRestore,
	windows []windowSnapshot,
) {
	if restore == nil || len(windows) == 0 {
		return
	}
	byID := make(map[string]int64, len(windows))
	byIndex := make(map[int]int64, len(windows))
	for _, window := range windows {
		if window.LastActivityEpochSeconds <= 0 {
			continue
		}
		if id := strings.TrimSpace(window.ID); id != "" {
			byID[id] = window.LastActivityEpochSeconds
		}
		byIndex[window.Index] = window.LastActivityEpochSeconds
	}
	for i := range restore.Windows {
		if restore.Windows[i].LastActivityEpochSeconds > 0 {
			continue
		}
		if id := strings.TrimSpace(restore.Windows[i].ID); id != "" {
			if activity := byID[id]; activity > 0 {
				restore.Windows[i].LastActivityEpochSeconds = activity
			}
			continue
		}
		if activity := byIndex[restore.Windows[i].Index]; activity > 0 {
			restore.Windows[i].LastActivityEpochSeconds = activity
		}
	}
}

func requestServerRestore(session string) (*serverRestore, error) {
	conn, err := dialSession(session)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return nil, err
	}
	if _, err := readControlHello(dec); err != nil {
		return nil, err
	}
	requestID := strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := enc.Encode(controlMessage{
		ID:      requestID,
		Type:    "upgrade_snapshot",
		Session: session,
	}); err != nil {
		return nil, err
	}
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return nil, err
		}
		if response.ID != requestID {
			continue
		}
		if response.Status == "error" || response.Type == "error" {
			return nil, errors.New(response.Error)
		}
		if response.Restore == nil || len(response.Restore.Windows) == 0 {
			return nil, errors.New("empty restore snapshot")
		}
		return response.Restore, nil
	}
}

func queryServerWindows(session string) ([]windowSnapshot, error) {
	conn, err := dialSession(session)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return nil, err
	}
	if _, err := readControlHello(dec); err != nil {
		return nil, err
	}
	requestID := strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := enc.Encode(controlMessage{
		ID:      requestID,
		Type:    "list_windows",
		Session: session,
	}); err != nil {
		return nil, err
	}
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return nil, err
		}
		if response.Type == "window_list" && (response.ID == requestID || response.ID == "") {
			return response.Windows, nil
		}
		if response.ID == requestID && (response.Status == "error" || response.Type == "error") {
			return nil, errors.New(response.Error)
		}
	}
}

func readControlHello(dec *json.Decoder) (controlResponse, error) {
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return controlResponse{}, err
		}
		if response.Type == "hello" {
			return response, nil
		}
	}
}

func restoreFromWindowSnapshots(windows []windowSnapshot) *serverRestore {
	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows:       make([]restoreWindowState, 0, len(windows)),
	}
	for _, window := range windows {
		restore.Windows = append(restore.Windows, restoreWindowState{
			ID:                        window.ID,
			Index:                     window.Index,
			Name:                      window.Name,
			Cwd:                       window.CurrentPath,
			CurrentCommand:            window.CurrentCommand,
			PanePid:                   window.PanePid,
			PaneTitle:                 window.PaneTitle,
			AgentTool:                 window.AgentTool,
			AgentToolConfirmed:        window.AgentToolConfirmed,
			AgentSessionID:            window.AgentSessionID,
			AgentSessionDir:           window.AgentSessionDir,
			AgentSessionPath:          window.AgentSessionPath,
			AgentSessionIdentityExact: window.AgentSessionIdentityExact,
			NativeAcpBridgeID:         window.NativeAcpBridgeID,
			NativeAcpProviderID:       window.NativeAcpProviderID,
			LastActivityEpochSeconds:  window.LastActivityEpochSeconds,
			PrivateModes:              privateModesFromWindowSnapshot(window),
			TerminalProgress:          copyTerminalProgressSnapshot(window.TerminalProgress),
			Active:                    window.Active,
		})
	}
	return restore
}

func privateModesFromWindowSnapshot(window windowSnapshot) map[string]bool {
	if modes := copyPrivateModes(window.PrivateModes); len(modes) > 0 {
		return modes
	}
	modes := map[string]bool{}
	if window.TerminalReportsMouseWheel {
		if window.TerminalMouseReportSgr {
			modes["1002"] = true
		} else {
			modes["1000"] = true
		}
	}
	if window.TerminalMouseReportSgr {
		modes["1006"] = true
	}
	if window.TerminalBracketedPaste {
		modes["2004"] = true
	}
	if len(modes) == 0 {
		return nil
	}
	return modes
}

func enrichRestoreWithCapturedShellHistory(session string, restore *serverRestore) {
	if restore == nil || !restoreNeedsShellHistory(restore) {
		return
	}
	histories := captureShellWindowHistories(session, restore)
	for i := range restore.Windows {
		if !isShellRestoreWindow(restore.Windows[i]) ||
			restore.Windows[i].HistoryBase64 != "" {
			continue
		}
		history := histories[restore.Windows[i].ID]
		if len(history) == 0 {
			continue
		}
		restore.Windows[i].HistoryBase64 = base64.StdEncoding.EncodeToString(history)
	}
}

func restoreHasNativeAcpWindows(restore *serverRestore) bool {
	if restore == nil {
		return false
	}
	for _, window := range restore.Windows {
		if window.NativeAcpBridgeID != "" && window.NativeAcpProviderID != "" {
			return true
		}
	}
	return false
}

func restoreNeedsShellHistory(restore *serverRestore) bool {
	for _, window := range restore.Windows {
		if isShellRestoreWindow(window) && window.HistoryBase64 == "" {
			return true
		}
	}
	return false
}

func captureShellWindowHistories(
	session string,
	restore *serverRestore,
) map[string][]byte {
	targets := map[string]restoreWindowState{}
	activeID := ""
	for _, window := range restore.Windows {
		if window.Active {
			activeID = window.ID
		}
		if isShellRestoreWindow(window) && window.ID != "" {
			targets[window.ID] = window
		}
	}
	if len(targets) == 0 {
		return nil
	}

	attachConn, err := dialSession(session)
	if err != nil {
		return nil
	}
	defer attachConn.Close()
	controlConn, err := dialSession(session)
	if err != nil {
		return nil
	}
	defer controlConn.Close()
	_ = attachConn.SetDeadline(time.Now().Add(socketTimeout))
	_ = controlConn.SetDeadline(time.Now().Add(socketTimeout))

	if err := json.NewEncoder(attachConn).Encode(controlMessage{
		Role:    "attach",
		Session: session,
		Width:   defaultColumns,
		Height:  defaultRows,
	}); err != nil {
		return nil
	}
	controlEnc := json.NewEncoder(controlConn)
	controlDec := json.NewDecoder(controlConn)
	if err := controlEnc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return nil
	}
	if _, err := readControlHello(controlDec); err != nil {
		return nil
	}

	histories := map[string][]byte{}
	if _, ok := targets[activeID]; ok {
		if history := readAttachReplayHistory(attachConn); len(history) > 0 {
			histories[activeID] = history
		}
	}
	for _, window := range restore.Windows {
		if _, ok := targets[window.ID]; !ok || window.ID == activeID {
			continue
		}
		if err := requestSelectWindow(controlEnc, controlDec, session, window.ID); err != nil {
			continue
		}
		if history := readAttachReplayHistory(attachConn); len(history) > 0 {
			histories[window.ID] = history
		}
	}
	if activeID != "" {
		_ = requestSelectWindow(controlEnc, controlDec, session, activeID)
	}
	return histories
}

func requestSelectWindow(
	enc *json.Encoder,
	dec *json.Decoder,
	session string,
	windowID string,
) error {
	requestID := strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := enc.Encode(controlMessage{
		ID:       requestID,
		Type:     "select_window",
		Session:  session,
		WindowID: windowID,
	}); err != nil {
		return err
	}
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return err
		}
		if response.ID != requestID {
			continue
		}
		if response.Status == "error" || response.Type == "error" {
			return errors.New(response.Error)
		}
		return nil
	}
}

func readAttachReplayHistory(conn net.Conn) []byte {
	var output bytes.Buffer
	buf := make([]byte, 32*1024)
	deadline := time.Now().Add(150 * time.Millisecond)
	_ = conn.SetReadDeadline(deadline)
	for output.Len() < windowHistoryLimitBytes {
		n, err := conn.Read(buf)
		if n > 0 {
			remaining := windowHistoryLimitBytes - output.Len()
			if n > remaining {
				n = remaining
			}
			_, _ = output.Write(buf[:n])
			deadline = time.Now().Add(50 * time.Millisecond)
			_ = conn.SetReadDeadline(deadline)
		}
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				break
			}
			break
		}
	}
	return normalizeCapturedReplayHistory(output.Bytes())
}

func normalizeCapturedReplayHistory(history []byte) []byte {
	if len(history) == 0 {
		return nil
	}
	if bytes.HasPrefix(history, []byte(activeWindowReplayPrefix)) {
		history = history[len(activeWindowReplayPrefix):]
	}
	if len(history) > windowHistoryLimitBytes {
		history = history[len(history)-windowHistoryLimitBytes:]
	}
	return append([]byte(nil), history...)
}

func enrichRestoreWithAgentSessionIDs(restore *serverRestore) {
	if restore == nil {
		return
	}
	panePids := map[int]struct{}{}
	paneWorkingDirectories := map[int]string{}
	hasAntigravityWindows := false
	hasCursorWindows := false
	hasPiWindows := false
	for _, window := range restore.Windows {
		tool := agentToolCandidateForRestore(window)
		if tool == "pi" {
			hasPiWindows = true
			if window.PanePid > 0 {
				panePids[window.PanePid] = struct{}{}
			}
		}
		switch tool {
		case "antigravity":
			hasAntigravityWindows = true
		case "cursor-agent":
			hasCursorWindows = true
		}
		if tool != "" && window.PanePid > 0 {
			panePids[window.PanePid] = struct{}{}
			paneWorkingDirectories[window.PanePid] = window.Cwd
		}
	}
	processes := map[int]processInfo{}
	if len(panePids) > 0 {
		processes = processTableForMetadata()
	}
	antigravitySessions := map[int]string{}
	if hasAntigravityWindows {
		antigravitySessions = discoverAntigravitySessionIDs(restore, processes, panePids)
	}
	cursorSessions := map[int]string{}
	if hasCursorWindows {
		cursorSessions = discoverCursorSessionIDs(restore, processes, panePids)
	}
	piSessions := map[int]piRestoreSession{}
	if hasPiWindows {
		piSessions = discoverPiSessions(restore, processes, panePids)
		applyPiRestoreSessions(restore, piSessions)
	}
	processDiscoveredSessions := map[string]map[int]string{}
	if len(processes) > 0 {
		processDiscoveredSessions = map[string]map[int]string{
			"copilot":  discoverCopilotSessionIDs(processes, panePids),
			"codex":    discoverAgentSessionIDs("codex", processes, panePids, paneWorkingDirectories),
			"opencode": discoverAgentSessionIDs("opencode", processes, panePids, paneWorkingDirectories),
			"claude":   discoverAgentSessionIDs("claude", processes, panePids, paneWorkingDirectories),
		}
	}
	for i := range restore.Windows {
		tool := agentToolForRestore(restore.Windows[i])
		panePid := restore.Windows[i].PanePid
		if tool == "" {
			continue
		}
		if tool == "pi" {
			// applyPiRestoreSessions already assigned validated identities and
			// cleared stale carried ones. Do not fall through to ID-only generic
			// discovery and lose the exact path.
			continue
		}
		discoveredSessionID := ""
		if panePid > 0 {
			discoveredSessionID = processDiscoveredSessions[tool][panePid]
		}
		if discoveredSessionID == "" && panePid > 0 && len(processes) > 0 {
			discoveredSessionID = sessionIDFromSelectedAgentProcessArgs(
				processes,
				panePid,
				tool,
			)
		}
		if discoveredSessionID == "" && tool == "antigravity" {
			discoveredSessionID = antigravitySessions[i]
		}
		if discoveredSessionID == "" && tool == "cursor-agent" {
			discoveredSessionID = cursorSessions[i]
		}
		// A carried ID describes what MonkeyMux tried to resume, not proof that
		// the resume succeeded. If the command fell back to a fresh agent, its
		// live argv/open file/store has no matching identity, so clear the stale
		// ID instead of forcing that old conversation again on the next upgrade.
		restore.Windows[i].AgentSessionID = discoveredSessionID
	}
	assignCopilotSessionsByWorkingDirectory(restore, processes, panePids)
}

func applyPiRestoreSessions(restore *serverRestore, sessions map[int]piRestoreSession) {
	for i := range restore.Windows {
		if agentToolCandidateForRestore(restore.Windows[i]) != "pi" {
			continue
		}
		restore.Windows[i].AgentSessionID = ""
		restore.Windows[i].AgentSessionDir = ""
		restore.Windows[i].AgentSessionPath = ""
		restore.Windows[i].AgentSessionIdentityExact = false
		if session, ok := sessions[i]; ok && agentToolForRestore(restore.Windows[i]) == "pi" {
			restore.Windows[i].AgentSessionID = session.sessionID
			restore.Windows[i].AgentSessionDir = session.sessionDir
			restore.Windows[i].AgentSessionPath = session.sessionPath
			restore.Windows[i].AgentSessionIdentityExact = session.identityExact
		}
	}
}

type antigravityHistoryEntry struct {
	conversationID string
	workspace      string
	updatedAt      time.Time
}

func assignAgentSessionsByWorkspace(
	restore *serverRestore,
	processes map[int]processInfo,
	panePids map[int]struct{},
	provider string,
	sessionIDForWorkspace func(string, time.Time) string,
) map[int]string {
	workspaceCounts := map[string]int{}
	for _, window := range restore.Windows {
		if agentToolForRestore(window) == provider {
			workspaceCounts[normalizedAgentWorkspacePath(window.Cwd)]++
		}
	}
	sessions := map[int]string{}
	liveProcesses := agentProcessesByPane(processes, panePids, provider)
	for i, window := range restore.Windows {
		if agentToolForRestore(window) != provider {
			continue
		}
		workspace := normalizedAgentWorkspacePath(window.Cwd)
		if workspace == "" || workspaceCounts[workspace] != 1 {
			continue
		}
		process, ok := liveProcesses[window.PanePid]
		if !ok {
			continue
		}
		processStarted := processStartedAtForMetadata(process.pid)
		if sessionID := sessionIDForWorkspace(
			workspace,
			processStarted,
		); sessionID != "" {
			sessions[i] = sessionID
		}
	}
	return sessions
}

func discoverAntigravitySessionIDs(
	restore *serverRestore,
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	entries := readAntigravityHistoryEntries()
	if len(entries) == 0 {
		return nil
	}
	return assignAgentSessionsByWorkspace(restore, processes, panePids, "antigravity",
		func(workspace string, started time.Time) string {
			return antigravitySessionIDForWorkspace(entries, workspace, started)
		})
}

func readAntigravityHistoryEntries() []antigravityHistoryEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	file, err := os.Open(filepath.Join(home, ".gemini", "antigravity-cli", "history.jsonl"))
	if err != nil {
		return nil
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	entries := []antigravityHistoryEntry{}
	for scanner.Scan() {
		var raw struct {
			ConversationID string `json:"conversationId"`
			Workspace      string `json:"workspace"`
			Timestamp      int64  `json:"timestamp"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			continue
		}
		sessionID := strings.TrimSpace(raw.ConversationID)
		if sessionID == "" {
			continue
		}
		entries = append(entries, antigravityHistoryEntry{
			conversationID: sessionID,
			workspace:      normalizedAgentWorkspacePath(raw.Workspace),
			updatedAt:      unixDatabaseTime(strconv.FormatInt(raw.Timestamp, 10)),
		})
	}
	return entries
}

func antigravitySessionIDForWorkspace(
	entries []antigravityHistoryEntry,
	workspace string,
	processStarted time.Time,
) string {
	normalizedWorkspace := normalizedAgentWorkspacePath(workspace)
	if normalizedWorkspace == "" {
		return ""
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].workspace == normalizedWorkspace &&
			sessionUpdatedDuringProcess(entries[i].updatedAt, processStarted) {
			return entries[i].conversationID
		}
	}
	return ""
}

func normalizedAgentWorkspacePath(value string) string {
	workspace := strings.TrimSpace(value)
	if workspace == "" {
		return ""
	}
	if strings.HasPrefix(strings.ToLower(workspace), "file://") {
		if path := pathFromOsc7(workspace); path != "" {
			workspace = path
		}
	}
	if expanded, err := expandHomePath(workspace); err == nil {
		workspace = expanded
	}
	return filepath.Clean(workspace)
}

// ── Cursor Agent ─────────────────────────────────────────────────────────────
// Cursor persists chats under ~/.cursor/chats/<workspaceHash>/<chatId>/meta.json.
// A fresh `cursor-agent` launch carries no resumable id in its process args.
// Restore only a unique chat for the pane's workspace that was updated during
// the current Cursor process; older chats leave a fresh window fresh.

type cursorChatEntry struct {
	chatID    string
	cwd       string
	updatedAt int64
}

func discoverCursorSessionIDs(
	restore *serverRestore,
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	entries := readCursorChatEntries()
	if len(entries) == 0 {
		return nil
	}
	return assignAgentSessionsByWorkspace(restore, processes, panePids, "cursor-agent",
		func(workspace string, started time.Time) string {
			return cursorSessionIDForWorkspace(entries, workspace, started)
		})
}

// readCursorChatEntries reads recent Cursor chat metadata, ordered oldest to
// newest so the newest match wins a reverse scan.
func readCursorChatEntries() []cursorChatEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	chatsRoot := filepath.Join(home, ".cursor", "chats")
	workspaceDirs, err := os.ReadDir(chatsRoot)
	if err != nil {
		return nil
	}
	entries := []cursorChatEntry{}
	for _, workspaceDir := range workspaceDirs {
		if !workspaceDir.IsDir() {
			continue
		}
		chatDirs, err := os.ReadDir(filepath.Join(chatsRoot, workspaceDir.Name()))
		if err != nil {
			continue
		}
		for _, chatDir := range chatDirs {
			if !chatDir.IsDir() {
				continue
			}
			metaPath := filepath.Join(
				chatsRoot,
				workspaceDir.Name(),
				chatDir.Name(),
				"meta.json",
			)
			if entry, ok := readCursorChatMeta(metaPath, chatDir.Name()); ok {
				entries = append(entries, entry)
			}
		}
	}
	sort.SliceStable(entries, func(a, b int) bool {
		return entries[a].updatedAt < entries[b].updatedAt
	})
	return entries
}

func readCursorChatMeta(path string, chatID string) (cursorChatEntry, bool) {
	// Current Cursor Agent writes hasConversation=false even for the chat id
	// owned by a live newly-started TUI. Live assignment is already constrained
	// by exact cwd and process start time, so that advisory flag must not hide it.
	data, err := os.ReadFile(path)
	if err != nil {
		return cursorChatEntry{}, false
	}
	var raw struct {
		Cwd         string `json:"cwd"`
		UpdatedAtMs int64  `json:"updatedAtMs"`
		CreatedAtMs int64  `json:"createdAtMs"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return cursorChatEntry{}, false
	}
	sessionID := strings.TrimSpace(chatID)
	if sessionID == "" {
		return cursorChatEntry{}, false
	}
	updatedAt := raw.UpdatedAtMs
	if updatedAt == 0 {
		updatedAt = raw.CreatedAtMs
	}
	return cursorChatEntry{
		chatID:    sessionID,
		cwd:       normalizedAgentWorkspacePath(raw.Cwd),
		updatedAt: updatedAt,
	}, true
}

func cursorSessionIDForWorkspace(
	entries []cursorChatEntry,
	workspace string,
	processStarted time.Time,
) string {
	normalizedWorkspace := normalizedAgentWorkspacePath(workspace)
	if normalizedWorkspace == "" {
		return ""
	}
	for i := len(entries) - 1; i >= 0; i-- {
		updatedAt := time.UnixMilli(entries[i].updatedAt)
		if entries[i].cwd == normalizedWorkspace &&
			sessionUpdatedDuringProcess(updatedAt, processStarted) {
			return entries[i].chatID
		}
	}
	return ""
}

// piSessionEntry is the resumable metadata stored in a primary Pi JSONL file.
type piSessionEntry struct {
	sessionID   string
	sessionName string
	rawCwd      string
	cwd         string
	path        string
	modTime     time.Time
	createdAt   time.Time
	// parentPath is the session file this one was rotated or relocated from
	// (the header's parentSession), which may no longer exist on disk.
	parentPath string
	// originDir and originCreatedAt describe the root of the parentSession
	// chain: the directory name and creation time of the session the pane's
	// Pi process originally started. Pi's worktree flow relocates a session
	// to a new cwd-encoded directory with a fresh id and timestamp and
	// deletes the original file, so only the chain origin still matches the
	// pane's working directory and process start time.
	originDir       string
	originCreatedAt time.Time
}

var processStartedAtForMetadata = func(pid int) time.Time {
	return inspectProcess(pid).started
}

var processTableForMetadata = readProcessTable

type piRestoreSession struct {
	sessionID     string
	sessionDir    string
	sessionPath   string
	identityExact bool
}

// discoverPiSessions first correlates each pane with its live Pi process. A
// named Pi session is matched to the exact terminal title Pi publishes. Pi
// writes JSONL entries with short-lived append calls, so an open-file match is
// only a best-effort shortcut. When neither is available, a unique session
// header creation time is matched against the process start. File mtime is used
// only to reject a match after later unowned activity, never to infer ownership.
// Plain cwd fallback remains limited to one unambiguous unused primary session.
func discoverPiSessions(
	restore *serverRestore,
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]piRestoreSession {
	if restore == nil {
		return nil
	}
	used := map[string]bool{}
	for _, window := range restore.Windows {
		if agentToolForRestore(window) == "pi" {
			continue
		}
		if id := strings.TrimSpace(window.AgentSessionID); id != "" {
			used[id] = true
		}
	}
	piPanePids := map[int]struct{}{}
	for _, window := range restore.Windows {
		if window.PanePid > 0 && agentToolCandidateForRestore(window) == "pi" {
			piPanePids[window.PanePid] = struct{}{}
		}
	}
	piProcesses := piProcessesByPane(processes, panePids, piPanePids)
	sessions := map[int]piRestoreSession{}
	processStarts := map[int]time.Time{}
	livePiWindows := map[int]bool{}
	trustedPiWindows := map[int]bool{}
	type fallbackKey struct {
		root string
		cwd  string
	}
	fallbackWindows := map[fallbackKey][]int{}
	for i, window := range restore.Windows {
		if agentToolCandidateForRestore(window) != "pi" {
			continue
		}
		process, hasProcess := piProcesses[window.PanePid]
		if agentToolForRestore(window) != "pi" && !hasProcess {
			continue
		}
		if hasProcess {
			restore.Windows[i].AgentToolConfirmed = true
			livePiWindows[i] = true
		}
		trustedPiWindows[i] = hasProcess ||
			(restore.Windows[i].AgentToolConfirmed &&
				agentToolForRestore(restore.Windows[i]) == "pi")
		if hasProcess {
			if window.AgentSessionIdentityExact {
				path := normalizedPiSessionDirectory(window.AgentSessionPath, window.Cwd)
				if entry, ok := readPiSessionEntry(path); ok &&
					entry.sessionID == strings.TrimSpace(window.AgentSessionID) &&
					!used[entry.sessionID] {
					sessions[i] = piRestoreSession{
						sessionID:     entry.sessionID,
						sessionDir:    filepath.Dir(entry.path),
						sessionPath:   entry.path,
						identityExact: true,
					}
					used[entry.sessionID] = true
					continue
				}
			}
			if entry, ok := piSessionFromProcessArgs(process.args, window.Cwd); ok && !used[entry.sessionID] {
				sessions[i] = piRestoreSession{
					sessionID:   entry.sessionID,
					sessionDir:  filepath.Dir(entry.path),
					sessionPath: entry.path,
				}
				used[entry.sessionID] = true
				continue
			}
			if sessionID := agentSessionIDFromArgs("pi", process.args); safePiSessionIDPattern.MatchString(sessionID) && !used[sessionID] {
				sessionDir := piSessionDirFromArgs(process.args, window.Cwd)
				sessions[i] = piRestoreSession{sessionID: sessionID, sessionDir: sessionDir}
				used[sessionID] = true
				continue
			}
			if entry, ok := piSessionFromOpenFiles(process.pid); ok && !used[entry.sessionID] {
				sessions[i] = piRestoreSession{
					sessionID:   entry.sessionID,
					sessionDir:  filepath.Dir(entry.path),
					sessionPath: entry.path,
				}
				used[entry.sessionID] = true
				continue
			}
			processStarts[i] = processStartedAtForMetadata(process.pid)
		}
		cwd := normalizedWorkingDirectory(window.Cwd)
		if cwd == "" {
			continue
		}
		root := ""
		if hasProcess {
			root = piSessionDirFromArgs(process.args, window.Cwd)
		}
		if root == "" && strings.TrimSpace(window.AgentSessionDir) != "" {
			root = normalizedPiSessionDirectory(window.AgentSessionDir, window.Cwd)
		}
		if root == "" && strings.TrimSpace(window.AgentSessionPath) != "" {
			root = filepath.Dir(normalizedPiSessionDirectory(window.AgentSessionPath, window.Cwd))
		}
		if root == "" {
			root = piSessionRootForWorkingDirectory(window.Cwd)
		}
		if root != "" {
			key := fallbackKey{root: root, cwd: cwd}
			fallbackWindows[key] = append(fallbackWindows[key], i)
		}
	}
	entriesByRoot := map[string][]piSessionEntry{}
	keys := make([]fallbackKey, 0, len(fallbackWindows))
	for key := range fallbackWindows {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].root != keys[j].root {
			return keys[i].root < keys[j].root
		}
		return keys[i].cwd < keys[j].cwd
	})
	for _, key := range keys {
		indices := fallbackWindows[key]
		entries, ok := entriesByRoot[key.root]
		if !ok {
			entries = readPiSessionEntries(key.root)
			entriesByRoot[key.root] = entries
		}
		// Pi's interactive /resume picker can switch to a session recorded in a
		// different working directory without putting the selected path in argv
		// or changing the shell process' cwd. Load current names before applying
		// cwd filtering so Pi's published title can retain that exact cross-cwd
		// candidate. Unnamed titles retain every matching cwd basename and rely
		// on the existing one-to-one activity/process evidence below.
		entries = piSessionsWithLatestNamesForTitles(restore, indices, entries)
		encodedCwd := piEncodedSessionDirName(key.cwd)
		candidates := []piSessionEntry{}
		for _, entry := range entries {
			if used[entry.sessionID] {
				continue
			}
			matchesPublishedTitle := false
			for _, index := range indices {
				if piSessionMatchesPaneTitle(entry, restore.Windows[index].PaneTitle) ||
					piSessionCwdMatchesPaneTitle(entry, restore.Windows[index].PaneTitle) {
					matchesPublishedTitle = true
					break
				}
			}
			// A relocated session (Pi's worktree flow) records the pane's
			// working directory only in the origin of its parentSession
			// chain, so match either the live cwd, that origin bucket, or an
			// exact title published after an interactive cross-cwd resume.
			if entry.cwd == key.cwd ||
				(encodedCwd != "" && entry.originDir == encodedCwd) ||
				matchesPublishedTitle {
				candidates = append(candidates, entry)
			}
		}

		// Official Pi publishes named sessions as `π - <name> - <cwd>`;
		// older/custom builds may use `Pi`. Unlike process-start correlation, this
		// remains authoritative when Pi delayed creating
		// its JSONL until the first assistant response or several restored Pi
		// processes started together during an earlier helper upgrade.
		for index, candidate := range uniquePiSessionsByPaneTitle(
			restore,
			indices,
			candidates,
		) {
			if !trustedPiWindows[index] ||
				!piSessionFreshForRestoreWindow(
					restore.Windows[index],
					candidate,
					processStarts[index],
					livePiWindows[index],
				) {
				continue
			}
			sessions[index] = piRestoreSession{
				sessionID:   candidate.sessionID,
				sessionDir:  filepath.Dir(candidate.path),
				sessionPath: candidate.path,
			}
			used[candidate.sessionID] = true
		}
		remainingIndices := make([]int, 0, len(indices))
		for _, index := range indices {
			if _, ok := sessions[index]; !ok {
				remainingIndices = append(remainingIndices, index)
			}
		}
		remainingCandidates := make([]piSessionEntry, 0, len(candidates))
		for _, candidate := range candidates {
			if !used[candidate.sessionID] {
				remainingCandidates = append(remainingCandidates, candidate)
			}
		}

		// Unnamed Pi windows all publish the same `Pi - <cwd>` title. Their
		// latest terminal output still brackets the JSONL append for that turn,
		// which gives upgrades a one-to-one signal even after /new or /resume
		// made process-start correlation stale. Fail closed if timestamps overlap.
		activityMatches := uniquePiSessionsByWindowActivity(
			restore,
			remainingIndices,
			remainingCandidates,
			trustedPiWindows,
		)
		freshActivityMatches := map[int]piSessionEntry{}
		activityOwnedSessionIDs := map[string]bool{}
		for index, candidate := range activityMatches {
			if !piSessionFreshForRestoreWindow(
				restore.Windows[index],
				candidate,
				processStarts[index],
				livePiWindows[index],
			) {
				continue
			}
			freshActivityMatches[index] = candidate
			activityOwnedSessionIDs[candidate.sessionID] = true
		}
		for index, candidate := range freshActivityMatches {
			if !processStarts[index].IsZero() && piSessionWasSuperseded(
				remainingCandidates,
				candidate,
				processStarts[index],
				activityOwnedSessionIDs,
			) {
				continue
			}
			sessions[index] = piRestoreSession{
				sessionID:   candidate.sessionID,
				sessionDir:  filepath.Dir(candidate.path),
				sessionPath: candidate.path,
			}
			used[candidate.sessionID] = true
		}
		remainingIndices = remainingIndices[:0]
		for _, index := range indices {
			if _, ok := sessions[index]; !ok {
				remainingIndices = append(remainingIndices, index)
			}
		}
		remainingCandidates = remainingCandidates[:0]
		for _, candidate := range candidates {
			if !used[candidate.sessionID] {
				remainingCandidates = append(remainingCandidates, candidate)
			}
		}

		// Compute every pane's process-time match before reserving any session.
		// A greedy pass can let an earlier pane steal a later pane's only match.
		processMatchesByWindow := map[int][]piSessionEntry{}
		for _, index := range remainingIndices {
			processMatchesByWindow[index] = piLeafSessionMatches(
				piSessionsCreatedForProcessStart(
					remainingCandidates,
					processStarts[index],
				),
				remainingCandidates,
			)
		}
		provisional := uniquePiSessionAssignments(processMatchesByWindow)
		ownedSessionIDs := map[string]bool{}
		for _, candidate := range provisional {
			ownedSessionIDs[candidate.sessionID] = true
		}
		accepted := map[int]piSessionEntry{}
		for index, candidate := range provisional {
			if piSessionWasSuperseded(
				remainingCandidates,
				candidate,
				processStarts[index],
				ownedSessionIDs,
			) {
				continue
			}
			accepted[index] = candidate
		}
		for index, candidate := range accepted {
			sessions[index] = piRestoreSession{
				sessionID:   candidate.sessionID,
				sessionDir:  filepath.Dir(candidate.path),
				sessionPath: candidate.path,
			}
			used[candidate.sessionID] = true
		}

		// Persisted identity is the last evidence-backed correlation before the
		// one-to-one cwd fallback. It carries unnamed Pi sessions through a second
		// upgrade after Pi has hidden its argv, but it must never override live
		// process/title evidence or a later /new or /resume rotation.
		persisted := map[int]piSessionEntry{}
		persistedOwners := map[string][]int{}
		for _, index := range remainingIndices {
			if _, ok := sessions[index]; ok || !livePiWindows[index] {
				continue
			}
			state := restore.Windows[index]
			persistedID := strings.TrimSpace(state.AgentSessionID)
			persistedPath := strings.TrimSpace(state.AgentSessionPath)
			if persistedID == "" && persistedPath == "" {
				continue
			}
			matches := []piSessionEntry{}
			for _, candidate := range remainingCandidates {
				if used[candidate.sessionID] ||
					(persistedID != "" && candidate.sessionID != persistedID) ||
					(persistedPath != "" && candidate.path != filepath.Clean(persistedPath)) {
					continue
				}
				matches = append(matches, candidate)
			}
			matches = piLeafSessionMatches(matches, remainingCandidates)
			if len(matches) != 1 ||
				!sessionUpdatedDuringProcess(matches[0].modTime, processStarts[index]) {
				continue
			}
			persisted[index] = matches[0]
			persistedOwners[matches[0].sessionID] = append(
				persistedOwners[matches[0].sessionID],
				index,
			)
		}
		for index, candidate := range persisted {
			if len(persistedOwners[candidate.sessionID]) != 1 {
				delete(persisted, index)
				continue
			}
			ownedSessionIDs[candidate.sessionID] = true
		}
		for index, candidate := range persisted {
			if piSessionWasSuperseded(
				remainingCandidates,
				candidate,
				processStarts[index],
				ownedSessionIDs,
			) {
				continue
			}
			sessions[index] = piRestoreSession{
				sessionID:   candidate.sessionID,
				sessionDir:  filepath.Dir(candidate.path),
				sessionPath: candidate.path,
			}
			used[candidate.sessionID] = true
		}

		// If process-table inspection was unavailable, a single confirmed Pi
		// window may still own the newest primary session in its cwd bucket. This
		// is weaker than an exact title/activity match, so allow it only for one
		// window, require a unique newest file no later than captured activity,
		// and never use it when another Pi pane could claim the same bucket.
		if len(indices) == 1 {
			index := indices[0]
			if _, ok := sessions[index]; !ok && trustedPiWindows[index] &&
				!livePiWindows[index] {
				if candidate, ok := uniqueLatestPiSession(remainingCandidates); ok {
					activity := time.Unix(restore.Windows[index].LastActivityEpochSeconds, 0)
					if !activity.IsZero() &&
						!candidate.modTime.After(activity.Add(piSessionActivityMatchTolerance)) {
						sessions[index] = piRestoreSession{
							sessionID:   candidate.sessionID,
							sessionDir:  filepath.Dir(candidate.path),
							sessionPath: candidate.path,
						}
						used[candidate.sessionID] = true
					}
				}
			}
		}

		// Preserve the old cwd fallback only for a genuinely one-to-one
		// bucket. Never hand a leftover session to a pane after a multi-pane
		// process match was rejected as ambiguous.
		if len(indices) == 1 && len(candidates) == 1 {
			index := indices[0]
			candidate := candidates[0]
			if _, ok := sessions[index]; !ok &&
				livePiWindows[index] &&
				sessionUpdatedDuringProcess(candidate.modTime, processStarts[index]) &&
				!piSessionWasSuperseded(
					candidates,
					candidate,
					processStarts[index],
					map[string]bool{candidate.sessionID: true},
				) {
				sessions[index] = piRestoreSession{
					sessionID:   candidate.sessionID,
					sessionDir:  filepath.Dir(candidate.path),
					sessionPath: candidate.path,
				}
				used[candidate.sessionID] = true
			}
		}
	}
	return sessions
}

func uniqueLatestPiSession(candidates []piSessionEntry) (piSessionEntry, bool) {
	var latest piSessionEntry
	found := false
	tied := false
	for _, candidate := range candidates {
		if candidate.modTime.IsZero() {
			continue
		}
		if !found || candidate.modTime.After(latest.modTime) {
			latest = candidate
			found = true
			tied = false
			continue
		}
		if candidate.modTime.Equal(latest.modTime) {
			tied = true
		}
	}
	return latest, found && !tied
}

func piSessionFreshForRestoreWindow(
	window restoreWindowState,
	candidate piSessionEntry,
	processStarted time.Time,
	hasLiveProcess bool,
) bool {
	if hasLiveProcess {
		return sessionUpdatedDuringProcess(candidate.modTime, processStarted)
	}
	if !window.AgentToolConfirmed || agentToolForRestore(window) != "pi" {
		return false
	}
	// A published Pi session name is an exact identity signal and remains
	// stable even while a long-running progress animation advances window
	// activity without touching the JSONL file.
	if piSessionMatchesPaneTitle(candidate, window.PaneTitle) {
		return true
	}
	if window.LastActivityEpochSeconds <= 0 || candidate.modTime.IsZero() {
		return false
	}
	activity := time.Unix(window.LastActivityEpochSeconds, 0)
	delta := candidate.modTime.Sub(activity)
	if delta < 0 {
		delta = -delta
	}
	return delta <= piSessionActivityMatchTolerance
}

func uniquePiSessionsByWindowActivity(
	restore *serverRestore,
	indices []int,
	candidates []piSessionEntry,
	livePiWindows map[int]bool,
) map[int]piSessionEntry {
	matchesByWindow := map[int][]piSessionEntry{}
	for _, index := range indices {
		if !livePiWindows[index] {
			continue
		}
		epoch := restore.Windows[index].LastActivityEpochSeconds
		if epoch <= 0 {
			continue
		}
		activity := time.Unix(epoch, 0)
		matches := []piSessionEntry{}
		for _, candidate := range candidates {
			if candidate.modTime.IsZero() {
				continue
			}
			delta := candidate.modTime.Sub(activity)
			if delta < 0 {
				delta = -delta
			}
			if delta <= piSessionActivityMatchTolerance {
				matches = append(matches, candidate)
			}
		}
		matchesByWindow[index] = piLeafSessionMatches(matches, candidates)
	}
	return uniquePiSessionAssignments(matchesByWindow)
}

func uniquePiSessionAssignments(
	matchesByWindow map[int][]piSessionEntry,
) map[int]piSessionEntry {
	claimants := map[string]int{}
	for _, matches := range matchesByWindow {
		for _, candidate := range matches {
			claimants[candidate.sessionID]++
		}
	}
	assignments := map[int]piSessionEntry{}
	for index, matches := range matchesByWindow {
		if len(matches) != 1 || claimants[matches[0].sessionID] != 1 {
			continue
		}
		assignments[index] = matches[0]
	}
	return assignments
}

func uniquePiSessionsByPaneTitle(
	restore *serverRestore,
	indices []int,
	candidates []piSessionEntry,
) map[int]piSessionEntry {
	matchesByWindow := map[int][]piSessionEntry{}
	for _, index := range indices {
		matches := []piSessionEntry{}
		for _, candidate := range candidates {
			if piSessionMatchesPaneTitle(candidate, restore.Windows[index].PaneTitle) {
				matches = append(matches, candidate)
			}
		}
		matchesByWindow[index] = piLeafSessionMatches(matches, candidates)
	}
	return uniquePiSessionAssignments(matchesByWindow)
}

func piSessionsWithLatestNamesForTitles(
	restore *serverRestore,
	indices []int,
	candidates []piSessionEntry,
) []piSessionEntry {
	if len(candidates) == 0 {
		return candidates
	}
	hasNamedTitle := false
	for _, index := range indices {
		title := cleanTerminalTitle(restore.Windows[index].PaneTitle)
		if strings.HasPrefix(title, "π - ") || strings.HasPrefix(title, "Pi - ") {
			hasNamedTitle = true
			break
		}
	}
	if !hasNamedTitle {
		return candidates
	}
	result := append([]piSessionEntry(nil), candidates...)
	for i := range result {
		if name, found := piLatestSessionName(result[i].path); found {
			result[i].sessionName = name
		}
	}
	return result
}

func piSessionMatchesPaneTitle(entry piSessionEntry, paneTitle string) bool {
	name := strings.TrimSpace(entry.sessionName)
	titleCwd := firstNonEmptyString(entry.rawCwd, entry.cwd)
	cwdName := filepath.Base(strings.TrimSpace(titleCwd))
	if name == "" || cwdName == "" {
		return false
	}
	title := cleanTerminalTitle(paneTitle)
	wantSuffix := " - " + name + " - " + cwdName
	return title == cleanTerminalTitle("π"+wantSuffix) ||
		title == cleanTerminalTitle("Pi"+wantSuffix)
}

func piSessionCwdMatchesPaneTitle(entry piSessionEntry, paneTitle string) bool {
	titleCwd := firstNonEmptyString(entry.rawCwd, entry.cwd)
	cwdName := filepath.Base(strings.TrimSpace(titleCwd))
	if cwdName == "" {
		return false
	}
	title := cleanTerminalTitle(paneTitle)
	wantSuffix := " - " + cwdName
	return title == cleanTerminalTitle("π"+wantSuffix) ||
		title == cleanTerminalTitle("Pi"+wantSuffix)
}

func piSessionsCreatedForProcessStart(
	entries []piSessionEntry,
	processStarted time.Time,
) []piSessionEntry {
	if processStarted.IsZero() {
		return nil
	}
	matches := []piSessionEntry{}
	for _, entry := range entries {
		// A relocated session's own timestamp records the relocation, not the
		// launch, so correlate the process start against the chain origin.
		createdAt := entry.originCreatedAt
		if createdAt.IsZero() {
			createdAt = entry.createdAt
		}
		if createdAt.IsZero() {
			continue
		}
		if !createdAt.Before(processStarted.Add(-2*time.Second)) &&
			!createdAt.After(processStarted.Add(10*time.Second)) {
			matches = append(matches, entry)
		}
	}
	return matches
}

// piLeafSessionMatches drops matches that another match descends from. Both
// rotation (/new, /resume) and worktree relocation record the file they came
// from as parentSession, so a match that a sibling match links back to is a
// session the pane has already left; the surviving leaf is where it is now.
// Forks branch from a shared parent without superseding each other, so a
// branched history keeps every leaf and stays ambiguous.
func piLeafSessionMatches(matches []piSessionEntry, entries []piSessionEntry) []piSessionEntry {
	if len(matches) < 2 {
		return matches
	}
	parentByPath := make(map[string]string, len(entries))
	for _, entry := range entries {
		parentByPath[entry.path] = entry.parentPath
	}
	matchedPaths := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		matchedPaths[match.path] = struct{}{}
	}
	ancestors := map[string]struct{}{}
	for _, match := range matches {
		seen := map[string]struct{}{}
		for parent := match.parentPath; parent != ""; parent = parentByPath[parent] {
			if _, ok := seen[parent]; ok {
				break
			}
			seen[parent] = struct{}{}
			if _, ok := matchedPaths[parent]; ok {
				ancestors[parent] = struct{}{}
			}
		}
	}
	leaves := make([]piSessionEntry, 0, len(matches))
	for _, match := range matches {
		if _, ok := ancestors[match.path]; ok {
			continue
		}
		leaves = append(leaves, match)
	}
	return leaves
}

// piSessionWasSuperseded prevents the process's initial session from winning
// after Pi rotates to another session via /new or /resume. Sessions uniquely
// owned by another pane's process-start match are ignored; any other same-cwd
// file written later makes the current pane ambiguous and therefore fresh.
func piSessionWasSuperseded(
	entries []piSessionEntry,
	candidate piSessionEntry,
	processStarted time.Time,
	ownedSessionIDs map[string]bool,
) bool {
	if processStarted.IsZero() {
		return true
	}
	for _, entry := range entries {
		if entry.sessionID == candidate.sessionID || ownedSessionIDs[entry.sessionID] {
			continue
		}
		if entry.modTime.Before(processStarted.Add(-2 * time.Second)) {
			continue
		}
		if entry.modTime.After(candidate.modTime) ||
			(!entry.createdAt.IsZero() &&
				entry.createdAt.After(processStarted.Add(10*time.Second)) &&
				!entry.modTime.Before(candidate.modTime)) {
			return true
		}
	}
	return false
}

func piProcessesByPane(
	processes map[int]processInfo,
	panePids map[int]struct{},
	knownPiPanePids map[int]struct{},
) map[int]processInfo {
	return uniqueShallowestProcessesByPane(processes, panePids, func(panePid int, command string) bool {
		_, knownPiPane := knownPiPanePids[panePid]
		return agentToolFromCommandName(command) == "pi" ||
			(knownPiPane && isGenericRuntimeCommandName(command))
	})
}

func processDepthFromAncestor(processes map[int]processInfo, pid int, ancestor int) int {
	seen := map[int]struct{}{}
	depth := 0
	for current := pid; current > 0; depth++ {
		if current == ancestor {
			return depth
		}
		if _, ok := seen[current]; ok {
			return -1
		}
		seen[current] = struct{}{}
		process, ok := processes[current]
		if !ok {
			return -1
		}
		current = process.ppid
	}
	return -1
}

func piSessionFromProcessArgs(args string, cwd string) (piSessionEntry, bool) {
	sessionArgument := strings.TrimSpace(agentSessionIDFromArgs("pi", args))
	if sessionArgument == "" {
		return piSessionEntry{}, false
	}
	if strings.ContainsAny(sessionArgument, "/\\") ||
		strings.HasSuffix(strings.ToLower(sessionArgument), ".jsonl") {
		return readPiSessionEntry(normalizedPiSessionDirectory(sessionArgument, cwd))
	}
	if !safePiSessionIDPattern.MatchString(sessionArgument) {
		return piSessionEntry{}, false
	}
	root := piSessionDirFromArgs(args, cwd)
	if root == "" {
		root = piSessionRootForWorkingDirectory(cwd)
	}
	for _, entry := range readPiSessionEntries(root) {
		if entry.sessionID == sessionArgument {
			return entry, true
		}
	}
	return piSessionEntry{}, false
}

func piSessionFromOpenFiles(pid int) (piSessionEntry, bool) {
	matches := map[string]piSessionEntry{}
	for _, path := range processOpenFilePathsForMetadata(pid) {
		if !strings.HasSuffix(strings.ToLower(path), ".jsonl") {
			continue
		}
		if entry, ok := readPiSessionEntry(path); ok {
			matches[entry.sessionID] = entry
		}
	}
	if len(matches) != 1 {
		return piSessionEntry{}, false
	}
	for _, entry := range matches {
		return entry, true
	}
	return piSessionEntry{}, false
}

func readPiSessionEntries(root string) []piSessionEntry {
	root = strings.TrimSpace(root)
	if root == "" {
		return nil
	}
	entries := []piSessionEntry{}
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		depth := 0
		if relative != "." {
			depth = len(strings.Split(relative, string(filepath.Separator)))
		}
		if entry.IsDir() {
			if depth >= 2 {
				return filepath.SkipDir
			}
			return nil
		}
		if depth > 2 || !strings.HasSuffix(strings.ToLower(entry.Name()), ".jsonl") {
			return nil
		}
		if session, ok := readPiSessionEntry(path); ok {
			entries = append(entries, session)
		}
		return nil
	})
	annotatePiSessionOrigins(entries)
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].modTime.After(entries[j].modTime) })
	return entries
}

func piSessionRootForWorkingDirectory(cwd string) string {
	if configured := strings.TrimSpace(os.Getenv("PI_CODING_AGENT_SESSION_DIR")); configured != "" {
		return normalizedPiSessionDirectory(configured, cwd)
	}
	agentDirectory := strings.TrimSpace(os.Getenv("PI_CODING_AGENT_DIR"))
	if agentDirectory == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		agentDirectory = filepath.Join(home, ".pi", "agent")
	} else {
		agentDirectory = normalizedPiSessionDirectory(agentDirectory, cwd)
	}
	setting := readPiSessionDirectorySetting(filepath.Join(agentDirectory, "settings.json"))
	projectDirectory := normalizedWorkingDirectory(cwd)
	if projectDirectory != "" {
		if projectSetting := readPiSessionDirectorySetting(filepath.Join(projectDirectory, ".pi", "settings.json")); projectSetting != "" {
			setting = projectSetting
		}
	}
	if setting != "" {
		return normalizedPiSessionDirectory(setting, cwd)
	}
	return filepath.Join(agentDirectory, "sessions")
}

func readPiSessionDirectorySetting(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var settings struct {
		SessionDir string `json:"sessionDir"`
	}
	if json.Unmarshal(data, &settings) != nil {
		return ""
	}
	return strings.TrimSpace(settings.SessionDir)
}

func piSessionDirFromArgs(args string, cwd string) string {
	match := piSessionDirArgumentPattern.FindStringSubmatch(args)
	if match == nil {
		return ""
	}
	for _, group := range match[1:] {
		if value := strings.TrimSpace(group); value != "" {
			return normalizedPiSessionDirectory(value, cwd)
		}
	}
	return ""
}

func normalizedPiSessionDirectory(path string, cwd string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	if expanded, err := expandHomePath(trimmed); err == nil {
		trimmed = expanded
	}
	if !filepath.IsAbs(trimmed) {
		base := normalizedWorkingDirectory(cwd)
		if base == "" {
			if absolute, err := filepath.Abs(trimmed); err == nil {
				return filepath.Clean(absolute)
			}
			return filepath.Clean(trimmed)
		}
		trimmed = filepath.Join(base, trimmed)
	}
	return filepath.Clean(trimmed)
}

func readPiSessionEntry(path string) (piSessionEntry, bool) {
	file, err := os.Open(path)
	if err != nil {
		return piSessionEntry{}, false
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return piSessionEntry{}, false
	}
	reader := bufio.NewReaderSize(file, 64*1024)
	scannedBytes := 0
	for scannedBytes < piSessionHeaderScanLimitBytes {
		line, truncated, bytesRead, readErr := readBoundedLine(
			reader,
			piSessionMetadataRecordLimitBytes,
		)
		scannedBytes += bytesRead
		if readErr != nil {
			return piSessionEntry{}, false
		}
		if scannedBytes > piSessionHeaderScanLimitBytes || truncated || len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var metadata struct {
			Type          string `json:"type"`
			ID            string `json:"id"`
			Timestamp     string `json:"timestamp"`
			Cwd           string `json:"cwd"`
			ParentSession string `json:"parentSession"`
		}
		if json.Unmarshal(line, &metadata) != nil || metadata.Type != "session" {
			continue
		}
		entry := piSessionEntry{
			sessionID: strings.TrimSpace(metadata.ID),
			rawCwd:    filepath.Clean(strings.TrimSpace(metadata.Cwd)),
			cwd:       normalizedWorkingDirectory(metadata.Cwd),
			path:      filepath.Clean(path),
			modTime:   info.ModTime(),
		}
		if entry.sessionID == "" || entry.cwd == "" {
			return piSessionEntry{}, false
		}
		entry.createdAt, _ = time.Parse(
			time.RFC3339Nano,
			strings.TrimSpace(metadata.Timestamp),
		)
		if parent := strings.TrimSpace(metadata.ParentSession); parent != "" {
			entry.parentPath = filepath.Clean(parent)
		}
		entry.originDir = filepath.Base(filepath.Dir(entry.path))
		entry.originCreatedAt = entry.createdAt
		return entry, true
	}
	return piSessionEntry{}, false
}

// readBoundedLine consumes exactly one JSONL record without retaining more than
// limit bytes. Oversized message/image records are drained through their newline
// so later metadata remains readable.
func readBoundedLine(reader *bufio.Reader, limit int) ([]byte, bool, int, error) {
	line := make([]byte, 0, min(limit, 64*1024))
	truncated := false
	bytesRead := 0
	for {
		fragment, err := reader.ReadSlice('\n')
		bytesRead += len(fragment)
		if remaining := limit - len(line); remaining > 0 {
			if len(fragment) > remaining {
				line = append(line, fragment[:remaining]...)
				truncated = true
			} else {
				line = append(line, fragment...)
			}
		} else if len(fragment) > 0 {
			truncated = true
		}
		switch {
		case err == nil:
			return bytes.TrimSuffix(line, []byte{'\n'}), truncated, bytesRead, nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		case errors.Is(err, io.EOF) && bytesRead > 0:
			return line, truncated, bytesRead, nil
		default:
			return nil, truncated, bytesRead, err
		}
	}
}

// piLatestSessionName mirrors Pi's last-session_info-wins behavior. Empty names
// are authoritative clears. Oversized unrelated records are skipped, while an
// actual I/O error makes the name unusable rather than accepting stale metadata.
func piLatestSessionName(path string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer file.Close()
	reader := bufio.NewReaderSize(file, 64*1024)
	name := ""
	found := false
	for {
		line, truncated, _, readErr := readBoundedLine(
			reader,
			piSessionMetadataRecordLimitBytes,
		)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return name, found
			}
			return "", false
		}
		if truncated {
			continue
		}
		var metadata struct {
			Type string `json:"type"`
			Name string `json:"name"`
		}
		if json.Unmarshal(line, &metadata) == nil && metadata.Type == "session_info" {
			name = strings.TrimSpace(metadata.Name)
			found = true
		}
	}
}

// piEncodedSessionDirName mirrors Pi's session bucket naming: the resolved
// cwd with its leading separator stripped and every path separator or drive
// colon replaced by "-", wrapped in "--". A deleted origin file's bucket name
// therefore still identifies the working directory it was created in.
func piEncodedSessionDirName(cwd string) string {
	resolved := normalizedWorkingDirectory(cwd)
	if resolved == "" {
		return ""
	}
	if resolved[0] == '/' || resolved[0] == '\\' {
		resolved = resolved[1:]
	}
	replaced := strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(resolved)
	return "--" + replaced + "--"
}

// piSessionFileTimestampPattern matches Pi's session file name prefix
// (an RFC3339 timestamp with ":" and "." replaced by "-").
var piSessionFileTimestampPattern = regexp.MustCompile(
	`^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z_`,
)

func piSessionCreatedAtFromFileName(name string) time.Time {
	match := piSessionFileTimestampPattern.FindStringSubmatch(name)
	if match == nil {
		return time.Time{}
	}
	fields := make([]int, 0, 7)
	for _, group := range match[1:] {
		value, err := strconv.Atoi(group)
		if err != nil {
			return time.Time{}
		}
		fields = append(fields, value)
	}
	return time.Date(
		fields[0],
		time.Month(fields[1]),
		fields[2],
		fields[3],
		fields[4],
		fields[5],
		fields[6]*int(time.Millisecond),
		time.UTC,
	)
}

// annotatePiSessionOrigins resolves each entry's parentSession chain to its
// origin. Intermediate links may still exist on disk (rotation via /new keeps
// the old file) or may be gone (worktree relocation deletes it); a missing
// link terminates the chain with the directory name and file-name timestamp
// taken from the dangling path itself.
func annotatePiSessionOrigins(entries []piSessionEntry) {
	byPath := map[string]int{}
	for i := range entries {
		byPath[entries[i].path] = i
	}
	for i := range entries {
		seen := map[int]struct{}{}
		current := i
		for {
			if _, ok := seen[current]; ok {
				break
			}
			seen[current] = struct{}{}
			parent := entries[current].parentPath
			if parent == "" {
				entries[i].originDir = filepath.Base(filepath.Dir(entries[current].path))
				entries[i].originCreatedAt = entries[current].createdAt
				break
			}
			if next, ok := byPath[parent]; ok {
				current = next
				continue
			}
			entries[i].originDir = filepath.Base(filepath.Dir(parent))
			if createdAt := piSessionCreatedAtFromFileName(filepath.Base(parent)); !createdAt.IsZero() {
				entries[i].originCreatedAt = createdAt
			}
			break
		}
	}
}

func agentToolCandidateForRestore(window restoreWindowState) string {
	// Explicit metadata is authoritative, including confirmed plain shells.
	// Do not replace a retired tool with one guessed from a window's label.
	if tool := strings.TrimSpace(window.AgentTool); tool != "" || window.AgentToolConfirmed {
		return agentToolFromCommandName(tool)
	}
	return firstNonEmptyString(
		agentToolFromCommandName(window.CurrentCommand),
		agentToolFromTerminalTitle(window.PaneTitle),
		agentToolFromCommandName(window.Name),
	)
}

func agentToolForRestore(window restoreWindowState) string {
	tool := agentToolCandidateForRestore(window)
	if tool == "pi" &&
		strings.TrimSpace(window.CurrentCommand) != "" &&
		isShellCommandName(window.CurrentCommand) &&
		!window.AgentToolConfirmed {
		return ""
	}
	return tool
}

type processInfo struct {
	pid  int
	ppid int
	pgid int
	comm string
	args string
}

type processTableCache struct {
	mu        sync.Mutex
	loadedAt  time.Time
	processes map[int]processInfo
}

var commandProcessTableCache processTableCache

var processOpenFilePathsForMetadata = defaultProcessOpenFilePathsForMetadata

var processWorkingDirectoryForMetadata = defaultProcessWorkingDirectoryForMetadata

func cachedProcessTable(now time.Time) map[int]processInfo {
	commandProcessTableCache.mu.Lock()
	defer commandProcessTableCache.mu.Unlock()
	if !commandProcessTableCache.loadedAt.IsZero() &&
		now.Sub(commandProcessTableCache.loadedAt) < processMetadataInterval {
		return commandProcessTableCache.processes
	}
	started := time.Now()
	processes := readProcessTable()
	commandProcessTableCache.processes = processes
	commandProcessTableCache.loadedAt = now
	if processes == nil {
		commandProcessTableCache.loadedAt = now.Add(time.Since(started))
	}
	return processes
}

func discoverCopilotSessionIDs(
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	stateDir := filepath.Join(home, ".copilot", "session-state")
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return nil
	}
	sessions := map[int]string{}
	chosenModTime := map[int]time.Time{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(stateDir, entry.Name())
		locks, err := filepath.Glob(filepath.Join(dir, "inuse.*.lock"))
		if err != nil {
			continue
		}
		for _, lock := range locks {
			pid := pidFromCopilotLockPath(lock)
			if pid <= 0 {
				continue
			}
			process, ok := processes[pid]
			if !ok || !strings.Contains(strings.ToLower(process.comm+" "+process.args), "copilot") {
				continue
			}
			panePid := ancestorPanePID(processes, pid, panePids)
			if panePid <= 0 {
				continue
			}
			// When more than one session dir maps to the same pane — a stale
			// inuse lock whose PID was reused by a live copilot, or a session
			// left behind by an earlier resume — keep the most recently locked
			// one so a restored window resumes the live session rather than an
			// abandoned one.
			modTime := copilotLockModTime(lock)
			if !sessionUpdatedDuringProcess(modTime, processStartedAtForMetadata(pid)) {
				continue
			}
			if previous, exists := chosenModTime[panePid]; exists && !modTime.After(previous) {
				continue
			}
			sessions[panePid] = entry.Name()
			chosenModTime[panePid] = modTime
		}
	}
	return sessions
}

// copilotLockModTime reports when a copilot inuse lock was last written, used to
// prefer the freshest session dir when several map to the same pane.
func copilotLockModTime(lock string) time.Time {
	if info, err := os.Stat(lock); err == nil {
		return info.ModTime()
	}
	return time.Time{}
}

type copilotSessionEntry struct {
	id        string
	updatedAt time.Time
}

// copilotSessionsByWorkingDirectory groups on-disk copilot sessions by the
// working directory recorded in each session's events log, most recently
// active first. It supplements authoritative inuse-lock discovery only with
// sessions updated during the window's current process lifetime.
func copilotSessionsByWorkingDirectory() map[string][]copilotSessionEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	stateDir := filepath.Join(home, ".copilot", "session-state")
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return nil
	}
	byDirectory := map[string][]copilotSessionEntry{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		eventsPath := filepath.Join(stateDir, entry.Name(), "events.jsonl")
		workingDirectory := copilotSessionWorkingDirectory(eventsPath)
		if workingDirectory == "" {
			continue
		}
		modTime := time.Time{}
		if info, err := os.Stat(eventsPath); err == nil {
			modTime = info.ModTime()
		}
		byDirectory[workingDirectory] = append(
			byDirectory[workingDirectory],
			copilotSessionEntry{id: entry.Name(), updatedAt: modTime},
		)
	}
	for _, list := range byDirectory {
		sort.SliceStable(list, func(i, j int) bool {
			return list[i].updatedAt.After(list[j].updatedAt)
		})
	}
	return byDirectory
}

// copilotSessionWorkingDirectory returns the normalized working directory a
// copilot session started in, read from the session.start event at the head of
// its events log.
func copilotSessionWorkingDirectory(eventsPath string) string {
	file, err := os.Open(eventsPath)
	if err != nil {
		return ""
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	// The cwd is recorded on the session.start event, which heads the log; scan
	// a few lines defensively in case an unrelated event ever comes first.
	for scanned := 0; scanned < 8; scanned++ {
		line, err := reader.ReadString('\n')
		if strings.TrimSpace(line) != "" {
			var raw struct {
				Data struct {
					Context struct {
						Cwd string `json:"cwd"`
					} `json:"context"`
				} `json:"data"`
			}
			if json.Unmarshal([]byte(line), &raw) == nil {
				if cwd := normalizedWorkingDirectory(raw.Data.Context.Cwd); cwd != "" {
					return cwd
				}
			}
		}
		if err != nil {
			break
		}
	}
	return ""
}

// normalizedWorkingDirectory canonicalizes a working directory so a
// window's cwd and a session's recorded cwd compare equal despite ~ expansion
// or symlinks (for example /tmp vs /private/tmp on macOS).
func normalizedWorkingDirectory(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	if expanded, err := expandHomePath(trimmed); err == nil {
		trimmed = expanded
	}
	cleaned := filepath.Clean(trimmed)
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		return resolved
	}
	return cleaned
}

// assignCopilotSessionsByWorkingDirectory is the on-disk fallback for restored
// Copilot windows whose inuse lock could not identify a session. It considers
// only sessions updated during that window process and uses terminal activity
// to disambiguate multiple candidates. Stale or overlapping evidence stays
// fresh; sessions claimed by another window are never reused.
func assignCopilotSessionsByWorkingDirectory(
	restore *serverRestore,
	processes map[int]processInfo,
	panePids map[int]struct{},
) {
	if restore == nil {
		return
	}
	sessionsByDirectory := copilotSessionsByWorkingDirectory()
	if len(sessionsByDirectory) == 0 {
		return
	}
	used := map[string]bool{}
	for i := range restore.Windows {
		if id := strings.TrimSpace(restore.Windows[i].AgentSessionID); id != "" {
			used[id] = true
		}
	}
	liveProcesses := agentProcessesByPane(processes, panePids, "copilot")
	matchesByWindow := map[int][]copilotSessionEntry{}
	for i := range restore.Windows {
		if strings.TrimSpace(restore.Windows[i].AgentSessionID) != "" ||
			agentToolForRestore(restore.Windows[i]) != "copilot" {
			continue
		}
		process, ok := liveProcesses[restore.Windows[i].PanePid]
		if !ok {
			continue
		}
		workingDirectory := normalizedWorkingDirectory(restore.Windows[i].Cwd)
		if workingDirectory == "" {
			continue
		}
		processStarted := processStartedAtForMetadata(process.pid)
		candidates := []copilotSessionEntry{}
		for _, session := range sessionsByDirectory[workingDirectory] {
			if used[session.id] ||
				!sessionUpdatedDuringProcess(session.updatedAt, processStarted) {
				continue
			}
			candidates = append(candidates, session)
		}
		if len(candidates) > 1 && restore.Windows[i].LastActivityEpochSeconds > 0 {
			activity := time.Unix(restore.Windows[i].LastActivityEpochSeconds, 0)
			activityMatches := candidates[:0]
			for _, candidate := range candidates {
				delta := candidate.updatedAt.Sub(activity)
				if delta < 0 {
					delta = -delta
				}
				if delta <= piSessionActivityMatchTolerance {
					activityMatches = append(activityMatches, candidate)
				}
			}
			candidates = activityMatches
		}
		matchesByWindow[i] = candidates
	}
	for index, session := range uniqueCopilotSessionAssignments(matchesByWindow) {
		restore.Windows[index].AgentSessionID = session.id
	}
}

func uniqueCopilotSessionAssignments(
	matchesByWindow map[int][]copilotSessionEntry,
) map[int]copilotSessionEntry {
	claimants := map[string]int{}
	for _, matches := range matchesByWindow {
		for _, candidate := range matches {
			claimants[candidate.id]++
		}
	}
	assignments := map[int]copilotSessionEntry{}
	for index, matches := range matchesByWindow {
		if len(matches) != 1 || claimants[matches[0].id] != 1 {
			continue
		}
		assignments[index] = matches[0]
	}
	return assignments
}

func agentProcessesByPane(
	processes map[int]processInfo,
	panePids map[int]struct{},
	tool string,
) map[int]processInfo {
	return uniqueShallowestProcessesByPane(processes, panePids, func(_ int, command string) bool {
		return agentToolFromCommandName(command) == tool
	})
}

func uniqueShallowestProcessesByPane(
	processes map[int]processInfo,
	panePids map[int]struct{},
	match func(panePid int, command string) bool,
) map[int]processInfo {
	selected := map[int]processInfo{}
	minimumDepth := map[int]int{}
	minimumDepthCount := map[int]int{}
	for _, process := range processes {
		panePid := ancestorPanePID(processes, process.pid, panePids)
		if panePid <= 0 {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if !match(panePid, command) {
			continue
		}
		depth := processDepthFromAncestor(processes, process.pid, panePid)
		if depth < 0 {
			continue
		}
		priorDepth, exists := minimumDepth[panePid]
		if !exists || depth < priorDepth {
			minimumDepth[panePid] = depth
			minimumDepthCount[panePid] = 1
			selected[panePid] = process
			continue
		}
		if depth == priorDepth {
			minimumDepthCount[panePid]++
		}
	}
	for panePid, count := range minimumDepthCount {
		if count != 1 {
			delete(selected, panePid)
		}
	}
	return selected
}

func agentWorkingDirectoryForMetadata(
	processPID int,
	panePID int,
	fallbackWorkingDirectories []map[int]string,
) string {
	if workingDirectory := normalizedMetadataPath(
		processWorkingDirectoryForMetadata(processPID),
	); workingDirectory != "" {
		return workingDirectory
	}
	if len(fallbackWorkingDirectories) == 0 {
		return ""
	}
	return normalizedMetadataPath(fallbackWorkingDirectories[0][panePID])
}

func discoverAgentSessionIDs(
	tool string,
	processes map[int]processInfo,
	panePids map[int]struct{},
	fallbackWorkingDirectories ...map[int]string,
) map[int]string {
	var decodeFile func(string) string
	var recentSession func(string, time.Time) string
	switch tool {
	case "codex":
		decodeFile = codexSessionIDFromRolloutFile
		recentSession = codexRecentSessionIDForWorkingDirectory
	case "claude":
		decodeFile = claudeSessionIDFromProjectFile
		recentSession = claudeRecentSessionIDForWorkingDirectory
	case "opencode":
		var entries []openCodeSessionEntry
		loaded := false
		recentSession = func(directory string, started time.Time) string {
			if !loaded {
				entries = readOpenCodeSessionEntries()
				loaded = true
			}
			return openCodeSessionIDForWorkingDirectory(entries, directory, started)
		}
	default:
		return nil
	}
	type unresolvedProcess struct {
		panePid          int
		workingDirectory string
		processStarted   time.Time
	}
	sessions := map[int]string{}
	unresolved := []unresolvedProcess{}
	workingDirectoryCounts := map[string]int{}
	for panePid, process := range agentProcessesByPane(processes, panePids, tool) {
		workingDirectory := agentWorkingDirectoryForMetadata(
			process.pid, panePid, fallbackWorkingDirectories,
		)
		if workingDirectory != "" {
			workingDirectoryCounts[workingDirectory]++
		}
		sessionID := agentSessionIDFromArgs(tool, process.args)
		if sessionID == "" && decodeFile != nil {
			for _, path := range processOpenFilePathsForMetadata(process.pid) {
				if sessionID = decodeFile(path); sessionID != "" {
					break
				}
			}
		}
		if sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		processStarted := processStartedAtForMetadata(process.pid)
		if workingDirectory != "" && !processStarted.IsZero() {
			unresolved = append(unresolved, unresolvedProcess{panePid, workingDirectory, processStarted})
		}
	}
	for _, candidate := range unresolved {
		if workingDirectoryCounts[candidate.workingDirectory] != 1 {
			continue
		}
		if sessionID := recentSession(candidate.workingDirectory, candidate.processStarted); sessionID != "" {
			sessions[candidate.panePid] = sessionID
		}
	}
	return sessions
}

func codexRecentSessionIDForWorkingDirectory(
	workingDirectory string,
	processStarted time.Time,
) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" || processStarted.IsZero() {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	sessionsDir := filepath.Join(home, ".codex", "sessions")
	for _, path := range recentAgentSessionFiles(sessionsDir, 30, isCodexRolloutPath) {
		info, err := os.Stat(path)
		if err != nil || !sessionUpdatedDuringProcess(info.ModTime(), processStarted) {
			continue
		}
		if normalizedMetadataPath(codexRolloutWorkingDirectory(path)) != workingDirectory {
			continue
		}
		if sessionID := codexSessionIDFromRolloutFile(path); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func codexRolloutWorkingDirectory(path string) string {
	if !isCodexRolloutPath(path) {
		return ""
	}
	return jsonStringFieldFromFile(path, "cwd")
}

func codexSessionIDFromRolloutFile(path string) string {
	if !isCodexRolloutPath(path) {
		return ""
	}
	if sessionID := codexSessionIDFromRolloutName(filepath.Base(path)); sessionID != "" {
		return sessionID
	}
	if sessionID := jsonStringFieldFromFile(path, "id"); sessionID != "" {
		return sessionID
	}
	return ""
}

func isCodexRolloutPath(path string) bool {
	normalized := filepath.ToSlash(path)
	if !strings.Contains(normalized, "/.codex/sessions/") {
		return false
	}
	name := filepath.Base(path)
	return strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl")
}

func codexSessionIDFromRolloutName(name string) string {
	match := codexSessionIDPattern.FindStringSubmatch(name)
	if len(match) > 1 {
		return match[1]
	}
	return ""
}

// ── OpenCode ───────────────────────────────────────────────────────────────
// OpenCode persists sessions in a SQLite store keyed by working directory, so
// a session launched fresh (`opencode`, no `--session`) carries no resumable
// ID in its process arguments. Recover only a same-directory row updated during
// the current OpenCode process so an older project session is never injected.

type openCodeSessionEntry struct {
	sessionID string
	directory string
	updatedAt time.Time
}

// openCodeSessionEntriesReader is overridable in tests so the SQLite-backed
// lookup can be stubbed without a live OpenCode database.
var openCodeSessionEntriesReader = defaultOpenCodeSessionEntries

func readOpenCodeSessionEntries() []openCodeSessionEntry {
	return openCodeSessionEntriesReader()
}

func openCodeSessionIDForWorkingDirectory(
	entries []openCodeSessionEntry,
	workingDirectory string,
	processStarted time.Time,
) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" || processStarted.IsZero() {
		return ""
	}
	// entries are ordered most-recently-updated first.
	for _, entry := range entries {
		if entry.directory == workingDirectory &&
			sessionUpdatedDuringProcess(entry.updatedAt, processStarted) {
			return entry.sessionID
		}
	}
	return ""
}

// defaultOpenCodeSessionEntries reads the most recent top-level OpenCode
// sessions from its SQLite store. OpenCode keeps recent writes in a WAL file,
// so the lookup shells out to sqlite3 (which the app already requires for
// OpenCode session discovery) instead of parsing the database file directly.
func defaultOpenCodeSessionEntries() []openCodeSessionEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	if _, err := os.Stat(dbPath); err != nil {
		return nil
	}
	sqlitePath, err := exec.LookPath("sqlite3")
	if err != nil {
		return nil
	}
	const separator = "\x1f"
	query := "SELECT id, directory, time_updated FROM session " +
		"WHERE parent_id IS NULL AND time_archived IS NULL " +
		"ORDER BY time_updated DESC LIMIT 200;"
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		sqlitePath,
		"-readonly",
		"-separator", separator,
		dbPath,
		query,
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	entries := []openCodeSessionEntry{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.SplitN(line, separator, 3)
		sessionID := strings.TrimSpace(parts[0])
		if sessionID == "" {
			continue
		}
		directory := ""
		if len(parts) > 1 {
			directory = normalizedMetadataPath(parts[1])
		}
		updatedAt := time.Time{}
		if len(parts) > 2 {
			updatedAt = unixDatabaseTime(parts[2])
		}
		entries = append(entries, openCodeSessionEntry{
			sessionID: sessionID,
			directory: directory,
			updatedAt: updatedAt,
		})
	}
	return entries
}

// ── Claude Code ──────────────────────────────────────────────────────────────
// Claude Code stores each session as
// `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. A freshly launched
// `claude` carries no `--resume` argument, so recover the session from the
// rollout file the process holds open, or a project file whose `cwd` matches
// the pane and which was written during this Claude process's lifetime.

var claudeSessionIDPattern = regexp.MustCompile(
	`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
)

func claudeRecentSessionIDForWorkingDirectory(
	workingDirectory string,
	processStarted time.Time,
) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" || processStarted.IsZero() {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	projectsDir := filepath.Join(home, ".claude", "projects")
	for _, path := range recentAgentSessionFiles(projectsDir, 60, isClaudeProjectSessionPath) {
		info, err := os.Stat(path)
		if err != nil || !sessionUpdatedDuringProcess(info.ModTime(), processStarted) {
			continue
		}
		if !claudeSessionMatchesWorkingDirectory(path, workingDirectory) {
			continue
		}
		if sessionID := claudeSessionIDFromProjectFile(path); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

// claudeSessionMatchesWorkingDirectory reports whether a project file belongs
// to a Claude session running in workingDirectory, which the caller has already
// normalized.
//
// The directory the file lives in is the signal to trust. Claude names it by
// encoding the session's working directory, and entering a git worktree *moves*
// the file into the worktree's project directory, so the name follows the
// session. The per-message `cwd` does not: it tracks the agent's shell, so a
// `cd` inside any tool call leaves the newest records naming a subdirectory,
// while a relocated session's opening records still name the directory it
// started in. Matching recorded values alone therefore missed every relocated
// session — no `--resume` after a helper upgrade — and could hand that session
// to an unrelated pane left behind in the original directory.
//
// Recorded directories stay the fallback for a project directory name this
// encoding cannot account for: a Claude release that names them differently
// must not cost every window its resume.
func claudeSessionMatchesWorkingDirectory(path string, workingDirectory string) bool {
	if workingDirectory == "" {
		return false
	}
	projectDir := claudeEncodedProjectDirName(filepath.Base(filepath.Dir(path)))
	if projectDir != "" && projectDir == claudeEncodedProjectDirName(workingDirectory) {
		return true
	}
	recorded := claudeRecordedWorkingDirectories(path)
	for _, dir := range recorded {
		// The project directory encodes a directory this very session recorded,
		// so the name is accounted for and names somewhere else: the session
		// has moved on from workingDirectory.
		if projectDir != "" && claudeEncodedProjectDirName(dir) == projectDir {
			return false
		}
	}
	for _, dir := range recorded {
		if normalizedMetadataPath(dir) == workingDirectory {
			return true
		}
	}
	return false
}

// claudeRecordedWorkingDirectories returns the distinct `cwd` values a session
// file records, read from its first and last sessionFileScanChunkBytes. A
// relocated session names its new directory from the move onwards, so the two
// ends together cover both the directory the session opened in and the one it
// is using now, however long the transcript in between grew.
func claudeRecordedWorkingDirectories(path string) []string {
	return jsonStringFieldValuesFromFileEnds(path, "cwd")
}

// claudeEncodedProjectDirName mirrors how Claude Code names the directory a
// session is stored in: every character outside [A-Za-z0-9] becomes "-", so
// `/work/project` lives in `~/.claude/projects/-work-project`. Encoding an
// already-encoded name is a no-op, so the same function normalizes both sides
// of the comparison even if Claude later preserves more characters.
func claudeEncodedProjectDirName(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	return strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			return r
		}
		return '-'
	}, trimmed)
}

func claudeSessionIDFromProjectFile(path string) string {
	if !isClaudeProjectSessionPath(path) {
		return ""
	}
	name := strings.TrimSuffix(filepath.Base(path), ".jsonl")
	if claudeSessionIDPattern.MatchString(name) {
		return name
	}
	if sessionID := jsonStringFieldFromFile(path, "sessionId"); claudeSessionIDPattern.MatchString(sessionID) {
		return sessionID
	}
	return ""
}

func isClaudeProjectSessionPath(path string) bool {
	normalized := filepath.ToSlash(path)
	if !strings.Contains(normalized, "/.claude/projects/") {
		return false
	}
	return strings.HasSuffix(normalized, ".jsonl")
}

// ── Shared agent session-file helpers ────────────────────────────────────────

// sessionUpdatedDuringProcess is the common safety boundary for cwd/history
// fallback. A store record from before the foreground process started cannot
// describe a fresh agent launched by that process.
func sessionUpdatedDuringProcess(updatedAt time.Time, processStarted time.Time) bool {
	return !updatedAt.IsZero() &&
		!processStarted.IsZero() &&
		!updatedAt.Before(processStarted.Add(-agentSessionStartTolerance))
}

func unixDatabaseTime(value string) time.Time {
	raw, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || raw <= 0 {
		return time.Time{}
	}
	switch {
	case raw >= 100_000_000_000_000_000:
		return time.Unix(0, raw)
	case raw >= 100_000_000_000_000:
		return time.UnixMicro(raw)
	case raw >= 100_000_000_000:
		return time.UnixMilli(raw)
	default:
		return time.Unix(raw, 0)
	}
}

// recentAgentSessionFiles returns up to limit matching files under root,
// ordered most-recently-modified first.
func recentAgentSessionFiles(
	root string,
	limit int,
	match func(path string) bool,
) []string {
	if limit <= 0 {
		return nil
	}
	type recentFile struct {
		path    string
		modTime time.Time
	}
	files := []recentFile{}
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry == nil || entry.IsDir() {
			return nil
		}
		if !match(path) {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return nil
		}
		files = append(files, recentFile{path: path, modTime: info.ModTime()})
		return nil
	})
	sort.Slice(files, func(i, j int) bool {
		return files[i].modTime.After(files[j].modTime)
	})
	if len(files) > limit {
		files = files[:limit]
	}
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.path)
	}
	return paths
}

func jsonStringFieldFromFile(path string, field string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		if value := jsonStringFieldFromLine(scanner.Text(), field); value != "" {
			return value
		}
	}
	return ""
}

// sessionFileScanChunkBytes bounds how much of each end of a session file is
// read when collecting a field's values. Agent transcripts grow into megabytes
// of tool output that says nothing about which pane owns the session.
const sessionFileScanChunkBytes = 256 * 1024

// jsonStringFieldValuesFromFileEnds returns the distinct values of field found
// in the first and last sessionFileScanChunkBytes of a JSONL file, in the order
// encountered. A single oversized record (a large tool result) can cut a chunk's
// scan short; callers treat the result as evidence collected, never as proof
// that no other value exists.
func jsonStringFieldValuesFromFileEnds(path string, field string) []string {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil
	}
	values := []string{}
	seen := map[string]bool{}
	collect := func(reader io.Reader, skipPartialRecord bool) {
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		if skipPartialRecord && !scanner.Scan() {
			return
		}
		for scanner.Scan() {
			value := jsonStringFieldFromLine(scanner.Text(), field)
			if value == "" || seen[value] {
				continue
			}
			seen[value] = true
			values = append(values, value)
		}
	}
	collect(io.LimitReader(file, sessionFileScanChunkBytes), false)
	// Scan the tail whenever the head did not cover the whole file.
	if info.Size() > sessionFileScanChunkBytes {
		if _, err := file.Seek(info.Size()-sessionFileScanChunkBytes, io.SeekStart); err == nil {
			collect(file, true)
		}
	}
	return values
}

func jsonStringFieldFromLine(line string, field string) string {
	var parsed any
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return ""
	}
	return jsonStringField(parsed, field)
}

func jsonStringField(value any, field string) string {
	switch typed := value.(type) {
	case map[string]any:
		if raw, ok := typed[field]; ok {
			if text, ok := raw.(string); ok {
				return strings.TrimSpace(text)
			}
		}
		for _, child := range typed {
			if text := jsonStringField(child, field); text != "" {
				return text
			}
		}
	case []any:
		for _, child := range typed {
			if text := jsonStringField(child, field); text != "" {
				return text
			}
		}
	}
	return ""
}

func defaultProcessOpenFilePathsForMetadata(pid int) []string {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"lsof",
		"-nP",
		"-p",
		strconv.Itoa(pid),
		"-Fn",
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	paths := []string{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "n") && len(line) > 1 {
			paths = append(paths, line[1:])
		}
	}
	return paths
}

func defaultProcessWorkingDirectoryForMetadata(pid int) string {
	if runtime.GOOS == "linux" {
		if target, err := os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "cwd")); err == nil {
			return target
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"lsof",
		"-nP",
		"-a",
		"-p",
		strconv.Itoa(pid),
		"-d",
		"cwd",
		"-Fn",
	).Output()
	if err != nil || ctx.Err() != nil {
		return ""
	}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "n") && len(line) > 1 {
			return line[1:]
		}
	}
	return ""
}

func normalizedMetadataPath(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	return filepath.Clean(trimmed)
}

func pidFromCopilotLockPath(path string) int {
	name := filepath.Base(path)
	if !strings.HasPrefix(name, "inuse.") || !strings.HasSuffix(name, ".lock") {
		return 0
	}
	pidText := strings.TrimSuffix(strings.TrimPrefix(name, "inuse."), ".lock")
	pid, err := strconv.Atoi(pidText)
	if err != nil {
		return 0
	}
	return pid
}

func ancestorPanePID(
	processes map[int]processInfo,
	pid int,
	panePids map[int]struct{},
) int {
	seen := map[int]struct{}{}
	for current := pid; current > 0; {
		if _, ok := panePids[current]; ok {
			return current
		}
		if _, ok := seen[current]; ok {
			return 0
		}
		seen[current] = struct{}{}
		process, ok := processes[current]
		if !ok {
			return 0
		}
		current = process.ppid
	}
	return 0
}

func sessionIDFromSelectedAgentProcessArgs(
	processes map[int]processInfo,
	panePid int,
	tool string,
) string {
	selected := agentProcessesByPane(
		processes,
		map[int]struct{}{panePid: {}},
		tool,
	)
	process, ok := selected[panePid]
	if !ok {
		return ""
	}
	return agentSessionIDFromArgs(tool, process.args)
}

func agentSessionIDFromArgs(tool string, args string) string {
	for _, pattern := range agentSessionIDArgumentPattern[tool] {
		match := pattern.FindStringSubmatch(args)
		if match == nil {
			continue
		}
		for _, group := range match[1:] {
			if strings.TrimSpace(group) != "" {
				return strings.TrimSpace(group)
			}
		}
	}
	return ""
}

func serveSession(
	session string,
	initialWindow createWindowOptions,
	restore *serverRestore,
	width int,
	height int,
) error {
	socket, err := socketPath(session)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return err
	}
	// Refuse to steal a socket for a fresh direct `serve` invocation. A
	// restore process is an already-approved replacement: the outgoing native
	// bridge host can republish its old socket during process startup, so remove
	// that race winner and retry the bind instead of silently attaching the old
	// bridge-only workspace.
	replacing := restore != nil && len(restore.Windows) > 0
	if _, err := queryRunningServerStatus(session); err == nil && !replacing {
		return fmt.Errorf("MonkeyMux session %q is already running", session)
	}
	var listener net.Listener
	for attempt := 0; attempt < 5; attempt++ {
		_ = os.Remove(socket)
		listener, err = net.Listen("unix", socket)
		if err == nil || !replacing {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		return err
	}
	disableUnixListenerUnlink(listener)
	identity, _ := socketFileIdentity(socket)
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		_ = listener.Close()
		removeSocketPathIfUnchanged(socket, identity)
		return err
	}
	defer func() {
		_ = listener.Close()
		removeSocketPathIfUnchanged(socket, identity)
		removeSessionPIDFile(session)
	}()
	_ = os.Chmod(socket, 0o600)

	server := newMuxServerWithSize(session, width, height)
	server.themeHint = append([]byte(nil), initialWindow.themeHint...)
	server.capabilityHint = append([]byte(nil), initialWindow.capabilityHint...)
	server.listener = listener
	server.socketPath = socket
	server.socketIdentity = identity
	if err := server.restoreOrCreateInitialWindow(restore, initialWindow); err != nil {
		return err
	}
	defer server.close()

	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	go func() {
		<-signals
		server.close()
	}()
	server.startSocketRepublisher()

	for {
		conn, err := server.acceptConnection()
		if err != nil {
			if server.isClosed() || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go server.handleConnection(conn)
	}
}

func newMuxServerWithSize(session string, width int, height int) *muxServer {
	if width <= 0 {
		width = defaultColumns
	}
	if height <= 0 {
		height = defaultRows
	}
	return &muxServer{
		session:         session,
		width:           width,
		height:          height,
		publishedWidth:  width,
		publishedHeight: height,
		attachClients:   map[net.Conn]*attachClient{},
		controls:        map[*controlClient]struct{}{},
	}
}

func readRestoreFile(path string) (*serverRestore, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var restore serverRestore
	if err := json.Unmarshal(data, &restore); err != nil {
		return nil, err
	}
	if restore.SchemaVersion != restoreSchemaVersion {
		return nil, fmt.Errorf("unsupported MonkeyMux restore schema %d", restore.SchemaVersion)
	}
	if isManagedRestoreFile(path) {
		_ = os.Remove(path)
	}
	return &restore, nil
}

func isManagedRestoreFile(path string) bool {
	absPath, err := filepath.Abs(path)
	if err != nil || !restoreFileNamePattern.MatchString(filepath.Base(absPath)) {
		return false
	}
	runDir, err := runtimeDirectory()
	if err != nil {
		return false
	}
	absRunDir, err := filepath.Abs(runDir)
	if err != nil {
		return false
	}
	return filepath.Dir(absPath) == absRunDir
}

func writeRestoreFile(session string, restore *serverRestore) (string, error) {
	runDir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(runDir, 0o700); err != nil {
		return "", err
	}
	data, err := json.Marshal(restore)
	if err != nil {
		return "", err
	}
	// Windows clocks can return the same UnixNano value for consecutive calls.
	// Create exclusively and advance the numeric suffix on collision so one
	// in-flight upgrade can never overwrite another snapshot.
	for suffix := time.Now().UnixNano(); ; suffix++ {
		path := filepath.Join(
			runDir,
			fmt.Sprintf(
				"monkeymux-restore-%s-%d.json",
				sessionToken(session),
				suffix,
			),
		)
		file, openErr := os.OpenFile(
			path,
			os.O_CREATE|os.O_EXCL|os.O_WRONLY,
			restoreFileMode,
		)
		if errors.Is(openErr, os.ErrExist) {
			continue
		}
		if openErr != nil {
			return "", openErr
		}
		_, writeErr := file.Write(data)
		closeErr := file.Close()
		if writeErr != nil || closeErr != nil {
			_ = os.Remove(path)
			return "", errors.Join(writeErr, closeErr)
		}
		return path, nil
	}
}

// sessionToken is a stable, whitespace-free identifier for a session name. It
// names restore snapshots and is passed to the server so its command line can
// identify the session it serves without depending on how argument boundaries
// survive being rendered as one string.
func sessionToken(session string) string {
	sum := sha256.Sum256([]byte(session))
	return hex.EncodeToString(sum[:])[:24]
}

func (s *muxServer) restoreOrCreateInitialWindow(
	restore *serverRestore,
	initialWindow createWindowOptions,
) error {
	if restore == nil || len(restore.Windows) == 0 {
		_, err := s.createWindow(initialWindow)
		return err
	}

	var activeID string
	var firstID string
	var pendingRedraw []string
	restored := 0
	for _, state := range restore.Windows {
		window, err := s.createWindow(
			createWindowOptionsForRestore(state, restore.StartInYoloMode),
		)
		if err != nil {
			continue
		}
		if firstID == "" {
			firstID = window.id
		}
		if state.Active {
			activeID = window.id
		}
		if s.windowUsesForegroundRedraw(window.id) {
			pendingRedraw = append(pendingRedraw, window.id)
		}
		restored++
	}
	if restored == 0 {
		_, err := s.createWindow(initialWindow)
		return err
	}
	s.markRestoreRedrawPending(pendingRedraw)
	if activeID == "" {
		activeID = firstID
	}
	if activeID != "" {
		_ = s.selectWindow(activeID)
	}
	return nil
}

func (s *muxServer) windowUsesForegroundRedraw(windowID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	window := s.windowByIDLocked(windowID)
	return window != nil && !window.closed && window.usesForegroundRedrawReplayLocked()
}

func (s *muxServer) markRestoreRedrawPending(windowIDs []string) {
	if len(windowIDs) == 0 {
		return
	}
	s.mu.Lock()
	if s.restoreRedrawPending == nil {
		s.restoreRedrawPending = make(map[string]bool, len(windowIDs))
	}
	for _, id := range windowIDs {
		s.restoreRedrawPending[id] = true
	}
	s.mu.Unlock()
}

// takeRestoreRedrawPending reports whether the window still needs post-restore
// redraw follow-ups and, if so, clears it so the follow-ups run only once.
func (s *muxServer) takeRestoreRedrawPending(windowID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.restoreRedrawPending[windowID] {
		return false
	}
	delete(s.restoreRedrawPending, windowID)
	return true
}

// scheduleRestoreRedrawFollowUps re-issues a forced foreground redraw for a
// freshly restored window a few times after it first becomes visible, so an
// agent that was still starting up when it first appeared is repainted without
// the user having to resize the terminal.
func (s *muxServer) scheduleRestoreRedrawFollowUps(windowID string) {
	s.mu.Lock()
	hasAttach := s.attachCountLocked() > 0
	s.mu.Unlock()
	if !hasAttach || !s.takeRestoreRedrawPending(windowID) {
		return
	}
	for _, delay := range restoreRedrawFollowUpDelays {
		scheduleRestoreRedraw(delay, func() {
			s.redrawRestoredWindow(windowID)
		})
	}
}

func (s *muxServer) redrawRestoredWindow(windowID string) {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	if s.attachCountLocked() == 0 || s.activeID != windowID {
		s.mu.Unlock()
		return
	}
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed || !window.supportsForegroundRedrawLocked() {
		s.mu.Unlock()
		return
	}
	width, height := s.primaryAttachSizeLocked()
	s.mu.Unlock()
	s.resizeWithRedraw(width, height, true, true, windowID)
}

// forceForegroundThemeRedraw makes [windowID] fully repaint after a theme
// change. A theme switch changes colors without changing the PTY size, so a real
// same-size SIGWINCH will not make the TUI re-emit explicitly-colored cells (e.g.
// Copilot CLI's header/footer bars). It therefore uses the synthetic width-1
// redraw dance — the same mechanism used to repaint a restored window — whose
// intermediate one-cell frame is hidden from attach clients by the
// synchronized-redraw transaction. It is pinned to [windowID] (the window that
// received the theme hint) and is a no-op if that window is no longer active
// (a concurrent switch will refresh the new window separately), is not a
// foreground-redraw window (plain shell), or when no client is attached.
func (s *muxServer) forceForegroundThemeRedraw(windowID string) {
	if windowID == "" {
		return
	}
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	if s.attachCountLocked() == 0 || s.activeID != windowID {
		s.mu.Unlock()
		return
	}
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed || !window.supportsForegroundRedrawLocked() {
		s.mu.Unlock()
		return
	}
	width, height := s.primaryAttachSizeLocked()
	s.mu.Unlock()
	if width <= 0 || height <= 0 {
		return
	}
	s.resizeWithRedraw(width, height, true, true, windowID)
}

func createWindowOptionsForRestore(
	state restoreWindowState,
	startInYoloMode bool,
) createWindowOptions {
	if validAcpBridgeID(state.NativeAcpBridgeID) &&
		validateAcpProviderID(state.NativeAcpProviderID) == nil {
		args, _ := nativeAcpWindowArguments(state.NativeAcpBridgeID)
		return createWindowOptions{
			name:                  firstNonEmptyString(state.Name, state.PaneTitle, "Native agent"),
			cwd:                   state.Cwd,
			args:                  args,
			paneTitle:             firstNonEmptyString(state.PaneTitle, state.Name),
			agentTool:             state.AgentTool,
			nativeAcpBridgeID:     state.NativeAcpBridgeID,
			nativeAcpProviderID:   state.NativeAcpProviderID,
			cursorVisible:         state.CursorVisible,
			cursorVisibilityKnown: state.CursorVisibilityKnown,
			privateModes:          privateModesForRestore(state.PrivateModes),
			terminalProgress:      copyTerminalProgressSnapshot(state.TerminalProgress),
		}
	}
	agentTool := agentToolForRestore(state)
	if agentTool == "" {
		state.AgentSessionID = ""
		state.AgentSessionDir = ""
		state.AgentSessionPath = ""
		state.AgentSessionIdentityExact = false
	}
	command := ""
	if agentTool != "" {
		launch := agentLaunchCommand(agentTool, startInYoloMode)
		if agentTool == "pi" {
			launch = piLaunchCommand(state.AgentSessionDir)
		}
		command = launch
		if sessionID := strings.TrimSpace(state.AgentSessionID); sessionID != "" {
			resume := agentResumeCommand(agentTool, sessionID, startInYoloMode)
			if agentTool == "pi" {
				resume = piResumeCommand(
					sessionID,
					state.AgentSessionDir,
					state.AgentSessionPath,
				)
				command = piResumeCommandWithFreshFallback(resume, launch)
			} else {
				command = agentResumeCommandWithFreshFallback(resume, launch)
			}
		}
	}
	history := []byte(nil)
	if isShellRestoreWindow(state) {
		history = decodeRestoreHistory(state.HistoryBase64)
		if !state.HistoryStartsAtGround {
			history = sanitizeLegacyRestoreHistory(history)
		}
		history = terminalHistoryAtGroundBoundaries(
			history,
			terminalOutputParserSnapshot{},
		)
		history = stripTerminalProgressFromRestoreHistory(history)
	}
	// CLI and shell restoration starts a new process. Its old task progress is
	// stale until the new process reports its own OSC 9;4 state. The native ACP
	// branch above preserves progress because its agent process keeps running.
	return createWindowOptions{
		name:                      firstNonEmptyString(state.Name, state.PaneTitle, state.CurrentCommand, "shell"),
		cwd:                       state.Cwd,
		command:                   command,
		history:                   history,
		paneTitle:                 firstNonEmptyString(state.PaneTitle, state.Name),
		agentTool:                 agentTool,
		agentToolConfirmed:        state.AgentToolConfirmed || strings.TrimSpace(state.AgentTool) != "",
		agentSessionID:            state.AgentSessionID,
		agentSessionDir:           state.AgentSessionDir,
		agentSessionPath:          state.AgentSessionPath,
		agentSessionIdentityExact: state.AgentSessionIdentityExact,
		cursorVisible:             state.CursorVisible,
		cursorVisibilityKnown:     state.CursorVisibilityKnown,
		privateModes:              privateModesForRestore(state.PrivateModes),
	}
}

func decodeRestoreHistory(encoded string) []byte {
	if strings.TrimSpace(encoded) == "" {
		return nil
	}
	history, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil
	}
	if len(history) > windowHistoryLimitBytes {
		return append([]byte(nil), history[len(history)-windowHistoryLimitBytes:]...)
	}
	return history
}

func isShellRestoreWindow(state restoreWindowState) bool {
	agentTool := agentToolForRestore(state)
	if agentTool != "" {
		return false
	}
	command := cleanProcessCommandName(state.CurrentCommand)
	return command == "" || isShellCommandName(command)
}

type createWindowOptions struct {
	name                      string
	cwd                       string
	command                   string
	args                      []string
	history                   []byte
	paneTitle                 string
	agentTool                 string
	agentToolConfirmed        bool
	agentSessionID            string
	agentSessionDir           string
	agentSessionPath          string
	agentSessionIdentityExact bool
	nativeAcpBridgeID         string
	nativeAcpProviderID       string
	cursorVisible             bool
	cursorVisibilityKnown     bool
	privateModes              map[string]bool
	terminalProgress          *terminalProgressSnapshot
	insertModeEnabled         bool
	insertModeKnown           bool
	applicationKeypadEnabled  bool
	applicationKeypadKnown    bool
	themeHint                 []byte
	capabilityHint            []byte
}

func newWindowAgentTool(
	options createWindowOptions,
	name string,
) (tool string, confirmed bool) {
	if options.agentToolConfirmed {
		return options.agentTool, true
	}
	commandTool := agentToolFromCommandText(options.command)
	tool = firstNonEmptyString(
		options.agentTool,
		commandTool,
		agentToolFromCommandName(name),
	)
	confirmed = strings.TrimSpace(options.agentTool) != "" || commandTool != ""
	return tool, confirmed
}

func (s *muxServer) createWindow(options createWindowOptions) (*muxWindow, error) {
	return s.createWindowWithStarter(options, startWindow)
}

// createWindowWithStarter lets lifecycle tests gate startup without global hooks.
func (s *muxServer) createWindowWithStarter(
	options createWindowOptions,
	start func(*exec.Cmd, int, int) (muxPty, muxProcess, error),
) (*muxWindow, error) {
	options.command = monkeyMuxAgentLaunchCommand(options.command)
	var replay []byte
	var snapshots []windowSnapshot
	var addedSnapshot *windowSnapshot
	var foregroundProcessGroup int
	var refreshPendingFocus bool
	var refreshPendingResize bool
	cwd := resolveStartupDirectory(options.cwd)

	shell := defaultShellPath()
	cmd := shellCommand(shell)
	name := filepath.Base(shell)
	if len(options.args) > 0 {
		cmd = exec.Command(options.args[0], options.args[1:]...)
		name = filepath.Base(options.args[0])
	} else if strings.TrimSpace(options.command) != "" {
		cmd = shellCommandForScript(shell, strings.TrimSpace(options.command))
	}
	if strings.TrimSpace(options.name) != "" {
		name = strings.TrimSpace(options.name)
	} else if strings.TrimSpace(options.command) != "" {
		name = firstShellWord(options.command)
	}
	agentTool, agentToolConfirmed := newWindowAgentTool(options, name)
	// Keep agent windows open when the agent exits abnormally right after
	// launching, so a fast startup failure (for example a locked macOS login
	// keychain that makes cursor-agent print an error and exit immediately)
	// stays on screen instead of the window closing before it can be read.
	if len(options.args) == 0 &&
		strings.TrimSpace(options.command) != "" &&
		agentTool != "" {
		cmd = shellCommandForScript(
			shell,
			holdAgentWindowCommand(shell, strings.TrimSpace(options.command)),
		)
	}
	paneTitle := firstNonEmptyString(options.paneTitle, name)
	cursorVisible := true
	if options.cursorVisibilityKnown {
		cursorVisible = options.cursorVisible
	}
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = terminalEnvironment(os.Environ())

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil, errServerClosed
	}
	s.pendingWindowStarts.Add(1)
	cols, rows := s.publishedWidth, s.publishedHeight
	s.mu.Unlock()

	windowPty, proc, err := start(cmd, cols, rows)
	if err != nil {
		s.pendingWindowStarts.Done()
		return nil, err
	}

	s.mu.Lock()
	if s.closed {
		// close() sets s.closed and snapshots s.windows under this same lock,
		// so a window registered from here on would never be torn down and its
		// watchers would join the group after close already waited. Tear the
		// freshly started process down instead of publishing it.
		s.mu.Unlock()
		go func() {
			defer s.pendingWindowStarts.Done()
			cleanupRejectedWindow(windowPty, proc)
		}()
		return nil, errServerClosed
	}
	// Registering the watchers here, rather than beside the `go` statements
	// below, keeps the count paired with the s.closed transition: once close()
	// observes s.closed it knows no further watchers can be added, so its Wait
	// cannot race an Add.
	s.windowWatchers.Add(2)
	s.pendingWindowStarts.Done() // Transfer ownership to the watchers under s.mu.
	s.nextID++
	window := &muxWindow{
		id:                        fmt.Sprintf("@%d", s.nextID),
		index:                     len(s.windows),
		name:                      name,
		cwd:                       cwd,
		command:                   filepath.Base(cmd.Path),
		agentTool:                 agentTool,
		agentToolConfirmed:        agentToolConfirmed,
		agentSessionID:            options.agentSessionID,
		agentSessionDir:           options.agentSessionDir,
		agentSessionPath:          options.agentSessionPath,
		agentSessionIdentityExact: options.agentSessionIdentityExact,
		nativeAcpBridgeID:         options.nativeAcpBridgeID,
		nativeAcpProviderID:       options.nativeAcpProviderID,
		foregroundPid:             proc.Pid(),
		foregroundCommand:         filepath.Base(cmd.Path),
		paneTitle:                 paneTitle,
		pty:                       windowPty,
		ptyWidth:                  cols,
		ptyHeight:                 rows,
		proc:                      proc,
		history:                   append([]byte(nil), options.history...),
		lastActivity:              time.Now(),
		cursorVisible:             cursorVisible,
		cursorVisibilityKnown:     options.cursorVisibilityKnown,
		privateModes:              copyPrivateModes(options.privateModes),
		terminalProgress:          copyTerminalProgressSnapshot(options.terminalProgress),
		insertModeEnabled:         options.insertModeEnabled,
		insertModeKnown:           options.insertModeKnown,
		applicationKeypadEnabled:  options.applicationKeypadEnabled,
		applicationKeypadKnown:    options.applicationKeypadKnown,
	}
	s.windows = append(s.windows, window)
	if s.activeID != "" && s.activeID != window.id {
		s.lastActiveID = s.activeID
	}
	s.activeID = window.id
	// Seed the Kitty image cache from any restored history so an image shown
	// before a server restart can still be replayed on the next reattach.
	if window.observeKittyGraphicsLocked(window.history) {
		s.enforceGlobalKittyImageBudgetLocked()
	}
	s.clearAlertsLocked(window.id)
	replay = s.replayBytesLocked(window)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	snapshots = s.snapshotsLocked()
	addedSnapshot = snapshotByID(snapshots, window.id)
	refreshPendingFocus =
		s.pendingFocusRefreshConn != nil &&
			s.pendingFocusRefreshConn == s.attachConn
	refreshPendingResize =
		s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0
	s.mu.Unlock()

	s.attachMu.Lock()
	redrew := s.broadcastAttachReplayAndResizeLocked(replay, window)
	s.attachMu.Unlock()
	if refreshPendingFocus || refreshPendingResize {
		s.refreshPendingClientViewport(refreshPendingFocus, refreshPendingResize)
	}
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	// The watcher count was registered under s.mu above, alongside the s.closed
	// check, so it is deliberately not incremented here.
	go func() {
		defer s.windowWatchers.Done()
		s.readWindow(window)
	}()
	go func() {
		defer s.windowWatchers.Done()
		_ = proc.Wait()
		s.markWindowClosed(window.id)
	}()
	s.broadcast(controlResponse{
		Type:    "window_added",
		Session: s.session,
		Window:  addedSnapshot,
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
	s.broadcast(controlResponse{
		Type:    "active_window_changed",
		Session: s.session,
		Windows: snapshots,
	})
	return window, nil
}

// cleanupRejectedWindow exclusively owns a started but unpublished window.
// There is no useful work to preserve, so force termination immediately rather
// than leaving a hangup-ignoring child alive. No Wait may run before Kill: on
// Unix the unreaped leader reserves its PID/PGID throughout group signaling.
// Keep terminal close and Wait off the rejection path, too.
func cleanupRejectedWindow(windowPty muxPty, proc muxProcess) {
	proc.Kill()
	_ = windowPty.Close()
	_ = proc.Wait()
}

func (s *muxServer) readWindow(window *muxWindow) {
	buf := make([]byte, 32*1024)
	for {
		n, err := window.pty.Read(buf)
		if n > 0 {
			s.handleWindowOutput(window.id, buf[:n])
		}
		if err != nil {
			return
		}
	}
}

func (s *muxServer) handleWindowOutput(windowID string, chunk []byte) {
	var attach net.Conn
	var forwarded []byte
	var failoverForwarded []byte
	var secondaryForwarded []byte
	var terminalQueries []byte
	var themeHint []byte
	var themeHintData []byte
	var capabilityHintData []byte
	var shouldWrite bool
	var refreshPendingFocus bool
	var refreshPendingResize bool
	var snapshot *windowSnapshot
	var maxAttachSequence uint64
	var outputGeneration uint64
	now := time.Now()

	for {
		s.mu.Lock()
		window := s.windowByIDLocked(windowID)
		waitForAttachTransition :=
			s.attachViewportTransitionWindowID == windowID &&
				window != nil &&
				!window.closed &&
				terminalViewportTransitionSafe(window)
		s.mu.Unlock()
		if !waitForAttachTransition {
			break
		}
		time.Sleep(time.Millisecond)
	}

	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return
	}
	before := window.broadcastIdentityLocked()
	s.mu.Unlock()
	s.refreshProcessMetadata(windowID)
	s.mu.Lock()
	if s.windowByIDLocked(windowID) != window || window.closed {
		s.mu.Unlock()
		return
	}
	window.terminalOutputForwarding =
		s.activeID == windowID && s.attachCountLocked() > 0
	wasAlert := window.alert
	window.lastActivity = now
	// Modes are observed before metadata so a `CSI ? 9001 h` arriving in the
	// same chunk as a colour query is already reflected when the query is
	// answered below (and when the answer is encoded in writeWindow).
	window.observeTerminalModesLocked(chunk)
	queryKeys := window.observeTerminalMetadataLocked(chunk)
	terminalBell := window.observeTerminalOutputStateLocked(chunk)
	if len(queryKeys) > 0 && len(s.themeHint) > 0 {
		themeHint = append([]byte(nil), s.themeHint...)
		themeHintData = themeHintResponsesForKeys(themeHint, queryKeys)
	}
	window.appendHistoryLocked(chunk)
	window.outputGeneration++
	outputGeneration = window.outputGeneration
	if window.observeKittyGraphicsLocked(chunk) {
		s.enforceGlobalKittyImageBudgetLocked()
	}
	if s.activeID == windowID {
		attach = s.attachConn
		shouldWrite = s.attachCountLocked() > 0
		maxAttachSequence = s.nextAttachSequence
	} else if terminalBell {
		window.alert = true
	}
	forwarded = window.stripLocallyAnsweredThemeQueriesLocked(chunk, themeHint)
	if !shouldWrite {
		// No terminal is showing this window, so its capability queries will not
		// be forwarded and answered. Buffer them so they can be delivered — and
		// answered — once a terminal attaches or the window is selected.
		if len(window.secondaryQueryCarry) > 0 {
			forwarded = append(
				append([]byte(nil), window.secondaryQueryCarry...),
				forwarded...,
			)
			window.secondaryQueryCarry = nil
			window.secondaryQueryPrimary = nil
		}
		capabilityHintData = window.appendPendingTerminalQueriesLocked(
			forwarded,
			s.capabilityHintLocked(),
			s.themeHint,
		)
	} else {
		// A terminal is showing this window again, so it answers the child's
		// queries directly. Reset the synthetic-answer budget for the next time
		// the window goes back to running unwatched.
		window.capabilityAnswerBytes = 0
		if len(window.pendingTerminalQueryCarry) > 0 {
			forwarded = append(
				append([]byte(nil), window.pendingTerminalQueryCarry...),
				forwarded...,
			)
			window.pendingTerminalQueryCarry = nil
		}
	}
	after := window.broadcastIdentityLocked()
	if before != after ||
		(!wasAlert && window.alert) ||
		window.lastBroadcast.IsZero() ||
		now.Sub(window.lastBroadcast) >= windowUpdateMinInterval {
		snap := s.snapshotLocked(window)
		snapshot = &snap
		window.lastBroadcast = now
	}
	if shouldWrite {
		hadQueryCarry := len(window.secondaryQueryCarry) > 0
		queryCarry := append([]byte(nil), window.secondaryQueryCarry...)
		queryPrimaryMissing := false
		if hadQueryCarry && window.secondaryQueryPrimary != nil {
			if s.isAttachConnectionLocked(window.secondaryQueryPrimary) {
				attach = window.secondaryQueryPrimary
			} else {
				queryPrimaryMissing = true
			}
		}
		secondaryForwarded = window.secondaryAttachOutputLocked(forwarded)
		terminalQueries = append(
			terminalQueries,
			window.lastForwardedTerminalQueries...,
		)
		failoverForwarded = forwarded
		if hadQueryCarry {
			failoverForwarded = append(queryCarry, forwarded...)
		}
		if queryPrimaryMissing && !window.redrawForwardingPaused {
			forwarded = append(queryCarry, forwarded...)
		} else if queryPrimaryMissing {
			attach = s.attachConn
			window.redrawForwardingPrimaryConn = attach
			window.redrawForwardingPrimaryNeedsFailover = true
		} else if window.redrawForwardingPaused &&
			hadQueryCarry &&
			window.redrawForwardingPrimaryConn != attach {
			window.redrawForwardingPrimaryConn = attach
		}
		if len(window.secondaryQueryCarry) > 0 {
			if !hadQueryCarry || queryPrimaryMissing {
				window.secondaryQueryPrimary = attach
			}
		} else {
			window.secondaryQueryPrimary = nil
		}
		if len(forwarded) > 0 && window.redrawForwardingPaused {
			window.redrawForwardingBuffer = append(
				window.redrawForwardingBuffer,
				forwarded...,
			)
			window.redrawForwardingFailoverBuffer = append(
				window.redrawForwardingFailoverBuffer,
				failoverForwarded...,
			)
			window.redrawForwardingSecondaryBuffer = append(
				window.redrawForwardingSecondaryBuffer,
				secondaryForwarded...,
			)
			window.redrawForwardingQueryBuffer = append(
				window.redrawForwardingQueryBuffer,
				terminalQueries...,
			)
			shouldWrite = false
			forwarded = nil
			secondaryForwarded = nil
			terminalQueries = nil
		}
	}
	s.mu.Unlock()

	if len(themeHintData) > 0 {
		_ = s.writeWindow(windowID, themeHintData)
	}
	// Answers to capability probes the child emitted while no terminal was
	// showing this window. Delivering them now (rather than only replaying the
	// queries on the next attach/switch) is what lets a restored agent see a
	// timely reply and keep its richer rendering mode.
	if len(capabilityHintData) > 0 {
		_ = s.writeWindow(windowID, capabilityHintData)
	}

	if shouldWrite {
		if len(forwarded) > 0 {
			s.writeAttachOutputIfActive(
				windowID,
				attach,
				forwarded,
				failoverForwarded,
				secondaryForwarded,
				terminalQueries,
				maxAttachSequence,
				outputGeneration,
			)
		}
	}
	s.mu.Lock()
	window = s.windowByIDLocked(windowID)
	if window != nil && !window.closed {
		window.terminalOutputForwarding = false
		refreshPendingFocus =
			s.pendingFocusRefreshConn != nil &&
				s.pendingFocusRefreshConn == s.attachConn &&
				len(window.secondaryQueryCarry) == 0 &&
				window.queryUtf8Remaining == 0 &&
				window.terminalOutputIsGroundLocked() &&
				!window.redrawForwardingPaused
		refreshPendingResize =
			s.pendingResizeWidth > 0 &&
				s.pendingResizeHeight > 0 &&
				terminalViewportTransitionSafe(window)
	}
	s.mu.Unlock()

	if snapshot != nil {
		s.broadcast(controlResponse{
			Type:    "window_updated",
			Session: s.session,
			Window:  snapshot,
		})
	}
	if refreshPendingFocus || refreshPendingResize {
		s.refreshPendingClientViewport(refreshPendingFocus, refreshPendingResize)
	}
}

// wrapSynchronizedTerminalOutput builds the resume write for one attach client.
// prefix (the reattach replay) is emitted verbatim so it repaints immediately,
// then the buffered foreground-redraw bytes are bracketed by MonkeySSH-private
// DEC mode 9002 so the client applies them as a single atomic repaint and never
// paints the synthetic width-1 dance frame captured mid-redraw. The begin and
// end markers are written together in this one buffer (never via a separate
// timer), so the close can never land mid-sequence and mode 9002 can never be
// left open. When there is no buffered redraw there is no intermediate frame to
// hide, so the replay is returned unwrapped.
func wrapSynchronizedTerminalOutput(prefix []byte, data []byte) []byte {
	if len(data) == 0 {
		if len(prefix) == 0 {
			return nil
		}
		return append([]byte(nil), prefix...)
	}
	output := make(
		[]byte,
		0,
		len(prefix)+len(terminalSynchronizedOutputBegin)+len(data)+
			len(terminalSynchronizedOutputEnd),
	)
	output = append(output, prefix...)
	output = append(output, terminalSynchronizedOutputBegin...)
	output = append(output, data...)
	output = append(output, terminalSynchronizedOutputEnd...)
	return output
}

func (s *muxServer) retireWindowLocked(window *muxWindow) {
	window.closed = true
	window.alert = false
	window.releaseRedrawForwardingStateLocked()
	window.clearKittyGraphicsPendingLocked()
	window.clearKittyImagesLocked()
	window.history = nil
	window.oscBuffer = nil
	window.attachOscBuffer = nil
	window.csiBuffer = nil
	window.pendingTerminalQueries = nil
	window.pendingTerminalQueriesInFlight = nil
	window.pendingTerminalQueryCarry = nil
	window.secondaryQueryCarry = nil
	window.secondaryQueryPrimary = nil
	window.lastForwardedTerminalQueries = nil
	for i, candidate := range s.windows {
		if candidate == window {
			copy(s.windows[i:], s.windows[i+1:])
			s.windows[len(s.windows)-1] = nil
			s.windows = s.windows[:len(s.windows)-1]
			break
		}
	}
}

func (s *muxServer) markWindowClosed(windowID string) {
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var redrew bool
	var shouldShutdown bool
	var windowPty muxPty
	var nativeAcpBridgeID string
	var resetViewportParser bool

	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	s.retireWindowLocked(window)
	if s.lastActiveID == windowID {
		s.lastActiveID = ""
	}
	// Capture the pty and close it after releasing s.mu (see below): on Windows
	// muxPty.Close() calls ClosePseudoConsole, which blocks until the output
	// pipe is drained by readWindow -> handleWindowOutput, and that reader needs
	// s.mu. Closing under the lock would deadlock the whole server.
	windowPty = window.pty
	nativeAcpBridgeID = window.nativeAcpBridgeID
	s.reindexWindowsLocked()
	if s.activeID == windowID {
		resetViewportParser =
			s.pendingFocusRefreshConn != nil ||
				(s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0)
		s.activeID = ""
		s.pendingFocusRefreshConn = nil
		for _, candidate := range s.windows {
			if !candidate.closed {
				s.activeID = candidate.id
				candidate.alert = false
				s.pendingResizeWidth = 0
				s.pendingResizeHeight = 0
				s.pendingResizeRedraw = false
				s.pendingResizeSyntheticRedraw = false
				s.pendingResizeThemeWindowID = ""
				if resetViewportParser {
					s.enqueueAttachViewportResizeAfterResetLocked(
						s.width,
						s.height,
					)
				} else {
					s.enqueueAttachViewportResizeLocked(s.width, s.height)
				}
				s.publishedWidth = s.width
				s.publishedHeight = s.height
				s.resizeActiveLocked(s.width, s.height)
				replay = s.replayBytesLocked(candidate)
				foregroundProcessGroup = candidate.foregroundProcessGroupLocked()
				redrawWindow = candidate
				activeChanged = true
				break
			}
		}
	}
	snapshots := s.snapshotsLocked()
	shouldShutdown = len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		redrew = s.broadcastAttachReplayAndResizeLocked(replay, redrawWindow)
	}
	s.attachMu.Unlock()

	// Now that s.mu/s.attachMu are released, tear down the pty. On Windows this
	// blocks until readWindow drains the final ConPTY output (which needs s.mu),
	// so it must happen after unlocking.
	if windowPty != nil {
		_ = window.closePty(windowPty)
	}
	if nativeAcpBridgeID != "" {
		_ = requestAcpBridgeStopAndWait(nativeAcpBridgeID)
	}

	s.broadcast(controlResponse{
		Type:    "window_removed",
		Session: s.session,
		Window:  &windowSnapshot{ID: windowID},
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
	if activeChanged {
		s.broadcast(controlResponse{
			Type:    "active_window_changed",
			Session: s.session,
			Windows: snapshots,
		})
		if redrew {
			signalForegroundResize(foregroundProcessGroup)
		}
	}
	if shouldShutdown {
		go s.close()
	}
}

func (s *muxServer) handleConnection(conn net.Conn) {
	_ = conn.SetReadDeadline(time.Now().Add(socketTimeout))
	reader := bufio.NewReader(conn)
	line, err := readBoundedProtocolLine(reader, controlMaxFrameBytes)
	if err != nil {
		_ = conn.Close()
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	var hello controlMessage
	if err := json.Unmarshal(line, &hello); err != nil {
		_ = conn.Close()
		return
	}
	switch hello.Role {
	case "attach":
		s.handleAttach(conn, reader, hello)
	case "control":
		s.handleControl(conn, reader)
	default:
		_ = conn.Close()
	}
}

func newAttachClient(conn net.Conn, hello controlMessage) *attachClient {
	clientID := strings.TrimSpace(hello.ClientID)
	if clientID == "" {
		clientID = fmt.Sprintf("client-%d-%d", os.Getpid(), time.Now().UnixNano())
	}
	client := &attachClient{
		conn:            conn,
		id:              clientID,
		width:           hello.Width,
		height:          hello.Height,
		clipViewport:    hello.ClipViewport,
		prefixEnabled:   !hello.NoPrefix,
		capabilityHint:  capabilityHintDataFromString(hello.CapabilityHint),
		queueReady:      make(chan struct{}, 1),
		inputQueueReady: make(chan struct{}, 1),
		done:            make(chan struct{}),
	}
	go client.writeLoop()
	return client
}

func (c *attachClient) writeLoop() {
	defer c.failQueuedWrites(io.ErrClosedPipe)
	for {
		write, ok := c.nextQueuedWrite()
		if !ok {
			return
		}
		if write.gate != nil {
			select {
			case <-write.gate.done:
				if !write.gate.deliver.Load() {
					c.finishQueuedWrite(write, nil)
					continue
				}
			case <-c.done:
				c.finishQueuedWrite(write, io.ErrClosedPipe)
				return
			}
		}
		if write.responseWindowID != "" && write.responseCount > 0 {
			c.expectTerminalResponses(
				write.responseWindowID,
				write.responseCount,
			)
			select {
			case <-c.done:
				c.finishQueuedWrite(write, io.ErrClosedPipe)
				return
			default:
			}
		}
		err := writeAttachConnection(c.conn, write.data)
		_ = c.conn.SetWriteDeadline(time.Time{})
		c.finishQueuedWrite(write, err)
		if err != nil {
			c.close()
			return
		}
	}
}

func (c *attachClient) nextQueuedWrite() (attachWrite, bool) {
	for {
		c.queueMu.Lock()
		if len(c.queue) > 0 {
			write := c.queue[0]
			if len(c.queue) == 1 {
				c.queue = nil
			} else {
				c.queue[0] = attachWrite{}
				c.queue = c.queue[1:]
			}
			c.queueMu.Unlock()
			return write, true
		}
		if c.queueClosed {
			c.queueMu.Unlock()
			return attachWrite{}, false
		}
		c.queueMu.Unlock()
		select {
		case <-c.queueReady:
		case <-c.done:
			return attachWrite{}, false
		}
	}
}

func (c *attachClient) finishQueuedWrite(write attachWrite, err error) {
	c.queueMu.Lock()
	c.queuedBytes -= len(write.data)
	c.queueMu.Unlock()
	if write.complete != nil {
		write.complete <- err
		close(write.complete)
	}
}

func (c *attachClient) failQueuedWrites(err error) {
	for {
		c.queueMu.Lock()
		if len(c.queue) == 0 {
			c.queue = nil
			c.queueMu.Unlock()
			return
		}

		write := c.queue[0]
		c.queue[0] = attachWrite{}
		c.queue = c.queue[1:]
		c.queuedBytes -= len(write.data)
		c.queueMu.Unlock()
		if write.complete != nil {
			write.complete <- err
			close(write.complete)
		}
	}
}

func (c *attachClient) enqueueInputActions(actions []attachInputAction) bool {
	if len(actions) == 0 {
		return true
	}
	addedBytes := 0
	for _, action := range actions {
		addedBytes += len(action.data)
	}
	c.inputQueueMu.Lock()
	if c.inputQueueClosed ||
		c.inputQueuedBytes+addedBytes > attachWriteQueueLimitBytes {
		c.inputQueueMu.Unlock()
		c.close()
		return false
	}
	queueWasEmpty := len(c.inputQueue) == 0
	c.inputQueuedBytes += addedBytes
	c.inputQueue = append(c.inputQueue, actions...)
	c.inputQueueMu.Unlock()
	if queueWasEmpty {
		select {
		case c.inputQueueReady <- struct{}{}:
		default:
		}
	}
	return true
}

func (c *attachClient) nextInputAction() (attachInputAction, bool) {
	for {
		c.inputQueueMu.Lock()
		if len(c.inputQueue) > 0 {
			action := c.inputQueue[0]
			c.inputQueue[0] = attachInputAction{}
			c.inputQueue = c.inputQueue[1:]
			c.inputQueuedBytes -= len(action.data)
			c.inputQueueMu.Unlock()
			return action, true
		}
		if c.inputQueueClosed {
			c.inputQueueMu.Unlock()
			return attachInputAction{}, false
		}
		c.inputQueueMu.Unlock()
		select {
		case <-c.inputQueueReady:
		case <-c.done:
			return attachInputAction{}, false
		}
	}
}

func writeConnection(conn net.Conn, data []byte) error {
	for len(data) > 0 {
		written, err := conn.Write(data)
		if err != nil {
			return err
		}
		if written <= 0 {
			return io.ErrUnexpectedEOF
		}
		data = data[written:]
	}
	return nil
}

func writeAttachConnection(conn net.Conn, data []byte) error {
	for len(data) > 0 {
		chunkSize := min(len(data), attachWriteChunkBytes)
		_ = conn.SetWriteDeadline(time.Now().Add(attachWriteTimeout))
		if err := writeConnection(conn, data[:chunkSize]); err != nil {
			return err
		}
		data = data[chunkSize:]
	}
	return nil
}

func (c *attachClient) enqueue(data []byte, wait bool) (<-chan error, bool) {
	return c.enqueueWrite(data, wait, "", 0, nil)
}

func (c *attachClient) enqueueTerminalQuery(
	data []byte,
	wait bool,
	windowID string,
	responseCount int,
) (<-chan error, bool) {
	return c.enqueueWrite(data, wait, windowID, responseCount, nil)
}

func (c *attachClient) enqueueConditionalTerminalQuery(
	data []byte,
	wait bool,
	windowID string,
	responseCount int,
	gate *attachWriteGate,
) (<-chan error, bool) {
	return c.enqueueWrite(data, wait, windowID, responseCount, gate)
}

func (c *attachClient) enqueueWrite(
	data []byte,
	wait bool,
	responseWindowID string,
	responseCount int,
	gate *attachWriteGate,
) (<-chan error, bool) {
	if len(data) == 0 {
		return nil, true
	}
	if len(data) > attachWriteQueueLimitBytes {
		c.close()
		return nil, false
	}
	write := attachWrite{
		data:             append([]byte(nil), data...),
		responseWindowID: responseWindowID,
		responseCount:    responseCount,
		gate:             gate,
	}
	if wait {
		write.complete = make(chan error, 1)
	}
	c.queueMu.Lock()
	queueClosed := c.queueClosed
	if queueClosed ||
		c.queuedBytes+len(write.data) > attachWriteQueueLimitBytes {
		c.queueMu.Unlock()
		if !queueClosed {
			c.close()
		}
		return nil, false
	}
	c.queuedBytes += len(write.data)
	queueWasEmpty := len(c.queue) == 0
	if attachWritesCanCoalesce(write) && len(c.queue) > 0 {
		last := &c.queue[len(c.queue)-1]
		if attachWritesCanCoalesce(*last) &&
			len(last.data)+len(write.data) <= attachWriteChunkBytes {
			last.data = append(last.data, write.data...)
			c.queueMu.Unlock()
			return nil, true
		}
	}
	c.queue = append(c.queue, write)
	c.queueMu.Unlock()
	if queueWasEmpty {
		select {
		case c.queueReady <- struct{}{}:
		default:
		}
	}
	return write.complete, true
}

func attachWritesCanCoalesce(write attachWrite) bool {
	return write.complete == nil &&
		write.responseWindowID == "" &&
		write.responseCount == 0 &&
		write.gate == nil
}

func (c *attachClient) waitForWrite(completion <-chan error) bool {
	if completion == nil {
		return true
	}
	err, ok := <-completion
	return ok && err == nil
}

func (c *attachClient) close() {
	c.closeOnce.Do(func() {
		c.queueMu.Lock()
		c.queueClosed = true
		c.queueMu.Unlock()
		c.inputQueueMu.Lock()
		c.inputQueueClosed = true
		c.inputQueueMu.Unlock()
		close(c.done)
		_ = c.conn.Close()
	})
}

func (c *attachClient) markOutputReplay(windowID string, generation uint64) {
	c.replayMu.Lock()
	c.replayedWindowID = windowID
	c.replayedOutputGeneration = generation
	c.replayMu.Unlock()
}

func (c *attachClient) clearOutputReplay() {
	c.replayMu.Lock()
	c.replayedWindowID = ""
	c.replayedOutputGeneration = 0
	c.replayMu.Unlock()
}

func (c *attachClient) suppressesReplayedOutput(
	windowID string,
	generation uint64,
) bool {
	if generation == 0 {
		return false
	}
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	if c.replayedWindowID != windowID {
		return false
	}
	if generation <= c.replayedOutputGeneration {
		return true
	}
	c.replayedWindowID = ""
	c.replayedOutputGeneration = 0
	return false
}

func (c *attachClient) expectTerminalResponses(windowID string, count int) {
	if c == nil || windowID == "" {
		return
	}
	c.inputDispatchMu.Lock()
	defer c.inputDispatchMu.Unlock()
	if count < 1 {
		count = 1
	}
	now := time.Now()
	var expiredInput []byte
	var expiredFocusSequence uint64
	var claim func(uint64)
	var passthrough func([]byte)
	inputLocked := false
	c.activityMu.Lock()
	if !c.terminalResponseUntil.IsZero() &&
		now.After(c.terminalResponseUntil) {
		if len(c.terminalResponseCarry) > 0 {
			c.inputMu.Lock()
			inputLocked = true
			expiredInput = append(
				expiredInput,
				c.terminalResponseCarry...,
			)
			expiredInput = append(
				expiredInput,
				c.terminalResponsePasteStartCarry...,
			)
			if c.focusSequenceSnapshot != nil {
				expiredFocusSequence = c.focusSequenceSnapshot()
			}
			claim = c.focusClaim
			passthrough = c.inputPassthrough
		} else if len(c.terminalResponsePasteStartCarry) > 0 {
			c.inputMu.Lock()
			inputLocked = true
			expiredInput = append(
				expiredInput,
				c.terminalResponsePasteStartCarry...,
			)
			if c.focusSequenceSnapshot != nil {
				expiredFocusSequence = c.focusSequenceSnapshot()
			}
			claim = c.focusClaim
			passthrough = c.inputPassthrough
		}
		c.resetTerminalResponseStateLocked()
	}
	outstanding := len(c.terminalResponseWindows)
	if c.terminalResponseActiveWindow != "" {
		outstanding++
	}
	if count > terminalResponseMaxOutstanding-outstanding {
		c.activityMu.Unlock()
		if inputLocked {
			c.inputMu.Unlock()
		}
		c.close()
		return
	}
	c.terminalResponseUntil = now.Add(terminalResponseFocusGrace)
	for range count {
		c.terminalResponseWindows = append(
			c.terminalResponseWindows,
			windowID,
		)
	}
	if len(c.terminalResponseCarry) > 0 ||
		len(c.terminalResponsePasteStartCarry) > 0 {
		c.scheduleTerminalResponseCarryLocked()
	}
	c.activityMu.Unlock()
	if !inputLocked {
		return
	}
	defer c.inputMu.Unlock()
	select {
	case <-c.done:
		return
	default:
	}
	if claim != nil {
		claim(expiredFocusSequence)
	}
	if passthrough != nil {
		passthrough(expiredInput)
	}
}

func (c *attachClient) routeInput(data []byte) attachInputRouting {
	result := attachInputRouting{}
	if len(data) == 0 {
		return result
	}
	if c == nil {
		result.addUserInput(data, false)
		result.claimsFocus = true
		return result
	}
	c.activityMu.Lock()
	defer c.activityMu.Unlock()
	previousInputUtf8Remaining := c.inputUtf8Remaining
	leadingInputUtf8Prefix := leadingUtf8ContinuationPrefix(
		data,
		previousInputUtf8Remaining,
	)
	c.inputUtf8Remaining = nextQueryUtf8Remaining(
		data,
		previousInputUtf8Remaining,
		leadingInputUtf8Prefix,
	)
	c.routeInputLocked(data, leadingInputUtf8Prefix, &result)
	return result
}

func (c *attachClient) routeInputLocked(
	data []byte,
	leadingInputUtf8Prefix int,
	result *attachInputRouting,
) {
	if len(data) == 0 {
		return
	}
	if len(c.inputBracketedPasteStartCarry) > 0 {
		combined := make(
			[]byte,
			0,
			len(c.inputBracketedPasteStartCarry)+len(data),
		)
		combined = append(combined, c.inputBracketedPasteStartCarry...)
		combined = append(combined, data...)
		c.inputBracketedPasteCarryGeneration++
		c.inputBracketedPasteCarryFocusSequence = 0
		paste := bracketedPasteStart(combined, 0)
		if paste.index == 0 {
			c.inputBracketedPasteStartCarry = nil
			pastePayloadLength := c.beginBracketedPasteLocked(
				combined[paste.length:],
			)
			pasteEnd := paste.length + pastePayloadLength
			if c.hasExpectedTerminalResponseLocked() {
				c.renewTerminalResponseDeadlineLocked()
			}
			c.routeBracketedPasteInputLocked(combined[:pasteEnd], result)
			c.routePostPasteInputLocked(combined[pasteEnd:], result)
			return
		}
		if suffixLength := bracketedPasteStartSuffixLength(
			combined,
			0,
		); suffixLength == len(combined) {
			c.storeBracketedPasteStartCarryLocked(combined)
			return
		}
		c.inputBracketedPasteStartCarry = nil
		c.routeInputLocked(combined, 0, result)
		return
	}
	if c.inputBracketedPasteActive {
		pasteLength := c.continueBracketedPasteLocked(
			data,
			leadingInputUtf8Prefix,
		)
		if c.hasExpectedTerminalResponseLocked() ||
			len(c.terminalResponseCarry) > 0 ||
			c.terminalResponseContinuation != 0 {
			c.renewTerminalResponseDeadlineLocked()
		}
		c.routeBracketedPasteInputLocked(data[:pasteLength], result)
		c.routePostPasteInputLocked(data[pasteLength:], result)
		return
	}
	now := time.Now()
	if !c.terminalResponseUntil.IsZero() &&
		now.After(c.terminalResponseUntil) {
		combined := make(
			[]byte,
			0,
			len(c.terminalResponseCarry)+
				len(c.terminalResponsePasteStartCarry)+
				len(data),
		)
		combined = append(combined, c.terminalResponseCarry...)
		freshStart := len(combined)
		combined = append(combined, c.terminalResponsePasteStartCarry...)
		combined = append(combined, data...)
		userStart := 0
		paste := bracketedPasteStart(combined, 0)
		if paste.index >= 0 {
			userStart = min(paste.index, freshStart)
		} else if suffixLength := bracketedPasteStartSuffixLength(
			combined,
			0,
		); suffixLength > 0 {
			userStart = min(len(combined)-suffixLength, freshStart)
		}
		windowID := c.currentTerminalResponseWindowLocked()
		if userStart > 0 && windowID != "" {
			result.addResponse(windowID, combined[:userStart])
		}
		c.resetTerminalResponseStateLocked()
		userInput := combined[userStart:]
		if paste = bracketedPasteStart(userInput, 0); paste.index >= 0 {
			c.routeUserInputWithPasteLocked(
				userInput,
				paste.index,
				paste.length,
				result,
			)
			return
		}
		c.routeUserInputLocked(userInput, result)
		return
	}
	if !c.hasExpectedTerminalResponseLocked() &&
		len(c.terminalResponseCarry) == 0 &&
		c.terminalResponseContinuation == 0 &&
		len(c.terminalResponsePasteStartCarry) == 0 {
		if paste := bracketedPasteStart(
			data,
			leadingInputUtf8Prefix,
		); paste.index >= 0 {
			c.routeUserInputWithPasteLocked(
				data,
				paste.index,
				paste.length,
				result,
			)
			return
		}
		c.routeUserInputLockedWithUtf8Prefix(
			data,
			leadingInputUtf8Prefix,
			false,
			true,
			result,
		)
		return
	}

	responseInput := data
	combined := responseInput
	responseLeadingUtf8Prefix := leadingInputUtf8Prefix
	if c.terminalResponseContinuation != 0 {
		if len(c.terminalResponsePasteStartCarry) > 0 {
			responseInput = make(
				[]byte,
				0,
				len(c.terminalResponsePasteStartCarry)+len(data),
			)
			responseInput = append(
				responseInput,
				c.terminalResponsePasteStartCarry...,
			)
			responseInput = append(responseInput, data...)
			c.terminalResponsePasteStartCarry = nil
			responseLeadingUtf8Prefix = 0
		}
		paste := bracketedPasteStart(
			responseInput,
			responseLeadingUtf8Prefix,
		)
		if paste.index >= 0 {
			prefix := responseInput[:paste.index]
			windowID := c.currentTerminalResponseWindowLocked()
			if len(prefix) > 0 {
				remaining, complete, trailingEscape, utf8Remaining :=
					consumeTerminalResponseContinuation(
						prefix,
						c.terminalResponseContinuation,
						c.terminalResponseContinuationEscape,
						c.terminalResponseContinuationUtf8,
					)
				consumed := len(prefix) - len(remaining)
				if consumed > 0 {
					result.addResponse(windowID, prefix[:consumed])
				}
				if complete {
					c.finishTerminalResponseLocked()
					c.terminalResponseContinuation = 0
					c.terminalResponseContinuationEscape = false
					c.terminalResponseContinuationUtf8 = 0
					c.routeInputLocked(
						responseInput[consumed:],
						0,
						result,
					)
					return
				}
				c.terminalResponseContinuationEscape = trailingEscape
				c.terminalResponseContinuationUtf8 = utf8Remaining
			}
			c.routeUserInputWithPasteLocked(
				responseInput[paste.index:],
				0,
				paste.length,
				result,
			)
			return
		}
		suffixLength := bracketedPasteStartSuffixLength(
			responseInput,
			responseLeadingUtf8Prefix,
		)
		processable := responseInput[:len(responseInput)-suffixLength]
		if len(processable) == 0 {
			c.terminalResponsePasteStartCarry = append(
				c.terminalResponsePasteStartCarry[:0],
				responseInput...,
			)
			c.renewTerminalResponseDeadlineLocked()
			return
		}
		remaining, complete, trailingEscape, utf8Remaining :=
			consumeTerminalResponseContinuation(
				processable,
				c.terminalResponseContinuation,
				c.terminalResponseContinuationEscape,
				c.terminalResponseContinuationUtf8,
			)
		c.terminalResponseContinuationEscape = trailingEscape
		c.terminalResponseContinuationUtf8 = utf8Remaining
		windowID := c.currentTerminalResponseWindowLocked()
		if !complete {
			if len(processable) > 0 {
				result.addResponse(windowID, processable)
			}
			c.terminalResponsePasteStartCarry = append(
				c.terminalResponsePasteStartCarry[:0],
				responseInput[len(processable):]...,
			)
			c.renewTerminalResponseDeadlineLocked()
			return
		}
		consumed := len(processable) - len(remaining)
		if consumed > 0 {
			result.addResponse(windowID, processable[:consumed])
		}
		c.finishTerminalResponseLocked()
		if c.hasExpectedTerminalResponseLocked() {
			c.renewTerminalResponseDeadlineLocked()
		}
		c.terminalResponseContinuation = 0
		c.terminalResponseContinuationEscape = false
		c.terminalResponseContinuationUtf8 = 0
		c.terminalResponsePasteStartCarry = nil
		combined = responseInput[consumed:]
		if len(combined) == 0 {
			return
		}
		responseInput = combined
		responseLeadingUtf8Prefix = 0
	}
	currentInputStart := 0
	if len(c.terminalResponseCarry) > 0 {
		responseLeadingUtf8Prefix = 0
		currentInputStart = len(c.terminalResponseCarry)
		combined = make(
			[]byte,
			0,
			len(c.terminalResponseCarry)+len(responseInput),
		)
		combined = append(combined, c.terminalResponseCarry...)
		combined = append(combined, responseInput...)
		c.terminalResponseCarry = nil
		c.terminalResponseCarryGeneration++
	}
	paste := bracketedPasteStart(combined, responseLeadingUtf8Prefix)
	scanInput := combined
	if paste.index >= 0 {
		scanInput = combined[:paste.index]
	}
	responseEnds, incompleteStart, continuation, passthroughStart :=
		scanTerminalResponseInput(scanInput, responseLeadingUtf8Prefix)
	responseStart := 0
	for _, responseEnd := range responseEnds {
		if !c.hasExpectedTerminalResponseLocked() {
			passthroughStart = responseStart
			incompleteStart = -1
			break
		}
		windowID := c.currentTerminalResponseWindowLocked()
		result.addResponse(windowID, combined[responseStart:responseEnd])
		c.finishTerminalResponseSequenceLocked(
			windowID,
			combined[responseStart:responseEnd],
		)
		if c.hasExpectedTerminalResponseLocked() {
			c.renewTerminalResponseDeadlineLocked()
		}
		responseStart = responseEnd
	}
	if incompleteStart >= 0 {
		if !c.hasExpectedTerminalResponseLocked() {
			userInput := combined[responseStart:]
			if paste.index >= 0 {
				pasteOffset := paste.index - responseStart
				c.routeUserInputWithPasteLocked(
					userInput,
					pasteOffset,
					paste.length,
					result,
				)
				return
			}
			c.routeUserInputLocked(userInput, result)
			return
		}
		incomplete := scanInput[incompleteStart:]
		if paste.index >= 0 {
			// A buffered reply has not reached the querying process yet, so it
			// can be safely abandoned while preserving the expectation for a
			// fresh complete reply after the paste. A streamed reply has already
			// reached the process; keep that continuation alive and skip only
			// the paste bytes from its stream.
			if currentInputStart == 0 &&
				len(incomplete) > terminalResponseCarryLimitBytes &&
				continuation != 0 {
				windowID := c.currentTerminalResponseWindowLocked()
				c.terminalResponseContinuation = continuation
				c.terminalResponseContinuationEscape =
					incomplete[len(incomplete)-1] == '\x1b'
				c.terminalResponseContinuationUtf8 =
					trailingUtf8ContinuationCount(incomplete)
				result.addResponse(windowID, incomplete)
			}
			userStart := paste.index
			if currentInputStart > 0 {
				if responseStart <= currentInputStart {
					userStart = min(currentInputStart, paste.index)
				}
			}
			userInput := combined[userStart:]
			c.routeUserInputWithPasteLocked(
				userInput,
				paste.index-userStart,
				paste.length,
				result,
			)
			return
		}
		c.renewTerminalResponseDeadlineLocked()
		if len(incomplete) <= terminalResponseCarryLimitBytes {
			c.storeTerminalResponseCarryLocked(incomplete)
		} else if continuation != 0 {
			suffixLength := bracketedPasteStartSuffixLength(
				incomplete,
				0,
			)
			streamable := incomplete[:len(incomplete)-suffixLength]
			windowID := c.currentTerminalResponseWindowLocked()
			c.terminalResponseContinuation = continuation
			c.terminalResponseContinuationEscape =
				len(streamable) > 0 &&
					streamable[len(streamable)-1] == '\x1b'
			c.terminalResponseContinuationUtf8 =
				trailingUtf8ContinuationCount(streamable)
			if len(streamable) > 0 {
				result.addResponse(windowID, streamable)
			}
			c.terminalResponsePasteStartCarry = append(
				c.terminalResponsePasteStartCarry[:0],
				incomplete[len(streamable):]...,
			)
			c.renewTerminalResponseDeadlineLocked()
		}
		return
	}
	if paste.index >= 0 {
		userStart := paste.index
		if passthroughStart < len(scanInput) {
			userStart = passthroughStart
		}
		userInput := combined[userStart:]
		pasteOffset := paste.index - userStart
		c.routeUserInputWithPasteLocked(
			userInput,
			pasteOffset,
			paste.length,
			result,
		)
		return
	}
	if passthroughStart >= len(scanInput) {
		return
	}
	userLeadingUtf8Prefix := 0
	if passthroughStart == 0 && currentInputStart == 0 {
		userLeadingUtf8Prefix = responseLeadingUtf8Prefix
	}
	c.routeUserInputLockedWithUtf8Prefix(
		combined[passthroughStart:],
		userLeadingUtf8Prefix,
		false,
		true,
		result,
	)
}

func (c *attachClient) routeUserInputWithPasteLocked(
	userInput []byte,
	pasteOffset int,
	pasteStartLength int,
	result *attachInputRouting,
) {
	payloadStart := pasteOffset + pasteStartLength
	pastePayloadLength := c.beginBracketedPasteLocked(
		userInput[payloadStart:],
	)
	pasteEnd := payloadStart + pastePayloadLength
	if c.hasExpectedTerminalResponseLocked() {
		c.renewTerminalResponseDeadlineLocked()
	}
	c.routeUserInputWithoutPasteCarryLocked(
		userInput[:pasteOffset],
		result,
	)
	c.routeBracketedPasteInputLocked(userInput[pasteOffset:pasteEnd], result)
	c.routePostPasteInputLocked(userInput[pasteEnd:], result)
}

func (c *attachClient) routePostPasteInputLocked(
	data []byte,
	result *attachInputRouting,
) {
	if len(data) == 0 {
		return
	}
	// MonkeySSH appends one separator space outside CSI 201~ so multiple
	// uploaded paths remain distinct shell arguments. Preserve it before
	// checking whether the remaining bytes resume a pending machine reply.
	if data[0] == ' ' &&
		(c.hasExpectedTerminalResponseLocked() ||
			c.terminalResponseContinuation != 0) {
		c.routeUserInputLocked(data[:1], result)
		data = data[1:]
		if len(data) == 0 {
			return
		}
	}
	if c.terminalResponseContinuation != 0 {
		c.routeInputLocked(data, 0, result)
		return
	}
	c.routeInputLocked(data, 0, result)
}

func (c *attachClient) routeUserInputLocked(
	data []byte,
	result *attachInputRouting,
) {
	c.routeUserInputLockedWithUtf8Prefix(data, 0, false, true, result)
}

func (c *attachClient) routeUserInputWithoutPasteCarryLocked(
	data []byte,
	result *attachInputRouting,
) {
	c.routeUserInputLockedWithUtf8Prefix(data, 0, false, false, result)
}

func (c *attachClient) routeBracketedPasteInputLocked(
	data []byte,
	result *attachInputRouting,
) {
	c.routeUserInputLockedWithUtf8Prefix(data, 0, true, false, result)
}

func (c *attachClient) routeUserInputLockedWithUtf8Prefix(
	data []byte,
	leadingUtf8Prefix int,
	bracketedPaste bool,
	holdPasteStart bool,
	result *attachInputRouting,
) {
	if len(data) == 0 {
		return
	}
	if holdPasteStart {
		if suffixLength := bracketedPasteStartSuffixLength(
			data,
			leadingUtf8Prefix,
		); suffixLength > 0 {
			c.storeBracketedPasteStartCarryLocked(
				data[len(data)-suffixLength:],
			)
			data = data[:len(data)-suffixLength]
		} else {
			c.inputBracketedPasteStartCarry = nil
			c.inputBracketedPasteCarryGeneration++
			c.inputBracketedPasteCarryFocusSequence = 0
		}
	}
	if len(data) == 0 {
		return
	}
	result.addUserInput(data, bracketedPaste)
	c.focusInputGeneration++
	focusGeneration := c.focusInputGeneration
	combinedFocusInput := data
	if len(c.focusInputCarry) > 0 {
		combinedFocusInput = make(
			[]byte,
			0,
			len(c.focusInputCarry)+len(data),
		)
		combinedFocusInput = append(combinedFocusInput, c.focusInputCarry...)
		combinedFocusInput = append(combinedFocusInput, data...)
		c.focusInputCarry = nil
	}
	filteredInput, focusCarry := stripFocusOutInput(combinedFocusInput)
	c.focusInputCarry = append(c.focusInputCarry[:0], focusCarry...)
	if len(c.focusInputCarry) > 0 {
		focusSequence := uint64(0)
		if c.focusSequenceSnapshot != nil {
			focusSequence = c.focusSequenceSnapshot()
		}
		time.AfterFunc(focusInputCarryDelay, func() {
			c.resolveAmbiguousFocusInput(focusGeneration, focusSequence)
		})
	}
	result.claimsFocus = result.claimsFocus || len(filteredInput) > 0
}

func (c *attachClient) storeBracketedPasteStartCarryLocked(data []byte) {
	c.inputBracketedPasteStartCarry = append(
		c.inputBracketedPasteStartCarry[:0],
		data...,
	)
	c.inputBracketedPasteCarryGeneration++
	if c.focusSequenceSnapshot != nil {
		c.inputBracketedPasteCarryFocusSequence = c.focusSequenceSnapshot()
	} else {
		c.inputBracketedPasteCarryFocusSequence = 0
	}
	generation := c.inputBracketedPasteCarryGeneration
	time.AfterFunc(bracketedPasteStartCarryDelay, func() {
		c.resolveAmbiguousBracketedPasteStart(generation)
	})
}

func (c *attachClient) resolveAmbiguousBracketedPasteStart(generation uint64) {
	c.inputDispatchMu.Lock()
	defer c.inputDispatchMu.Unlock()
	c.activityMu.Lock()
	if c.inputBracketedPasteCarryGeneration != generation ||
		len(c.inputBracketedPasteStartCarry) == 0 {
		c.activityMu.Unlock()
		return
	}
	if c.inputBracketedPasteActive {
		c.inputBracketedPasteCarryGeneration++
		nextGeneration := c.inputBracketedPasteCarryGeneration
		time.AfterFunc(bracketedPasteStartCarryDelay, func() {
			c.resolveAmbiguousBracketedPasteStart(nextGeneration)
		})
		c.activityMu.Unlock()
		return
	}
	c.inputMu.Lock()
	data := append([]byte(nil), c.inputBracketedPasteStartCarry...)
	c.inputBracketedPasteStartCarry = nil
	c.inputBracketedPasteCarryGeneration++
	focusSequence := c.inputBracketedPasteCarryFocusSequence
	c.inputBracketedPasteCarryFocusSequence = 0
	claim := c.focusClaim
	passthrough := c.inputPassthrough
	c.activityMu.Unlock()
	c.inputMu.Unlock()
	select {
	case <-c.done:
		return
	default:
	}
	if claim != nil {
		claim(focusSequence)
	}
	if passthrough != nil {
		passthrough(data)
	}
}

func (c *attachClient) hasExpectedTerminalResponseLocked() bool {
	return c.terminalResponseActiveWindow != "" ||
		len(c.terminalResponseWindows) > 0
}

func (c *attachClient) resetTerminalResponseStateLocked() {
	c.terminalResponseCarry = nil
	c.terminalResponseCarryGeneration++
	c.terminalResponseContinuation = 0
	c.terminalResponseContinuationEscape = false
	c.terminalResponseContinuationUtf8 = 0
	c.terminalResponsePasteStartCarry = nil
	c.terminalResponseWindows = nil
	c.terminalResponseActiveWindow = ""
	c.terminalResponseUntil = time.Time{}
}

func (c *attachClient) renewTerminalResponseDeadlineLocked() {
	c.terminalResponseUntil = time.Now().Add(terminalResponseFocusGrace)
	if len(c.terminalResponseCarry) > 0 ||
		len(c.terminalResponsePasteStartCarry) > 0 {
		c.scheduleTerminalResponseCarryLocked()
	}
}

func (c *attachClient) storeTerminalResponseCarryLocked(
	data []byte,
) {
	c.terminalResponseCarry = append(c.terminalResponseCarry[:0], data...)
	c.scheduleTerminalResponseCarryLocked()
}

func (c *attachClient) scheduleTerminalResponseCarryLocked() {
	c.terminalResponseCarryGeneration++
	generation := c.terminalResponseCarryGeneration
	focusSequence := uint64(0)
	if c.focusSequenceSnapshot != nil {
		focusSequence = c.focusSequenceSnapshot()
	}
	delay := time.Until(c.terminalResponseUntil)
	if delay < 0 {
		delay = 0
	}
	time.AfterFunc(delay, func() {
		c.resolveAmbiguousTerminalResponseInput(generation, focusSequence)
	})
}

func (c *attachClient) resolveAmbiguousTerminalResponseInput(
	generation uint64,
	focusSequence uint64,
) {
	c.inputDispatchMu.Lock()
	defer c.inputDispatchMu.Unlock()
	c.activityMu.Lock()
	if c.terminalResponseCarryGeneration != generation ||
		(len(c.terminalResponseCarry) == 0 &&
			len(c.terminalResponsePasteStartCarry) == 0) {
		c.activityMu.Unlock()
		return
	}
	if c.inputBracketedPasteActive {
		c.renewTerminalResponseDeadlineLocked()
		c.activityMu.Unlock()
		return
	}
	c.inputMu.Lock()
	data := make(
		[]byte,
		0,
		len(c.terminalResponseCarry)+
			len(c.terminalResponsePasteStartCarry),
	)
	data = append(data, c.terminalResponseCarry...)
	data = append(data, c.terminalResponsePasteStartCarry...)
	c.terminalResponseCarry = nil
	c.terminalResponsePasteStartCarry = nil
	c.terminalResponseCarryGeneration++
	if !c.terminalResponseUntil.IsZero() &&
		time.Now().After(c.terminalResponseUntil) {
		c.resetTerminalResponseStateLocked()
	}
	claim := c.focusClaim
	passthrough := c.inputPassthrough
	c.activityMu.Unlock()
	defer c.inputMu.Unlock()

	select {
	case <-c.done:
		return
	default:
	}
	if claim != nil {
		claim(focusSequence)
	}
	if passthrough != nil {
		passthrough(data)
	}
}

func (c *attachClient) currentTerminalResponseWindowLocked() string {
	if c.terminalResponseActiveWindow != "" {
		return c.terminalResponseActiveWindow
	}
	if len(c.terminalResponseWindows) == 0 {
		return ""
	}
	c.terminalResponseActiveWindow = c.terminalResponseWindows[0]
	c.terminalResponseWindows = c.terminalResponseWindows[1:]
	return c.terminalResponseActiveWindow
}

func (c *attachClient) finishTerminalResponseLocked() {
	c.terminalResponseActiveWindow = ""
	if len(c.terminalResponseWindows) == 0 {
		c.terminalResponseUntil = time.Time{}
	}
}

func (c *attachClient) finishTerminalResponseSequenceLocked(
	windowID string,
	sequence []byte,
) {
	c.finishTerminalResponseLocked()
	remaining := terminalResponseSequenceExpectationCount(sequence) - 1
	for remaining > 0 &&
		len(c.terminalResponseWindows) > 0 &&
		c.terminalResponseWindows[0] == windowID {
		c.terminalResponseWindows = c.terminalResponseWindows[1:]
		remaining--
	}
	if len(c.terminalResponseWindows) == 0 {
		c.terminalResponseUntil = time.Time{}
	}
}

func (c *attachClient) resolveAmbiguousFocusInput(
	generation uint64,
	focusSequence uint64,
) {
	c.activityMu.Lock()
	if c.focusInputGeneration != generation || len(c.focusInputCarry) == 0 {
		c.activityMu.Unlock()
		return
	}
	c.focusInputCarry = nil
	c.focusInputGeneration++
	claim := c.focusClaim
	c.activityMu.Unlock()
	if claim != nil {
		claim(focusSequence)
	}
}

func (s *muxServer) primaryAttachSizeLocked() (int, int) {
	width := s.width
	height := s.height
	client := s.primaryAttachClientLocked()
	if client == nil {
		return width, height
	}
	if client.width > 0 {
		width = client.width
	}
	if client.height > 0 {
		height = client.height
	}
	return width, height
}

func (s *muxServer) hasViewportClippingClientLocked() bool {
	for _, client := range s.attachClients {
		if client.clipViewport {
			return true
		}
	}
	return false
}

func terminalViewportTransitionSafe(window *muxWindow) bool {
	return window == nil ||
		window.closed ||
		(!window.terminalOutputForwarding &&
			!window.redrawForwardingPaused &&
			len(window.secondaryQueryCarry) == 0 &&
			window.queryUtf8Remaining == 0 &&
			window.terminalOutputIsGroundLocked())
}

func (s *muxServer) primaryAttachClientLocked() *attachClient {
	return s.attachClients[s.attachConn]
}

func (s *muxServer) attachClientByIDLocked(clientID string) *attachClient {
	normalizedID := strings.TrimSpace(clientID)
	if normalizedID == "" {
		return s.primaryAttachClientLocked()
	}
	var matched *attachClient
	for _, client := range s.attachClients {
		if client.id != normalizedID {
			continue
		}
		if matched == nil || client.sequence > matched.sequence {
			matched = client
		}
	}
	return matched
}

func moreRecentlyFocusedAttachClient(
	first *attachClient,
	second *attachClient,
) bool {
	firstFocus := first.focusSequence.Load()
	secondFocus := second.focusSequence.Load()
	if firstFocus != secondFocus {
		return firstFocus > secondFocus
	}
	return first.sequence > second.sequence
}

func (s *muxServer) isAttachConnectionLocked(conn net.Conn) bool {
	if conn == nil {
		return false
	}
	_, ok := s.attachClients[conn]
	return ok
}

// capabilityHintLocked returns the static terminal replies to answer a window's
// capability probes with. The primary attached client's hint wins, including
// when it has none: a client that did not declare its capabilities (an older
// helper, or a plain terminal running `monkeymux attach`) must not have another
// client's terminal identity advertised on its behalf. The session-level hint
// is only used while no attach client is registered — the upgrade-restore
// window this whole mechanism exists for.
func (s *muxServer) capabilityHintLocked() []byte {
	if client, ok := s.attachClients[s.attachConn]; ok && client != nil {
		return client.capabilityHint
	}
	return s.capabilityHint
}

func (s *muxServer) attachCountLocked() int {
	return len(s.attachClients)
}

func (s *muxServer) promoteAttachClient(client *attachClient) {
	s.focusAttachClient(client, 0, 0, true)
}

func (s *muxServer) focusSequenceSnapshot() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.nextFocusSequence
}

func (s *muxServer) focusAttachClientIfUnchanged(
	client *attachClient,
	expectedFocusSequence uint64,
) bool {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	if client == nil {
		return false
	}
	s.mu.Lock()
	if s.nextFocusSequence != expectedFocusSequence {
		s.mu.Unlock()
		return false
	}
	registered := s.attachClients[client.conn]
	if registered == nil {
		s.mu.Unlock()
		return false
	}
	primaryChanged := s.attachConn != registered.conn
	if primaryChanged {
		s.pendingFocusRefreshConn = nil
	}
	s.nextFocusSequence++
	registered.focusSequence.Store(s.nextFocusSequence)
	s.attachConn = registered.conn
	targetWidth, targetHeight := s.primaryAttachSizeLocked()
	sizeChanged :=
		targetWidth != s.publishedWidth ||
			targetHeight != s.publishedHeight
	s.mu.Unlock()
	s.applyFocusedClientViewport(
		registered,
		targetWidth,
		targetHeight,
		sizeChanged,
		primaryChanged,
	)
	return true
}

func (s *muxServer) focusAttachClientByID(
	clientID string,
	width int,
	height int,
	forceRedraw bool,
) bool {
	return s.focusAttachClientByIDWithResult(
		clientID,
		width,
		height,
		forceRedraw,
	).focused
}

func (s *muxServer) focusAttachClientByIDWithResult(
	clientID string,
	width int,
	height int,
	forceRedraw bool,
) attachFocusResult {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	client := s.attachClientByIDLocked(clientID)
	s.mu.Unlock()
	return s.focusAttachClientLocked(client, width, height, forceRedraw)
}

func (s *muxServer) focusAttachClient(
	client *attachClient,
	width int,
	height int,
	forceRedraw bool,
) bool {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	return s.focusAttachClientLocked(
		client,
		width,
		height,
		forceRedraw,
	).focused
}

func (s *muxServer) focusAttachClientLocked(
	client *attachClient,
	width int,
	height int,
	forceRedraw bool,
) attachFocusResult {
	if client == nil {
		return attachFocusResult{}
	}
	s.mu.Lock()
	registered := s.attachClients[client.conn]
	if registered == nil {
		s.mu.Unlock()
		return attachFocusResult{}
	}
	if width > 0 {
		registered.width = width
	}
	if height > 0 {
		registered.height = height
	}
	primaryChanged := s.attachConn != registered.conn
	if primaryChanged {
		s.pendingFocusRefreshConn = nil
	}
	s.nextFocusSequence++
	registered.focusSequence.Store(s.nextFocusSequence)
	s.attachConn = registered.conn
	targetWidth, targetHeight := s.primaryAttachSizeLocked()
	sizeChanged :=
		targetWidth != s.publishedWidth ||
			targetHeight != s.publishedHeight
	s.mu.Unlock()
	s.applyFocusedClientViewport(
		registered,
		targetWidth,
		targetHeight,
		sizeChanged,
		primaryChanged && forceRedraw,
	)
	return attachFocusResult{
		focused:        true,
		primaryChanged: primaryChanged,
	}
}

func (s *muxServer) applyFocusedClientViewport(
	client *attachClient,
	width int,
	height int,
	sizeChanged bool,
	refreshOnHandoff bool,
) {
	if refreshOnHandoff {
		s.replayFocusedWindowToClient(client, width, height)
		return
	}
	if sizeChanged {
		s.resizeWithRedraw(width, height, false, false, "")
	}
}

func (s *muxServer) refreshPendingFocusedClient() {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	conn := s.pendingFocusRefreshConn
	if conn == nil {
		s.mu.Unlock()
		return
	}
	s.pendingFocusRefreshConn = nil
	client := s.attachClients[conn]
	if client == nil || s.attachConn != conn {
		s.mu.Unlock()
		return
	}
	width, height := s.primaryAttachSizeLocked()
	s.mu.Unlock()
	s.replayFocusedWindowToClient(client, width, height)
}

func (s *muxServer) refreshPendingClientViewport(
	refreshFocus bool,
	refreshResize bool,
) {
	if refreshFocus {
		s.refreshPendingFocusedClient()
	}
	if refreshResize {
		s.refreshPendingViewportResize()
	}
}

func (s *muxServer) removeAttachClient(client *attachClient) {
	if client == nil {
		return
	}
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	var width int
	var height int
	var sizeChanged bool
	var primaryRemoved bool
	s.mu.Lock()
	if _, ok := s.attachClients[client.conn]; !ok {
		s.mu.Unlock()
		client.close()
		return
	}
	delete(s.attachClients, client.conn)
	if s.pendingFocusRefreshConn == client.conn {
		s.pendingFocusRefreshConn = nil
	}
	if s.attachConn == client.conn {
		primaryRemoved = true
		s.attachConn = nil
		var replacement *attachClient
		for _, candidate := range s.attachClients {
			if replacement == nil ||
				candidate.focusSequence.Load() >
					replacement.focusSequence.Load() ||
				(candidate.focusSequence.Load() ==
					replacement.focusSequence.Load() &&
					candidate.sequence > replacement.sequence) {
				replacement = candidate
			}
		}
		if replacement != nil {
			s.attachConn = replacement.conn
		}
	}
	width, height = s.primaryAttachSizeLocked()
	if primaryRemoved {
		s.pendingResizeWidth = 0
		s.pendingResizeHeight = 0
		s.pendingResizeRedraw = false
		s.pendingResizeSyntheticRedraw = false
		s.pendingResizeThemeWindowID = ""
		if s.attachConn == nil {
			width = s.publishedWidth
			height = s.publishedHeight
		}
		s.width = width
		s.height = height
	}
	sizeChanged =
		width != s.publishedWidth ||
			height != s.publishedHeight
	s.mu.Unlock()
	client.close()
	if sizeChanged {
		s.resizeWithRedraw(width, height, false, false, "")
	}
}

func (s *muxServer) handleAttach(conn net.Conn, reader *bufio.Reader, hello controlMessage) {
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var activeWindowID string
	var themeHintData []byte
	var themeHintWindowID string
	var sendFocusTransition bool
	client := newAttachClient(conn, hello)
	client.focusSequenceSnapshot = s.focusSequenceSnapshot
	client.focusClaim = func(expectedFocusSequence uint64) {
		s.focusAttachClientIfUnchanged(client, expectedFocusSequence)
	}
	client.inputPassthrough = func(data []byte) {
		client.enqueueInputActions([]attachInputAction{{
			userInput: true,
			data:      append([]byte(nil), data...),
		}})
	}
	go s.runAttachInputActions(client)
	transitionDeadline := time.Now().Add(attachTransitionTimeout)
	s.attachTransitionMu.Lock()
	attachTransitionLocked := true
	defer func() {
		if attachTransitionLocked {
			s.attachTransitionMu.Unlock()
		}
	}()
	transitionWindowID := ""
	for {
		s.mu.Lock()
		if s.closed || !time.Now().Before(transitionDeadline) {
			s.attachViewportTransitionWindowID = ""
			s.mu.Unlock()
			client.close()
			return
		}
		transitionWindowID = s.activeID
		s.attachViewportTransitionWindowID = transitionWindowID
		window := s.windowByIDLocked(transitionWindowID)
		transitionSafe := terminalViewportTransitionSafe(window)
		s.mu.Unlock()
		if !transitionSafe {
			time.Sleep(time.Millisecond)
			continue
		}

		s.resizeMu.Lock()
		s.attachMu.Lock()
		s.mu.Lock()
		window = s.windowByIDLocked(s.activeID)
		if !s.closed && time.Now().Before(transitionDeadline) &&
			s.activeID == transitionWindowID &&
			terminalViewportTransitionSafe(window) {
			break
		}
		s.mu.Unlock()
		s.attachMu.Unlock()
		s.resizeMu.Unlock()
		time.Sleep(time.Millisecond)
	}
	if s.attachClients == nil {
		s.attachClients = map[net.Conn]*attachClient{}
	}
	s.nextAttachSequence++
	client.sequence = s.nextAttachSequence
	s.nextFocusSequence++
	client.focusSequence.Store(s.nextFocusSequence)
	s.attachClients[conn] = client
	s.attachConn = conn
	if themeHint := themeHintDataFromString(hello.Data); len(themeHint) > 0 {
		s.themeHint = append(s.themeHint[:0], themeHint...)
	}
	if hint := capabilityHintDataFromString(hello.CapabilityHint); len(hint) > 0 {
		s.capabilityHint = append(s.capabilityHint[:0], hint...)
	}
	width, height := s.primaryAttachSizeLocked()
	window := s.windowByIDLocked(s.activeID)
	if width > 0 && height > 0 {
		s.pendingFocusRefreshConn = nil
		s.pendingResizeWidth = 0
		s.pendingResizeHeight = 0
		s.pendingResizeRedraw = false
		s.pendingResizeSyntheticRedraw = false
		s.pendingResizeThemeWindowID = ""
		s.width = width
		s.height = height
		s.enqueueAttachViewportResizeLocked(width, height)
		s.publishedWidth = width
		s.publishedHeight = height
		s.resizeActiveLocked(width, height)
	} else {
		s.pendingFocusRefreshConn = nil
	}
	replay := s.activeReplayLocked()
	var completion <-chan error
	var queued bool
	if window != nil {
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
		redrawWindow = window
		activeWindowID = window.id
		client.markOutputReplay(activeWindowID, window.outputGeneration)
		if len(s.themeHint) > 0 {
			themeHintData = window.themeHintRefreshDataLocked(s.themeHint)
			themeHintWindowID = window.id
			sendFocusTransition = window.themeHintFocusTransitionLocked()
		}
	}
	completion, queued = client.enqueue(replay, true)
	if !queued {
		client.clearOutputReplay()
	}
	s.attachViewportTransitionWindowID = ""
	s.mu.Unlock()
	s.attachMu.Unlock()
	s.resizeMu.Unlock()
	s.attachTransitionMu.Unlock()
	attachTransitionLocked = false
	if queued {
		queued = client.waitForWrite(completion)
	}
	s.attachMu.Lock()
	redrew := false
	if queued {
		redrew = s.simulateForegroundResizeIfAttached(conn, redrawWindow)
	}
	s.flushPendingTerminalQueriesLocked(conn, activeWindowID)
	s.attachMu.Unlock()
	if len(themeHintData) > 0 {
		_ = s.writeWindow(themeHintWindowID, themeHintData)
	}
	if sendFocusTransition {
		s.sendFocusTransition(themeHintWindowID)
	}
	s.broadcastWindowList("active_window_changed")
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	s.scheduleRestoreRedrawFollowUps(activeWindowID)

	defer func() {
		s.removeAttachClient(client)
	}()

	buf := make([]byte, 32*1024)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			client.inputDispatchMu.Lock()
			routing := client.routeInput(buf[:n])
			if routing.claimsFocus {
				s.promoteAttachClient(client)
			}
			enqueued := client.enqueueInputActions(routing.actions)
			client.inputDispatchMu.Unlock()
			if !enqueued {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func (s *muxServer) runAttachInputActions(client *attachClient) {
	for {
		action, ok := client.nextInputAction()
		if !ok {
			return
		}
		if action.userInput {
			if s.handleAttachInputSerialized(
				client,
				action.data,
				action.bracketedPaste,
			) {
				client.close()
				return
			}
			continue
		}
		if action.windowID == "" {
			s.mu.Lock()
			action.windowID = s.activeID
			s.mu.Unlock()
		}
		_ = s.writeWindow(action.windowID, action.data)
	}
}

func (s *muxServer) handleControl(conn net.Conn, reader *bufio.Reader) {
	client := newControlClient(conn)
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		_ = conn.Close()
		return
	}
	s.controls[client] = struct{}{}
	s.mu.Unlock()
	defer func() {
		client.close()
		s.removeControl(client)
		_ = conn.Close()
	}()

	client.send(controlResponse{
		Type:         "hello",
		Status:       "ok",
		Version:      monkeyMuxVersion,
		Session:      s.session,
		Capabilities: capabilities,
		AttachCount:  s.attachCount(),
	})
	client.send(controlResponse{
		Type:    "window_list",
		Status:  "ok",
		Session: s.session,
		Windows: s.snapshots(),
	})

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), controlMaxFrameBytes)
	for scanner.Scan() {
		var request controlMessage
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			client.send(controlResponse{
				Type:   "error",
				Status: "error",
				Error:  err.Error(),
			})
			continue
		}
		s.handleControlRequest(client, request)
	}
}

func (s *muxServer) handleControlRequest(client *controlClient, request controlMessage) {
	switch request.Type {
	case "ping":
		client.send(controlResponse{ID: request.ID, Type: "pong", Status: "ok"})
	case "list_windows":
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "window_list",
			Status:  "ok",
			Session: s.session,
			Windows: s.snapshots(),
		})
	case "upgrade_snapshot":
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "upgrade_snapshot",
			Status:  "ok",
			Session: s.session,
			Restore: s.restoreSnapshot(),
		})
	case "create_window":
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
		window, err := s.createWindow(createWindowOptions{
			name:    request.Name,
			cwd:     request.Cwd,
			command: request.Command,
			args:    request.Args,
		})
		if err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "window_created",
			Status:  "ok",
			Session: s.session,
			Window:  ptrWindowSnapshot(s.snapshot(window)),
		})
	case "select_window":
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		clientImages := request.HaveImageSignatures
		if !s.canUseClientImageSignatures(request.ClientID) {
			clientImages = nil
		}
		var err error
		if request.SuppressReplay {
			err = s.selectWindowWithoutReplay(id)
		} else {
			err = s.selectWindowWithSkip(id, clientImages)
		}
		if err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_selected", Status: "ok"})
	case "request_images":
		served := s.replayRequestedImages(request.ClientID, request.ImageIDs)
		client.send(controlResponse{
			ID:                 request.ID,
			Type:               "images_replayed",
			Status:             "ok",
			ImageIDs:           served,
			ImagesAcknowledged: true,
		})
	case "close_window", "kill_window":
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		shouldShutdown, err := s.closeWindow(id)
		if err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_closed", Status: "ok"})
		if shouldShutdown {
			go s.close()
		}
	case "resize":
		if request.Width <= 0 || request.Height <= 0 {
			client.sendError(request, errors.New("invalid terminal size"))
			return
		}
		s.resizeForClient(
			request.ClientID,
			request.Width,
			request.Height,
			request.Redraw,
		)
		client.send(controlResponse{ID: request.ID, Type: "resized", Status: "ok"})
	case "focus_client":
		if strings.TrimSpace(request.ClientID) == "" {
			client.sendError(request, errors.New("missing client id"))
			return
		}
		if request.Width <= 0 || request.Height <= 0 {
			client.sendError(request, errors.New("invalid terminal size"))
			return
		}
		result := s.focusAttachClientByIDWithResult(
			request.ClientID,
			request.Width,
			request.Height,
			request.Redraw,
		)
		if !result.focused {
			client.sendError(request, errors.New("foreground client is not attached"))
			return
		}
		client.send(controlResponse{
			ID:           request.ID,
			Type:         "client_focused",
			Status:       "ok",
			FocusChanged: result.primaryChanged,
		})
	case "query_active_context":
		s.refreshProcessMetadata("")
		s.mu.Lock()
		window := s.windowByIDLocked(s.activeID)
		if window == nil || window.closed {
			s.mu.Unlock()
			client.sendError(request, errors.New("no active window"))
			return
		}
		currentPath := window.cwd
		currentCommand := window.currentCommandLocked()
		s.mu.Unlock()
		client.send(controlResponse{
			ID:             request.ID,
			Type:           "active_context",
			Status:         "ok",
			Session:        s.session,
			CurrentPath:    currentPath,
			CurrentCommand: currentCommand,
		})
	case "query_attach_state":
		// The MonkeySSH mux bar may only appear for the SSH connection whose
		// own attach client owns the session, so this answer is always scoped
		// to an exact client ID. A query without one reports no attach rather
		// than leaking another connection's attach state.
		hasAttach := s.hasAttachClientByID(request.ClientID)
		client.send(controlResponse{
			ID:          request.ID,
			Type:        "attach_state",
			Status:      "ok",
			Session:     s.session,
			HasAttach:   hasAttach,
			AttachCount: s.attachCount(),
		})
	case "run_command":
		if strings.TrimSpace(request.Command) == "" {
			client.sendError(request, errors.New("missing command"))
			return
		}
		client.runShellCommandAsync(s, request)
	case "start_acp_bridge":
		client.startAcpBridgeAsync(s, request)
	case "inject_input":
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
		id := request.WindowID
		if id == "" {
			id = s.activeWindowID()
		}
		if err := s.writeWindowInput(
			id,
			[]byte(request.Data),
			request.BracketedPaste,
		); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "input_injected", Status: "ok"})
	case "focus_changed":
		s.focusAttachClientByID(request.ClientID, request.Width, request.Height, false)
		s.sendThemeHint(request.Data)
		client.send(controlResponse{ID: request.ID, Type: "focus_hint_sent", Status: "ok"})
	case "theme_changed":
		themeWindowID, _ := s.sendThemeHintToActiveWindow(request.Data)
		if request.Redraw {
			// A theme switch changes colors without changing the PTY size, and
			// a same-size SIGWINCH alone will not make a TUI re-emit its
			// explicitly-colored regions (e.g. Copilot CLI's header/footer
			// bars), so force a full repaint of the window that received the
			// hint after it has been delivered.
			s.forceForegroundThemeRedraw(themeWindowID)
		}
		client.send(controlResponse{ID: request.ID, Type: "theme_hint_ack", Status: "ok"})
	case "shutdown":
		client.send(controlResponse{ID: request.ID, Type: "shutdown", Status: "ok"})
		go s.close()
	default:
		client.sendError(request, fmt.Errorf("unsupported command %q", request.Type))
	}
}

func (s *muxServer) removeControl(client *controlClient) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.controls, client)
}

func (s *muxServer) hasAttachClientByID(clientID string) bool {
	normalizedID := strings.TrimSpace(clientID)
	if normalizedID == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attachClientByIDLocked(normalizedID) != nil
}

func (s *muxServer) attachCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attachCountLocked()
}

func (s *muxServer) canUseClientImageSignatures(clientID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attachCountLocked() != 1 {
		return false
	}
	normalizedID := strings.TrimSpace(clientID)
	if normalizedID == "" {
		return true
	}
	for _, client := range s.attachClients {
		return client.id == normalizedID
	}
	return false
}

func newControlClient(conn net.Conn) *controlClient {
	client := &controlClient{
		conn:     conn,
		commands: map[string]context.CancelFunc{},
	}
	if conn != nil {
		client.enc = json.NewEncoder(conn)
	}
	return client
}

func (c *controlClient) send(response controlResponse) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.enc == nil {
		return
	}
	_ = c.conn.SetWriteDeadline(time.Now().Add(socketTimeout))
	if err := c.enc.Encode(response); err != nil {
		_ = c.conn.Close()
	}
}

func (c *controlClient) sendError(request controlMessage, err error) {
	c.send(controlResponse{
		ID:     request.ID,
		Type:   "error",
		Status: "error",
		Error:  err.Error(),
	})
}

func (c *controlClient) trackCommand(key string, cancel context.CancelFunc) bool {
	c.commandsMu.Lock()
	defer c.commandsMu.Unlock()
	if c.closed {
		return false
	}
	c.commands[key] = cancel
	return true
}

func (c *controlClient) untrackCommand(key string) {
	c.commandsMu.Lock()
	defer c.commandsMu.Unlock()
	delete(c.commands, key)
}

func (c *controlClient) close() {
	c.commandsMu.Lock()
	if c.closed {
		c.commandsMu.Unlock()
		return
	}
	c.closed = true
	cancels := make([]context.CancelFunc, 0, len(c.commands))
	for _, cancel := range c.commands {
		cancels = append(cancels, cancel)
	}
	c.commands = map[string]context.CancelFunc{}
	c.commandsMu.Unlock()

	for _, cancel := range cancels {
		cancel()
	}
}

func startAcpBridgeInProcess(
	ctx context.Context,
	providerID string,
	provider string,
	command string,
	cwd string,
) (string, error) {
	if err := validateAcpLaunch(provider, command, cwd); err != nil {
		return "", err
	}
	if err := validateAcpProviderID(providerID); err != nil {
		return "", err
	}
	id, err := newAcpBridgeID()
	if err != nil {
		return "", errors.New("unable to allocate ACP bridge")
	}
	bridge, err := newAcpBridge(id, providerID, provider, command, cwd)
	if errors.Is(err, errCursorAgentKeychainLocked) {
		return "", errCursorAgentKeychainLocked
	}
	if err != nil {
		return "", errors.New("unable to start ACP provider")
	}
	bridge.providerID = providerID
	serveDone := make(chan error, 1)
	go func() { serveDone <- serveAcpBridge(bridge) }()

	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case err := <-serveDone:
			if err == nil {
				err = errors.New("ACP bridge stopped before startup")
			}
			return "", err
		case <-ctx.Done():
			bridge.stop()
			return "", errors.New("ACP bridge did not start")
		case <-ticker.C:
			conn, err := dialAcpBridge(id)
			if err == nil {
				_ = conn.Close()
				return id, nil
			}
		}
	}
}

func (c *controlClient) startAcpBridgeAsync(s *muxServer, request controlMessage) {
	commandKey := fmt.Sprintf("%s/acp/%d", request.ID, time.Now().UnixNano())
	ctx, cancel := context.WithTimeout(context.Background(), socketTimeout)
	if !c.trackCommand(commandKey, cancel) {
		cancel()
		c.sendError(request, errRunCommandClientClosed)
		return
	}
	go func() {
		defer c.untrackCommand(commandKey)
		defer cancel()
		bridgeID, err := startAcpBridgeInProcess(
			ctx,
			request.ProviderID,
			request.Provider,
			request.Command,
			request.Cwd,
		)
		if err != nil {
			c.sendError(request, err)
			return
		}
		windowArgs, err := nativeAcpWindowArguments(bridgeID)
		if err != nil {
			_ = requestAcpBridgeStopAndWait(bridgeID)
			c.sendError(request, errors.New("unable to create native agent window"))
			return
		}
		window, err := s.createWindow(createWindowOptions{
			name:                request.Provider,
			cwd:                 request.Cwd,
			args:                windowArgs,
			nativeAcpBridgeID:   bridgeID,
			nativeAcpProviderID: request.ProviderID,
		})
		if err != nil {
			_ = requestAcpBridgeStopAndWait(bridgeID)
			c.sendError(request, errors.New("unable to create native agent window"))
			return
		}
		frame, err := json.Marshal(acpWireMessage{
			Version:  acpBridgeProtocolVersion,
			Type:     "started",
			BridgeID: bridgeID,
			WindowID: window.id,
		})
		if err != nil {
			c.sendError(request, errors.New("unable to encode ACP bridge response"))
			return
		}
		c.send(controlResponse{
			ID:      request.ID,
			Type:    "acp_bridge_started",
			Status:  "ok",
			Session: s.session,
			Data:    string(frame),
		})
	}()
}

func (c *controlClient) runShellCommandAsync(s *muxServer, request controlMessage) {
	commandKey := fmt.Sprintf("%s/%d", request.ID, time.Now().UnixNano())
	go func() {
		output, exitCode, err := c.runShellCommand(s, commandKey, request.Command)
		if err != nil {
			c.sendError(request, err)
			return
		}
		c.send(controlResponse{
			ID:       request.ID,
			Type:     "command_output",
			Status:   "ok",
			Session:  s.session,
			Data:     output,
			ExitCode: exitCode,
		})
	}()
}

func (c *controlClient) runShellCommand(
	s *muxServer,
	commandKey string,
	command string,
) (string, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), runCommandTimeout)
	if !c.trackCommand(commandKey, cancel) {
		cancel()
		return "", 0, errRunCommandClientClosed
	}
	defer c.untrackCommand(commandKey)
	defer cancel()
	return s.runShellCommandContext(ctx, command)
}

func (s *muxServer) broadcast(response controlResponse) {
	s.mu.Lock()
	clients := make([]*controlClient, 0, len(s.controls))
	for client := range s.controls {
		clients = append(clients, client)
	}
	s.mu.Unlock()
	for _, client := range clients {
		client.send(response)
	}
}

func (s *muxServer) broadcastWindowList(eventType string) {
	s.broadcast(controlResponse{
		Type:    eventType,
		Session: s.session,
		Windows: s.snapshots(),
	})
}

func (s *muxServer) snapshots() []windowSnapshot {
	s.refreshAllProcessMetadata()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotsLocked()
}

func (s *muxServer) snapshotsLocked() []windowSnapshot {
	windows := make([]windowSnapshot, 0, len(s.windows))
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		windows = append(windows, s.snapshotLocked(window))
	}
	return windows
}

func (s *muxServer) restoreSnapshot() *serverRestore {
	s.refreshAllProcessMetadata()
	s.mu.Lock()
	defer s.mu.Unlock()

	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows:       make([]restoreWindowState, 0, len(s.windows)),
	}
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		state := restoreWindowState{
			ID:                        window.id,
			Index:                     window.index,
			Name:                      window.name,
			Cwd:                       window.cwd,
			CurrentCommand:            window.currentCommandLocked(),
			PanePid:                   window.metadataProcessIDLocked(),
			PaneTitle:                 window.paneTitle,
			AgentTool:                 window.agentToolLocked(),
			AgentToolConfirmed:        window.agentToolConfirmedLocked(),
			AgentSessionID:            window.agentSessionID,
			AgentSessionDir:           window.agentSessionDir,
			AgentSessionPath:          window.agentSessionPath,
			AgentSessionIdentityExact: window.agentSessionIdentityExact,
			NativeAcpBridgeID:         window.nativeAcpBridgeID,
			NativeAcpProviderID:       window.nativeAcpProviderID,
			LastActivityEpochSeconds:  window.lastActivity.Unix(),
			CursorVisible:             window.cursorVisible,
			CursorVisibilityKnown:     window.cursorVisibilityKnown,
			PrivateModes:              copyPrivateModes(window.privateModes),
			TerminalProgress:          copyTerminalProgressSnapshot(window.terminalProgress),
			InsertModeEnabled:         window.insertModeEnabled,
			InsertModeKnown:           window.insertModeKnown,
			ApplicationKeypadEnabled:  window.applicationKeypadEnabled,
			ApplicationKeypadKnown:    window.applicationKeypadKnown,
			Active:                    s.activeID == window.id,
		}
		if isShellRestoreWindow(state) && len(window.history) > 0 {
			history, historyStart := window.historyTailWithParserLocked()
			history = terminalHistoryAtGroundBoundaries(history, historyStart)
			if len(history) > 0 {
				state.HistoryBase64 = base64.StdEncoding.EncodeToString(history)
				state.HistoryStartsAtGround = true
			}
		}
		restore.Windows = append(restore.Windows, state)
	}
	return restore
}

func (s *muxServer) snapshot(window *muxWindow) windowSnapshot {
	s.refreshProcessMetadata(window.id)
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked(window)
}

func (s *muxServer) snapshotLocked(window *muxWindow) windowSnapshot {
	flags := ""
	if window.alert {
		flags = "#"
	}
	return windowSnapshot{
		ID:                        window.id,
		Index:                     window.index,
		Name:                      window.name,
		Active:                    s.activeID == window.id,
		CurrentCommand:            window.currentCommandLocked(),
		CurrentPath:               window.cwd,
		PanePid:                   window.metadataProcessIDLocked(),
		Flags:                     flags,
		PaneTitle:                 window.paneTitle,
		AgentTool:                 window.agentToolLocked(),
		AgentToolConfirmed:        window.agentToolConfirmedLocked(),
		AgentSessionID:            window.agentSessionID,
		AgentSessionDir:           window.agentSessionDir,
		AgentSessionPath:          window.agentSessionPath,
		AgentSessionIdentityExact: window.agentSessionIdentityExact,
		NativeAcpBridgeID:         window.nativeAcpBridgeID,
		NativeAcpProviderID:       window.nativeAcpProviderID,
		LastActivityEpochSeconds:  window.lastActivity.Unix(),
		TerminalReportsMouseWheel: window.reportsMouseWheelLocked(),
		TerminalMouseReportSgr:    window.mouseTrackingActiveLocked() && window.privateModes["1006"],
		TerminalBracketedPaste:    window.privateModes["2004"],
		PrivateModes:              copyPrivateModes(window.privateModes),
		TerminalProgress:          copyTerminalProgressSnapshot(window.terminalProgress),
	}
}

func (s *muxServer) runShellCommand(command string) (string, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), runCommandTimeout)
	defer cancel()
	return s.runShellCommandContext(ctx, command)
}

func (s *muxServer) runShellCommandContext(
	ctx context.Context,
	command string,
) (string, int, error) {
	s.mu.Lock()
	cwd := ""
	if window := s.windowByIDLocked(s.activeID); window != nil {
		cwd = window.cwd
	}
	s.mu.Unlock()

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	output := newBoundedCommandOutput(runCommandOutputMaxBytes, cancel)
	cmd := newRunCommand(command)
	cmd.WaitDelay = 250 * time.Millisecond
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = inheritedEnvironment(os.Environ())
	cmd.Stdout = output
	cmd.Stderr = output
	if err := cmd.Start(); err != nil {
		return "", 0, err
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	var err error
	select {
	case err = <-waitCh:
	case <-ctx.Done():
		killCommandProcessGroup(cmd)
		err = <-waitCh
	}

	if output.exceeded() {
		return output.String(), 0, errRunCommandOutputLimit
	}
	if ctx.Err() == context.DeadlineExceeded {
		return output.String(), 0, errRunCommandTimeout
	}
	if ctx.Err() == context.Canceled {
		return output.String(), 0, errRunCommandCanceled
	}
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return "", 0, err
		}
	}
	return output.String(), exitCode, nil
}

type boundedCommandOutput struct {
	mu        sync.Mutex
	buffer    bytes.Buffer
	limit     int
	cancel    context.CancelFunc
	overLimit bool
}

func newBoundedCommandOutput(
	limit int,
	cancel context.CancelFunc,
) *boundedCommandOutput {
	return &boundedCommandOutput{limit: limit, cancel: cancel}
}

func (o *boundedCommandOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	remaining := o.limit - o.buffer.Len()
	if remaining > 0 {
		if remaining > len(p) {
			remaining = len(p)
		}
		_, _ = o.buffer.Write(p[:remaining])
	}
	exceededNow := len(p) > remaining && !o.overLimit
	if len(p) > remaining {
		o.overLimit = true
	}
	cancel := o.cancel
	o.mu.Unlock()

	if exceededNow && cancel != nil {
		cancel()
	}
	return len(p), nil
}

func (o *boundedCommandOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buffer.String()
}

func (o *boundedCommandOutput) exceeded() bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.overLimit
}

func (s *muxServer) selectWindow(windowID string) error {
	return s.selectWindowWithSkip(windowID, nil)
}

// selectWindowWithoutReplay updates server/window focus without writing the
// placeholder's terminal snapshot. Native ACP clients replace the terminal
// viewport, so replaying and redrawing that hidden pseudo-pane only delays the
// handoff and can apply backpressure behind a large prior terminal frame.
func (s *muxServer) selectWindowWithoutReplay(windowID string) error {
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	if s.activeID != windowID {
		s.lastActiveID = s.activeID
		s.activeID = windowID
	}
	window.alert = false
	s.mu.Unlock()
	s.attachMu.Unlock()
	s.broadcastWindowList("active_window_changed")
	return nil
}

// replayRequestedImages re-sends specific retained Kitty image transmissions to
// the attach connection. The client calls this after a switch/redraw when it
// finds placeholder cells referencing images it never received (they fell
// outside the bounded switch replay). The bytes are the store-only (a=t)
// transmissions, so they only repopulate the client's image cache — the
// placeholder cells already on screen then resolve on the next repaint without
// drawing or moving the cursor. Only the active window is served: the attach
// connection is viewing it, and requested ids are scoped to what it just drew.
//
// The request carries no window id and resolves against whichever window is
// active when the server processes it. This is deliberate and safe if a window
// switch races the request: the ids are looked up in the now-active window's
// retained cache, so ids it does not hold are simply skipped (a no-op), and the
// client resets its per-visit request set on every window change and re-requests
// whatever the new window is still missing. The worst case is a redundant or
// skipped transmission, never a wrong-window image persisting on screen.
// Served ids are returned only after the attach write completes, which applies
// backpressure between the client's bounded repair batches.
func (s *muxServer) replayRequestedImages(
	clientID string,
	ids []string,
) []string {
	if len(ids) == 0 {
		return nil
	}
	var client *attachClient
	var payload []byte
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return nil
	}
	if normalizedID := strings.TrimSpace(clientID); normalizedID != "" {
		client = s.attachClientByIDLocked(normalizedID)
	} else {
		client = s.attachClients[s.attachConn]
	}
	if client == nil {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return nil
	}
	payload, ids = window.kittyImageTransmissionsForLocked(ids)
	s.mu.Unlock()
	if len(payload) == 0 {
		s.attachMu.Unlock()
		return nil
	}
	completion, queued := client.enqueue(payload, true)
	s.attachMu.Unlock()
	if !queued || !client.waitForWrite(completion) {
		return nil
	}
	return ids
}

// selectWindowWithSkip activates a window and streams its reattach replay,
// omitting retained Kitty images the client reports already holding in
// clientHas (nil replays every retained image).
func (s *muxServer) selectWindowWithSkip(
	windowID string,
	clientHas map[string]uint32,
) error {
	var replay []byte
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var primary net.Conn
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	resetViewportParser :=
		s.pendingFocusRefreshConn != nil ||
			(s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0)
	if s.activeID != windowID {
		s.lastActiveID = s.activeID
		s.activeID = windowID
	}
	window.alert = false
	s.pendingFocusRefreshConn = nil
	s.pendingResizeWidth = 0
	s.pendingResizeHeight = 0
	s.pendingResizeRedraw = false
	s.pendingResizeSyntheticRedraw = false
	s.pendingResizeThemeWindowID = ""
	if resetViewportParser {
		s.enqueueAttachViewportResizeAfterResetLocked(s.width, s.height)
	} else {
		s.enqueueAttachViewportResizeLocked(s.width, s.height)
	}
	s.publishedWidth = s.width
	s.publishedHeight = s.height
	targetWidth := s.width
	targetHeight := s.height
	if s.attachCountLocked() > 1 {
		clientHas = nil
	}
	primary = s.attachConn
	replay = s.replayBytesLockedWithSkip(window, clientHas)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	redrawWindow = window
	s.mu.Unlock()
	// The redraw below owns delivering this geometry to the PTY. Resizing here
	// first would leave it already at the target, forcing that redraw to
	// manufacture a temporary size and making the foreground app render a whole
	// extra frame for a geometry that never existed.
	redrew := s.broadcastAttachReplayAndResizeLocked(replay, redrawWindow)
	if !redrew {
		s.mu.Lock()
		s.resizeWindowLocked(window, targetWidth, targetHeight)
		s.mu.Unlock()
	}
	s.flushPendingTerminalQueriesLocked(primary, windowID)
	s.attachMu.Unlock()
	s.broadcastWindowList("active_window_changed")
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	s.scheduleRestoreRedrawFollowUps(windowID)
	return nil
}

func (s *muxServer) closeWindow(windowID string) (bool, error) {
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var redrew bool
	var shouldShutdown bool
	var process muxProcess
	var windowPty muxPty
	var nativeAcpBridgeID string
	var nativeAcpBridgeStopped bool
	var snapshots []windowSnapshot
	var resetViewportParser bool
	var targetWidth int
	var targetHeight int

	// Native windows retain their window/concurrency identity until the bridge
	// confirms shutdown. Mark the stop in flight without closing the window so
	// a failed request remains visible and retryable. Never wait for bridge I/O
	// while holding s.mu or attachMu.
	s.mu.Lock()
	initialWindow := s.windowByIDLocked(windowID)
	if initialWindow == nil || initialWindow.closed || initialWindow.closing {
		s.mu.Unlock()
		return false, fmt.Errorf("window %q not found", windowID)
	}
	nativeAcpBridgeID = initialWindow.nativeAcpBridgeID
	if nativeAcpBridgeID != "" {
		initialWindow.closing = true
	}
	s.mu.Unlock()

	if nativeAcpBridgeID != "" {
		if err := stopNativeAcpBridgeForWindow(nativeAcpBridgeID); err != nil {
			s.mu.Lock()
			if current := s.windowByIDLocked(windowID); current != nil && !current.closed {
				current.closing = false
			}
			s.mu.Unlock()
			return false, fmt.Errorf("stop native ACP bridge: %w", err)
		}
		nativeAcpBridgeStopped = true
	}

	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		shouldShutdown = len(s.snapshotsLocked()) == 0
		s.mu.Unlock()
		s.attachMu.Unlock()
		if nativeAcpBridgeStopped {
			// The bridge's `acp wait` watcher committed and broadcast the close
			// while shutdown was being confirmed. Treat the requested close as
			// successful rather than reporting a spurious not-found error.
			return shouldShutdown, nil
		}
		return false, fmt.Errorf("window %q not found", windowID)
	}
	openCount := 0
	for _, candidate := range s.windows {
		if !candidate.closed {
			openCount++
		}
	}
	if s.activeID == windowID {
		resetViewportParser =
			s.pendingFocusRefreshConn != nil ||
				(s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0)
		replacement := s.replacementWindowForClosedLocked(window)
		if replacement != nil {
			s.activeID = replacement.id
			s.pendingFocusRefreshConn = nil
			replacement.alert = false
			s.pendingResizeWidth = 0
			s.pendingResizeHeight = 0
			s.pendingResizeRedraw = false
			s.pendingResizeSyntheticRedraw = false
			s.pendingResizeThemeWindowID = ""
			if resetViewportParser {
				s.enqueueAttachViewportResizeAfterResetLocked(
					s.width,
					s.height,
				)
			} else {
				s.enqueueAttachViewportResizeLocked(s.width, s.height)
			}
			s.publishedWidth = s.width
			s.publishedHeight = s.height
			targetWidth = s.width
			targetHeight = s.height
			replay = s.replayBytesLocked(replacement)
			foregroundProcessGroup = replacement.foregroundProcessGroupLocked()
			redrawWindow = replacement
			activeChanged = true
		} else {
			s.activeID = ""
			s.pendingFocusRefreshConn = nil
		}
	}
	s.retireWindowLocked(window)
	if s.lastActiveID == windowID {
		s.lastActiveID = ""
	}
	process = window.proc
	windowPty = window.pty
	s.reindexWindowsLocked()
	snapshots = s.snapshotsLocked()
	shouldShutdown = openCount <= 1 || len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		// The redraw owns delivering the geometry so the replacement window's
		// foreground app repaints once, at the final size.
		redrew = s.broadcastAttachReplayAndResizeLocked(replay, redrawWindow)
		if !redrew {
			s.mu.Lock()
			s.resizeWindowLocked(redrawWindow, targetWidth, targetHeight)
			s.mu.Unlock()
		}
	}
	s.attachMu.Unlock()

	s.broadcast(controlResponse{
		Type:    "window_removed",
		Session: s.session,
		Window:  &windowSnapshot{ID: windowID},
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
	if activeChanged {
		s.broadcast(controlResponse{
			Type:    "active_window_changed",
			Session: s.session,
			Windows: snapshots,
		})
		if redrew {
			signalForegroundResize(foregroundProcessGroup)
		}
	}
	if process != nil {
		process.Hangup()
	}
	if windowPty != nil {
		_ = window.closePty(windowPty)
	}
	return shouldShutdown, nil
}

func (s *muxServer) replacementWindowForClosedLocked(closing *muxWindow) *muxWindow {
	for _, candidate := range s.windows {
		if candidate.closed || candidate.id == closing.id {
			continue
		}
		if candidate.index > closing.index {
			return candidate
		}
	}
	for _, candidate := range s.windows {
		if !candidate.closed && candidate.id != closing.id {
			return candidate
		}
	}
	return nil
}

func (s *muxServer) resize(width int, height int) {
	s.resizeWithRedraw(width, height, false, false, "")
}

func (s *muxServer) resizeForClient(
	clientID string,
	width int,
	height int,
	forceRedraw bool,
) {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	if len(s.attachClients) == 0 {
		s.mu.Unlock()
		if strings.TrimSpace(clientID) == "" {
			s.resizeWithRedraw(width, height, forceRedraw, false, "")
		}
		return
	}

	client := s.attachClientByIDLocked(clientID)
	if client == nil {
		s.mu.Unlock()
		return
	}
	client.width = width
	client.height = height
	isPrimary := s.attachConn == client.conn
	targetWidth, targetHeight := s.primaryAttachSizeLocked()
	s.mu.Unlock()
	if isPrimary {
		s.resizeWithRedraw(targetWidth, targetHeight, forceRedraw, false, "")
	}
}

func (s *muxServer) resizeWithRedraw(
	width int,
	height int,
	forceRedraw bool,
	syntheticRedraw bool,
	pinnedWindowID string,
) {
	var attach net.Conn
	var modeReplay []byte
	var foregroundProcessGroup int
	var shouldSignal bool

	s.mu.Lock()
	serializeViewport := s.hasViewportClippingClientLocked()
	s.mu.Unlock()
	if serializeViewport {
		s.attachMu.Lock()
		defer s.attachMu.Unlock()
	}

	s.mu.Lock()
	// A pinned caller (a theme redraw) targets one specific window. If a
	// concurrent window switch changed the active window since the caller
	// resolved it, skip: the hint went to the old window and the switch will
	// drive its own theme refresh for the new one, so dancing here would repaint
	// the wrong window.
	if pinnedWindowID != "" && s.activeID != pinnedWindowID {
		s.mu.Unlock()
		return
	}
	window := s.windowByIDLocked(s.activeID)
	if serializeViewport && !terminalViewportTransitionSafe(window) {
		s.width = width
		s.height = height
		s.pendingResizeWidth = width
		s.pendingResizeHeight = height
		s.pendingResizeRedraw = s.pendingResizeRedraw || forceRedraw
		s.pendingResizeSyntheticRedraw =
			s.pendingResizeSyntheticRedraw || (forceRedraw && syntheticRedraw)
		if forceRedraw && syntheticRedraw && pinnedWindowID != "" {
			// Preserve the pin so the replayed dance still targets the window
			// that received the theme hint, not whatever is active at replay.
			s.pendingResizeThemeWindowID = pinnedWindowID
		}
		s.mu.Unlock()
		return
	}
	hadPendingResize :=
		s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0
	s.pendingResizeWidth = 0
	s.pendingResizeHeight = 0
	s.pendingResizeRedraw = false
	s.pendingResizeSyntheticRedraw = false
	s.pendingResizeThemeWindowID = ""
	dimensionsChanged :=
		s.width != width ||
			s.height != height ||
			s.publishedWidth != width ||
			s.publishedHeight != height
	sizeChanged := dimensionsChanged || hadPendingResize
	s.width = width
	s.height = height
	// Publish the canonical grid on every resize, not only when the server
	// believes it changed. Clipping clients size their terminal buffer solely
	// from this sequence, so a single missed or dropped publish would otherwise
	// leave a client rendering the wrong grid for the rest of the session with
	// no way to ask for a correction.
	if serializeViewport {
		s.enqueueAttachViewportResizeLocked(width, height)
	}
	s.publishedWidth = width
	s.publishedHeight = height
	s.resizeWindowLocked(window, width, height)
	if window != nil &&
		!window.closed &&
		(window.usesForegroundRedrawReplayLocked() ||
			(syntheticRedraw && window.supportsForegroundRedrawLocked())) &&
		(forceRedraw || sizeChanged) {
		// Genuine viewport changes rely on the real PTY resize and forward their
		// reflow immediately. Restore/theme redraws always need the synthetic
		// width-1 dance, while a same-size settle redraw only needs it on
		// platforms such as Windows that cannot explicitly signal a foreground
		// resize after ResizePseudoConsole ignores an unchanged size.
		//
		// The intermediate frame is hidden from attach clients by the
		// synchronized redraw transaction in resumePausedAttachForwarding.
		if shouldSimulateForegroundRedraw(
			forceRedraw,
			syntheticRedraw,
			dimensionsChanged,
			supportsExplicitForegroundResizeSignal,
		) {
			s.pauseAttachForwardingForRedrawLocked(window, width, height)
			simulateForegroundResize(window, width, height)
		}
		attach = s.attachConn
		modeReplay = window.modeReplayForAttachedTerminalLocked()
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
		shouldSignal = true
	}
	s.mu.Unlock()
	if serializeViewport {
		if attach != nil {
			s.writeAllAttachesLocked(modeReplay)
		}
	} else {
		s.writeAttach(attach, modeReplay)
	}
	if shouldSignal {
		signalForegroundResize(foregroundProcessGroup)
	}
}

func (s *muxServer) refreshPendingViewportResize() {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	width := s.pendingResizeWidth
	height := s.pendingResizeHeight
	forceRedraw := s.pendingResizeRedraw
	syntheticRedraw := s.pendingResizeSyntheticRedraw
	themeWindowID := s.pendingResizeThemeWindowID
	s.mu.Unlock()
	if width <= 0 || height <= 0 {
		return
	}
	s.resizeWithRedraw(width, height, forceRedraw, syntheticRedraw, themeWindowID)
}

func (s *muxServer) resizeActiveLocked(width int, height int) {
	window := s.windowByIDLocked(s.activeID)
	s.resizeWindowLocked(window, width, height)
}

func (s *muxServer) resizeWindowLocked(window *muxWindow, width int, height int) {
	if window == nil || window.closed || window.pty == nil {
		return
	}
	if window.retainsConPtyNormalScreenLocked() && window.ptySizeIs(width, height) {
		return
	}
	window.resizePty(width, height)
}

func (s *muxServer) writeAttachReplayAndResizeLocked(
	conn net.Conn,
	replay []byte,
	window *muxWindow,
) bool {
	s.writeAttachLocked(conn, replay)
	return s.simulateForegroundResizeIfAttached(conn, window)
}

func (s *muxServer) broadcastAttachReplayAndResizeLocked(
	replay []byte,
	window *muxWindow,
) bool {
	if s.deferAttachReplayForRedrawLocked(replay, window) {
		return true
	}
	s.writeAllAttachesLocked(replay)
	return s.simulateForegroundResizeIfAnyAttached(window)
}

func (s *muxServer) deferAttachReplayForRedrawLocked(
	replay []byte,
	window *muxWindow,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attachCountLocked() == 0 ||
		window == nil ||
		window.closed ||
		!window.usesForegroundRedrawReplayLocked() {
		return false
	}
	if _, _, ok := foregroundRedrawTemporarySize(
		s.publishedWidth,
		s.publishedHeight,
	); !ok {
		return false
	}
	// Foreground-redraw panes repaint in response to the synthetic resize. Keep
	// the reset replay with that repaint so attach clients never paint the
	// intermediate cleared/stale frame.
	s.pauseAttachForwardingForRedrawLocked(
		window,
		s.publishedWidth,
		s.publishedHeight,
	)
	window.redrawForwardingReplay = append(
		window.redrawForwardingReplay[:0],
		replay...,
	)
	deliverForegroundGeometry(window, s.publishedWidth, s.publishedHeight)
	return true
}

func (s *muxServer) simulateForegroundResizeIfAttached(
	conn net.Conn,
	window *muxWindow,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.isAttachConnectionLocked(conn) || window == nil || window.closed ||
		window.retainsConPtyNormalScreenLocked() {
		return false
	}
	s.pauseAttachForwardingForRedrawLocked(
		window,
		s.publishedWidth,
		s.publishedHeight,
	)
	deliverForegroundGeometry(window, s.publishedWidth, s.publishedHeight)
	return true
}

func (s *muxServer) simulateForegroundResizeIfAnyAttached(window *muxWindow) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attachCountLocked() == 0 || window == nil || window.closed ||
		window.retainsConPtyNormalScreenLocked() {
		return false
	}
	s.pauseAttachForwardingForRedrawLocked(
		window,
		s.publishedWidth,
		s.publishedHeight,
	)
	deliverForegroundGeometry(window, s.publishedWidth, s.publishedHeight)
	return true
}

func (s *muxServer) pauseAttachForwardingForRedrawLocked(
	window *muxWindow,
	width int,
	height int,
) {
	if window == nil ||
		window.closed ||
		s.attachCountLocked() == 0 ||
		!window.supportsForegroundRedrawLocked() {
		return
	}
	if _, _, ok := foregroundRedrawTemporarySize(width, height); !ok {
		return
	}
	preservedQueries := append(
		[]byte(nil),
		window.redrawForwardingQueryBuffer...,
	)
	preservedPrimary := window.redrawForwardingPrimaryConn
	window.redrawForwardingBuffer = append(
		window.redrawForwardingBuffer[:0],
		preservedQueries...,
	)
	window.redrawForwardingFailoverBuffer = append(
		window.redrawForwardingFailoverBuffer[:0],
		preservedQueries...,
	)
	window.redrawForwardingSecondaryBuffer = nil
	window.redrawForwardingQueryBuffer = append(
		window.redrawForwardingQueryBuffer[:0],
		preservedQueries...,
	)
	if len(preservedQueries) > 0 &&
		s.isAttachConnectionLocked(preservedPrimary) {
		window.redrawForwardingPrimaryConn = preservedPrimary
	} else {
		window.redrawForwardingPrimaryConn = s.attachConn
	}
	window.redrawForwardingPrimaryNeedsFailover =
		len(preservedQueries) > 0 &&
			!s.isAttachConnectionLocked(preservedPrimary)
	if !window.redrawForwardingPaused ||
		len(window.redrawForwardingFallbackHistory) == 0 {
		// Snapshot the pre-resize frame for every redraw pause, not just
		// deferred window-switch replays: restore and theme redraws start the
		// same transaction directly and hit the same coalesced-SIGWINCH
		// failure. Only a frame with visible content is worth retaining: a
		// snapshot taken in the instant after the child cleared but before it
		// repainted would hand the user exactly the emptiness this fallback
		// exists to avoid.
		if snapshot := s.foregroundHistoryFallbackHistoryLocked(
			window,
		); terminalOutputHasVisibleContent(snapshot) {
			window.redrawForwardingFallbackHistory = snapshot
		} else {
			window.redrawForwardingFallbackHistory = nil
		}
	} else if refreshed := s.foregroundHistoryFallbackHistoryLocked(
		window,
	); terminalOutputHasVisibleContent(refreshed) {
		// A pause restarted while another is in flight only re-snapshots when
		// the history still holds a complete frame. If the first (empty) redraw
		// already cleared the screen, re-reading it would capture that blank
		// frame and hand the user exactly the emptiness this fallback exists to
		// avoid, so the original snapshot is kept instead.
		window.redrawForwardingFallbackHistory = refreshed
	}
	window.redrawForwardingPaused = true
	window.redrawForwardingGeneration += 1
	windowID := window.id
	generation := window.redrawForwardingGeneration
	time.AfterFunc(foregroundRedrawForwardingPause, func() {
		s.resumePausedAttachForwarding(windowID, generation)
	})
}

func trimForegroundRedrawBuffer(data []byte, preservedPrefix []byte) []byte {
	if len(data) <= foregroundRedrawBufferLimitBytes {
		return data
	}
	body := data
	prefix := []byte(nil)
	if len(preservedPrefix) > 0 && bytes.HasPrefix(body, preservedPrefix) {
		prefix = preservedPrefix
		body = body[len(preservedPrefix):]
	}
	if len(body) <= foregroundRedrawBufferLimitBytes {
		return data
	}
	start := len(body) - foregroundRedrawBufferLimitBytes
	start = advanceReplayStartToTerminalGround(
		body,
		start,
		terminalOutputParserSnapshot{},
	)
	if start >= len(body) {
		return append([]byte(nil), prefix...)
	}
	// Prefer a natural terminal/text boundary near the size cut so the reset
	// replay is followed by a complete control sequence or line.
	scanEnd := start + 2048
	if scanEnd > len(body) {
		scanEnd = len(body)
	}
	for index := start; index < scanEnd; index++ {
		switch body[index] {
		case '\x1b', '\n', '\r':
			start = index
			index = scanEnd
		}
	}
	result := make([]byte, 0, len(prefix)+len(body)-start)
	result = append(result, prefix...)
	result = append(result, body[start:]...)
	return result
}

func (s *muxServer) resumePausedAttachForwarding(
	windowID string,
	generation int,
) {
	var replay []byte
	var buffered []byte
	var failoverBuffered []byte
	var secondaryBuffered []byte
	var queryData []byte
	var primary net.Conn
	var primaryNeedsFailover bool
	var clients []*attachClient
	var refreshPendingFocus bool
	var refreshPendingResize bool
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil ||
		window.closed ||
		!window.redrawForwardingPaused ||
		window.redrawForwardingGeneration != generation {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	replay = window.redrawForwardingReplay
	buffered = window.redrawForwardingBuffer
	failoverBuffered = window.redrawForwardingFailoverBuffer
	secondaryBuffered = window.redrawForwardingSecondaryBuffer
	queryData = window.redrawForwardingQueryBuffer
	primary = window.redrawForwardingPrimaryConn
	if !s.isAttachConnectionLocked(primary) {
		primary = s.attachConn
		primaryNeedsFailover = true
	}
	primaryNeedsFailover =
		primaryNeedsFailover || window.redrawForwardingPrimaryNeedsFailover
	// A long normal-buffer agent such as Pi can repaint its entire transcript
	// on SIGWINCH. The reset replay already establishes a clean terminal frame,
	// so retain only a parser-safe tail of that redraw instead of sending many
	// megabytes to a mobile client. Preserve terminal-query prefixes verbatim.
	if len(replay) > 0 && window.terminalOutputIsGroundLocked() {
		buffered = trimForegroundRedrawBuffer(buffered, queryData)
		failoverBuffered = trimForegroundRedrawBuffer(failoverBuffered, queryData)
		secondaryBuffered = trimForegroundRedrawBuffer(secondaryBuffered, nil)
	}
	// Substituting the fallback discards the buffered redraw, so it is only
	// safe once that redraw has ended on a sequence boundary. Resuming mid
	// escape sequence would drop the head of a sequence whose tail is still to
	// come and corrupt the client, so leave those redraws to forward normally.
	if !terminalOutputHasVisibleContent(secondaryBuffered) &&
		window.terminalOutputIsGroundLocked() {
		// Some TUIs coalesce the temporary and restored SIGWINCH notifications
		// and emit no redraw at all. Sending the normal foreground replay in
		// that case would only clear the client, leaving it blank until future
		// output. Fall back to the retained screen history and paint it inside
		// one synchronized transaction so the user sees the last complete frame
		// rather than an empty viewport.
		fallbackReplay := s.foregroundHistoryFallbackReplayLocked(
			window,
			window.redrawForwardingFallbackHistory,
		)
		// Substitute only a frame that actually paints something. An
		// escape-only snapshot (a clear the child had just emitted) is long
		// enough to look like a frame while rendering exactly the blank screen
		// this fallback exists to prevent.
		if terminalOutputHasVisibleContent(
			window.redrawForwardingFallbackHistory,
		) && len(fallbackReplay) > 0 {
			replay = nil
			buffered = append(
				append([]byte(nil), fallbackReplay...),
				queryData...,
			)
			failoverBuffered = append(
				append([]byte(nil), fallbackReplay...),
				queryData...,
			)
			secondaryBuffered = append([]byte(nil), fallbackReplay...)
		}
	}
	window.releaseRedrawForwardingStateLocked()
	refreshPendingFocus = s.pendingFocusRefreshConn != nil &&
		s.pendingFocusRefreshConn == s.attachConn &&
		len(window.secondaryQueryCarry) == 0 &&
		window.queryUtf8Remaining == 0 &&
		window.terminalOutputIsGroundLocked()
	refreshPendingResize =
		s.pendingResizeWidth > 0 &&
			s.pendingResizeHeight > 0 &&
			terminalViewportTransitionSafe(window)
	if s.activeID == windowID {
		clients = make([]*attachClient, 0, len(s.attachClients))
		for _, client := range s.attachClients {
			clients = append(clients, client)
		}
	}
	s.mu.Unlock()
	primaryOutput := wrapSynchronizedTerminalOutput(
		replay,
		buffered,
	)
	failoverOutput := wrapSynchronizedTerminalOutput(
		replay,
		failoverBuffered,
	)
	secondaryOutput := wrapSynchronizedTerminalOutput(
		replay,
		secondaryBuffered,
	)
	var primaryClient *attachClient
	for _, client := range clients {
		if client.conn == primary {
			primaryClient = client
			break
		}
	}
	var deliveredPrimary *attachClient
	if len(queryData) > 0 {
		type queryFallback struct {
			client              *attachClient
			queryCompletion     <-chan error
			queryGate           *attachWriteGate
			secondaryOutputGate *attachWriteGate
		}
		responseCount := terminalQueryResponseCount(queryData)
		initialOutput := primaryOutput
		if primaryNeedsFailover {
			initialOutput = failoverOutput
		}
		var primaryCompletion <-chan error
		primaryQueued := false
		if primaryClient != nil {
			primaryCompletion, primaryQueued =
				primaryClient.enqueueTerminalQuery(
					initialOutput,
					true,
					windowID,
					responseCount,
				)
		}
		sortedClients := append([]*attachClient(nil), clients...)
		sort.Slice(sortedClients, func(i int, j int) bool {
			return moreRecentlyFocusedAttachClient(
				sortedClients[i],
				sortedClients[j],
			)
		})
		fallbacks := make([]queryFallback, 0, len(sortedClients))
		for _, client := range sortedClients {
			if client == primaryClient {
				continue
			}
			queryGate := &attachWriteGate{done: make(chan struct{})}
			queryCompletion, queued :=
				client.enqueueConditionalTerminalQuery(
					failoverOutput,
					true,
					windowID,
					responseCount,
					queryGate,
				)
			if !queued {
				continue
			}
			fallback := queryFallback{
				client:          client,
				queryCompletion: queryCompletion,
				queryGate:       queryGate,
			}
			if len(secondaryOutput) > 0 {
				secondaryGate := &attachWriteGate{done: make(chan struct{})}
				if _, queued := client.enqueueWrite(
					secondaryOutput,
					false,
					"",
					0,
					secondaryGate,
				); queued {
					fallback.secondaryOutputGate = secondaryGate
				}
			}
			fallbacks = append(fallbacks, fallback)
		}
		s.attachMu.Unlock()
		primaryDelivered := primaryQueued &&
			primaryClient.waitForWrite(primaryCompletion)
		for _, fallback := range fallbacks {
			tryFallback := !primaryDelivered
			fallback.queryGate.deliver.Store(tryFallback)
			close(fallback.queryGate.done)
			if tryFallback &&
				fallback.client.waitForWrite(fallback.queryCompletion) {
				primaryDelivered = true
			}
			if fallback.secondaryOutputGate != nil {
				fallback.secondaryOutputGate.deliver.Store(!tryFallback)
				close(fallback.secondaryOutputGate.done)
			}
		}
		if !primaryDelivered {
			s.redeliverTerminalQueries(
				windowID,
				queryData,
				nil,
				nil,
			)
		}
		if refreshPendingFocus || refreshPendingResize {
			go s.refreshPendingClientViewport(
				refreshPendingFocus,
				refreshPendingResize,
			)
		}
		return
	}
	if primaryClient != nil {
		_, queued := primaryClient.enqueue(primaryOutput, false)
		if queued {
			deliveredPrimary = primaryClient
		}
	}
	if deliveredPrimary == nil {
		sort.Slice(clients, func(i int, j int) bool {
			return moreRecentlyFocusedAttachClient(clients[i], clients[j])
		})
		for _, client := range clients {
			if client == primaryClient {
				continue
			}
			_, queued := client.enqueue(failoverOutput, false)
			if !queued {
				continue
			}
			deliveredPrimary = client
			break
		}
	}
	for _, client := range clients {
		if client == deliveredPrimary || len(secondaryOutput) == 0 {
			continue
		}
		_, _ = client.enqueue(secondaryOutput, false)
	}
	if refreshPendingFocus || refreshPendingResize {
		go s.refreshPendingClientViewport(
			refreshPendingFocus,
			refreshPendingResize,
		)
	}
	s.attachMu.Unlock()
}

func (w *muxWindow) foregroundProcessGroupLocked() int {
	pgrp := foregroundProcessGroupForWindow(w)
	if pgrp <= 0 {
		return 0
	}
	w.foregroundPid = pgrp
	return pgrp
}

func (w *muxWindow) modeReplayForAttachedTerminalLocked() []byte {
	if w == nil || w.closed {
		return nil
	}
	modes := terminalModePostReplaySequence(w)
	cursor := cursorVisibilityReplaySequence(w.cursorVisibleForReplayLocked())
	replay := make([]byte, 0, len(modes)+len(cursor))
	replay = append(replay, modes...)
	replay = append(replay, cursor...)
	return replay
}

func (s *muxServer) activeReplayLocked() []byte {
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		return nil
	}
	return s.replayBytesLocked(window)
}

func (s *muxServer) replayBytesLocked(window *muxWindow) []byte {
	return s.replayBytesLockedWithSkip(window, nil)
}

// replayBytesLockedWithSkip builds the reattach replay, omitting retained Kitty
// images whose id/signature the client reports already holding in clientHas
// (nil replays every retained image, as a fresh attach does).
func (s *muxServer) replayBytesLockedWithSkip(
	window *muxWindow,
	clientHas map[string]uint32,
) []byte {
	history, historyStart := window.historyTailWithParserLocked()
	if window.retainsConPtyNormalScreenLocked() {
		// Keep the full bounded screen history: differential updates may leave
		// the composer untouched beyond the short shell scrollback limit.
		start := advanceReplayStartToTerminalGround(history, 0, historyStart)
		history = stripTerminalQueriesFromReplay(history[start:])
		history = window.withheldAttachOscSuffixTrimmedLocked(history)
		images := window.kittyImageReplayLocked(clientHas)
		replayHistory := append(images, history...)
		return wrapSynchronizedTerminalOutput(nil, buildWindowReplay(window, replayHistory))
	}
	if window.usesForegroundRedrawReplayLocked() {
		// The foreground app redraws its own cells on reattach (driven by a
		// resize), so we must not replay the visible history or it would draw
		// twice. We do, however, replay any retained Kitty graphics image
		// transmissions: placeholder-protocol clients (e.g. Copilot CLI)
		// transmit an image once and then only re-emit the placeholder cells,
		// so without restoring the image bytes the redrawn placeholders would
		// have nothing to composite and render blank. The retained transmissions
		// survive eviction from the rolling visible history and are store-only
		// (a=T downgraded to a=t) so they produce no visible output themselves.
		history = window.kittyImageReplayLocked(clientHas)
	} else {
		history = trimReplayHistoryForAttachWithParser(history, historyStart)
		history = stripTerminalQueriesFromReplay(history)
		history = window.withheldAttachOscSuffixTrimmedLocked(history)
	}
	return buildWindowReplay(window, history)
}

// releaseRedrawForwardingStateLocked drops every buffer a redraw pause retains
// and marks the pause finished.
func (w *muxWindow) releaseRedrawForwardingStateLocked() {
	if w == nil {
		return
	}
	w.redrawForwardingPaused = false
	w.redrawForwardingReplay = nil
	w.redrawForwardingFallbackHistory = nil
	w.redrawForwardingBuffer = nil
	w.redrawForwardingFailoverBuffer = nil
	w.redrawForwardingSecondaryBuffer = nil
	w.redrawForwardingQueryBuffer = nil
	w.redrawForwardingPrimaryConn = nil
	w.redrawForwardingPrimaryNeedsFailover = false
}

// foregroundHistoryFallbackHistoryLocked snapshots the frame bytes to fall back
// to if the redraw about to be triggered produces nothing. The result must be a
// copy: these helpers can return slices aliasing window.history, which
// appendHistoryLocked rewrites in place as output arrives during the pause,
// which would mutate the snapshot into the very redraw it exists to recover
// from.
func (s *muxServer) foregroundHistoryFallbackHistoryLocked(
	window *muxWindow,
) []byte {
	if window == nil || !window.supportsForegroundRedrawLocked() {
		return nil
	}
	history, historyStart := window.historyTailWithParserLocked()
	// This is a TUI frame recovery, not the short shell scrollback replay.
	// Differential updates can leave the composer untouched for more than
	// windowReplayLimitBytes of output. Cutting to that tail discards the
	// cells (and cursor position) those updates depend on, so a switch paints
	// the transcript over a blank/misaligned composer until a real resize.
	// Keep the full, already bounded foreground history and only skip an
	// incomplete leading control sequence left by history eviction.
	start := advanceReplayStartToTerminalGround(history, 0, historyStart)
	history = history[start:]
	history = stripTerminalQueriesFromReplay(history)
	if len(history) == 0 {
		return nil
	}
	return append([]byte(nil), history...)
}

// foregroundHistoryFallbackReplayLocked renders the snapshot taken when the
// redraw pause began into a full replay. The frame bytes are the pre-resize
// history, but the surrounding mode, cursor, and retained-image state is read
// now, so state the window learned *during* the pause (a mode change, a new
// image upload) is carried into the fallback instead of being dropped with the
// discarded redraw.
func (s *muxServer) foregroundHistoryFallbackReplayLocked(
	window *muxWindow,
	history []byte,
) []byte {
	if window == nil || len(history) == 0 {
		return nil
	}
	images := window.kittyImageReplayLocked(nil)
	history = window.withheldAttachOscSuffixTrimmedLocked(history)
	replayHistory := make([]byte, 0, len(images)+len(history))
	replayHistory = append(replayHistory, images...)
	replayHistory = append(replayHistory, history...)
	return buildWindowReplay(window, replayHistory)
}

func buildWindowReplay(window *muxWindow, history []byte) []byte {
	title := terminalTitleReplaySequence(window)
	preModes := terminalModePreReplaySequence(window)
	preHistoryClear := terminalPreHistoryClearSequence(window)
	postModes := terminalModePostReplaySequence(window)
	postParser := []byte(terminalParserResetSequence)
	postCharset := []byte(terminalCharacterSetResetSequence)
	cursor := cursorVisibilityReplaySequence(window.cursorVisibleForReplayLocked())
	replay := make(
		[]byte,
		0,
		len(activeWindowReplayPrefix)+len(title)+len(preModes)+
			len(preHistoryClear)+len(history)+
			len(postParser)+len(postModes)+len(postCharset)+len(cursor),
	)
	replay = append(replay, activeWindowReplayPrefix...)
	replay = append(replay, title...)
	replay = append(replay, preModes...)
	replay = append(replay, preHistoryClear...)
	replay = append(replay, history...)
	replay = append(replay, postParser...)
	replay = append(replay, postModes...)
	replay = append(replay, postCharset...)
	replay = append(replay, cursor...)
	return replay
}

// Explicit theme/restore redraws still repaint normal-screen console agents.
// Switching back to their retained screen does not require that repaint.
func (w *muxWindow) supportsForegroundRedrawLocked() bool {
	return w != nil && (w.alternateScreenModeActiveLocked() || w.agentToolLocked() != "")
}

func (w *muxWindow) usesForegroundRedrawReplayLocked() bool {
	if w == nil {
		return false
	}
	// ConPTY already maintains the normal screen and its retained VT output
	// can restore that screen without asking the application to repaint its
	// transcript. A temporary resize on every return makes normal-buffer TUIs
	// reflow/reinsert history, visibly scrolling the restored window again.
	return w.alternateScreenModeActiveLocked() ||
		(!w.retainsConPtyNormalScreenLocked() && w.agentToolLocked() != "")
}

func (w *muxWindow) retainsConPtyNormalScreenLocked() bool {
	return w != nil && w.win32InputMode && !w.alternateScreenModeActiveLocked()
}

func (w *muxWindow) alternateScreenModeActiveLocked() bool {
	return w.privateModes["1047"] || w.privateModes["1049"]
}

func (w *muxWindow) reportsMouseWheelLocked() bool {
	return w.mouseTrackingActiveLocked()
}

// reportsMouseWheelRawLocked reports whether any mouse-tracking mode is enabled
// in the window's tracked state, ignoring which process enabled it.
func (w *muxWindow) reportsMouseWheelRawLocked() bool {
	if w == nil {
		return false
	}
	return w.privateModes["1000"] ||
		w.privateModes["1002"] ||
		w.privateModes["1003"]
}

// mouseTrackingActiveLocked reports whether mouse-tracking should be considered
// active for the window's *current* foreground process. A TUI that enables
// mouse tracking and then exits (or is killed, e.g. when the app crashes
// mid-session) leaves the mode set in our tracked state, but the shell that
// returns to the foreground does not want mouse reports. Gating on the
// foreground PID — mirroring focus/theme mode handling — stops a plain shell
// prompt from being told it reports mouse wheel, which would otherwise turn
// touch-scrolls into SGR mouse-report spew.
func (w *muxWindow) mouseTrackingActiveLocked() bool {
	if !w.reportsMouseWheelRawLocked() {
		return false
	}
	activePid := w.activeForegroundPidLocked()
	return w.mouseTrackingProcessID <= 0 ||
		activePid <= 0 ||
		w.mouseTrackingProcessID == activePid
}

func copyPrivateModes(privateModes map[string]bool) map[string]bool {
	if len(privateModes) == 0 {
		return nil
	}
	copied := make(map[string]bool, len(privateModes))
	for mode, enabled := range privateModes {
		if _, ok := trackedPrivateModes[mode]; ok {
			copied[mode] = enabled
		}
	}
	if len(copied) == 0 {
		return nil
	}
	return copied
}

// privateModesForRestore keeps display-only state needed to replay retained
// shell history, but drops every process-owned input/query mode. A restore
// starts a fresh process, which re-enables the modes it needs. Carrying DEC 2031
// forward caused theme refreshes to write CSI ?997 replies into the replacement
// shell, where they appeared as literal ^[[?997;1n text; stale mouse, focus,
// paste, cursor-key, and alternate-scroll modes can corrupt input similarly.
func privateModesForRestore(privateModes map[string]bool) map[string]bool {
	copied := copyPrivateModes(privateModes)
	if copied == nil {
		return nil
	}
	for _, mode := range []string{
		"1", "1000", "1002", "1003", "1004", "1006", "1007", "2004", "2031",
	} {
		delete(copied, mode)
	}
	if len(copied) == 0 {
		return nil
	}
	return copied
}

func terminalTitleReplaySequence(window *muxWindow) []byte {
	title := ""
	if window != nil {
		title = firstNonEmptyString(window.paneTitle, window.name)
	}
	title = sanitizeTerminalTitle(title)
	return []byte("\x1b]0;" + title + "\x07\x1b]1;" + title + "\x07\x1b]2;" + title + "\x07")
}

func sanitizeTerminalTitle(value string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, strings.TrimSpace(value))
}

func terminalModePreReplaySequence(window *muxWindow) []byte {
	if window == nil {
		return nil
	}
	return terminalModeReplaySequence(window, preReplayPrivateModes, true)
}

func terminalPreHistoryClearSequence(window *muxWindow) []byte {
	if window == nil || !window.alternateScreenModeActiveLocked() {
		return nil
	}
	return []byte(terminalScreenClearSequence)
}

func terminalModePostReplaySequence(window *muxWindow) []byte {
	if window == nil {
		return nil
	}
	return terminalModeReplaySequence(window, postReplayPrivateModes, true)
}

func terminalModeReplaySequence(
	window *muxWindow,
	privateModes []string,
	includeApplicationKeypad bool,
) []byte {
	var replay []byte
	for _, mode := range privateModes {
		if groupedReplayPrivateMode(mode) {
			continue
		}
		enabled, ok := window.privateModes[mode]
		if !ok {
			continue
		}
		if mode == "1004" && enabled && !window.focusModeActiveLocked() {
			continue
		}
		replay = appendPrivateModeReplay(replay, mode, enabled)
	}
	for _, group := range groupedReplayPrivateModes {
		replay = appendGroupedPrivateModeReplay(replay, window, privateModes, group)
	}
	if window.insertModeKnown {
		if window.insertModeEnabled {
			replay = append(replay, "\x1b[4h"...)
		} else {
			replay = append(replay, "\x1b[4l"...)
		}
	}
	if includeApplicationKeypad && window.applicationKeypadKnown {
		if window.applicationKeypadEnabled {
			replay = append(replay, "\x1b="...)
		} else {
			replay = append(replay, "\x1b>"...)
		}
	}
	return replay
}

func appendGroupedPrivateModeReplay(
	replay []byte,
	window *muxWindow,
	privateModes []string,
	group []string,
) []byte {
	for _, mode := range group {
		if !containsString(privateModes, mode) {
			continue
		}
		if enabled, ok := window.privateModes[mode]; ok && !enabled {
			replay = appendPrivateModeReplay(replay, mode, false)
		}
	}
	for _, mode := range group {
		if !containsString(privateModes, mode) {
			continue
		}
		if enabled, ok := window.privateModes[mode]; ok && enabled {
			// Don't re-enable mouse tracking on replay if the process that
			// turned it on is no longer in the foreground; the prefix already
			// disabled it, so the reattached client ends up in the effective
			// (off) state instead of spewing mouse reports at a shell prompt.
			if isMouseWheelMode(mode) && !window.mouseTrackingActiveLocked() {
				continue
			}
			replay = appendPrivateModeReplay(replay, mode, true)
		}
	}
	return replay
}

func isMouseWheelMode(mode string) bool {
	return mode == "1000" || mode == "1002" || mode == "1003"
}

func appendPrivateModeReplay(replay []byte, mode string, enabled bool) []byte {
	final := byte('l')
	if enabled {
		final = 'h'
	}
	replay = append(replay, "\x1b[?"...)
	replay = append(replay, mode...)
	replay = append(replay, final)
	return replay
}

func groupedReplayPrivateMode(mode string) bool {
	for _, group := range groupedReplayPrivateModes {
		if containsString(group, mode) {
			return true
		}
	}
	return false
}

func containsString(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func (s *muxServer) writeAttach(conn net.Conn, data []byte) {
	if len(data) == 0 {
		return
	}
	s.attachMu.Lock()
	s.writeAllAttachesLocked(data)
	s.attachMu.Unlock()
}

func (s *muxServer) writeAttachLocked(conn net.Conn, data []byte) bool {
	if conn == nil || len(data) == 0 {
		return false
	}
	s.mu.Lock()
	client := s.attachClients[conn]
	s.mu.Unlock()
	if client == nil {
		return false
	}
	_, queued := client.enqueue(data, false)
	return queued
}

func (s *muxServer) writeAllAttachesLocked(data []byte) {
	if len(data) == 0 {
		return
	}
	s.mu.Lock()
	clients := make([]*attachClient, 0, len(s.attachClients))
	for _, client := range s.attachClients {
		clients = append(clients, client)
	}
	s.mu.Unlock()
	for _, client := range clients {
		_, _ = client.enqueue(data, false)
	}
}

func terminalViewportResizeSequence(
	width int,
	height int,
	resetParser bool,
) []byte {
	if width <= 0 || height <= 0 {
		return nil
	}
	sequence := fmt.Sprintf("\x1b[?8;%d;%dt", height, width)
	if resetParser {
		sequence = terminalParserResetSequence + sequence
	}
	return []byte(sequence)
}

// enqueueAttachViewportResizeLocked keeps clipping-aware clients on the shared
// PTY grid while each client retains its own viewport dimensions for focus.
// The caller holds attachMu and mu and invokes this before resizing the PTY, so
// the sequence is queued before the corresponding redraw output.
func (s *muxServer) enqueueAttachViewportResizeLocked(width int, height int) {
	s.enqueueAttachViewportTransitionLocked(width, height, false)
}

func (s *muxServer) enqueueAttachViewportResizeAfterResetLocked(
	width int,
	height int,
) {
	s.enqueueAttachViewportTransitionLocked(width, height, true)
}

func (s *muxServer) enqueueAttachViewportTransitionLocked(
	width int,
	height int,
	resetParser bool,
) {
	sequence := terminalViewportResizeSequence(width, height, resetParser)
	if len(sequence) == 0 {
		return
	}
	for _, client := range s.attachClients {
		if !client.clipViewport {
			continue
		}
		_, _ = client.enqueue(sequence, false)
	}
}

func (s *muxServer) writeAttachOutputIfActive(
	windowID string,
	primary net.Conn,
	primaryData []byte,
	failoverPrimaryData []byte,
	secondaryData []byte,
	queryData []byte,
	maxAttachSequence uint64,
	outputGeneration uint64,
) {
	if len(primaryData) == 0 {
		return
	}
	s.attachMu.Lock()

	s.mu.Lock()
	if s.activeID != windowID {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	clients := make([]*attachClient, 0, len(s.attachClients))
	allClients := make([]*attachClient, 0, len(s.attachClients))
	for _, client := range s.attachClients {
		allClients = append(allClients, client)
		if client.sequence <= maxAttachSequence {
			clients = append(clients, client)
		}
	}
	currentPrimary := s.attachConn
	s.mu.Unlock()

	var primaryClient *attachClient
	for _, client := range clients {
		if client.conn == primary {
			primaryClient = client
			break
		}
	}
	var deliveredPrimary *attachClient
	if len(queryData) > 0 {
		responseCount := terminalQueryResponseCount(queryData)
		type queryFallback struct {
			client              *attachClient
			queryCompletion     <-chan error
			queryGate           *attachWriteGate
			secondaryOutputGate *attachWriteGate
		}
		var primaryCompletion <-chan error
		primaryQueued := false
		if primaryClient != nil {
			data := primaryData
			if primaryClient.suppressesReplayedOutput(
				windowID,
				outputGeneration,
			) {
				data = queryData
			}
			primaryCompletion, primaryQueued =
				primaryClient.enqueueTerminalQuery(
					data,
					true,
					windowID,
					responseCount,
				)
		}
		sort.Slice(allClients, func(i int, j int) bool {
			iCurrent := allClients[i].conn == currentPrimary
			jCurrent := allClients[j].conn == currentPrimary
			if iCurrent != jCurrent {
				return iCurrent
			}
			return moreRecentlyFocusedAttachClient(
				allClients[i],
				allClients[j],
			)
		})
		fallbacks := make([]queryFallback, 0, len(allClients))
		for _, client := range allClients {
			if client == primaryClient {
				continue
			}
			suppressesOutput := client.suppressesReplayedOutput(
				windowID,
				outputGeneration,
			)
			data := queryData
			if client.sequence <= maxAttachSequence && !suppressesOutput {
				data = failoverPrimaryData
			}
			queryGate := &attachWriteGate{done: make(chan struct{})}
			queryCompletion, queued :=
				client.enqueueConditionalTerminalQuery(
					data,
					true,
					windowID,
					responseCount,
					queryGate,
				)
			if !queued {
				continue
			}
			fallback := queryFallback{
				client:          client,
				queryCompletion: queryCompletion,
				queryGate:       queryGate,
			}
			if client.sequence <= maxAttachSequence &&
				len(secondaryData) > 0 &&
				!suppressesOutput {
				secondaryGate := &attachWriteGate{done: make(chan struct{})}
				if _, queued := client.enqueueWrite(
					secondaryData,
					false,
					"",
					0,
					secondaryGate,
				); queued {
					fallback.secondaryOutputGate = secondaryGate
				}
			}
			fallbacks = append(fallbacks, fallback)
		}
		s.attachMu.Unlock()

		primaryDelivered := primaryQueued &&
			primaryClient.waitForWrite(primaryCompletion)
		for _, fallback := range fallbacks {
			tryFallback := !primaryDelivered
			fallback.queryGate.deliver.Store(tryFallback)
			close(fallback.queryGate.done)
			if tryFallback &&
				fallback.client.waitForWrite(fallback.queryCompletion) {
				primaryDelivered = true
			}
			if fallback.secondaryOutputGate != nil {
				fallback.secondaryOutputGate.deliver.Store(!tryFallback)
				close(fallback.secondaryOutputGate.done)
			}
		}
		if !primaryDelivered {
			s.redeliverTerminalQueries(
				windowID,
				queryData,
				nil,
				nil,
			)
		}
		return
	}
	if primaryClient != nil {
		if primaryClient.suppressesReplayedOutput(windowID, outputGeneration) {
			deliveredPrimary = primaryClient
		} else {
			_, queued := primaryClient.enqueue(primaryData, false)
			if queued {
				deliveredPrimary = primaryClient
			}
		}
	}
	if deliveredPrimary == nil {
		sort.Slice(clients, func(i int, j int) bool {
			iCurrent := clients[i].conn == currentPrimary
			jCurrent := clients[j].conn == currentPrimary
			if iCurrent != jCurrent {
				return iCurrent
			}
			return moreRecentlyFocusedAttachClient(clients[i], clients[j])
		})
		for _, client := range clients {
			if client == primaryClient {
				continue
			}
			if client.suppressesReplayedOutput(windowID, outputGeneration) {
				deliveredPrimary = client
				break
			}
			_, queued := client.enqueue(failoverPrimaryData, false)
			if queued {
				deliveredPrimary = client
				break
			}
		}
	}
	for _, client := range clients {
		if client == deliveredPrimary ||
			len(secondaryData) == 0 ||
			client.suppressesReplayedOutput(windowID, outputGeneration) {
			continue
		}
		_, _ = client.enqueue(secondaryData, false)
	}
	s.attachMu.Unlock()
}

func (s *muxServer) enqueuePrimaryAttachLocked(
	preferred net.Conn,
	data []byte,
	tracked bool,
	windowID string,
) (*attachClient, <-chan error, bool) {
	if len(data) == 0 {
		return nil, nil, true
	}
	s.mu.Lock()
	clients := make([]*attachClient, 0, len(s.attachClients))
	currentPrimary := s.attachConn
	for _, client := range s.attachClients {
		clients = append(clients, client)
	}
	s.mu.Unlock()
	sort.Slice(clients, func(i int, j int) bool {
		iPreferred := clients[i].conn == preferred
		jPreferred := clients[j].conn == preferred
		if iPreferred != jPreferred {
			return iPreferred
		}
		iCurrent := clients[i].conn == currentPrimary
		jCurrent := clients[j].conn == currentPrimary
		if iCurrent != jCurrent {
			return iCurrent
		}
		return moreRecentlyFocusedAttachClient(clients[i], clients[j])
	})
	responseCount := terminalQueryResponseCount(data)
	for _, client := range clients {
		completion, queued := client.enqueueTerminalQuery(
			data,
			tracked,
			windowID,
			responseCount,
		)
		if !queued {
			continue
		}
		return client, completion, true
	}
	return nil, nil, false
}

func (s *muxServer) watchTerminalQueryWrite(
	windowID string,
	client *attachClient,
	completion <-chan error,
	queries []byte,
	onSuccess func(),
	onDeferred func(),
) {
	if client == nil || completion == nil {
		if onSuccess != nil {
			onSuccess()
		}
		return
	}
	go func() {
		writeErr, ok := <-completion
		if !ok {
			writeErr = io.ErrClosedPipe
		}
		if writeErr == nil {
			if onSuccess != nil {
				onSuccess()
			}
			return
		}
		s.redeliverTerminalQueries(
			windowID,
			queries,
			onSuccess,
			onDeferred,
		)
	}()
}

func (s *muxServer) redeliverTerminalQueries(
	windowID string,
	queries []byte,
	onSuccess func(),
	onDeferred func(),
) {
	if len(queries) == 0 {
		return
	}
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	if s.activeID != windowID || s.attachCountLocked() == 0 {
		if onDeferred == nil {
			s.storePendingTerminalQueriesLocked(window, queries)
		}
		s.mu.Unlock()
		s.attachMu.Unlock()
		if onDeferred != nil {
			onDeferred()
		}
		return
	}
	preferred := s.attachConn
	s.mu.Unlock()
	client, completion, queued := s.enqueuePrimaryAttachLocked(
		preferred,
		queries,
		true,
		windowID,
	)
	if !queued {
		if onDeferred == nil {
			s.mu.Lock()
			window = s.windowByIDLocked(windowID)
			if window != nil && !window.closed {
				s.storePendingTerminalQueriesLocked(window, queries)
			}
			s.mu.Unlock()
		}
		s.attachMu.Unlock()
		if onDeferred != nil {
			onDeferred()
		}
		return
	}
	s.attachMu.Unlock()
	if client == nil {
		if onSuccess != nil {
			onSuccess()
		}
		return
	}
	s.watchTerminalQueryWrite(
		windowID,
		client,
		completion,
		queries,
		onSuccess,
		onDeferred,
	)
}

func (s *muxServer) storePendingTerminalQueriesLocked(
	window *muxWindow,
	queries []byte,
) {
	if window == nil ||
		len(queries) == 0 ||
		bytes.Contains(window.pendingTerminalQueries, queries) ||
		len(window.pendingTerminalQueries)+len(queries) >
			pendingTerminalQueryLimitBytes {
		return
	}
	window.pendingTerminalQueries = append(
		window.pendingTerminalQueries,
		queries...,
	)
}

// flushPendingTerminalQueriesLocked delivers to the freshly attached terminal any
// capability/status queries the active window's child emitted while no terminal
// was showing it. An agent (e.g. Copilot CLI) relaunched during an upgrade
// restore queries the terminal at startup, before the client reattaches; those
// queries land in history but foreground-redraw windows do not replay history, so
// the terminal would otherwise never answer and the agent falls back to a less
// rich rendering mode. Re-emitting just the queries makes the terminal answer
// them, and the answers route back to the active window's child via the normal
// attach-input path. Must be called with attachMu held.
//
// Colour-scheme queries are dropped rather than replayed, because their reply is
// the one that cannot be delivered late: it reaches the window pty as input, so
// if the process that asked has exited by then its shell echoes the reply as
// literal `^[[?997;1n` text at the prompt. A live agent loses nothing — the
// daemon answers this query from the cached theme hint the moment it is emitted,
// and a window that opted into colour-scheme updates (DEC 2031) is sent a fresh
// mode report by the attach theme-hint path anyway.
func (s *muxServer) flushPendingTerminalQueriesLocked(conn net.Conn, windowID string) {
	if conn == nil {
		return
	}
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	var pending []byte
	if window != nil && !window.closed &&
		s.activeID == windowID && s.attachConn == conn {
		// This terminal is now showing the window, so it answers the child's
		// queries itself from here on. Clear the synthetic-answer budget so a
		// window that spent it while unwatched can be answered again the next
		// time it goes back to running in the background — even if it produced
		// no output while it was visible.
		window.capabilityAnswerBytes = 0
	}
	if window != nil && !window.closed &&
		s.activeID == windowID && s.attachConn == conn &&
		len(window.pendingTerminalQueriesInFlight) == 0 &&
		len(window.pendingTerminalQueries) > 0 {
		pending = dropColorSchemeQueries(window.pendingTerminalQueries)
		window.pendingTerminalQueries = nil
		window.pendingTerminalQueriesInFlight = append(
			window.pendingTerminalQueriesInFlight[:0],
			pending...,
		)
	}
	s.mu.Unlock()
	if len(pending) == 0 {
		return
	}
	client, completion, queued := s.enqueuePrimaryAttachLocked(
		conn,
		pending,
		true,
		windowID,
	)
	if !queued {
		s.restorePendingTerminalQueries(windowID, pending)
		return
	}
	if client != nil {
		s.watchTerminalQueryWrite(
			windowID,
			client,
			completion,
			pending,
			func() {
				s.clearPendingTerminalQueriesInFlight(windowID, pending)
			},
			func() {
				s.restorePendingTerminalQueries(windowID, pending)
			},
		)
		return
	}
	s.clearPendingTerminalQueriesInFlight(windowID, pending)
}

// dropColorSchemeQueries returns pending without the colour-scheme queries,
// preserving the emission order of the queries that remain.
func dropColorSchemeQueries(pending []byte) []byte {
	remaining := make([]byte, 0, len(pending))
	for index := 0; index < len(pending); {
		sequenceEnd, _, incomplete, recognized := terminalQuerySequenceAt(
			pending,
			index,
		)
		if incomplete {
			remaining = append(remaining, pending[index:]...)
			break
		}
		if !recognized {
			remaining = append(remaining, pending[index])
			index++
			continue
		}
		if !isTerminalColorSchemeQuery(pending[index:sequenceEnd]) {
			remaining = append(remaining, pending[index:sequenceEnd]...)
		}
		index = sequenceEnd
	}
	return remaining
}

func (s *muxServer) clearPendingTerminalQueriesInFlight(
	windowID string,
	pending []byte,
) {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window != nil &&
		bytes.Equal(window.pendingTerminalQueriesInFlight, pending) {
		window.pendingTerminalQueriesInFlight = nil
	}
	s.mu.Unlock()
}

func (s *muxServer) restorePendingTerminalQueries(
	windowID string,
	pending []byte,
) {
	s.mu.Lock()
	defer s.mu.Unlock()
	window := s.windowByIDLocked(windowID)
	if window == nil ||
		!bytes.Equal(window.pendingTerminalQueriesInFlight, pending) {
		return
	}
	window.pendingTerminalQueriesInFlight = nil
	if len(pending)+len(window.pendingTerminalQueries) >
		pendingTerminalQueryLimitBytes {
		return
	}
	restored := make([]byte, 0, len(pending)+len(window.pendingTerminalQueries))
	restored = append(restored, pending...)
	restored = append(restored, window.pendingTerminalQueries...)
	window.pendingTerminalQueries = restored
}

func (s *muxServer) handleAttachInputSerialized(
	client *attachClient,
	data []byte,
	bracketedPaste bool,
) bool {
	client.inputMu.Lock()
	defer client.inputMu.Unlock()
	if bracketedPaste {
		s.writeActiveFromAttachInput(data, true)
		return false
	}
	return s.handleAttachInput(client, data)
}

func (s *muxServer) handleAttachInput(client *attachClient, data []byte) bool {
	if client == nil || len(data) == 0 {
		return false
	}
	if !client.prefixEnabled {
		s.writeActiveFromAttach(data)
		return false
	}

	pending := make([]byte, 0, len(data))
	flush := func() {
		if len(pending) == 0 {
			return
		}
		s.writeActiveFromAttach(pending)
		pending = pending[:0]
	}
	for _, value := range data {
		if client.confirmCloseID != "" {
			windowID := client.confirmCloseID
			client.confirmCloseID = ""
			if value == 'y' || value == 'Y' {
				shouldShutdown, err := s.closeWindow(windowID)
				if err != nil {
					s.ringAttachBell(client)
					s.replayActiveWindowToClient(client)
				} else if shouldShutdown {
					go s.close()
				}
			} else {
				s.replayActiveWindowToClient(client)
			}
			continue
		}
		if client.prefixPending {
			client.prefixPending = false
			flush()
			if s.handleAttachPrefixCommand(client, value) {
				return true
			}
			continue
		}
		if value == 0x02 {
			flush()
			client.prefixPending = true
			continue
		}
		pending = append(pending, value)
	}
	flush()
	return false
}

func (s *muxServer) handleAttachPrefixCommand(
	client *attachClient,
	command byte,
) bool {
	var err error
	switch command {
	case 0x02:
		s.writeActiveFromAttach([]byte{0x02})
	case 'c':
		err = s.createWindowFromActiveDirectory()
	case 'n':
		err = s.selectRelativeWindow(1)
	case 'p':
		err = s.selectRelativeWindow(-1)
	case 'l':
		err = s.selectLastWindow()
	case '&':
		err = s.requestCloseActiveWindow(client)
	case 'd':
		client.close()
		return true
	default:
		if command >= '0' && command <= '9' {
			err = s.selectWindowByIndex(int(command - '0'))
		} else {
			err = fmt.Errorf("unsupported prefix command")
		}
	}
	if err != nil {
		s.ringAttachBell(client)
	}
	return false
}

func (s *muxServer) createWindowFromActiveDirectory() error {
	s.mu.Lock()
	window := s.windowByIDLocked(s.activeID)
	cwd := ""
	if window != nil && !window.closed {
		cwd = window.cwd
	}
	s.mu.Unlock()
	_, err := s.createWindow(createWindowOptions{cwd: cwd})
	return err
}

func (s *muxServer) selectRelativeWindow(offset int) error {
	s.mu.Lock()
	open := make([]string, 0, len(s.windows))
	activeIndex := -1
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		if window.id == s.activeID {
			activeIndex = len(open)
		}
		open = append(open, window.id)
	}
	s.mu.Unlock()
	if len(open) == 0 || activeIndex < 0 {
		return errors.New("no active window")
	}
	target := (activeIndex + offset) % len(open)
	if target < 0 {
		target += len(open)
	}
	return s.selectWindow(open[target])
}

func (s *muxServer) selectWindowByIndex(index int) error {
	id := s.windowIDForIndex(index)
	if id == "" {
		return fmt.Errorf("window index %d not found", index)
	}
	return s.selectWindow(id)
}

func (s *muxServer) selectLastWindow() error {
	s.mu.Lock()
	id := s.lastActiveID
	window := s.windowByIDLocked(id)
	if window == nil || window.closed {
		id = ""
	}
	s.mu.Unlock()
	if id == "" {
		return errors.New("no last window")
	}
	return s.selectWindow(id)
}

func (s *muxServer) requestCloseActiveWindow(client *attachClient) error {
	id := s.activeWindowID()
	if id == "" {
		return errors.New("no active window")
	}
	client.confirmCloseID = id
	s.attachMu.Lock()
	s.writeAttachLocked(
		client.conn,
		[]byte("\r\n[monkeymux] close current window? (y/n) "),
	)
	s.attachMu.Unlock()
	return nil
}

func (s *muxServer) replayActiveWindowToClient(client *attachClient) {
	if client == nil {
		return
	}
	var replay []byte
	var window *muxWindow
	var foregroundProcessGroup int
	var windowID string
	s.attachMu.Lock()
	s.mu.Lock()
	window = s.windowByIDLocked(s.activeID)
	if window != nil && !window.closed {
		windowID = window.id
		replay = s.replayBytesLocked(window)
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
	}
	s.mu.Unlock()
	if window == nil {
		s.attachMu.Unlock()
		return
	}
	redrew := s.writeAttachReplayAndResizeLocked(client.conn, replay, window)
	s.flushPendingTerminalQueriesLocked(client.conn, windowID)
	s.attachMu.Unlock()
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
}

func (s *muxServer) replayFocusedWindowToClient(
	client *attachClient,
	width int,
	height int,
) bool {
	if client == nil {
		return false
	}
	var foregroundProcessGroup int
	var windowID string
	var window *muxWindow
	var replay []byte
	s.attachMu.Lock()
	s.mu.Lock()
	if s.attachConn != client.conn ||
		s.attachClients[client.conn] != client {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false
	}
	window = s.windowByIDLocked(s.activeID)
	if !terminalViewportTransitionSafe(window) {
		s.width = width
		s.height = height
		s.pendingFocusRefreshConn = client.conn
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false
	}
	s.pendingFocusRefreshConn = nil
	s.pendingResizeWidth = 0
	s.pendingResizeHeight = 0
	s.pendingResizeRedraw = false
	s.pendingResizeSyntheticRedraw = false
	s.pendingResizeThemeWindowID = ""
	s.width = width
	s.height = height
	s.enqueueAttachViewportResizeLocked(width, height)
	s.publishedWidth = width
	s.publishedHeight = height
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false
	}
	s.resizeActiveLocked(width, height)
	windowID = window.id
	replay = s.replayBytesLocked(window)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	client.markOutputReplay(windowID, window.outputGeneration)
	_, queued := client.enqueue(replay, false)
	s.mu.Unlock()
	if !queued {
		client.clearOutputReplay()
		s.attachMu.Unlock()
		return false
	}
	redrew := s.simulateForegroundResizeIfAttached(client.conn, window)
	s.flushPendingTerminalQueriesLocked(client.conn, windowID)
	s.attachMu.Unlock()
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	return true
}

func (s *muxServer) ringAttachBell(client *attachClient) {
	if client == nil {
		return
	}
	s.attachMu.Lock()
	s.writeAttachLocked(client.conn, []byte{'\a'})
	s.attachMu.Unlock()
}

func (s *muxServer) writeActiveFromAttach(data []byte) {
	s.writeActiveFromAttachInput(data, false)
}

func (s *muxServer) writeActiveFromAttachInput(
	data []byte,
	bracketedPaste bool,
) {
	if len(data) == 0 {
		return
	}
	s.mu.Lock()
	windowID := s.activeID
	window := s.windowByIDLocked(windowID)
	stripFocusReports := window == nil || !window.focusModeActiveLocked()
	s.mu.Unlock()
	if stripFocusReports && !bracketedPaste {
		data = stripFocusReportsFromAttachInput(data)
		if len(data) == 0 {
			return
		}
	}
	_ = s.writeWindowInput(windowID, data, bracketedPaste)
}

func (s *muxServer) sendThemeHint(data string) bool {
	_, ok := s.sendThemeHintToActiveWindow(data)
	return ok
}

// sendThemeHintToActiveWindow delivers the theme hint to the active window and
// returns the id of that window (empty only when there is no usable active
// window). Callers that follow up with a forced repaint use the returned id to
// pin the redraw to the same window, so a concurrent window switch cannot leave
// the hint on one window while the synthetic resize repaints another. The bool
// reports whether hint bytes / a focus nudge were actually delivered; the window
// id is returned even when nothing was pushed so the caller can still repaint
// the intended window.
func (s *muxServer) sendThemeHintToActiveWindow(data string) (string, bool) {
	s.refreshProcessMetadata("")
	themeHint := themeHintDataFromString(data)
	var themeHintData []byte
	s.mu.Lock()
	if len(themeHint) > 0 {
		s.themeHint = append(s.themeHint[:0], themeHint...)
	}
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return "", false
	}
	windowID := window.id
	sendFocusTransition := window.themeHintFocusTransitionLocked()
	if len(themeHint) > 0 {
		themeHintData = window.themeHintRefreshDataLocked(themeHint)
	}
	if len(themeHintData) == 0 && !sendFocusTransition {
		s.mu.Unlock()
		return windowID, false
	}
	s.mu.Unlock()

	if len(themeHintData) > 0 {
		if err := s.writeWindow(windowID, themeHintData); err != nil {
			return windowID, false
		}
	}
	if sendFocusTransition {
		s.sendFocusTransition(windowID)
	}
	return windowID, true
}

func themeHintDataFromString(data string) []byte {
	data = strings.TrimSpace(data)
	if data == "" || len(data) > themeHintLimitBytes {
		return nil
	}
	return []byte(data)
}

func capabilityHintDataFromString(data string) []byte {
	data = strings.TrimSpace(data)
	if data == "" || len(data) > capabilityHintLimitBytes {
		return nil
	}
	return []byte(data)
}

func (s *muxServer) sendFocusTransition(windowID string) {
	go func() {
		_ = s.writeWindowInput(windowID, []byte("\x1b[O"), false)
		time.Sleep(50 * time.Millisecond)
		_ = s.writeWindowInput(windowID, []byte("\x1b[I"), false)
	}()
}

// Terminal replies have their own stream state, independent of user input and
// focus events, which can arrive while a large reply is still being streamed.
func (s *muxServer) writeWindow(windowID string, data []byte) error {
	return s.writeWindowData(windowID, data, false, true)
}

func (s *muxServer) writeWindowInput(
	windowID string,
	data []byte,
	bracketedPaste bool,
) error {
	return s.writeWindowData(windowID, data, bracketedPaste, false)
}

func (s *muxServer) writeWindowData(windowID string, data []byte, bracketedPaste, response bool) error {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	win32InputMode := window.win32InputMode
	s.mu.Unlock()
	window.inputMu.Lock()
	defer window.inputMu.Unlock()
	// Native console readers receive encoded protocol bytes as typed keys.
	// Query the console mode rather than inferring the reader from an app name.
	// Ordinary keys need no probe: both reader types use the same encoding.
	// Keep an already-started native paste on the same path until its closing
	// marker arrives. A split paste needs one mode query, not one per packet.
	responseFilter := window.nativeResponse
	var filteredResponse []byte
	var hasResponse bool
	if win32InputMode && response {
		filteredResponse, hasResponse = responseFilter.filter(data)
	}
	nativeConsoleInput := win32InputMode && ((bracketedPaste &&
		(window.nativePaste.inPaste || len(window.nativePaste.carry) > 0)) ||
		(response && window.nativeResponse.kind != 0))
	if win32InputMode && !nativeConsoleInput && (bracketedPaste || hasResponse) {
		if console, ok := window.pty.(interface{ virtualTerminalInputEnabled() (bool, error) }); ok {
			vtInput, err := console.virtualTerminalInputEnabled()
			nativeConsoleInput = err == nil && !vtInput
		}
	}
	if win32InputMode && response {
		if !nativeConsoleInput {
			responseFilter.kind, responseFilter.escape = 0, false
		}
		window.nativeResponse = responseFilter
	}
	if nativeConsoleInput {
		if bracketedPaste {
			data = window.nativePaste.encode(data)
		} else {
			data = filteredResponse
			data = encodeTerminalInputForWin32InputMode(data)
		}
	} else if win32InputMode {
		// ConPTY's input parser cannot disambiguate a bare ESC and drops raw
		// OSC/DCS sequences, so a standalone Escape keystroke and synthetic
		// replies (theme hints, clipboard responses, relayed query answers)
		// must be re-encoded as win32-input-mode key events to survive the
		// trip through conhost to the child process.
		if bracketedPaste {
			data = encodeBracketedPasteInputForWin32InputMode(data)
		} else {
			data = encodeTerminalInputForWin32InputMode(data)
		}
		data = encodeTerminalResponsesForWin32InputMode(data)
	}
	_, err := window.pty.Write(data)
	return err
}

// terminalOscOrDcsSequencePattern matches complete OSC (`ESC ] ... BEL|ST`) and
// DCS (`ESC P ... ST`) sequences. CSI sequences and plain text are left alone:
// ConPTY's input parser passes those through unmodified.
var terminalOscOrDcsSequencePattern = regexp.MustCompile(
	`\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|P[^\x1b]*\x1b\\)`,
)

// encodeTerminalResponsesForWin32InputMode re-encodes any OSC/DCS sequences in
// data as win32-input-mode key events (`CSI Vk;Sc;Uc;Kd;Cs;Rc _`), the format
// ConPTY expects for terminal input while DEC private mode 9001 is enabled.
// All other bytes pass through untouched.
func encodeTerminalResponsesForWin32InputMode(data []byte) []byte {
	if !bytes.Contains(data, []byte("\x1b]")) && !bytes.Contains(data, []byte("\x1bP")) {
		return data
	}
	var output bytes.Buffer
	cursor := 0
	for _, match := range terminalOscOrDcsSequencePattern.FindAllIndex(data, -1) {
		output.Write(data[cursor:match[0]])
		writeWin32InputModeKeyEvents(&output, data[match[0]:match[1]])
		cursor = match[1]
	}
	output.Write(data[cursor:])
	return output.Bytes()
}

func writeWin32InputModeKeyEvents(output *bytes.Buffer, sequence []byte) {
	for _, codeUnit := range utf16.Encode([]rune(string(sequence))) {
		// Only the Unicode char, key-down, and repeat-count fields are set,
		// mirroring how Windows Terminal forwards characters that have no
		// associated virtual key.
		fmt.Fprintf(output, "\x1b[0;0;%d;1;0;1_", codeUnit)
	}
}

// win32InputModeEscapeKeyEvents are the win32-input-mode key-down and key-up
// events for the Escape key: `CSI Vk;Sc;Uc;Kd;Cs;Rc _` with VK_ESCAPE (27), the
// Escape scan code (1) and U+001B, matching what Windows Terminal sends for a
// physical Escape.
const win32InputModeEscapeKeyEvents = "\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_"

const win32InputModeEscapeCharacterEvent = "\x1b[0;0;27;1;0;1_"

// encodeTerminalInputForWin32InputMode re-encodes a standalone Escape keystroke
// as win32-input-mode key events.
//
// ConPTY's input parser cannot tell a bare ESC from the first byte of an escape
// sequence, so it holds the byte back until enough input arrives to disambiguate
// it. A lone Escape therefore only reaches the window's child once the next key
// is pressed, which reads as "Escape stopped working" (TUIs never leave their
// mode, and Ctrl+C is the only way out). An explicit key event has no such
// ambiguity.
func encodeTerminalInputForWin32InputMode(data []byte) []byte {
	if len(data) != 1 || data[0] != 0x1b {
		return data
	}
	return []byte(win32InputModeEscapeKeyEvents)
}

// encodeBracketedPasteInputForWin32InputMode re-encodes every ESC in an
// already-classified bracketed paste as a generic Unicode character event.
// ConPTY otherwise consumes the CSI 200~/201~ framing (and can interpret escape
// sequences inside the paste body) before the child sees it.
func encodeBracketedPasteInputForWin32InputMode(data []byte) []byte {
	if !bytes.Contains(data, []byte{0x1b}) {
		return data
	}
	var output bytes.Buffer
	cursor := 0
	for index := 0; index < len(data); index++ {
		if data[index] != 0x1b {
			continue
		}
		output.Write(data[cursor:index])
		output.WriteString(win32InputModeEscapeCharacterEvent)
		cursor = index + 1
	}
	if cursor == 0 {
		return data
	}
	output.Write(data[cursor:])
	return output.Bytes()
}

// win32InputModeRequests are the DEC private mode 9001 (win32-input-mode)
// enable/disable sequences a foreground child emits to negotiate rich keyboard
// input with its terminal.
var win32InputModeRequests = [][]byte{
	[]byte("\x1b[?9001h"),
	[]byte("\x1b[?9001l"),
}

// win32InputModeRequestStripper removes win32-input-mode (DEC private mode 9001)
// requests from a stream of window output before it reaches os.Stdout.
//
// On Windows the `monkeymux attach` process runs inside the SSH server's own
// ConPTY (conhost). That conhost watches the attach process's output for a
// `CSI ? 9001 h` and, on seeing one, switches its input delivery to
// win32-input-mode — decomposing the client's raw VT input (e.g. an arrow key's
// `ESC [ A`) into individual character key events. Those char events survive the
// relay to the window's own ConPTY as a bare ESC followed by literal `[A`, which
// PSReadLine and other line editors treat as an Escape keypress plus typed text
// instead of a cursor key (so Up/Down stop recalling history). The window's
// child still negotiates win32-input-mode directly with its own ConPTY, so
// hiding the request from the outer conhost is safe and keeps arrow keys intact.
type win32InputModeRequestStripper struct {
	dst   io.Writer
	carry []byte
}

func newWin32InputModeRequestStripper(dst io.Writer) *win32InputModeRequestStripper {
	return &win32InputModeRequestStripper{dst: dst}
}

func (s *win32InputModeRequestStripper) Write(p []byte) (int, error) {
	out, carry := stripWin32InputModeRequests(s.carry, p)
	s.carry = carry
	if len(out) > 0 {
		if _, err := s.dst.Write(out); err != nil {
			return 0, err
		}
	}
	return len(p), nil
}

// Flush writes any buffered partial sequence to the destination. It must be
// called once the source stream ends so a trailing run that looked like the
// start of a win32-input-mode request (but was never completed) is not dropped.
func (s *win32InputModeRequestStripper) Flush() error {
	if len(s.carry) == 0 {
		return nil
	}
	carry := s.carry
	s.carry = nil
	_, err := s.dst.Write(carry)
	return err
}

// stripWin32InputModeRequests removes any complete win32-input-mode requests from
// prev+data and returns the bytes to emit plus a carry holding a trailing partial
// that could still complete into a request on the next write. A trailing byte run
// is only carried when it is a strict prefix of a request sequence, so ordinary
// escape sequences are never delayed by more than the bytes they share with the
// `ESC [ ? 9 0 0 1` prefix.
func stripWin32InputModeRequests(prev, data []byte) (out, carry []byte) {
	buf := data
	if len(prev) > 0 {
		buf = append(append(make([]byte, 0, len(prev)+len(data)), prev...), data...)
	}
	out = make([]byte, 0, len(buf))
	i := 0
	for i < len(buf) {
		next := bytes.IndexByte(buf[i:], '\x1b')
		if next < 0 {
			out = append(out, buf[i:]...)
			return out, nil
		}
		escape := i + next
		out = append(out, buf[i:escape]...)
		rest := buf[escape:]
		if stripped, ok := matchWin32InputModeRequest(rest); ok {
			i = escape + stripped
			continue
		}
		if isWin32InputModeRequestPrefix(rest) {
			carry = append(make([]byte, 0, len(rest)), rest...)
			return out, carry
		}
		out = append(out, '\x1b')
		i = escape + 1
	}
	return out, nil
}

// matchWin32InputModeRequest reports whether rest begins with a complete
// win32-input-mode request and, if so, its length.
func matchWin32InputModeRequest(rest []byte) (length int, ok bool) {
	for _, request := range win32InputModeRequests {
		if bytes.HasPrefix(rest, request) {
			return len(request), true
		}
	}
	return 0, false
}

// isWin32InputModeRequestPrefix reports whether rest is a non-empty strict prefix
// of a win32-input-mode request (so it might complete into one on the next
// write).
func isWin32InputModeRequestPrefix(rest []byte) bool {
	for _, request := range win32InputModeRequests {
		if len(rest) < len(request) && bytes.HasPrefix(request, rest) {
			return true
		}
	}
	return false
}

func (s *muxServer) activeWindowID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.activeID
}

func (s *muxServer) windowIDForIndex(index int) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, window := range s.windows {
		if !window.closed && window.index == index {
			return window.id
		}
	}
	return ""
}

func (s *muxServer) windowByIDLocked(windowID string) *muxWindow {
	for _, window := range s.windows {
		if window.id == windowID {
			return window
		}
	}
	return nil
}

func (w *muxWindow) appendHistoryLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	limit := w.historyLimitLocked()
	if len(chunk) >= limit {
		parser := w.historyStartTerminalOutput
		parser.observe(w.history)
		parser.observe(chunk[:len(chunk)-limit])
		w.historyStartTerminalOutput = parser
		w.history = append(
			w.history[:0],
			chunk[len(chunk)-limit:]...,
		)
		return
	}
	// Grow the underlying buffer to 2x the limit so trims are amortized:
	// each byte gets shifted at most once before falling out of history.
	if cap(w.history) < 2*limit {
		grown := make([]byte, len(w.history), 2*limit)
		copy(grown, w.history)
		w.history = grown
	}
	w.history = append(w.history, chunk...)
	if len(w.history) > 2*limit {
		start := len(w.history) - limit
		w.historyStartTerminalOutput.observe(w.history[:start])
		// copy() handles the overlap correctly because src is after dst.
		n := copy(w.history, w.history[start:])
		w.history = w.history[:n]
	}
}

func (w *muxWindow) historyTailWithParserLocked() (
	[]byte,
	terminalOutputParserSnapshot,
) {
	limit := w.historyLimitLocked()
	if len(w.history) <= limit {
		return w.history, w.historyStartTerminalOutput
	}
	start := len(w.history) - limit
	start = advanceToUtf8Boundary(w.history, start)
	parser := w.historyStartTerminalOutput
	parser.observe(w.history[:start])
	return w.history[start:], parser
}

func (w *muxWindow) historyLimitLocked() int {
	if w.usesForegroundRedrawReplayLocked() || w.retainsConPtyNormalScreenLocked() {
		return windowFullReplayHistoryLimitBytes
	}
	return windowHistoryLimitBytes
}

func trimReplayHistoryForAttachWithParser(
	history []byte,
	historyStart terminalOutputParserSnapshot,
) []byte {
	if len(history) <= windowReplayLimitBytes && historyStart.isGround() {
		return history
	}
	start := 0
	if len(history) > windowReplayLimitBytes {
		start = len(history) - windowReplayLimitBytes
	}
	start = advanceReplayStartToTerminalGround(history, start, historyStart)
	if start >= len(history) {
		return nil
	}
	scanEnd := start + 2048
	if scanEnd > len(history) {
		scanEnd = len(history)
	}
	for i := start; i < scanEnd; i++ {
		switch history[i] {
		case '\x1b', '\n', '\r':
			return history[i:]
		}
	}
	start = advanceToUtf8Boundary(history, start)
	return history[start:]
}

// advanceReplayStartToTerminalGround moves a size-based replay cut past any
// escape sequence it bisects. In particular, starting inside a Kitty APC would
// render its base64 payload as text and scroll the image away from its anchor.
func advanceReplayStartToTerminalGround(
	data []byte,
	start int,
	scanner terminalOutputParserSnapshot,
) int {
	if start >= len(data) {
		return len(data)
	}
	scanner.observe(data[:start])
	for start < len(data) && !scanner.isGround() {
		scanner.observe(data[start : start+1])
		start++
	}
	return advanceToUtf8Boundary(data, start)
}

func terminalHistoryAtGroundBoundaries(
	data []byte,
	startState terminalOutputParserSnapshot,
) []byte {
	start := advanceReplayStartToTerminalGround(data, 0, startState)
	if start >= len(data) {
		return nil
	}
	data = data[start:]
	scanner := terminalOutputParserSnapshot{}
	lastGround := 0
	for i := range data {
		scanner.observe(data[i : i+1])
		if scanner.isGround() {
			lastGround = i + 1
		}
	}
	return data[:lastGround]
}

// sanitizeLegacyRestoreHistory discards a payload-like prefix from snapshots
// written before parser-boundary state was recorded. Ordinary short shell text
// is preserved, while a retained Kitty base64 tail is resumed at the first
// trustworthy terminal boundary.
func sanitizeLegacyRestoreHistory(data []byte) []byte {
	boundary := -1
	resume := -1
	for i, value := range data {
		switch value {
		case '\n', '\r':
			boundary = i
		case '\a':
			boundary = i
			resume = i + 1
		case '\x1b':
			boundary = i
			if i+1 < len(data) && data[i+1] == '\\' {
				resume = i + 2
			}
		}
		if boundary >= 0 {
			break
		}
	}
	prefixEnd := len(data)
	if boundary >= 0 {
		prefixEnd = boundary
	}
	if resume < 0 && !looksLikeKittyPayload(data[:prefixEnd]) {
		return data
	}
	if boundary < 0 {
		return nil
	}
	if resume >= 0 {
		return data[resume:]
	}
	return data[boundary:]
}

func looksLikeKittyPayload(data []byte) bool {
	if len(data) < 256 {
		return false
	}
	for _, value := range data {
		if base64DecodeValue[value] < 0 && value != '=' {
			return false
		}
	}
	return true
}

// advanceToUtf8Boundary moves start forward past any UTF-8 continuation bytes
// (0b10xxxxxx) so the returned slice begins on a valid UTF-8 starter. This
// prevents replay payloads from beginning in the middle of a multi-byte
// character, which would force strict UTF-8 decoders (such as Dart's
// default Utf8Decoder) to throw and drop the chunk that contained the next
// redraw frame.
func advanceToUtf8Boundary(data []byte, start int) int {
	if start < 0 {
		start = 0
	}
	limit := start + 4
	if limit > len(data) {
		limit = len(data)
	}
	for start < limit && data[start]&0xC0 == 0x80 {
		start++
	}
	return start
}

func stripFocusReportsFromAttachInput(data []byte) []byte {
	if len(data) < 3 || !bytes.Contains(data, []byte("\x1b[")) {
		return data
	}
	var output []byte
	copyStart := 0
	for i := 0; i+2 < len(data); i++ {
		if data[i] != '\x1b' || data[i+1] != '[' ||
			(data[i+2] != 'I' && data[i+2] != 'O') {
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-3)
		}
		output = append(output, data[copyStart:i]...)
		copyStart = i + 3
		i += 2
	}
	if output == nil {
		return data
	}
	output = append(output, data[copyStart:]...)
	return output
}

func (w *muxWindow) observeTerminalOutputStateLocked(data []byte) bool {
	parser := terminalOutputParserSnapshot{
		state:         w.terminalOutputState,
		bytes:         w.terminalOutputBytes,
		utf8Remaining: w.terminalOutputUtf8Remaining,
	}
	bell := parser.observe(data)
	w.terminalOutputState = parser.state
	w.terminalOutputBytes = parser.bytes
	w.terminalOutputUtf8Remaining = parser.utf8Remaining
	return bell
}

func (p *terminalOutputParserSnapshot) observe(data []byte) (bell bool) {
	for _, value := range data {
		if p.utf8Remaining > 0 {
			if value&0xc0 == 0x80 {
				p.utf8Remaining--
				continue
			}
			p.utf8Remaining = 0
		}
		if remaining := utf8ContinuationCount(value); remaining > 0 {
			p.utf8Remaining = remaining
			continue
		}
		if value == 0x18 || value == 0x1a {
			p.reset()
			continue
		}
		if value == '\a' && p.state <= terminalOutputParserCsi {
			bell = true
		}
		switch p.state {
		case terminalOutputParserGround:
			switch value {
			case '\x1b':
				p.state = terminalOutputParserEscape
			case 0x90, 0x98, 0x9e, 0x9f:
				p.state = terminalOutputParserString
			case 0x9b:
				p.state = terminalOutputParserCsi
			case 0x9d:
				p.state = terminalOutputParserOsc
			}
		case terminalOutputParserEscape:
			switch {
			case value == '\x1b':
				p.state = terminalOutputParserEscape
			case value == '[':
				p.state = terminalOutputParserCsi
			case value == ']':
				p.state = terminalOutputParserOsc
			case value == 'P' || value == 'X' || value == '^' || value == '_':
				p.state = terminalOutputParserString
			case value >= 0x20 && value <= 0x2f:
				p.state = terminalOutputParserEscapeIntermediate
			default:
				p.reset()
			}
		case terminalOutputParserEscapeIntermediate:
			switch {
			case value == '\x1b':
				p.state = terminalOutputParserEscape
			case value >= 0x20 && value <= 0x2f:
			case value >= 0x30 && value <= 0x7e:
				p.reset()
			default:
				p.reset()
			}
		case terminalOutputParserCsi:
			switch {
			case value == '\x1b':
				p.state = terminalOutputParserEscape
			case value >= 0x40 && value <= 0x7e:
				p.reset()
			}
		case terminalOutputParserOsc:
			switch value {
			case '\a', 0x9c:
				p.reset()
			case '\x1b':
				p.state = terminalOutputParserOscEscape
			}
		case terminalOutputParserOscEscape:
			switch value {
			case '\\', '\a', 0x9c:
				p.reset()
			case '\x1b':
				p.state = terminalOutputParserOscEscape
			default:
				p.state = terminalOutputParserOsc
			}
		case terminalOutputParserString:
			switch value {
			case 0x9c:
				p.reset()
			case '\x1b':
				p.state = terminalOutputParserStringEscape
			}
		case terminalOutputParserStringEscape:
			switch value {
			case '\\', 0x9c:
				p.reset()
			case '\x1b':
				p.state = terminalOutputParserStringEscape
			default:
				p.state = terminalOutputParserString
			}
		}
		if p.state != terminalOutputParserGround {
			p.bytes++
			if p.bytes > maxKittyGraphicsPendingBytes {
				p.reset()
			}
		}
	}
	return bell
}

func terminalOutputHasVisibleContent(data []byte) bool {
	parser := terminalOutputParserSnapshot{}
	rendition := terminalRenditionSnapshot{}
	for index := 0; index < len(data); {
		if parser.state != terminalOutputParserGround ||
			parser.utf8Remaining > 0 {
			parser.observe(data[index : index+1])
			index++
			continue
		}
		end, control, kitty := kittyGraphicsControlAt(data, index)
		if kitty && end > 0 {
			action := parseKittyControl(control)["a"]
			if action == "T" || action == "p" || action == "a" || action == "c" {
				return true
			}
			parser.observe(data[index:end])
			index = end
			continue
		}
		if kitty {
			// The APC is truncated, or terminated in a way the Kitty scanner
			// does not model (a CAN/SUB cancellation). Hand the bytes to the
			// byte-wise parser, which does track those, instead of giving up on
			// the rest of the buffer: text after a cancelled APC still paints.
			parser.observe(data[index : index+1])
			index++
			continue
		}
		if csiEnd, params, final, ok := controlSequenceAt(data, index); ok {
			if final == 'm' {
				rendition.observeSelectGraphicRendition(params)
			}
			parser.observe(data[index:csiEnd])
			index = csiEnd
			continue
		}
		value := data[index]
		if value < 0x20 || value == 0x7f || (value >= 0x80 && value < 0xa0) {
			parser.observe(data[index : index+1])
			index++
			continue
		}
		r, size := utf8.DecodeRune(data[index:])
		if r == utf8.RuneError && size == 1 {
			parser.observe(data[index : index+1])
			index++
			continue
		}
		if !unicode.IsSpace(r) || rendition.paintsWhitespace() {
			return true
		}
		parser.observe(data[index : index+size])
		index += size
	}
	return false
}

// terminalRenditionSnapshot tracks the subset of SGR state that makes a run of
// spaces paint visible cells. Whitespace is only invisible under the default
// rendition: with a non-default background, reverse video, an underline, a
// strike-through, or an overline the same spaces are a real frame, so the
// emptiness check must not discard them and restore stale history instead.
type terminalRenditionSnapshot struct {
	background bool
	reverse    bool
	underline  bool
	strike     bool
	overline   bool
}

func (r terminalRenditionSnapshot) paintsWhitespace() bool {
	return r.background || r.reverse || r.underline || r.strike || r.overline
}

func (r *terminalRenditionSnapshot) observeSelectGraphicRendition(
	params string,
) {
	if params != "" && params[0] >= 0x3c && params[0] <= 0x3f {
		// Private forms such as CSI > 4 ; 2 m (modifyOtherKeys) are not SGR.
		return
	}
	fields := strings.Split(params, ";")
	for index := 0; index < len(fields); index++ {
		field := fields[index]
		base := field
		sub := ""
		if colon := strings.IndexByte(field, ':'); colon >= 0 {
			base = field[:colon]
			sub = field[colon+1:]
		}
		code := 0
		if base != "" {
			parsed, err := strconv.Atoi(base)
			if err != nil {
				continue
			}
			code = parsed
		}
		switch {
		case code == 0:
			*r = terminalRenditionSnapshot{}
		case code == 4:
			r.underline = sub != "0"
		case code == 7:
			r.reverse = true
		case code == 9:
			r.strike = true
		case code == 21:
			r.underline = true
		case code == 24:
			r.underline = false
		case code == 27:
			r.reverse = false
		case code == 29:
			r.strike = false
		case code == 38 || code == 48:
			if code == 48 {
				r.background = true
			}
			if sub != "" {
				// Colon sub-parameter form keeps the color in this field.
				break
			}
			if index+1 < len(fields) {
				switch fields[index+1] {
				case "5":
					index += 2
				case "2":
					index += 4
				}
			}
		case code >= 40 && code <= 47:
			r.background = true
		case code == 49:
			r.background = false
		case code == 53:
			r.overline = true
		case code == 55:
			r.overline = false
		case code >= 100 && code <= 107:
			r.background = true
		}
	}
}

// controlSequenceAt reports the extent, parameter bytes, and final byte of a
// complete CSI sequence starting at start. It returns ok=false when the bytes
// are not a CSI introducer or the sequence is truncated, leaving those bytes to
// the byte-wise parser.
func controlSequenceAt(
	data []byte,
	start int,
) (end int, params string, final byte, ok bool) {
	from := 0
	switch {
	case start+1 < len(data) &&
		data[start] == '\x1b' &&
		data[start+1] == '[':
		from = start + 2
	case data[start] == 0x9b:
		from = start + 1
	default:
		return 0, "", 0, false
	}
	for index := from; index < len(data); index++ {
		value := data[index]
		if value >= 0x40 && value <= 0x7e {
			return index + 1, string(data[from:index]), value, true
		}
		if value < 0x20 || value > 0x3f {
			return 0, "", 0, false
		}
	}
	return 0, "", 0, false
}

func kittyGraphicsControlAt(
	data []byte,
	start int,
) (end int, control string, recognized bool) {
	if start+2 < len(data) &&
		data[start] == '\x1b' &&
		data[start+1] == '_' &&
		data[start+2] == 'G' {
		return kittyGraphicsControlExtent(data, start, start+3)
	}
	if start+1 >= len(data) || data[start] != 0x9f || data[start+1] != 'G' {
		return 0, "", false
	}
	return kittyGraphicsControlExtent(data, start, start+2)
}

// kittyGraphicsControlExtent finds the ST that closes a Kitty APC sequence whose
// payload begins at from, accepting both the 7-bit "ESC \" and 8-bit 0x9c
// terminators, and returns the control (pre-payload) portion.
func kittyGraphicsControlExtent(
	data []byte,
	start int,
	from int,
) (end int, control string, recognized bool) {
	to := -1
	for index := from; index < len(data); index++ {
		if data[index] == 0x18 || data[index] == 0x1a {
			// CAN/SUB cancel the APC. Report it as unresolved so the caller
			// hands the bytes to the byte-wise parser, which models the
			// cancellation; scanning on to a later ST would swallow the visible
			// text that follows the cancelled sequence.
			return -1, "", true
		}
		switch {
		case data[index] == 0x9c:
			end = index + 1
			to = index
		case index+1 < len(data) &&
			data[index] == '\x1b' &&
			data[index+1] == '\\':
			end = index + 2
			to = index
		}
		if end > 0 {
			break
		}
	}
	if end == 0 {
		return -1, "", true
	}
	if semi := bytes.IndexByte(data[from:to], ';'); semi >= 0 {
		to = from + semi
	}
	return end, string(data[from:to]), true
}

func (p *terminalOutputParserSnapshot) reset() {
	p.state = terminalOutputParserGround
	p.bytes = 0
}

func (p terminalOutputParserSnapshot) isGround() bool {
	return p.state == terminalOutputParserGround && p.utf8Remaining == 0
}

func (w *muxWindow) terminalOutputIsGroundLocked() bool {
	return terminalOutputParserSnapshot{
		state:         w.terminalOutputState,
		utf8Remaining: w.terminalOutputUtf8Remaining,
	}.isGround()
}

// stripLocallyAnsweredThemeQueries removes OSC 10/11/12/17/19 background-color
// queries and OSC 4 palette queries from chunk when MonkeyMux can answer them
// locally from hint. The daemon already writes the cached responses directly
// to the window PTY in handleWindowOutput, so forwarding the same queries to
// the SSH client would produce a duplicate reply. That duplicate would travel
// back through the attach socket as keyboard input and surface inside the
// active TUI as literal text (the user-visible "spew" bug). Queries we cannot
// answer (no cached response for every queried key) are left in place so the
// client can still reply.
func stripLocallyAnsweredThemeQueries(chunk []byte, hint []byte) []byte {
	window := &muxWindow{}
	output := window.stripLocallyAnsweredThemeQueriesLocked(chunk, hint)
	if len(window.attachOscBuffer) == 0 {
		return output
	}
	output = append(output, window.attachOscBuffer...)
	return output
}

func (w *muxWindow) stripLocallyAnsweredThemeQueriesLocked(chunk []byte, hint []byte) []byte {
	if len(chunk) == 0 && len(w.attachOscBuffer) == 0 {
		return chunk
	}
	data := chunk
	if len(w.attachOscBuffer) > 0 {
		combined := make([]byte, 0, len(w.attachOscBuffer)+len(chunk))
		combined = append(combined, w.attachOscBuffer...)
		combined = append(combined, chunk...)
		data = combined
		w.attachOscBuffer = nil
	}

	var responses map[string][]byte
	answerable := func(queryKeys []string) bool {
		if len(queryKeys) == 0 || len(hint) == 0 {
			return false
		}
		if responses == nil {
			responses = themeHintResponseMap(hint)
			if len(responses) == 0 {
				return false
			}
		}
		for _, key := range queryKeys {
			if len(responses[key]) == 0 {
				return false
			}
		}
		return true
	}

	var output []byte
	copyStart := 0
	for i := 0; i < len(data); {
		if data[i] != '\x1b' {
			i++
			continue
		}
		if i+1 >= len(data) {
			if w.storeAttachPartialOscLocked(data[i:]) {
				if output == nil {
					return data[:i]
				}
				output = append(output, data[copyStart:i]...)
				return output
			}
			break
		}
		if data[i+1] != ']' {
			i++
			continue
		}
		payloadStart := i + 2
		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			if w.storeAttachPartialOscLocked(data[i:]) {
				if output == nil {
					return data[:i]
				}
				output = append(output, data[copyStart:i]...)
				return output
			}
			break
		}
		sequenceEnd := payloadStart + payloadEnd + terminatorLength
		payload := data[payloadStart : payloadStart+payloadEnd]
		privatePiIdentity := bytes.HasPrefix(payload, []byte("1337;MonkeyMuxPi="))
		queryKeys := themeQueryKeysFromOscPayload(string(payload))
		if !privatePiIdentity && !answerable(queryKeys) {
			i = sequenceEnd
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-(sequenceEnd-i))
		}
		output = append(output, data[copyStart:i]...)
		copyStart = sequenceEnd
		i = sequenceEnd
	}
	if output == nil {
		return data
	}
	output = append(output, data[copyStart:]...)
	return output
}

func (w *muxWindow) storeAttachPartialOscLocked(data []byte) bool {
	if len(data) > oscBufferLimitBytes {
		w.attachOscBuffer = nil
		return false
	}
	w.attachOscBuffer = append(w.attachOscBuffer[:0], data...)
	return true
}

// withheldAttachOscSuffixTrimmedLocked removes from a replay the partial OSC
// that stripLocallyAnsweredThemeQueriesLocked is still holding back from the
// live stream, so the replay ends exactly where the live stream did.
//
// The buffer exists so a colour query split across two PTY reads can still be
// recognised (and stripped) when its tail arrives, which means its leading
// bytes are withheld from the forwarded output until then. appendHistoryLocked
// records the whole chunk regardless, so a replay built straight from history
// would hand the client bytes the live stream is about to send again. A
// duplicated `ESC` is not cosmetic: `ESC ESC ] 8 ; ...` makes the terminal
// consume both escapes and print the rest of the hyperlink introducer as
// literal text.
//
// Trimming the replay rather than dropping the buffer keeps this correct for
// every client. A replay is built per client, so releasing window-global state
// when one client reattaches would strand the clients that never saw it, and a
// replay whose history was trimmed away entirely (which
// trimReplayHistoryForAttachWithParser does when it finds no terminal ground
// state — the very case that fills this buffer) would strand all of them.
func (w *muxWindow) withheldAttachOscSuffixTrimmedLocked(
	history []byte,
) []byte {
	if w == nil || len(w.attachOscBuffer) == 0 {
		return history
	}
	if !bytes.HasSuffix(history, w.attachOscBuffer) {
		return history
	}
	return history[:len(history)-len(w.attachOscBuffer)]
}

func stripTerminalQueriesFromReplay(data []byte) []byte {
	if len(data) == 0 {
		return data
	}

	var output []byte
	copyStart := 0
	for i := 0; i < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAt(data, i)
		if incomplete {
			break
		}
		if !recognized {
			i++
			continue
		}
		shouldStrip := isQuery ||
			isReplayUnsafeOscNotificationSequence(data[i:sequenceEnd])
		if !shouldStrip {
			i = sequenceEnd
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-(sequenceEnd-i))
		}
		output = append(output, data[copyStart:i]...)
		copyStart = sequenceEnd
		i = sequenceEnd
	}
	if output == nil {
		return data
	}
	output = append(output, data[copyStart:]...)
	return output
}

func terminalQueryResponseCount(data []byte) int {
	count := 0
	for index := 0; index < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAt(data, index)
		if incomplete {
			break
		}
		if !recognized {
			index++
			continue
		}
		if isQuery {
			count += terminalQuerySequenceResponseCount(
				data[index:sequenceEnd],
			)
		}
		index = sequenceEnd
	}
	return count
}

func terminalQuerySequenceResponseCount(sequence []byte) int {
	payloadStart := 0
	osc := false
	dcs := false
	switch {
	case len(sequence) >= 2 &&
		sequence[0] == '\x1b' &&
		sequence[1] == ']':
		payloadStart = 2
		osc = true
	case len(sequence) >= 1 && sequence[0] == 0x9d:
		payloadStart = 1
		osc = true
	case len(sequence) >= 2 &&
		sequence[0] == '\x1b' &&
		sequence[1] == 'P':
		payloadStart = 2
		dcs = true
	case len(sequence) >= 1 && sequence[0] == 0x90:
		payloadStart = 1
		dcs = true
	default:
		return 1
	}
	findTerminator := findStringTerminator
	if osc {
		findTerminator = findOscTerminator
	}
	end, _, ok := findTerminator(sequence[payloadStart:])
	if !ok {
		return 1
	}
	payload := sequence[payloadStart : payloadStart+end]
	if dcs {
		if !bytes.HasPrefix(payload, []byte("+q")) {
			return 1
		}
		count := 0
		for _, capability := range bytes.Split(payload[2:], []byte{';'}) {
			if len(capability) > 0 {
				count++
			}
		}
		if count > 0 {
			return count
		}
		return 0
	}
	code, value, ok := strings.Cut(
		string(payload),
		";",
	)
	if !ok || code != "4" {
		return 1
	}
	args := strings.Split(value, ";")
	count := 0
	for index := 0; index+1 < len(args); index += 2 {
		paletteIndex, err := strconv.Atoi(strings.TrimSpace(args[index]))
		if err != nil ||
			paletteIndex < 0 ||
			paletteIndex > 255 ||
			strings.TrimSpace(args[index+1]) != "?" {
			continue
		}
		count++
	}
	if count == 0 {
		return 1
	}
	return count
}

func terminalResponseSequenceExpectationCount(sequence []byte) int {
	payloadStart := 0
	switch {
	case len(sequence) >= 2 &&
		sequence[0] == '\x1b' &&
		sequence[1] == 'P':
		payloadStart = 2
	case len(sequence) >= 1 && sequence[0] == 0x90:
		payloadStart = 1
	default:
		return 1
	}
	end, _, ok := findStringTerminator(sequence[payloadStart:])
	if !ok {
		return 1
	}
	payload := sequence[payloadStart : payloadStart+end]
	if !bytes.HasPrefix(payload, []byte("0+r")) &&
		!bytes.HasPrefix(payload, []byte("1+r")) {
		return 1
	}
	count := 0
	for _, capability := range bytes.Split(payload[3:], []byte{';'}) {
		if len(capability) > 0 {
			count++
		}
	}
	if count > 0 {
		return count
	}
	return 1
}

func (w *muxWindow) secondaryAttachOutputLocked(chunk []byte) []byte {
	w.lastForwardedTerminalQueries = nil
	if len(chunk) == 0 && len(w.secondaryQueryCarry) == 0 {
		return chunk
	}
	data := chunk
	previousUtf8Remaining := w.queryUtf8Remaining
	leadingUtf8Prefix := leadingUtf8ContinuationPrefix(
		data,
		previousUtf8Remaining,
	)
	w.queryUtf8Remaining = 0
	if len(w.secondaryQueryCarry) > 0 {
		combined := make([]byte, 0, len(w.secondaryQueryCarry)+len(chunk))
		combined = append(combined, w.secondaryQueryCarry...)
		combined = append(combined, chunk...)
		data = combined
		w.secondaryQueryCarry = nil
		leadingUtf8Prefix = 0
	}

	output := make([]byte, 0, len(data))
	copyStart := 0
	for i := 0; i < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAtWithUtf8Prefix(
				data,
				i,
				leadingUtf8Prefix,
			)
		if incomplete {
			w.queryUtf8Remaining = 0
			output = append(output, data[copyStart:i]...)
			if !w.storeSecondaryQueryCarryLocked(data[i:]) {
				output = append(output, data[i:]...)
			}
			return output
		}
		if !recognized {
			i++
			continue
		}
		if isQuery {
			if len(w.lastForwardedTerminalQueries)+sequenceEnd-i <=
				pendingTerminalQueryLimitBytes {
				w.lastForwardedTerminalQueries = append(
					w.lastForwardedTerminalQueries,
					data[i:sequenceEnd]...,
				)
			}
			output = append(output, data[copyStart:i]...)
			copyStart = sequenceEnd
		}
		i = sequenceEnd
	}
	output = append(output, data[copyStart:]...)
	w.queryUtf8Remaining = nextQueryUtf8Remaining(
		data,
		previousUtf8Remaining,
		leadingUtf8Prefix,
	)
	return output
}

func (w *muxWindow) storeSecondaryQueryCarryLocked(data []byte) bool {
	if len(data) > oscBufferLimitBytes {
		w.secondaryQueryCarry = nil
		return false
	}
	w.secondaryQueryCarry = append(w.secondaryQueryCarry[:0], data...)
	return true
}

// kittyGraphicsEvent is a complete retained Kitty root, animation command, or
// hard image-data delete in its original stream order.
type kittyGraphicsEvent struct {
	id          string
	imageNumber string
	buf         []byte
	animation   bool
	delete      bool
	clearCache  bool
	mappingOnly bool
}

// scanKittyTransmissions parses complete Kitty graphics events from the front of
// data. It returns retained roots (a=T rewritten to a=t), animation commands and
// hard deletes in stream order, plus the number of leading bytes fully consumed.
// data[consumed:] is the trailing remainder, which either is empty or begins an
// incomplete transmission and must be prepended to the next chunk.
//
// Non-graphics bytes are consumed and discarded; the remainder therefore never
// accumulates ordinary terminal output.
func scanKittyTransmissions(
	data []byte,
) (events []kittyGraphicsEvent, consumed int) {
	i := 0
	for i < len(data) {
		if data[i] != '\x1b' {
			i++
			consumed = i
			continue
		}
		// data[i] == ESC. A graphics command is ESC _ G.
		if i+2 >= len(data) {
			// Not enough bytes to tell. If it cannot become "_G", consume the
			// ESC; otherwise carry the partial introducer forward.
			if i+1 < len(data) && data[i+1] != '_' {
				i++
				consumed = i
				continue
			}
			return events, i
		}
		if data[i+1] != '_' || data[i+2] != 'G' {
			i++
			consumed = i
			continue
		}
		end, buf, id, imageNumber, isDelete, isAnimation, ok :=
			assembleKittyTransmission(data, i)
		if !ok {
			// Incomplete transmission: carry everything from here forward.
			return events, i
		}
		if isDelete {
			selector := parseKittyControl(kittyControl(data, i, end))["d"]
			clearCache := selector == "A" ||
				selector == "C" ||
				selector == "P" ||
				selector == "X" ||
				selector == "Y"
			if id != "" || imageNumber != "" || clearCache {
				events = append(events, kittyGraphicsEvent{
					id: id, imageNumber: imageNumber, delete: true, clearCache: clearCache,
				})
			}
		} else if buf != nil {
			events = append(events, kittyGraphicsEvent{
				id: id, imageNumber: imageNumber, buf: buf, animation: isAnimation,
			})
		} else {
			args := parseKittyControl(kittyControl(data, i, end))
			if args["a"] == "p" && args["i"] != "" && args["I"] != "" {
				events = append(events, kittyGraphicsEvent{
					id: args["i"], imageNumber: args["I"], mappingOnly: true,
				})
			}
		}
		i = end
		consumed = end
	}
	return events, consumed
}

// assembleKittyTransmission parses a (possibly multi-chunk) Kitty graphics
// command beginning at start. It returns the index just past the final APC, the
// store-only transmission bytes (nil for non-transmissions), the image id, an
// isDelete flag for a=d commands, and ok=false if the command is incomplete and
// needs more bytes. a=T is downgraded to a=t so replay never draws or moves the
// cursor.
func assembleKittyTransmission(
	data []byte,
	start int,
) (
	end int,
	buf []byte,
	id string,
	imageNumber string,
	isDelete bool,
	isAnimation bool,
	ok bool,
) {
	apcEnd := kittyApcEnd(data, start)
	if apcEnd < 0 {
		return 0, nil, "", "", false, false, false
	}
	args := parseKittyControl(kittyControl(data, start, apcEnd))
	action := args["a"]
	if action == "" {
		action = "t"
	}
	switch action {
	case "d":
		selector := args["d"]
		freeImageData := selector == "A" ||
			selector == "C" ||
			selector == "I" ||
			selector == "N" ||
			selector == "P" ||
			selector == "X" ||
			selector == "Y"
		return apcEnd, nil, args["i"], args["I"],
			freeImageData, false, true
	case "t", "T":
		// An image transmission; assemble continuation chunks below.
		buf = append(buf, rewriteKittyReplayCommand(data[start:apcEnd], true)...)
	case "f":
		// Animation frame payloads use the same continuation rules as roots.
		buf = append(buf, rewriteKittyReplayCommand(data[start:apcEnd], false)...)
		isAnimation = true
	case "a", "c":
		// Control/composition commands have no chunked payload.
		return apcEnd, rewriteKittyReplayCommand(data[start:apcEnd], false),
			args["i"], args["I"], false, true, true
	default:
		// Queries (a=q), placements (a=p) etc. are complete but not retained.
		return apcEnd, nil, "", "", false, false, true
	}

	more := args["m"] == "1"
	next := apcEnd
	for more {
		if next+2 >= len(data) || data[next] != '\x1b' ||
			data[next+1] != '_' || data[next+2] != 'G' {
			return 0, nil, "", "", false, false, false
		}
		chunkEnd := kittyApcEnd(data, next)
		if chunkEnd < 0 {
			return 0, nil, "", "", false, false, false
		}
		chunkArgs := parseKittyControl(kittyControl(data, next, chunkEnd))
		buf = append(buf, data[next:chunkEnd]...)
		more = chunkArgs["m"] == "1"
		next = chunkEnd
	}
	return next, buf, args["i"], args["I"], false, isAnimation, true
}

// observeKittyGraphicsLocked retains the Kitty image transmissions seen in chunk
// so they can be replayed on reattach regardless of how much later output has
// evicted them from the rolling visible history. Partial transmissions split
// across chunks are carried forward in kittyGraphicsPending.
func (w *muxWindow) observeKittyGraphicsLocked(chunk []byte) bool {
	if len(chunk) == 0 && len(w.kittyGraphicsPending) == 0 {
		return false
	}
	data := chunk
	if len(w.kittyGraphicsPending) > 0 {
		if len(chunk) > maxKittyGraphicsPendingBytes-len(w.kittyGraphicsPending) {
			// The incomplete root cannot ever fit into the replay budget. Drop
			// it, then scan the new chunk independently so a later well-formed
			// root can resynchronize immediately.
			w.clearKittyGraphicsPendingLocked()
			return w.observeKittyGraphicsLocked(chunk)
		}
		w.kittyGraphicsPending = append(w.kittyGraphicsPending, chunk...)
		nextScan, nextTerm, complete, valid := advanceKittyGraphicsPending(
			w.kittyGraphicsPending,
			w.kittyGraphicsPendingScan,
			w.kittyGraphicsPendingTerm,
		)
		w.kittyGraphicsPendingScan = nextScan
		w.kittyGraphicsPendingTerm = nextTerm
		if !valid {
			recovery := resyncKittyGraphicsData(
				w.kittyGraphicsPending,
				w.kittyGraphicsPendingScan,
			)
			w.clearKittyGraphicsPendingLocked()
			if len(recovery) == 0 {
				return false
			}
			return w.observeKittyGraphicsLocked(recovery)
		}
		if !complete {
			return false
		}
		data = w.kittyGraphicsPending
		w.clearKittyGraphicsPendingLocked()
	}

	events, consumed := scanKittyTransmissions(data)
	changed := w.applyKittyGraphicsEventsLocked(events)

	remainder := data[consumed:]
	if len(remainder) > maxKittyGraphicsPendingBytes {
		// An unterminated or oversized graphics sequence: drop it rather than
		// buffer unbounded bytes; parsing resyncs at the next introducer.
		w.clearKittyGraphicsPendingLocked()
		return changed
	}
	if len(remainder) == 0 {
		w.clearKittyGraphicsPendingLocked()
		return changed
	}
	w.kittyGraphicsPending = append(w.kittyGraphicsPending[:0], remainder...)
	nextScan, nextTerm, complete, valid := advanceKittyGraphicsPending(
		w.kittyGraphicsPending,
		0,
		0,
	)
	w.kittyGraphicsPendingScan = nextScan
	w.kittyGraphicsPendingTerm = nextTerm
	if !valid {
		recovery := resyncKittyGraphicsData(
			w.kittyGraphicsPending,
			w.kittyGraphicsPendingScan,
		)
		w.clearKittyGraphicsPendingLocked()
		if len(recovery) > 0 {
			changed = w.observeKittyGraphicsLocked(recovery) || changed
		}
	} else if complete {
		recovery := append([]byte(nil), w.kittyGraphicsPending...)
		w.clearKittyGraphicsPendingLocked()
		changed = w.observeKittyGraphicsLocked(recovery) || changed
	}
	return changed
}

// advanceKittyGraphicsPending scans only APC boundaries that arrived since the
// previous call. It avoids reparsing and copying the whole image for every
// 32-KiB PTY read while a multi-megabyte m=1 transmission is still in flight.
// The full transmission is assembled once, after its final m=0 chunk arrives.
func advanceKittyGraphicsPending(
	data []byte,
	scan int,
	termScan int,
) (nextScan int, nextTermScan int, complete bool, valid bool) {
	const introducer = "\x1b_G"
	for {
		if scan >= len(data) {
			return scan, termScan, false, true
		}
		remaining := len(data) - scan
		if remaining < len(introducer) {
			if bytes.Equal(data[scan:], []byte(introducer[:remaining])) {
				return scan, termScan, false, true
			}
			return scan, termScan, false, false
		}
		if !bytes.Equal(data[scan:scan+len(introducer)], []byte(introducer)) {
			return scan, termScan, false, false
		}
		if termScan < scan+len(introducer) {
			termScan = scan + len(introducer)
		}
		end := -1
		for i := termScan; i+1 < len(data); i++ {
			if data[i] == '\x1b' && data[i+1] == '\\' {
				end = i + 2
				break
			}
		}
		if end < 0 {
			// Keep a one-byte overlap so an ESC at the end of this read can
			// pair with the ST backslash at the start of the next read.
			nextTerm := len(data) - 1
			if nextTerm < scan+len(introducer) {
				nextTerm = scan + len(introducer)
			}
			return scan, nextTerm, false, true
		}
		args := parseKittyControl(kittyControl(data, scan, end))
		if args["m"] != "1" {
			return end, end, true, true
		}
		scan = end
		termScan = scan + len(introducer)
	}
}

func (w *muxWindow) clearKittyGraphicsPendingLocked() {
	w.kittyGraphicsPending = nil
	w.kittyGraphicsPendingScan = 0
	w.kittyGraphicsPendingTerm = 0
}

func resyncKittyGraphicsData(data []byte, scan int) []byte {
	const introducer = "\x1b_G"
	searchFrom := scan + 1
	if searchFrom < 0 {
		searchFrom = 0
	}
	if searchFrom < len(data) {
		if next := bytes.Index(data[searchFrom:], []byte(introducer)); next >= 0 {
			return data[searchFrom+next:]
		}
	}
	for keep := len(introducer) - 1; keep > 0; keep-- {
		if len(data) >= keep &&
			bytes.Equal(data[len(data)-keep:], []byte(introducer[:keep])) {
			return data[len(data)-keep:]
		}
	}
	return nil
}

func (w *muxWindow) applyKittyGraphicsEventsLocked(
	events []kittyGraphicsEvent,
) bool {
	changed := false
	for _, event := range events {
		if event.delete {
			if event.clearCache {
				if w.clearKittyImagesLocked() {
					changed = true
				}
				continue
			}
			id := event.id
			if id == "" && event.imageNumber != "" {
				id = w.kittyImageNumberToID[event.imageNumber]
			}
			if w.removeKittyImageLocked(id) {
				changed = true
			}
			continue
		}
		id := event.id
		if event.imageNumber != "" {
			if id == "" {
				if event.animation {
					id = w.kittyImageNumberToID[event.imageNumber]
				} else {
					id = fmt.Sprintf(
						"I:%s:%d",
						event.imageNumber,
						kittyImageStoreSeq+1,
					)
					if _, exists := w.kittyImageNumberToID[event.imageNumber]; !exists &&
						len(w.kittyImageNumberToID) >= maxRetainedKittyImageNumbers {
						w.evictOldestKittyImageNumberMappingLocked()
					}
					w.recordKittyImageNumberMappingLocked(event.imageNumber, id)
				}
			} else {
				if (event.mappingOnly || event.animation) &&
					w.kittyImages[id] == nil {
					continue
				}
				if w.kittyImageNumberToID == nil {
					w.kittyImageNumberToID = map[string]string{}
				}
				if _, exists := w.kittyImageNumberToID[event.imageNumber]; !exists &&
					len(w.kittyImageNumberToID) >= maxRetainedKittyImageNumbers {
					w.evictOldestKittyImageNumberMappingLocked()
				}
				w.recordKittyImageNumberMappingLocked(event.imageNumber, id)
			}
		}
		if event.mappingOnly {
			kittyImageStoreSeq++
			w.kittyImageSeq[id] = kittyImageStoreSeq
			w.enforceKittyImageCapsLocked()
			changed = true
			continue
		}
		if id == "" {
			continue // cannot dedupe or replay without an id
		}
		if event.animation {
			animation := rewriteKittyImageReferenceToID(event.buf, id)
			changed = w.appendKittyImageAnimationLocked(id, animation) || changed
		} else {
			w.storeKittyImageLocked(id, event.buf)
			changed = true
		}
	}
	return changed
}

func (w *muxWindow) storeKittyImageLocked(id string, buf []byte) {
	if w.kittyImages == nil {
		w.kittyImages = map[string][]byte{}
	}
	if w.kittyImageSeq == nil {
		w.kittyImageSeq = map[string]uint64{}
	}
	if w.kittyImageToken == nil {
		w.kittyImageToken = map[string]uint32{}
	}
	if _, exists := w.kittyImages[id]; exists {
		w.kittyImageOrder = removeStringOnce(w.kittyImageOrder, id)
	}
	w.kittyImageOrder = append(w.kittyImageOrder, id)
	w.kittyImages[id] = append([]byte(nil), buf...)
	delete(w.kittyImageAnimations, id)
	w.kittyImageToken[id] = kittyTransmissionPayloadSignature(buf)
	kittyImageStoreSeq++
	w.kittyImageSeq[id] = kittyImageStoreSeq
	w.enforceKittyImageCapsLocked()
}

func (w *muxWindow) appendKittyImageAnimationLocked(id string, buf []byte) bool {
	if len(buf) == 0 {
		return false
	}
	if _, exists := w.kittyImages[id]; !exists {
		return false
	}
	if w.kittyImageAnimations == nil {
		w.kittyImageAnimations = map[string][]byte{}
	}
	if len(w.kittyImages[id])+len(w.kittyImageAnimations[id])+len(buf) >
		kittyImagePerIDBudgetBytes {
		return w.removeKittyImageLocked(id)
	}
	w.kittyImageAnimations[id] = append(w.kittyImageAnimations[id], buf...)
	kittyImageStoreSeq++
	w.kittyImageSeq[id] = kittyImageStoreSeq
	w.enforceKittyImageCapsLocked()
	return true
}

func (w *muxWindow) removeKittyImageLocked(id string) bool {
	if _, ok := w.kittyImages[id]; !ok {
		return false
	}
	delete(w.kittyImages, id)
	delete(w.kittyImageAnimations, id)
	delete(w.kittyImageSeq, id)
	delete(w.kittyImageToken, id)
	for number, mappedID := range w.kittyImageNumberToID {
		if mappedID == id {
			delete(w.kittyImageNumberToID, number)
			delete(w.kittyImageNumberSeq, number)
		}
	}
	w.kittyImageOrder = removeStringOnce(w.kittyImageOrder, id)
	return true
}

func (w *muxWindow) evictOldestKittyImageNumberMappingLocked() {
	var oldestNumber string
	var oldestSeq uint64
	for number := range w.kittyImageNumberToID {
		seq := w.kittyImageNumberSeq[number]
		if oldestNumber == "" || seq < oldestSeq ||
			(seq == oldestSeq && number < oldestNumber) {
			oldestNumber = number
			oldestSeq = seq
		}
	}
	if oldestNumber != "" {
		delete(w.kittyImageNumberToID, oldestNumber)
		delete(w.kittyImageNumberSeq, oldestNumber)
	}
}

func (w *muxWindow) recordKittyImageNumberMappingLocked(number, id string) {
	if w.kittyImageNumberToID == nil {
		w.kittyImageNumberToID = map[string]string{}
	}
	if w.kittyImageNumberSeq == nil {
		w.kittyImageNumberSeq = map[string]uint64{}
	}
	kittyImageStoreSeq++
	w.kittyImageNumberToID[number] = id
	w.kittyImageNumberSeq[number] = kittyImageStoreSeq
}

func (w *muxWindow) clearKittyImagesLocked() bool {
	changed := len(w.kittyImages) > 0
	w.kittyImages = nil
	w.kittyImageAnimations = nil
	w.kittyImageNumberToID = nil
	w.kittyImageNumberSeq = nil
	w.kittyImageOrder = nil
	w.kittyImageSeq = nil
	w.kittyImageToken = nil
	return changed
}

func (w *muxWindow) enforceKittyImageCapsLocked() {
	total := 0
	for id, b := range w.kittyImages {
		total += len(b) + len(w.kittyImageAnimations[id])
	}
	for len(w.kittyImageOrder) > 0 &&
		(len(w.kittyImageOrder) > maxRetainedKittyImages ||
			(total > maxRetainedKittyImageBytes && len(w.kittyImageOrder) > 1)) {
		oldest := w.kittyImageOrder[0]
		for _, id := range w.kittyImageOrder[1:] {
			if w.kittyImageSeq[id] < w.kittyImageSeq[oldest] {
				oldest = id
			}
		}
		total -= len(w.kittyImages[oldest]) + len(w.kittyImageAnimations[oldest])
		w.removeKittyImageLocked(oldest)
	}
}

// kittyImageStoreSeq is a global monotonic counter assigning each image mutation
// an order, used to evict the least recently changed image under the local and
// machine-wide budgets. Mutated only while the server lock is held.
var kittyImageStoreSeq uint64

// kittyImagePerIDBudgetBytes prevents one long-running animation from bypassing
// the per-window/global "keep one image" policy and growing without bound.
// Package-level so tests can exercise overflow without allocating 64 MiB.
var kittyImagePerIDBudgetBytes = maxRetainedKittyImageBytes

// kittyImageGlobalBudgetBytes bounds the total Kitty image bytes retained across
// all windows so a busy multi-window session cannot exhaust memory on a small
// host (e.g. a Raspberry Pi). Computed once from detected system memory; a var
// so tests can override it.
var kittyImageGlobalBudgetBytes = computeKittyImageGlobalBudgetBytes()

// enforceGlobalKittyImageBudgetLocked evicts the globally-oldest retained images
// across every window until the total retained bytes fit the machine-wide
// budget. The server lock must be held.
func (s *muxServer) enforceGlobalKittyImageBudgetLocked() {
	budget := kittyImageGlobalBudgetBytes
	if budget <= 0 {
		return
	}
	total := 0
	count := 0
	for _, w := range s.windows {
		for id, b := range w.kittyImages {
			total += len(b) + len(w.kittyImageAnimations[id])
			count++
		}
	}
	// Keep at least one image so a single oversized image is never fully
	// dropped (it would just render blank otherwise); the per-window caps still
	// bound any single window.
	for total > budget && count > 1 {
		var victimWin *muxWindow
		var victimID string
		var victimSeq uint64
		found := false
		for _, w := range s.windows {
			for id, seq := range w.kittyImageSeq {
				if _, ok := w.kittyImages[id]; !ok {
					continue
				}
				if !found || seq < victimSeq {
					found = true
					victimSeq = seq
					victimWin = w
					victimID = id
				}
			}
		}
		if !found || victimWin == nil {
			return
		}
		total -= len(victimWin.kittyImages[victimID]) +
			len(victimWin.kittyImageAnimations[victimID])
		count--
		victimWin.removeKittyImageLocked(victimID)
	}
}

// computeKittyImageGlobalBudgetBytes derives the machine-wide image cache budget
// from detected system memory, clamped to a safe range. Unknown memory falls
// back to a conservative default.
func computeKittyImageGlobalBudgetBytes() int {
	const (
		floorBytes    = 32 * 1024 * 1024  // always allow some image caching
		ceilingBytes  = 512 * 1024 * 1024 // cap on large machines
		defaultBytes  = 256 * 1024 * 1024 // used when memory is undetectable
		memoryDivisor = 8                 // ~12.5% of RAM for the image cache
	)
	mem := detectSystemMemoryBytes()
	if mem == 0 {
		return defaultBytes
	}
	budget := int(mem / memoryDivisor)
	if budget < floorBytes {
		budget = floorBytes
	}
	if budget > ceilingBytes {
		budget = ceilingBytes
	}
	return budget
}

// kittyImageReplayLocked returns the most-recent retained image transmissions,
// bounded by count and bytes, so a reattaching client repopulates the images
// most likely still on screen without decoding many megabytes on its UI thread.
// Older retained transmissions are omitted; the foreground app re-emits them on
// its next redraw if they are still visible.
//
// Images whose id maps to a matching signature in clientHas are omitted: the
// client already holds identical bytes and would re-parse (then discard) them,
// so re-sending only adds switch latency. The id still counts against the caps
// so the "most recent N" window is unchanged whether or not the client has them.
func (w *muxWindow) kittyImageReplayLocked(clientHas map[string]uint32) []byte {
	if len(w.kittyImageOrder) == 0 {
		return nil
	}
	// Select by mutation recency so an actively changing older root is retained.
	// Emission below still follows root order to preserve I= mapping semantics.
	candidates := append([]string(nil), w.kittyImageOrder...)
	sort.SliceStable(candidates, func(i, j int) bool {
		return w.kittyImageSeq[candidates[i]] > w.kittyImageSeq[candidates[j]]
	})
	selected := make([]string, 0, maxReplayedKittyImages)
	total := 0
	for _, id := range candidates {
		imageBytes := len(w.kittyImages[id]) +
			len(w.kittyImageNumberReplayLocked(id)) +
			len(w.kittyImageAnimations[id])
		if len(selected) >= maxReplayedKittyImages {
			break
		}
		if imageBytes > maxReplayedKittyImageBytes ||
			total+imageBytes > maxReplayedKittyImageBytes {
			continue
		}
		selected = append(selected, id)
		total += imageBytes
	}
	selectedSet := make(map[string]struct{}, len(selected))
	for _, id := range selected {
		selectedSet[id] = struct{}{}
	}
	// Emit selected roots in original transmission order so repeated I= mappings
	// end in the same state as the live stream.
	var out []byte
	for _, id := range w.kittyImageOrder {
		if _, ok := selectedSet[id]; !ok {
			continue
		}
		clientHasRoot := false
		if len(clientHas) > 0 {
			if token, ok := clientHas[id]; ok &&
				token == w.kittyImageToken[id] {
				clientHasRoot = true
			}
		}
		if !clientHasRoot {
			out = append(out, w.kittyImageRootReplayLocked(id)...)
		}
		out = append(out, w.kittyImageNumberReplayLocked(id)...)
		out = append(out, w.kittyImageAnimations[id]...)
	}
	return out
}

func (w *muxWindow) kittyImageNumberReplayLocked(id string) []byte {
	numericID, err := strconv.ParseUint(id, 10, 32)
	if err != nil || numericID == 0 {
		return nil
	}
	var numbers []string
	for number, mappedID := range w.kittyImageNumberToID {
		if mappedID == id {
			numbers = append(numbers, number)
		}
	}
	sort.Strings(numbers)
	var out []byte
	for _, number := range numbers {
		out = append(out, "\x1b_Ga=a,i="...)
		out = append(out, id...)
		out = append(out, ",I="...)
		out = append(out, number...)
		out = append(out, ",q=2\x1b\\"...)
	}
	return out
}

// kittyImageTransmissionsForLocked returns the concatenated store-only
// transmissions of the requested image ids, in request order, skipping ids that
// are unknown or duplicated. Missing-image repair keeps the replay count cap
// but allows a larger byte budget because it runs after attach and targets only
// placeholder images the visible terminal explicitly reports missing.
func (w *muxWindow) kittyImageTransmissionsForLocked(
	ids []string,
) ([]byte, []string) {
	if len(ids) == 0 || len(w.kittyImages) == 0 {
		return nil, nil
	}
	var out []byte
	var served []string
	var seen map[string]struct{}
	for _, id := range ids {
		if len(seen) >= maxReplayedKittyImages {
			break
		}
		if id == "" {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		buf, ok := w.kittyImages[id]
		if !ok {
			continue
		}
		buf = w.kittyImageRootReplayLocked(id)
		mappings := w.kittyImageNumberReplayLocked(id)
		animation := w.kittyImageAnimations[id]
		imageBytes := len(buf) + len(mappings) + len(animation)
		if imageBytes > maxKittyImageRepairBytes ||
			len(out)+imageBytes > maxKittyImageRepairBytes {
			continue
		}
		if seen == nil {
			seen = make(map[string]struct{}, len(ids))
		}
		seen[id] = struct{}{}
		out = append(out, buf...)
		out = append(out, mappings...)
		out = append(out, animation...)
		served = append(served, id)
	}
	return out, served
}

func (w *muxWindow) kittyImageRootReplayLocked(id string) []byte {
	buf := w.kittyImages[id]
	if len(buf) == 0 {
		return buf
	}
	apcEnd := kittyApcEnd(buf, 0)
	if apcEnd < 0 {
		return buf
	}
	number := parseKittyControl(kittyControl(buf, 0, apcEnd))["I"]
	if number == "" || w.kittyImageNumberToID[number] == id {
		return buf
	}
	return rewriteKittyImageReferenceToID(buf, id)
}

func removeStringOnce(items []string, target string) []string {
	for i, item := range items {
		if item == target {
			return append(items[:i], items[i+1:]...)
		}
	}
	return items
}

// base64DecodeValue maps an ASCII byte to its 6-bit base64 value, or -1 for any
// non-base64 byte (whitespace, padding, control). Package-level so the lenient
// decoder allocates nothing per call.
var base64DecodeValue = func() [256]int8 {
	var table [256]int8
	for i := range table {
		table[i] = -1
	}
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i := 0; i < len(alphabet); i++ {
		table[alphabet[i]] = int8(i)
	}
	return table
}()

// decodeLenientBase64 decodes base64 the same way the client parser does:
// non-base64 bytes (whitespace, padding) are skipped and 6-bit groups are
// emitted as bytes as they accumulate, tolerating a missing final group. Both
// sides must decode identically for the payload signatures to match.
func decodeLenientBase64(payload []byte) []byte {
	out := make([]byte, 0, len(payload)*3/4+1)
	var accumulator uint32
	var bits int
	for _, c := range payload {
		v := base64DecodeValue[c]
		if v < 0 {
			continue
		}
		accumulator = (accumulator << 6) | uint32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte((accumulator>>uint(bits))&0xff))
		}
	}
	return out
}

// kittyTransmissionPayloadSignature returns the FNV-1a-32 signature of the
// base64-decoded payload of a stored Kitty transmission, matching the client's
// terminalGraphicsSourceSignature over the same bytes. Returns 0 when there is
// no payload, which never matches a client-reported signature.
//
// A transmission larger than a single APC is split into m=1 continuation chunks
// (Kitty caps each APC payload at 4096 base64 bytes), and a stored image buffer
// concatenates every chunk's full APC. The client appends each chunk's decoded
// payload into one buffer before hashing, so the signature MUST cover the whole
// concatenated payload — hashing only the first chunk would never match a
// multi-chunk image (i.e. every non-trivial screenshot), defeating the switch
// replay skip and forcing the whole image set to be re-sent on every switch.
func kittyTransmissionPayloadSignature(buf []byte) uint32 {
	var payload []byte
	for i := 0; i+2 < len(buf); {
		if buf[i] != '\x1b' || buf[i+1] != '_' || buf[i+2] != 'G' {
			i++
			continue
		}
		apcEnd := kittyApcEnd(buf, i)
		if apcEnd < 0 {
			break
		}
		chunk := buf[i:apcEnd]
		if semi := bytes.IndexByte(chunk, ';'); semi >= 0 {
			body := chunk[semi+1:]
			if end := bytes.Index(body, []byte{'\x1b', '\\'}); end >= 0 {
				body = body[:end]
			}
			if bel := bytes.IndexByte(body, '\a'); bel >= 0 {
				body = body[:bel]
			}
			payload = append(payload, decodeLenientBase64(body)...)
		}
		i = apcEnd
	}
	if len(payload) == 0 {
		return 0
	}
	return fnv32ImageSignature(payload)
}

// fnv32ImageSignature mirrors the client's terminalGraphicsSourceSignature: an
// FNV-1a-32 over the exact length (4 little-endian bytes) plus an evenly-spaced
// sample of at most ~4096 bytes. Returns a non-zero value for non-empty input.
func fnv32ImageSignature(b []byte) uint32 {
	if len(b) == 0 {
		return 0
	}
	const (
		fnvOffset = uint32(0x811c9dc5)
		fnvPrime  = uint32(0x01000193)
	)
	hash := fnvOffset
	length := len(b)
	for i := 0; i < 4; i++ {
		hash = (hash ^ uint32(length&0xFF)) * fnvPrime
		length >>= 8
	}
	step := 1
	if len(b) > 4096 {
		step = len(b) / 4096
	}
	for i := 0; i < len(b); i += step {
		hash = (hash ^ uint32(b[i])) * fnvPrime
	}
	if hash == 0 {
		return 1
	}
	return hash
}

// kittyApcEnd returns the index just past the ST (ESC \) that terminates the
// Kitty APC sequence beginning at start, or -1 if it is incomplete. The base64
// payload never contains ESC, so the first ESC \ after the introducer is the
// terminator.
func kittyApcEnd(data []byte, start int) int {
	for i := start + 3; i+1 < len(data); i++ {
		if data[i] == '\x1b' && data[i+1] == '\\' {
			return i + 2
		}
	}
	return -1
}

// kittyControl returns the control portion (the bytes between "_G" and the ';'
// payload separator, or the ST if there is no payload) of the APC sequence that
// spans [start, end).
func kittyControl(data []byte, start, end int) string {
	from := start + 3
	to := end - 2 // before the terminating ESC \
	if to > len(data) {
		to = len(data)
	}
	if semi := bytes.IndexByte(data[from:to], ';'); semi >= 0 {
		to = from + semi
	}
	if from > to {
		return ""
	}
	return string(data[from:to])
}

// parseKittyControl parses a comma-separated key=value Kitty control string.
func parseKittyControl(control string) map[string]string {
	args := map[string]string{}
	if control == "" {
		return args
	}
	for _, pair := range strings.Split(control, ",") {
		if eq := strings.IndexByte(pair, '='); eq >= 0 {
			args[pair[:eq]] = pair[eq+1:]
		}
	}
	return args
}

// rewriteKittyReplayCommand suppresses protocol responses during replay and,
// for roots, downgrades a=T to store-only a=t so replay never draws or moves
// the cursor before the foreground app redraws its placements.
func rewriteKittyReplayCommand(seq []byte, storeOnly bool) []byte {
	if len(seq) < 5 {
		return append([]byte(nil), seq...)
	}
	controlEnd := len(seq) - 2 // before ST
	if semi := bytes.IndexByte(seq, ';'); semi >= 0 && semi < controlEnd {
		controlEnd = semi
	}
	parts := strings.Split(string(seq[3:controlEnd]), ",")
	foundQuiet := false
	for index, part := range parts {
		key, _, _ := strings.Cut(part, "=")
		switch key {
		case "a":
			if storeOnly && part == "a=T" {
				parts[index] = "a=t"
			}
		case "q":
			parts[index] = "q=2"
			foundQuiet = true
		}
	}
	if !foundQuiet {
		parts = append(parts, "q=2")
	}
	out := make([]byte, 0, len(seq)+4)
	out = append(out, seq[:3]...)
	out = append(out, strings.Join(parts, ",")...)
	out = append(out, seq[controlEnd:]...)
	return out
}

// rewriteKittyImageReferenceToID makes a retained command independent of an
// image-number mapping that may change later. Synthetic I=-only roots have no
// numeric id yet and are intentionally left unchanged.
func rewriteKittyImageReferenceToID(seq []byte, imageID string) []byte {
	numericID, err := strconv.ParseUint(imageID, 10, 32)
	if err != nil || numericID == 0 || len(seq) < 5 {
		return seq
	}
	apcEnd := kittyApcEnd(seq, 0)
	if apcEnd < 0 {
		return seq
	}
	controlEnd := apcEnd - 2 // before ST
	if semi := bytes.IndexByte(seq[:apcEnd], ';'); semi >= 0 {
		controlEnd = semi
	}
	parts := strings.Split(string(seq[3:controlEnd]), ",")
	rewritten := make([]string, 0, len(parts)+1)
	foundID := false
	for _, part := range parts {
		key, _, _ := strings.Cut(part, "=")
		switch key {
		case "I":
			continue
		case "i":
			rewritten = append(rewritten, "i="+imageID)
			foundID = true
		default:
			rewritten = append(rewritten, part)
		}
	}
	if !foundID {
		rewritten = append(rewritten, "i="+imageID)
	}
	out := make([]byte, 0, len(seq)+len(imageID)+3)
	out = append(out, seq[:3]...)
	out = append(out, strings.Join(rewritten, ",")...)
	out = append(out, seq[controlEnd:]...)
	return out
}

func csiSequenceEnd(data []byte, start int) int {
	for i := start; i < len(data); i++ {
		if data[i] >= 0x40 && data[i] <= 0x7e {
			return i
		}
	}
	return -1
}

func terminalQuerySequenceAt(
	data []byte,
	index int,
) (int, bool, bool, bool) {
	return terminalQuerySequenceAtWithUtf8Prefix(data, index, 0)
}

func terminalQuerySequenceAtWithUtf8Prefix(
	data []byte,
	index int,
	leadingUtf8Prefix int,
) (int, bool, bool, bool) {
	if index < 0 || index >= len(data) {
		return -1, false, false, false
	}
	if index < leadingUtf8Prefix && data[index]&0xc0 == 0x80 {
		return -1, false, false, false
	}
	introducer := data[index]
	payloadStart := index + 1
	escaped := false
	if introducer == '\x1b' {
		if index+1 >= len(data) {
			return -1, false, true, true
		}
		escaped = true
		introducer = data[index+1]
		payloadStart = index + 2
	} else if isUtf8ContinuationAt(data, index) {
		return -1, false, false, false
	}
	switch introducer {
	case '[':
		if !escaped {
			return -1, false, false, false
		}
		end := csiSequenceEnd(data, payloadStart)
		if end < 0 {
			return -1, false, true, true
		}
		sequenceEnd := end + 1
		return sequenceEnd,
			isReplayUnsafeCsiQuery(data[index:sequenceEnd]),
			false,
			true
	case 0x9b:
		end := csiSequenceEnd(data, payloadStart)
		if end < 0 {
			return -1, false, true, true
		}
		sequenceEnd := end + 1
		return sequenceEnd,
			isReplayUnsafeCsiQuery(data[index:sequenceEnd]),
			false,
			true
	case ']':
		if !escaped {
			return -1, false, false, false
		}
		end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeOscQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 0x9d:
		end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeOscQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 'P':
		if !escaped {
			return -1, false, false, false
		}
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeDcsQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 0x90:
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeDcsQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case '_':
		if !escaped {
			return -1, false, false, false
		}
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeKittyQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 0x9f:
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeKittyQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	default:
		return -1, false, false, false
	}
}

func leadingUtf8ContinuationPrefix(data []byte, remaining int) int {
	count := 0
	for count < len(data) &&
		count < remaining &&
		data[count]&0xc0 == 0x80 {
		count++
	}
	return count
}

func nextQueryUtf8Remaining(
	data []byte,
	previousRemaining int,
	leadingPrefix int,
) int {
	if leadingPrefix == len(data) && leadingPrefix < previousRemaining {
		return previousRemaining - leadingPrefix
	}
	return trailingUtf8ContinuationCount(data)
}

func isReplayUnsafeOscNotificationSequence(sequence []byte) bool {
	payloadStart := 0
	switch {
	case len(sequence) >= 2 && sequence[0] == '\x1b' && sequence[1] == ']':
		payloadStart = 2
	case len(sequence) >= 1 && sequence[0] == 0x9d:
		payloadStart = 1
	default:
		return false
	}
	end, _, ok := findOscTerminator(sequence[payloadStart:])
	return ok && isReplayUnsafeOscNotification(
		sequence[payloadStart:payloadStart+end],
	)
}

func isReplayUnsafeCsiQuery(sequence []byte) bool {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return false
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[bodyStart : len(sequence)-1])
	switch final {
	case 'c':
		return params == "" ||
			params == "0" ||
			strings.HasPrefix(params, "?") ||
			strings.HasPrefix(params, ">") ||
			strings.HasPrefix(params, "=")
	case 'n':
		return params == "5" ||
			params == "6" ||
			params == "?6" ||
			params == "?15" ||
			params == "?25" ||
			params == "?26" ||
			params == "?53" ||
			params == "?996"
	case 'q':
		// XTVERSION (CSI > q): the child asks the terminal to identify itself,
		// which agents such as Copilot CLI use to unlock richer rendering. The
		// space-intermediate DECSCUSR cursor-style control (CSI Ps SP q) is not
		// a query. Replaying an already-answered XTVERSION would make the
		// terminal send a second, unsolicited identity report.
		return strings.HasPrefix(params, ">")
	case 'p':
		return strings.HasSuffix(params, "$")
	case 't':
		primary, _, _ := strings.Cut(params, ";")
		switch primary {
		case "14", "15", "16", "18", "19", "20", "21":
			return true
		default:
			return false
		}
	case 'u':
		return params == "?"
	default:
		return false
	}
}

const (
	capabilityHintRecordSeparator = 0x1e
	capabilityHintFieldSeparator  = 0x1f

	capabilityHintKeyPrimaryDeviceAttributes   = "da1"
	capabilityHintKeySecondaryDeviceAttributes = "da2"
	capabilityHintKeyTertiaryDeviceAttributes  = "da3"
	capabilityHintKeyTerminalVersion           = "xtversion"
	capabilityHintKeyDeviceStatus              = "dsr"
)

// capabilityHintResponseMap parses the attaching client's static terminal
// capability replies into a query-key -> reply map. The wire format is
// `key US reply` records joined by RS; both separators are C0 controls that
// never occur inside a terminal reply, so no escaping is needed.
func capabilityHintResponseMap(hint []byte) map[string][]byte {
	if len(hint) == 0 {
		return nil
	}
	responses := map[string][]byte{}
	for _, record := range bytes.Split(
		hint,
		[]byte{capabilityHintRecordSeparator},
	) {
		key, response, found := bytes.Cut(
			record,
			[]byte{capabilityHintFieldSeparator},
		)
		if !found {
			continue
		}
		name := strings.TrimSpace(string(key))
		if name == "" || len(response) == 0 {
			continue
		}
		responses[name] = append([]byte(nil), response...)
	}
	if len(responses) == 0 {
		return nil
	}
	return responses
}

// isTerminalColorSchemeQuery reports whether sequence is the DEC colour-scheme
// status query (`CSI ? 996 n`), which asks whether the terminal is currently
// using a dark or a light colour scheme.
func isTerminalColorSchemeQuery(sequence []byte) bool {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return false
	}
	return sequence[len(sequence)-1] == 'n' &&
		string(sequence[bodyStart:len(sequence)-1]) == "?996"
}

// capabilityQueryKey maps a terminal query sequence to the capability hint key
// whose cached reply answers it, or "" when the answer is not constant for a
// terminal (cursor position, window metrics, kitty keyboard flags, ...) and so
// must come from the client itself.
func capabilityQueryKey(sequence []byte) string {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return ""
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[bodyStart : len(sequence)-1])
	switch final {
	case 'c':
		switch params {
		case "", "0":
			return capabilityHintKeyPrimaryDeviceAttributes
		case ">", ">0":
			return capabilityHintKeySecondaryDeviceAttributes
		case "=", "=0":
			return capabilityHintKeyTertiaryDeviceAttributes
		}
	case 'q':
		if params == ">" || params == ">0" {
			return capabilityHintKeyTerminalVersion
		}
	case 'n':
		if params == "5" {
			return capabilityHintKeyDeviceStatus
		}
	}
	return ""
}

// Bracketed-paste start/end markers in ESC-based and single-byte C1 forms.
var (
	bracketedPasteStart7Bit = []byte("\x1b[200~")
	bracketedPasteStart8Bit = []byte("\x9b200~")
	bracketedPasteEnd7Bit   = []byte("\x1b[201~")
	bracketedPasteEnd8Bit   = []byte("\x9b201~")
)

type bracketedPasteStartMatch struct {
	index  int
	length int
}

func matchBracketedPasteMarker(
	data, sevenBit, eightBit []byte,
	leadingUtf8Prefix int,
) bracketedPasteStartMatch {
	match := bracketedPasteStartMatch{index: -1}
	if index := bytes.Index(data, sevenBit); index >= 0 {
		match = bracketedPasteStartMatch{
			index:  index,
			length: len(sevenBit),
		}
	}
	for offset := 0; offset < len(data); {
		index := bytes.Index(data[offset:], eightBit)
		if index < 0 {
			break
		}
		index += offset
		if (index >= leadingUtf8Prefix ||
			data[index]&0xc0 != 0x80) &&
			!isUtf8ContinuationAt(data, index) {
			if match.index < 0 || index < match.index {
				match = bracketedPasteStartMatch{
					index:  index,
					length: len(eightBit),
				}
			}
			break
		}
		offset = index + 1
	}
	return match
}

func bracketedPasteMarkerSuffixLength(
	data, sevenBit, eightBit []byte,
	leadingUtf8Prefix int,
) int {
	longest := 0
	for _, marker := range [][]byte{
		sevenBit,
		eightBit,
	} {
		maximum := min(len(data), len(marker)-1)
		for length := maximum; length > longest; length-- {
			start := len(data) - length
			if !bytes.Equal(data[start:], marker[:length]) {
				continue
			}
			if marker[0] == 0x9b &&
				((start < leadingUtf8Prefix &&
					data[start]&0xc0 == 0x80) ||
					isUtf8ContinuationAt(data, start)) {
				continue
			}
			longest = length
			break
		}
	}
	return longest
}

func bracketedPasteStart(data []byte, leadingUtf8Prefix int) bracketedPasteStartMatch {
	return matchBracketedPasteMarker(data, bracketedPasteStart7Bit, bracketedPasteStart8Bit, leadingUtf8Prefix)
}

func bracketedPasteEnd(data []byte, leadingUtf8Prefix int) bracketedPasteStartMatch {
	return matchBracketedPasteMarker(data, bracketedPasteEnd7Bit, bracketedPasteEnd8Bit, leadingUtf8Prefix)
}

func bracketedPasteStartSuffixLength(data []byte, leadingUtf8Prefix int) int {
	return bracketedPasteMarkerSuffixLength(data, bracketedPasteStart7Bit, bracketedPasteStart8Bit, leadingUtf8Prefix)
}

func bracketedPasteEndSuffix(data []byte, leadingUtf8Prefix int) []byte {
	longest := bracketedPasteMarkerSuffixLength(data, bracketedPasteEnd7Bit, bracketedPasteEnd8Bit, leadingUtf8Prefix)
	if longest == 0 {
		return nil
	}
	return append([]byte(nil), data[len(data)-longest:]...)
}

func (c *attachClient) beginBracketedPasteLocked(data []byte) int {
	if end := bracketedPasteEnd(data, 0); end.index >= 0 {
		c.inputBracketedPasteActive = false
		c.inputBracketedPasteEndCarry = nil
		return end.index + end.length
	}
	c.inputBracketedPasteActive = true
	c.inputBracketedPasteEndCarry = bracketedPasteEndSuffix(data, 0)
	return len(data)
}

func (c *attachClient) continueBracketedPasteLocked(
	data []byte,
	leadingUtf8Prefix int,
) int {
	combined := data
	carryLength := len(c.inputBracketedPasteEndCarry)
	if len(c.inputBracketedPasteEndCarry) > 0 {
		combined = make(
			[]byte,
			0,
			len(c.inputBracketedPasteEndCarry)+len(data),
		)
		combined = append(combined, c.inputBracketedPasteEndCarry...)
		combined = append(combined, data...)
		leadingUtf8Prefix = 0
	}
	if end := bracketedPasteEnd(
		combined,
		leadingUtf8Prefix,
	); end.index >= 0 {
		c.inputBracketedPasteActive = false
		c.inputBracketedPasteEndCarry = nil
		return end.index + end.length - carryLength
	}
	c.inputBracketedPasteEndCarry = bracketedPasteEndSuffix(
		combined,
		leadingUtf8Prefix,
	)
	return len(data)
}

func scanTerminalResponseInput(
	data []byte,
	leadingUtf8Prefix int,
) ([]int, int, byte, int) {
	if len(data) == 0 {
		return nil, -1, 0, 0
	}
	var responseEnds []int
	for index := 0; index < len(data); {
		if index < leadingUtf8Prefix &&
			data[index]&0xc0 == 0x80 {
			return responseEnds, -1, 0, index
		}
		sequenceEnd := -1
		isResponse := false
		introducer := data[index]
		payloadStart := index + 1
		escaped := false
		if introducer == '\x1b' {
			if index+1 >= len(data) {
				return responseEnds, index, 0, len(data)
			}
			escaped = true
			introducer = data[index+1]
			payloadStart = index + 2
		}
		switch introducer {
		case '[':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end := csiSequenceEnd(data, payloadStart)
			if end < 0 {
				return responseEnds, index, 0, len(data)
			}
			sequenceEnd = end + 1
			isResponse = isTerminalResponseCsi(data[index:sequenceEnd])
		case 0x9b:
			end := csiSequenceEnd(data, payloadStart)
			if end < 0 {
				return responseEnds, index, 0, len(data)
			}
			sequenceEnd = end + 1
			isResponse = isTerminalResponseCsi(data[index:sequenceEnd])
		case ']':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
			if !ok {
				return responseEnds, index, ']', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseOsc(
				data[payloadStart : payloadStart+end],
			)
		case 0x9d:
			end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
			if !ok {
				return responseEnds, index, ']', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseOsc(
				data[payloadStart : payloadStart+end],
			)
		case 'P':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, 'P', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseDcs(
				data[payloadStart : payloadStart+end],
			)
		case 0x90:
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, 'P', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseDcs(
				data[payloadStart : payloadStart+end],
			)
		case '_':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, '_', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseKitty(
				data[payloadStart : payloadStart+end],
			)
		case 0x9f:
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, '_', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseKitty(
				data[payloadStart : payloadStart+end],
			)
		default:
			return responseEnds, -1, 0, index
		}
		if !isResponse {
			return responseEnds, -1, 0, index
		}
		responseEnds = append(responseEnds, sequenceEnd)
		index = sequenceEnd
	}
	return responseEnds, -1, 0, len(data)
}

func stripFocusOutInput(data []byte) ([]byte, []byte) {
	var output []byte
	copyStart := 0
	for index := 0; index < len(data); {
		sequenceLength := 0
		switch {
		case bytes.HasPrefix(data[index:], []byte("\x1b[O")):
			sequenceLength = 3
		case bytes.HasPrefix(data[index:], []byte{0x9b, 'O'}):
			sequenceLength = 2
		case bytes.Equal(data[index:], []byte{'\x1b'}) ||
			bytes.Equal(data[index:], []byte("\x1b[")) ||
			bytes.Equal(data[index:], []byte{0x9b}):
			if output == nil {
				output = append([]byte(nil), data[:index]...)
			} else {
				output = append(output, data[copyStart:index]...)
			}
			return output, append([]byte(nil), data[index:]...)
		default:
			index++
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-sequenceLength)
		}
		output = append(output, data[copyStart:index]...)
		index += sequenceLength
		copyStart = index
	}
	if output == nil {
		return data, nil
	}
	output = append(output, data[copyStart:]...)
	return output, nil
}

func consumeTerminalResponseContinuation(
	data []byte,
	kind byte,
	leadingEscape bool,
	utf8Remaining int,
) ([]byte, bool, bool, int) {
	if leadingEscape && len(data) > 0 && data[0] == '\\' {
		return data[1:], true, false, 0
	}
	for index := 0; index < len(data); index++ {
		if utf8Remaining > 0 {
			if data[index]&0xc0 == 0x80 {
				utf8Remaining--
				continue
			}
			utf8Remaining = 0
		}
		if remaining := utf8ContinuationCount(data[index]); remaining > 0 {
			utf8Remaining = remaining
			continue
		}
		if data[index] == 0x9c ||
			(kind == ']' && data[index] == '\a') {
			return data[index+1:], true, false, 0
		}
		if data[index] == '\x1b' &&
			index+1 < len(data) &&
			data[index+1] == '\\' {
			return data[index+2:], true, false, 0
		}
	}
	return nil,
		false,
		len(data) > 0 && data[len(data)-1] == '\x1b',
		utf8Remaining
}

func utf8ContinuationCount(lead byte) int {
	switch {
	case lead >= 0xc2 && lead <= 0xdf:
		return 1
	case lead >= 0xe0 && lead <= 0xef:
		return 2
	case lead >= 0xf0 && lead <= 0xf4:
		return 3
	default:
		return 0
	}
}

func trailingUtf8ContinuationCount(data []byte) int {
	if len(data) == 0 {
		return 0
	}
	_, size := utf8.DecodeLastRune(data)
	if size > 1 {
		return 0
	}
	for index := len(data) - 1; index >= 0 && len(data)-index <= 4; index-- {
		remaining := utf8ContinuationCount(data[index])
		if remaining == 0 {
			continue
		}
		available := len(data) - index - 1
		if available < remaining {
			return remaining - available
		}
		return 0
	}
	return 0
}

func isTerminalResponseCsi(sequence []byte) bool {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return false
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[bodyStart : len(sequence)-1])
	switch final {
	case 'c':
		return strings.HasPrefix(params, "?") ||
			strings.HasPrefix(params, ">") ||
			strings.HasPrefix(params, "=")
	case 'n':
		return params == "0" || strings.HasPrefix(params, "?")
	case 'R':
		return terminalResponseNumericParams(
			strings.TrimPrefix(params, "?"),
		)
	case 't':
		first, _, ok := strings.Cut(params, ";")
		return ok && containsString([]string{"4", "5", "6", "8", "9"}, first)
	case 'y':
		return strings.HasSuffix(params, "$")
	case 'u':
		return strings.HasPrefix(params, "?")
	default:
		return false
	}
}

func terminalResponseNumericParams(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && character != ';' {
			return false
		}
	}
	return true
}

func isTerminalResponseOsc(payload []byte) bool {
	if len(payload) > 0 && (payload[0] == 'L' || payload[0] == 'l') {
		return true
	}
	code, value, ok := strings.Cut(string(payload), ";")
	if !ok || value == "?" {
		return false
	}
	switch code {
	case "4", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "52":
		return true
	default:
		return false
	}
}

func isTerminalResponseDcs(payload []byte) bool {
	return bytes.HasPrefix(payload, []byte(">|")) ||
		bytes.HasPrefix(payload, []byte("!|")) ||
		bytes.HasPrefix(payload, []byte("0+r")) ||
		bytes.HasPrefix(payload, []byte("1+r")) ||
		bytes.HasPrefix(payload, []byte("0$r")) ||
		bytes.HasPrefix(payload, []byte("1$r"))
}

func isTerminalResponseKitty(payload []byte) bool {
	if len(payload) < 2 || payload[0] != 'G' {
		return false
	}
	separator := bytes.IndexByte(payload, ';')
	if separator < 0 || separator+1 >= len(payload) {
		return false
	}
	response := payload[separator+1:]
	return bytes.HasPrefix(response, []byte("OK")) ||
		bytes.HasPrefix(response, []byte("ERROR")) ||
		bytes.HasPrefix(response, []byte("ENOTSUP"))
}

func isReplayUnsafeOscQuery(payload []byte) bool {
	code, value, ok := strings.Cut(string(payload), ";")
	if !ok || !strings.Contains(value, "?") {
		return false
	}
	switch code {
	case "4", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "52":
		return true
	default:
		return false
	}
}

func isReplayUnsafeDcsQuery(payload []byte) bool {
	return bytes.HasPrefix(payload, []byte("$q")) ||
		bytes.HasPrefix(payload, []byte("+q"))
}

func isReplayUnsafeKittyQuery(payload []byte) bool {
	if len(payload) < 2 || payload[0] != 'G' {
		return false
	}
	control := payload[1:]
	if separator := bytes.IndexByte(control, ';'); separator >= 0 {
		control = control[:separator]
	}
	for _, field := range bytes.Split(control, []byte{','}) {
		if bytes.Equal(field, []byte("a=q")) {
			return true
		}
	}
	return false
}

// isReplayUnsafeOscNotification reports whether payload is a desktop
// notification escape (OSC 9 / 777 / 99). These are transient events, so
// replaying them when a window is reattached would re-fire the notification.
func isReplayUnsafeOscNotification(payload []byte) bool {
	code, rest, ok := strings.Cut(string(payload), ";")
	if !ok {
		return false
	}
	switch code {
	case "99", "777":
		return true
	case "1337":
		return strings.HasPrefix(rest, "MonkeyMuxPi=")
	case "9":
		// iTerm2 notifications are `OSC 9 ; <text>`. ConEmu reuses OSC 9 with a
		// numeric sub-command (9;4 progress, 9;9 working dir, ...); leave those
		// alone since they aren't notifications.
		if first, _, hasSub := strings.Cut(rest, ";"); hasSub {
			if _, err := strconv.Atoi(strings.TrimSpace(first)); err == nil {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func (w *muxWindow) processID() int {
	if w == nil || w.proc == nil {
		return 0
	}
	return w.proc.Pid()
}

func (w *muxWindow) metadataProcessIDLocked() int {
	if w.foregroundPid > 0 {
		return w.foregroundPid
	}
	return w.processID()
}

func (w *muxWindow) currentCommandLocked() string {
	if strings.TrimSpace(w.foregroundCommand) != "" {
		return w.foregroundCommand
	}
	return w.command
}

func (w *muxWindow) agentToolConfirmedLocked() bool {
	if agentToolFromCommandName(w.currentCommandLocked()) != "" {
		return true
	}
	return w.agentToolConfirmed
}

func (w *muxWindow) agentToolLocked() string {
	if tool := agentToolFromCommandName(w.currentCommandLocked()); tool != "" {
		return tool
	}
	if tool := strings.TrimSpace(w.agentTool); tool != "" {
		return tool
	}
	// A restored retired agent is now a known shell, even if its retained
	// title/name resembles another tool. Live commands still win above.
	if w.agentToolConfirmed {
		return ""
	}
	if tool := agentToolFromTerminalTitle(w.paneTitle); tool != "" {
		return tool
	}
	return agentToolFromCommandName(w.name)
}

func (w *muxWindow) broadcastIdentityLocked() windowBroadcastIdentity {
	identity := windowBroadcastIdentity{
		name:      w.name,
		cwd:       w.cwd,
		command:   w.currentCommandLocked(),
		paneTitle: w.paneTitle,
		agentTool: w.agentToolLocked(),
		panePid:   w.metadataProcessIDLocked(),
		alert:     w.alert,
	}
	if progress := w.terminalProgress; progress != nil {
		identity.progressActive = true
		identity.progressState = progress.State
		if progress.Percentage != nil {
			identity.progressHasPercentage = true
			identity.progressPercentage = *progress.Percentage
		}
	}
	return identity
}

func (s *muxServer) refreshAllProcessMetadata() {
	s.mu.Lock()
	windows := append([]*muxWindow(nil), s.windows...)
	s.mu.Unlock()
	for _, window := range windows {
		s.refreshProcessMetadata(window.id)
	}
}

func (s *muxServer) refreshProcessMetadata(windowID string) {
	s.mu.Lock()
	if windowID == "" {
		windowID = s.activeID
	}
	w := s.windowByIDLocked(windowID)
	now := time.Now()
	if w == nil || w.closed || w.pty == nil ||
		(!w.lastProcessMetadataRefresh.IsZero() &&
			now.Sub(w.lastProcessMetadataRefresh) < processMetadataInterval) {
		s.mu.Unlock()
		return
	}
	w.lastProcessMetadataRefresh = now
	pgrp := w.foregroundProcessGroupLocked()
	pty, process := w.pty, w.proc
	identity := w.broadcastIdentityLocked()
	fallbackTool := (&muxWindow{
		agentTool: w.agentTool, agentToolConfirmed: w.agentToolConfirmed,
		paneTitle: w.paneTitle, name: w.name,
	}).agentToolLocked()
	sessionID := w.agentSessionID
	s.mu.Unlock()

	command := commandNameForProcessGroup(pgrp)
	tool := identity.agentTool
	if command != "" {
		tool = firstNonEmptyString(agentToolFromCommandName(command), fallbackTool)
	}
	if sessionID == "" && tool == "cursor-agent" && pgrp > 0 {
		if started := processStartedAtForMetadata(pgrp); !started.IsZero() {
			sessionID = cursorSessionIDForWorkspace(readCursorChatEntries(), identity.cwd, started)
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.windowByIDLocked(windowID) != w || w.closed || w.pty != pty || w.proc != process ||
		w.lastProcessMetadataRefresh != now || w.foregroundProcessGroupLocked() != pgrp ||
		w.broadcastIdentityLocked() != identity {
		return
	}
	if command != "" {
		w.foregroundCommand = command
	}
	if w.agentSessionID == "" && sessionID != "" {
		w.agentSessionID = sessionID
		w.agentSessionIdentityExact = true
	}
}

// themeHintRefreshKeysLocked returns the OSC theme-query keys the daemon
// should re-answer when refreshing the cached theme hint.
//
// Do not infer safety from a previous OSC color query alone: many TUIs
// query OSC 10/11 once at startup, react to the first response, and then
// never expect another one. Any follow-up push (every reconnect, every
// brightness change, every app-resume) surfaces as literal `]11;rgb:...`
// text in their input composer (observed with Nous Hermes, Codex, and
// Claude Code). Synthetic focus-out/focus-in transitions can cause the
// same kind of prompt/composer pollution.
//
// DEC private mode 2031 is the opt-in signal for color-scheme update
// reports. Only windows that currently have that mode enabled get
// refreshed replies for previously observed color queries. Focus-aware TUIs
// get a FocusIn nudge so they can re-query colors through the normal path.
// Known agent TUIs also get the default background response they already
// tolerate through the tmux refresh path.
//
// The contractually-correct live-query response path in
// handleWindowOutput still answers OSC 10/11/4/17/19 queries the
// foreground process actually emits. Other focus-aware programs can re-query
// after the FocusIn nudge instead of receiving unsolicited OSC bytes.
func (w *muxWindow) themeHintRefreshKeysLocked() []string {
	if !w.themeRefreshModeActiveLocked() {
		return nil
	}
	return w.activeThemeColorQueryKeysLocked()
}

// themeHintFocusTransitionLocked reports whether theme refresh should send a
// synthetic FocusOut/FocusIn pair.
//
// Any focus-reporting window gets this nudge — including coding agents we do
// not yet detect by name. DEC 2031 is not required: focus mode is the opt-in.
// Apps that never enabled focus reporting are left alone.
func (w *muxWindow) themeHintFocusTransitionLocked() bool {
	return w.focusModeActiveLocked()
}

func (w *muxWindow) themeHintRefreshDataLocked(themeHint []byte) []byte {
	var themeHintData []byte
	// On Windows ConPTY (win32-input-mode) an OSC color report written into the
	// window pty is re-encoded as win32-input-mode key events, which conhost
	// then delivers to the foreground app as a run of typed characters. Apps
	// that read console input records instead of a VT stream (e.g. Codex) render
	// that as literal `]11;rgb:...` text in their composer. Unsolicited refresh
	// pushes have no matching read on the app side, so skip the OSC reports
	// there; the live query-response path in handleWindowOutput still answers
	// OSC color queries the app actually makes, and focus-aware apps still get a
	// FocusIn nudge to re-query through that safe path.
	if !w.win32InputMode {
		var refreshKeys []string
		refreshKeys = appendThemeQueryKeys(refreshKeys, w.themeHintRefreshKeysLocked())
		refreshKeys = appendThemeQueryKeys(refreshKeys, w.agentThemeHintRefreshKeysLocked())
		themeHintData = themeHintResponsesForKeys(themeHint, refreshKeys)
	}
	if w.themeHintModeReportLocked() {
		themeHintData = append(terminalThemeModeReportFromHint(themeHint), themeHintData...)
	}
	return themeHintData
}

// themeHintModeReportLocked reports whether this window should receive the DEC
// 997 color-scheme mode report (?997;1n dark / ?997;2n light) on a theme
// refresh.
//
// DEC private mode 2031 is the only opt-in. Apps that want live theme flips
// enable it after startup (Copilot CLI does so after its OSC 10/11 + ?996n
// handshake; Cursor Agent enables it from its theme-detection hook). Gating on
// 2031 — not an agent-name allowlist — keeps future agents working and avoids
// pushing unsolicited CSI at shells or TUIs that never asked for color-scheme
// updates. CSI mode reports are also safe under Windows ConPTY, unlike
// unsolicited OSC color pushes which must stay suppressed there.
func (w *muxWindow) themeHintModeReportLocked() bool {
	return w.themeRefreshModeActiveLocked()
}

// agentThemeHintRefreshKeysLocked returns unsolicited OSC color keys used on the
// tmux-era agent refresh path.
//
// Kept narrower than focus transitions: only windows detected as a coding agent
// get a proactive OSC 11 push. Unknown focus-aware TUIs still get FocusOut/In
// (so undetected agents can re-query) but must not receive unsolicited OSC
// (composer spew / Hermes). Win32 still strips these OSCs in
// themeHintRefreshDataLocked because ConPTY delivers encoded OSC as keystrokes.
func (w *muxWindow) agentThemeHintRefreshKeysLocked() []string {
	if !w.focusModeActiveLocked() || w.agentToolLocked() == "" {
		return nil
	}
	return []string{"11"}
}

func (w *muxWindow) themeRefreshModeActiveLocked() bool {
	if w == nil || !w.privateModes["2031"] {
		return false
	}
	activePid := w.activeForegroundPidLocked()
	return w.themeRefreshModeProcessID <= 0 ||
		activePid <= 0 ||
		w.themeRefreshModeProcessID == activePid
}

func (w *muxWindow) activeThemeColorQueryKeysLocked() []string {
	activePid := w.activeForegroundPidLocked()
	if w.themeColorQueryPid <= 0 ||
		activePid <= 0 ||
		w.themeColorQueryPid != activePid ||
		len(w.themeColorQueryKeys) == 0 {
		return nil
	}
	keys := make([]string, 0, len(w.themeColorQueryKeys))
	for key := range w.themeColorQueryKeys {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func (w *muxWindow) activeForegroundPidLocked() int {
	if w.pty == nil {
		return w.metadataProcessIDLocked()
	}
	return w.foregroundProcessGroupLocked()
}

func (w *muxWindow) focusModeActiveLocked() bool {
	if w == nil || !w.focusModeEnabled {
		return false
	}
	activePid := w.activeForegroundPidLocked()
	return w.focusModeProcessID <= 0 ||
		activePid <= 0 ||
		w.focusModeProcessID == activePid
}

func commandNameForProcessGroup(pgrp int) string {
	if pgrp <= 0 {
		return ""
	}
	processes := cachedProcessTable(time.Now())
	info := processes[pgrp]
	directCommand := commandNameFromProcessFields(info.comm, info.args)
	if directCommand != "" &&
		!isGenericRuntimeCommandName(directCommand) &&
		!isShellCommandName(directCommand) {
		return directCommand
	}

	fallback := directCommand
	if agentToolFromCommandName(fallback) != "" {
		return fallback
	}

	if len(processes) == 0 {
		return fallback
	}
	for _, process := range processes {
		if process.pgid != pgrp {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if command == "" {
			continue
		}
		if agentToolFromCommandName(command) != "" {
			return command
		}
		if process.pid == pgrp && !isGenericRuntimeCommandName(command) {
			return command
		}
		if fallback == "" ||
			(!isShellCommandName(command) &&
				!isGenericRuntimeCommandName(command)) {
			fallback = command
		}
	}
	return fallback
}

func commandNameFromProcessFields(command string, args string) string {
	if agentCommand := agentCommandNameFromProcessArgs(args); agentCommand != "" {
		return agentCommand
	}
	if command := cleanProcessCommandName(command); command != "" {
		return command
	}
	return cleanProcessCommandName(args)
}

func cleanProcessCommandName(value string) string {
	for _, line := range strings.Split(value, "\n") {
		command := strings.TrimSpace(line)
		if command == "" {
			continue
		}
		command = strings.Fields(command)[0]
		command = strings.Trim(command, `"'`)
		command = filepath.Base(command)
		command = strings.TrimSuffix(command, ".exe")
		command = strings.TrimSuffix(command, ".js")
		return command
	}
	return ""
}

func agentCommandNameFromProcessArgs(args string) string {
	trimmed := strings.TrimSpace(args)
	if trimmed == "" {
		return ""
	}
	for _, token := range strings.Fields(trimmed) {
		command := cleanProcessCommandName(token)
		if agentToolFromCommandName(command) != "" {
			return canonicalAgentCommandName(command)
		}
	}

	lowered := strings.ToLower(trimmed)
	switch {
	case strings.Contains(lowered, "@openai/codex") ||
		strings.Contains(lowered, "/codex/bin/codex") ||
		strings.Contains(lowered, "/codex.js"):
		return "codex"
	case strings.Contains(lowered, "@anthropic-ai/claude-code") ||
		strings.Contains(lowered, "/claude-code/"):
		return "claude"
	case strings.Contains(lowered, "@earendil-works/pi-coding-agent") ||
		strings.Contains(lowered, "@earendil-works\\pi-coding-agent") ||
		strings.Contains(lowered, "@mariozechner/pi-coding-agent") ||
		strings.Contains(lowered, "@mariozechner\\pi-coding-agent"):
		return "pi"
	case strings.Contains(lowered, "cursor-agent/versions/"):
		// The `cursor-agent`/`agent` launchers are Node wrappers whose argv[0]
		// (often the generic `agent`) is ambiguous, so match the versioned
		// install path instead.
		return "cursor-agent"
	default:
		return ""
	}
}

func agentToolFromCommandText(command string) string {
	return firstNonEmptyString(
		agentToolFromCommandName(commandNameFromShellCommand(command)),
		agentToolFromCommandName(agentCommandNameFromProcessArgs(command)),
	)
}

func agentToolFromCommandName(command string) string {
	normalized := strings.ToLower(cleanProcessCommandName(command))
	switch normalized {
	case "claude", "claude-code":
		return "claude"
	case "copilot", "github-copilot":
		return "copilot"
	case "codex", "codex-cli":
		return "codex"
	case "opencode", "open-code":
		return "opencode"
	case "agy", "antigravity", "antigravity-cli":
		return "antigravity"
	case "cursor-agent":
		return "cursor-agent"
	case "pi", "pi-agent":
		return "pi"
	default:
		return ""
	}
}

func monkeyMuxAgentLaunchCommand(command string) string {
	trimmed := strings.TrimSpace(command)
	if trimmed == "pi" {
		return monkeyMuxPiAgentLaunchCommand()
	}
	if strings.HasPrefix(trimmed, "pi ") {
		return monkeyMuxPiAgentLaunchCommand() + trimmed[len("pi"):]
	}
	return command
}

func monkeyMuxPiAgentLaunchCommand() string {
	executable, err := os.Executable()
	if err == nil {
		if invocation, ok := shellExecutableCommand(executable); ok {
			return invocation + " pi-agent"
		}
	}
	return "monkeymux pi-agent"
}

var agentCommands = map[string]struct {
	executable       string
	permissionFlags  string
	resumeArgument   string
	supportsContinue bool
}{
	"claude":       {"claude", "--dangerously-skip-permissions", "--resume", false},
	"copilot":      {"copilot", "--yolo", "--resume", false},
	"codex":        {"codex", "--yolo", "resume", false},
	"opencode":     {"opencode", "", "--session", true},
	"antigravity":  {"agy", "--dangerously-skip-permissions", "--conversation", true},
	"cursor-agent": {"cursor-agent", "--force", "--resume", true},
}

func agentLaunchCommand(tool string, startInYoloMode bool) string {
	if tool == "pi" {
		return monkeyMuxPiAgentLaunchCommand()
	}
	descriptor := agentCommands[tool]
	command := descriptor.executable
	if startInYoloMode {
		if tool == "opencode" {
			return "OPENCODE_PERMISSION=" + shellQuote(`{"*":"allow"}`) + " " + command
		}
		if descriptor.permissionFlags != "" {
			command += " " + descriptor.permissionFlags
		}
	}
	return command
}

func piLaunchCommand(sessionDir string) string {
	sessionDir = strings.TrimSpace(sessionDir)
	if sessionDir == "" {
		return monkeyMuxPiAgentLaunchCommand()
	}
	argument, ok := shellArgument(sessionDir)
	if !ok {
		return ""
	}
	return monkeyMuxPiAgentLaunchCommand() + " --session-dir " + argument
}

func piResumeCommand(sessionID string, sessionDir string, sessionPath string) string {
	if !safePiSessionIDPattern.MatchString(strings.TrimSpace(sessionID)) {
		return ""
	}
	if sessionPath = strings.TrimSpace(sessionPath); sessionPath != "" {
		argument, ok := shellArgument(sessionPath)
		if !ok {
			return ""
		}
		return monkeyMuxPiAgentLaunchCommand() + " --session " + argument
	}
	launch := piLaunchCommand(sessionDir)
	if launch == "" {
		return ""
	}
	return launch + " --session " + sessionID
}

func agentResumeCommand(tool string, sessionID string, startInYoloMode bool) string {
	quotedSessionID, ok := shellArgument(sessionID)
	if !ok {
		return ""
	}
	if tool == "pi" {
		if !safePiSessionIDPattern.MatchString(sessionID) {
			return ""
		}
		return piResumeCommand(sessionID, "", "")
	}
	launch := agentLaunchCommand(tool, startInYoloMode)
	if launch == "" {
		return ""
	}
	descriptor := agentCommands[tool]
	if sessionID == "_continue" && descriptor.supportsContinue {
		return launch + " --continue"
	}
	resume := launch + " " + descriptor.resumeArgument + " " + quotedSessionID
	if tool == "codex" {
		return codexResumeGateCommand(sessionID, resume)
	}
	return resume
}

func canonicalAgentCommandName(command string) string {
	return firstNonEmptyString(agentToolFromCommandName(command), cleanProcessCommandName(command))
}

// agentResumeCommandWithFreshFallback wraps a restored agent's --resume command
// so a resume that exits immediately falls back to launching the agent fresh,
// keeping the restored window alive instead of letting it vanish.
//
// After a MonkeyMux helper upgrade every window is recreated by relaunching its
// foreground process. For an agent this is something like `copilot --resume
// <id>`. When that session can no longer be resumed — a window that never
// committed a session before the restart, a session store that lives on another
// machine, a stale id — the CLI prints an error and exits non-zero (Copilot CLI
// reports "No session, task, or name matched" and exits 1). The window's shell
// then has nothing left to run, so the pane closes and the user loses the whole
// window. Falling back to a fresh launch preserves the window; a successful
// resume runs interactively and only exits when the user quits, so the "||"
// branch is reached solely when the resume itself failed to start. An
// intentional close signals the whole process group (SIGHUP), which terminates
// the shell before it can reach the fallback, so closing a window never
// relaunches the agent. During Codex server teardown, shutdownCodex freezes the
// wrapping shell before TERM and leaves it stopped through the final group kill.
func agentResumeCommandWithFreshFallback(resume string, launch string) string {
	return piResumeCommandWithFreshFallback(resume, launch)
}

func agentToolFromTerminalTitle(title string) string {
	normalized := strings.ToLower(strings.Join(strings.Fields(title), " "))
	normalized = strings.Trim(normalized, "·-: ")
	switch {
	case normalized == "claude" || normalized == "claude code" ||
		strings.HasPrefix(normalized, "claude code "):
		return "claude"
	case normalized == "copilot" || normalized == "copilot cli" ||
		strings.HasPrefix(normalized, "copilot cli "):
		return "copilot"
	case normalized == "codex" || strings.HasPrefix(normalized, "codex "):
		return "codex"
	case normalized == "opencode" || normalized == "open code" ||
		strings.HasPrefix(normalized, "opencode "):
		return "opencode"
	case normalized == "agy" || normalized == "antigravity" ||
		strings.HasPrefix(normalized, "agy ") || strings.HasPrefix(normalized, "antigravity "):
		return "antigravity"
	case normalized == "cursor agent" ||
		normalized == "cursor-agent" || normalized == "cursor cli" ||
		strings.HasPrefix(normalized, "cursor agent "):
		return "cursor-agent"
	case normalized == "pi" || strings.HasPrefix(normalized, "pi - ") ||
		normalized == "π" || strings.HasPrefix(normalized, "π - "):
		return "pi"
	default:
		return ""
	}
}

func isGenericRuntimeCommandName(command string) bool {
	switch strings.ToLower(cleanProcessCommandName(command)) {
	case "node", "nodejs", "npm", "npx", "bun", "deno", "python", "python3":
		return true
	default:
		return false
	}
}

func isShellCommandName(command string) bool {
	switch strings.ToLower(cleanProcessCommandName(command)) {
	case "sh", "bash", "zsh", "fish", "dash", "ksh",
		"cmd", "powershell", "pwsh":
		return true
	default:
		return false
	}
}

func commandNameFromShellCommand(command string) string {
	normalized := strings.TrimSpace(command)
	for normalized != "" {
		if match := leadingCdCommandPattern.FindStringIndex(normalized); match != nil && match[0] == 0 {
			normalized = strings.TrimSpace(normalized[match[1]:])
			continue
		}
		if match := leadingEnvPattern.FindStringIndex(normalized); match != nil && match[0] == 0 {
			normalized = strings.TrimSpace(normalized[match[1]:])
			continue
		}
		break
	}
	token := leadingShellToken(normalized)
	if token == "" {
		return ""
	}
	return cleanProcessCommandName(token)
}

func leadingShellToken(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	if quote := trimmed[0]; quote == '\'' || quote == '"' {
		if end := strings.IndexByte(trimmed[1:], quote); end >= 0 {
			return trimmed[1 : end+1]
		}
	}
	fields := strings.Fields(trimmed)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

func (w *muxWindow) observeTerminalModesLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	data := chunk
	if len(w.csiBuffer) > 0 {
		combined := make([]byte, 0, len(w.csiBuffer)+len(chunk))
		combined = append(combined, w.csiBuffer...)
		combined = append(combined, chunk...)
		data = combined
		w.csiBuffer = nil
	}

	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return
		}
		if escapeIndex+1 >= len(data) {
			w.storePartialCsiLocked(data[escapeIndex:])
			return
		}
		switch data[escapeIndex+1] {
		case '[':
		case '=':
			w.applicationKeypadEnabled = true
			w.applicationKeypadKnown = true
			data = data[escapeIndex+2:]
			continue
		case '>':
			w.applicationKeypadEnabled = false
			w.applicationKeypadKnown = true
			data = data[escapeIndex+2:]
			continue
		default:
			data = data[escapeIndex+1:]
			continue
		}

		end := csiSequenceEnd(data, escapeIndex+2)
		if end < 0 {
			w.storePartialCsiLocked(data[escapeIndex:])
			return
		}
		final := data[end]
		if final == 'h' || final == 'l' {
			params := string(data[escapeIndex+2 : end])
			enabled := final == 'h'
			if strings.HasPrefix(params, "?") {
				for _, mode := range csiModeParams(strings.TrimPrefix(params, "?")) {
					w.setPrivateModeLocked(mode, enabled)
				}
			} else {
				for _, mode := range csiModeParams(params) {
					if mode == "4" {
						w.insertModeEnabled = enabled
						w.insertModeKnown = true
					}
				}
			}
		}
		data = data[end+1:]
	}
}

func (w *muxWindow) storePartialCsiLocked(data []byte) {
	if len(data) > csiBufferLimitBytes {
		w.csiBuffer = nil
		return
	}
	w.csiBuffer = append(w.csiBuffer[:0], data...)
}

// appendPendingTerminalQueriesLocked scans a chunk of the window's child output
// for terminal capability/status queries (CSI, OSC, and DCS). It is called only
// while no terminal is showing the window, so these queries are not being
// forwarded to a terminal that could answer them.
//
// Queries whose reply is constant for the attached terminal are answered right
// away from [hint]: the returned bytes must be written to the window's pty by
// the caller. This is what keeps an agent relaunched by an upgrade restore from
// timing out on its startup XTVERSION/device-attribute probes and settling on a
// less capable rendering mode while it waits in a background (or not yet
// attached) window.
//
// The colour-scheme query (`CSI ? 996 n`) is answered from [themeHint], which
// carries the client's current dark/light mode report. Buffering it instead
// would replay it to the terminal on the next attach, and the reply lands in
// the window pty as input: if the process that asked has exited by then (an
// agent that quit while the window ran unwatched), its shell echoes the reply
// as literal `^[[?997;1n` text at the prompt.
//
// The remaining queries are buffered in pendingTerminalQueries, and
// flushPendingTerminalQueriesLocked re-delivers them once a terminal attaches
// or the window is selected. A query split across pty reads is carried in
// pendingTerminalQueryCarry until the rest arrives. Queries answered from the
// cached theme hint are stripped before reaching this scanner.
//
// A capability probe group is conventionally terminated by a fence query — DA1
// or DSR — that the child reads as "the terminal has answered everything it
// supports". Answering a fence from the hint while an earlier probe of the same
// group is still buffered would close the group before those answers exist, so
// fence queries are only answered while nothing is already waiting on the
// terminal. That keeps a probe group the daemon cannot fully answer (XTGETTCAP,
// DECRQM, kitty graphics) on the buffer-and-replay path, in emission order,
// exactly as before.
func (w *muxWindow) appendPendingTerminalQueriesLocked(
	chunk []byte,
	hint []byte,
	themeHint []byte,
) []byte {
	if len(chunk) == 0 {
		return nil
	}
	var answers []byte
	var hintResponses map[string][]byte
	hintParsed := false
	withinAnswerBudget := func(response []byte) bool {
		// Bound what a window running unwatched can push into its own child's
		// stdin. Output replayed into a background window (an ANSI art file, a
		// terminal recording) can carry an unbounded stream of device attribute
		// queries, and synthesizing a reply for each would block the window's
		// reader goroutine on a child that is not draining its input. Queries
		// past the budget fall through to the buffer, whose own limit then
		// closes the fence gate below for the rest of the stream.
		return len(response) > 0 &&
			w.capabilityAnswerBytes+len(answers)+len(response) <=
				pendingTerminalQueryLimitBytes
	}
	answerFor := func(sequence []byte) []byte {
		// Like XTVERSION, the colour-scheme query is never used as a probe
		// group terminator, so it is answered even behind a buffered probe.
		if isTerminalColorSchemeQuery(sequence) {
			response := terminalThemeModeReportFromHint(themeHint)
			if !withinAnswerBudget(response) {
				return nil
			}
			return response
		}
		key := capabilityQueryKey(sequence)
		if key == "" {
			return nil
		}
		// DA1/DA2/DA3 and DSR are the conventional group terminators, so they
		// are only answered while nothing is already waiting on the terminal.
		// XTVERSION is never used as a terminator — its DCS reply identifies
		// itself — so it is answered even behind a buffered probe, which is
		// what actually restores an agent's richer rendering mode.
		if key != capabilityHintKeyTerminalVersion &&
			(len(w.pendingTerminalQueries) > 0 ||
				len(w.pendingTerminalQueriesInFlight) > 0) {
			return nil
		}
		if !hintParsed {
			hintResponses = capabilityHintResponseMap(hint)
			hintParsed = true
		}
		response := hintResponses[key]
		if !withinAnswerBudget(response) {
			return nil
		}
		return response
	}
	data := chunk
	previousUtf8Remaining := w.queryUtf8Remaining
	leadingUtf8Prefix := leadingUtf8ContinuationPrefix(
		data,
		previousUtf8Remaining,
	)
	w.queryUtf8Remaining = 0
	if len(w.pendingTerminalQueryCarry) > 0 {
		combined := make([]byte, 0, len(w.pendingTerminalQueryCarry)+len(chunk))
		combined = append(combined, w.pendingTerminalQueryCarry...)
		combined = append(combined, chunk...)
		data = combined
		w.pendingTerminalQueryCarry = nil
		leadingUtf8Prefix = 0
	}
	for index := 0; index < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAtWithUtf8Prefix(
				data,
				index,
				leadingUtf8Prefix,
			)
		if incomplete {
			w.queryUtf8Remaining = 0
			w.storePartialPendingTerminalQueryLocked(data[index:])
			w.capabilityAnswerBytes += len(answers)
			return answers
		}
		if !recognized {
			index++
			continue
		}
		sequence := data[index:sequenceEnd]
		if isQuery {
			if response := answerFor(sequence); len(response) > 0 {
				answers = append(answers, response...)
			} else if len(w.pendingTerminalQueries)+len(sequence) <=
				pendingTerminalQueryLimitBytes {
				w.pendingTerminalQueries = append(
					w.pendingTerminalQueries,
					sequence...,
				)
			}
		}
		index = sequenceEnd
	}
	w.queryUtf8Remaining = nextQueryUtf8Remaining(
		data,
		previousUtf8Remaining,
		leadingUtf8Prefix,
	)
	w.capabilityAnswerBytes += len(answers)
	return answers
}

func (w *muxWindow) storePartialPendingTerminalQueryLocked(data []byte) {
	if len(data) > pendingTerminalQueryLimitBytes {
		w.pendingTerminalQueryCarry = nil
		return
	}
	w.pendingTerminalQueryCarry = append(w.pendingTerminalQueryCarry[:0], data...)
}

func (w *muxWindow) setPrivateModeLocked(mode string, enabled bool) {
	if mode == "25" {
		w.cursorVisible = enabled
		w.cursorVisibilityKnown = true
		return
	}
	if mode == "9001" {
		w.win32InputMode = enabled
		return
	}
	if mode == "1004" {
		w.focusModeEnabled = enabled
		if enabled {
			w.focusModeProcessID = w.activeForegroundPidLocked()
		} else {
			w.focusModeProcessID = 0
		}
	}
	if mode == "2031" {
		if enabled {
			w.themeRefreshModeProcessID = w.activeForegroundPidLocked()
		} else {
			w.themeRefreshModeProcessID = 0
		}
	}
	if _, ok := trackedPrivateModes[mode]; !ok {
		return
	}
	if w.privateModes == nil {
		w.privateModes = map[string]bool{}
	}
	w.privateModes[mode] = enabled
	if mode == "1000" || mode == "1002" || mode == "1003" {
		// Remember which foreground process owns mouse tracking so it can be
		// suppressed once that process is no longer in the foreground. Clear it
		// once no mouse-tracking mode remains enabled.
		if w.reportsMouseWheelRawLocked() {
			if enabled {
				w.mouseTrackingProcessID = w.activeForegroundPidLocked()
			}
		} else {
			w.mouseTrackingProcessID = 0
		}
	}
}

func csiModeParams(params string) []string {
	if params == "" {
		return nil
	}
	parts := strings.Split(params, ";")
	modes := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		mode, _, _ := strings.Cut(part, ":")
		if mode != "" {
			modes = append(modes, mode)
		}
	}
	return modes
}

func (w *muxWindow) cursorVisibleForReplayLocked() bool {
	return !w.cursorVisibilityKnown || w.cursorVisible
}

func cursorVisibilityReplaySequence(visible bool) string {
	if visible {
		return "\x1b[?25h"
	}
	return "\x1b[?25l"
}

func (w *muxWindow) observeTerminalMetadataLocked(chunk []byte) []string {
	if len(chunk) == 0 {
		return nil
	}
	data := chunk
	leadingUtf8Prefix := leadingUtf8ContinuationPrefix(
		chunk,
		w.terminalOutputUtf8Remaining,
	)
	if len(w.oscBuffer) > 0 {
		combined := make([]byte, 0, len(w.oscBuffer)+len(chunk))
		combined = append(combined, w.oscBuffer...)
		combined = append(combined, chunk...)
		data = combined
		leadingUtf8Prefix = 0
		w.oscBuffer = nil
	}

	var observedThemeQueries []string
	for len(data) > 0 {
		sequenceStart := -1
		payloadStart := -1
		for index := 0; index < len(data); index++ {
			switch data[index] {
			case '\x1b':
				if index+1 >= len(data) {
					w.storePartialOscLocked(data[index:])
					return observedThemeQueries
				}
				if data[index+1] == ']' {
					sequenceStart = index
					payloadStart = index + 2
				}
			case 0x9d:
				if index >= leadingUtf8Prefix &&
					!isUtf8ContinuationAt(data, index) {
					sequenceStart = index
					payloadStart = index + 1
				}
			}
			if sequenceStart >= 0 {
				break
			}
		}
		if sequenceStart < 0 {
			return observedThemeQueries
		}

		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			w.storePartialOscLocked(data[sequenceStart:])
			return observedThemeQueries
		}
		observedThemeQueries = appendThemeQueryKeys(
			observedThemeQueries,
			w.applyOscPayloadLocked(
				string(data[payloadStart:payloadStart+payloadEnd]),
			),
		)
		data = data[payloadStart+payloadEnd+terminatorLength:]
		leadingUtf8Prefix = 0
	}
	return observedThemeQueries
}

func findOscTerminator(data []byte) (payloadEnd int, terminatorLength int, ok bool) {
	for i := 0; i < len(data); i++ {
		switch data[i] {
		case '\a':
			return i, 1, true
		case 0x9c:
			if !isUtf8ContinuationAt(data, i) {
				return i, 1, true
			}
		case '\x1b':
			if i+1 >= len(data) {
				return 0, 0, false
			}
			if data[i+1] == '\\' {
				return i, 2, true
			}
		}
	}
	return 0, 0, false
}

func findStringTerminator(
	data []byte,
) (payloadEnd int, terminatorLength int, ok bool) {
	for index := 0; index < len(data); index++ {
		if data[index] == 0x9c && !isUtf8ContinuationAt(data, index) {
			return index, 1, true
		}
		if data[index] == '\x1b' &&
			index+1 < len(data) &&
			data[index+1] == '\\' {
			return index, 2, true
		}
	}
	return 0, 0, false
}

func isUtf8ContinuationAt(data []byte, index int) bool {
	if index <= 0 || index >= len(data) || data[index]&0xc0 != 0x80 {
		return false
	}
	for start := index - 1; start >= 0 && index-start <= 3; start-- {
		if data[start]&0xc0 == 0x80 {
			continue
		}
		expected := utf8ContinuationCount(data[start])
		return expected > 0 && index-start <= expected
	}
	return false
}

func (w *muxWindow) storePartialOscLocked(data []byte) {
	if len(data) > oscBufferLimitBytes {
		w.oscBuffer = nil
		return
	}
	w.oscBuffer = append(w.oscBuffer[:0], data...)
}

func copyTerminalProgressSnapshot(
	progress *terminalProgressSnapshot,
) *terminalProgressSnapshot {
	if progress == nil {
		return nil
	}
	copied := &terminalProgressSnapshot{State: progress.State}
	if progress.Percentage != nil {
		percentage := *progress.Percentage
		copied.Percentage = &percentage
	}
	return copied
}

func (w *muxWindow) applyTerminalProgressPayloadLocked(value string) {
	parts := strings.Split(value, ";")
	if len(parts) < 2 || strings.TrimSpace(parts[0]) != "4" {
		return
	}
	state, err := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err != nil {
		return
	}
	switch state {
	case 0:
		w.terminalProgress = nil
	case 1:
		percentage, ok := terminalProgressPercentage(parts, 2)
		if !ok {
			return
		}
		w.terminalProgress = &terminalProgressSnapshot{
			State:      state,
			Percentage: &percentage,
		}
	case 2, 4:
		var percentage *int
		if len(parts) > 2 && strings.TrimSpace(parts[2]) != "" {
			parsed, ok := terminalProgressPercentage(parts, 2)
			if !ok {
				return
			}
			percentage = &parsed
		} else if w.terminalProgress != nil && w.terminalProgress.Percentage != nil {
			parsed := *w.terminalProgress.Percentage
			percentage = &parsed
		}
		w.terminalProgress = &terminalProgressSnapshot{
			State:      state,
			Percentage: percentage,
		}
	case 3:
		w.terminalProgress = &terminalProgressSnapshot{State: state}
	}
}

func terminalProgressPercentage(parts []string, index int) (int, bool) {
	if len(parts) <= index {
		return 0, false
	}
	percentage, err := strconv.Atoi(strings.TrimSpace(parts[index]))
	if err != nil || percentage < 0 || percentage > 100 {
		return 0, false
	}
	return percentage, true
}

func (w *muxWindow) applyOscPayloadLocked(payload string) []string {
	code, value, ok := strings.Cut(payload, ";")
	if !ok {
		return nil
	}
	switch code {
	case "0", "1", "2":
		title := cleanTerminalTitle(value)
		if title == "" {
			return nil
		}
		w.paneTitle = title
	case "7":
		path := pathFromOsc7(value)
		if path != "" {
			w.cwd = path
		}
	case "9":
		w.applyTerminalProgressPayloadLocked(value)
	case "1337":
		w.applyPiIdentityPayloadLocked(value)
	}
	queryKeys := themeQueryKeysFromOscPayload(payload)
	if len(queryKeys) == 0 {
		return nil
	}
	if w.win32InputMode {
		// ConPTY forwards the child's OSC 4 palette queries out of the pty but
		// swallows its OSC 10/11 default-colour queries, so a colour
		// interrogation observed under win32-input-mode implies the swallowed
		// default foreground/background queries as well. Answering them
		// unprompted is the only way the child ever learns those colours.
		queryKeys = appendThemeQueryKeys(queryKeys, conPtySwallowedThemeQueryKeys)
	}
	queryPid := w.activeForegroundPidLocked()
	if queryPid <= 0 {
		return nil
	}
	if w.themeColorQueryPid != queryPid {
		w.themeColorQueryKeys = nil
	}
	w.themeColorQueryPid = queryPid
	if w.themeColorQueryKeys == nil {
		w.themeColorQueryKeys = map[string]bool{}
	}
	for _, key := range queryKeys {
		w.themeColorQueryKeys[key] = true
	}
	return queryKeys
}

func (w *muxWindow) applyPiIdentityPayloadLocked(value string) {
	const prefix = "MonkeyMuxPi="
	if !strings.HasPrefix(value, prefix) || w.agentToolLocked() != "pi" {
		return
	}
	encoded := strings.TrimPrefix(value, prefix)
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil || len(data) == 0 || len(data) > oscBufferLimitBytes {
		return
	}
	var identity struct {
		ID   string `json:"id"`
		File string `json:"file"`
	}
	if json.Unmarshal(data, &identity) != nil {
		return
	}
	identity.ID = strings.TrimSpace(identity.ID)
	identity.File = filepath.Clean(strings.TrimSpace(identity.File))
	if !safePiSessionIDPattern.MatchString(identity.ID) ||
		!filepath.IsAbs(identity.File) ||
		!strings.HasSuffix(strings.ToLower(identity.File), ".jsonl") {
		return
	}
	w.agentSessionID = identity.ID
	w.agentSessionPath = identity.File
	w.agentSessionDir = filepath.Dir(identity.File)
	w.agentSessionIdentityExact = true
	w.agentTool = "pi"
	w.agentToolConfirmed = true
}

func appendThemeQueryKeys(existing []string, keys []string) []string {
	if len(keys) == 0 {
		return existing
	}
	seen := make(map[string]bool, len(existing)+len(keys))
	for _, key := range existing {
		seen[key] = true
	}
	for _, key := range keys {
		if seen[key] {
			continue
		}
		seen[key] = true
		existing = append(existing, key)
	}
	return existing
}

func themeQueryKeysFromOscPayload(payload string) []string {
	parts := strings.Split(payload, ";")
	if len(parts) < 2 {
		return nil
	}
	code := strings.TrimSpace(parts[0])
	args := parts[1:]
	switch code {
	case "4":
		return paletteThemeQueryKeys(args)
	case "10", "11", "12", "17", "19":
		if strings.TrimSpace(args[0]) == "?" {
			return []string{code}
		}
	}
	return nil
}

func paletteThemeQueryKeys(args []string) []string {
	var keys []string
	for i := 0; i+1 < len(args); i += 2 {
		if strings.TrimSpace(args[i+1]) != "?" {
			continue
		}
		index, err := strconv.Atoi(strings.TrimSpace(args[i]))
		if err != nil || index < 0 || index > 255 {
			continue
		}
		keys = append(keys, fmt.Sprintf("4;%d", index))
	}
	return keys
}

func themeHintResponsesForKeys(hint []byte, keys []string) []byte {
	if len(hint) == 0 || len(keys) == 0 {
		return nil
	}
	responses := themeHintResponseMap(hint)
	if len(responses) == 0 {
		return nil
	}
	var output []byte
	seen := make(map[string]bool, len(keys))
	for _, key := range keys {
		if seen[key] {
			continue
		}
		seen[key] = true
		response := responses[key]
		if len(response) == 0 {
			continue
		}
		output = append(output, response...)
	}
	return output
}

func terminalThemeModeReportFromHint(hint []byte) []byte {
	const darkReport = "\x1b[?997;1n"
	const lightReport = "\x1b[?997;2n"
	darkIndex := bytes.Index(hint, []byte(darkReport))
	lightIndex := bytes.Index(hint, []byte(lightReport))
	if darkIndex < 0 && lightIndex < 0 {
		return nil
	}
	if lightIndex < 0 || (darkIndex >= 0 && darkIndex < lightIndex) {
		return []byte(darkReport)
	}
	return []byte(lightReport)
}

func themeHintResponseMap(hint []byte) map[string][]byte {
	responses := map[string][]byte{}
	data := hint
	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return responses
		}
		if escapeIndex+1 >= len(data) {
			return responses
		}
		if data[escapeIndex+1] != ']' {
			data = data[escapeIndex+1:]
			continue
		}

		payloadStart := escapeIndex + 2
		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			return responses
		}
		sequenceEnd := payloadStart + payloadEnd + terminatorLength
		key := themeResponseKeyFromOscPayload(
			string(data[payloadStart : payloadStart+payloadEnd]),
		)
		if key != "" {
			responses[key] = append([]byte(nil), data[escapeIndex:sequenceEnd]...)
		}
		data = data[sequenceEnd:]
	}
	return responses
}

func themeResponseKeyFromOscPayload(payload string) string {
	parts := strings.Split(payload, ";")
	if len(parts) < 2 {
		return ""
	}
	code := strings.TrimSpace(parts[0])
	switch code {
	case "4":
		if len(parts) < 3 {
			return ""
		}
		index, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || index < 0 || index > 255 {
			return ""
		}
		return fmt.Sprintf("4;%d", index)
	case "10", "11", "12", "17", "19":
		if strings.TrimSpace(parts[1]) == "?" {
			return ""
		}
		return code
	}
	return ""
}

func cleanTerminalTitle(value string) string {
	title := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	title = strings.Join(strings.Fields(title), " ")
	if len(title) <= maxTitleBytes {
		return title
	}
	for i := range title {
		if i > maxTitleBytes {
			return title[:i]
		}
	}
	return title
}

func pathFromOsc7(value string) string {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "file" {
		return ""
	}
	if !strings.HasPrefix(parsed.Path, "/") {
		return ""
	}
	return parsed.Path
}

func (s *muxServer) clearAlertsLocked(activeID string) {
	for _, window := range s.windows {
		if window.id == activeID {
			window.alert = false
		}
	}
}

func (s *muxServer) reindexWindowsLocked() {
	index := 0
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		window.index = index
		index++
	}
}

func (s *muxServer) close() {
	s.mu.Lock()
	if s.closed {
		// Shutdown is triggered concurrently (`go s.close()`) as well as from
		// deferred calls, so a later caller must not report the server as torn
		// down while the first caller is still tearing it down. Wait for that
		// caller instead of returning immediately.
		inFlight := s.closeDone
		s.mu.Unlock()
		if inFlight != nil {
			<-inFlight
		}
		return
	}
	s.closed = true
	s.closeDone = make(chan struct{})
	closeDone := s.closeDone
	listener := s.listener
	socket := s.socketPath
	identity := s.socketIdentity
	s.listener = nil
	attachClients := make([]*attachClient, 0, len(s.attachClients))
	for _, client := range s.attachClients {
		attachClients = append(attachClients, client)
	}
	s.attachConn = nil
	s.attachClients = map[net.Conn]*attachClient{}
	controls := make([]*controlClient, 0, len(s.controls))
	for control := range s.controls {
		controls = append(controls, control)
	}
	windows := append([]*muxWindow(nil), s.windows...)
	// Mark the windows closed while still holding s.mu. A watcher that outruns
	// the bounded wait below then finds its window already closed and returns
	// from markWindowClosed before touching any server state.
	codexWindows := make(map[*muxWindow]bool)
	for _, window := range windows {
		codexWindows[window] = !window.closed && window.agentTool == "codex" && window.nativeAcpBridgeID == ""
		window.closed = true
		window.releaseRedrawForwardingStateLocked()
		window.clearKittyGraphicsPendingLocked()
	}
	s.mu.Unlock()
	defer close(closeDone)

	if listener != nil {
		_ = listener.Close()
	}
	if socket != "" {
		removeSocketPathIfUnchanged(socket, identity)
	}
	for _, client := range attachClients {
		client.close()
	}
	for _, control := range controls {
		_ = control.conn.Close()
	}
	shutdownDeadline := time.Now().Add(windowWatcherShutdownTimeout)
	var teardowns sync.WaitGroup
	for _, window := range windows {
		teardowns.Add(1)
		go func() {
			defer teardowns.Done()
			if process, ok := window.proc.(interface {
				shutdownCodex(*muxWindow, time.Time)
			}); ok && codexWindows[window] {
				process.shutdownCodex(window, shutdownDeadline)
			} else if window.proc != nil {
				window.proc.Hangup()
			}
			if window.pty != nil {
				_ = window.closePty(window.pty)
			}
			if window.nativeAcpBridgeID != "" {
				_ = requestAcpBridgeStopAndWait(window.nativeAcpBridgeID)
			}
		}()
	}
	teardowns.Wait()
	// Closing the ptys ends the reader goroutines and the hangup above ends the
	// child processes, so the watchers finish promptly. Wait for them so no
	// goroutine mutates server state after close returns. The wait is bounded
	// because a child that ignores SIGHUP must not be able to hang shutdown;
	// marking the windows closed above is what makes overrunning a watcher
	// harmless rather than a late mutation of server state.
	s.waitForWindowWatchers(time.Until(shutdownDeadline))
	// A republisher may already have bound a replacement and be waiting to
	// reacquire s.mu. Join it before close returns so it can observe closed and
	// remove that listener's path rather than leaving stale socket residue.
	s.socketRepublishers.Wait()
	// Admission closed under s.mu before any Wait, so no start can join late.
	// Unlike normal watchers, unpublished children have no useful work to
	// preserve: join their forced cleanup through Wait before closing closeDone.
	s.pendingWindowStarts.Wait()
}

// windowWatcherShutdownTimeout includes Codex's parallel graceful escalation
// and the remaining watcher wait. Do not add the grace period to this budget:
// server replacement allows only one additional second for the old server exit.
const windowWatcherShutdownTimeout = 2 * time.Second

func (s *muxServer) waitForWindowWatchers(timeout time.Duration) {
	done := make(chan struct{})
	go func() {
		s.windowWatchers.Wait()
		close(done)
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	}
}

func (s *muxServer) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

func (s *muxServer) currentListener() net.Listener {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listener
}

func (s *muxServer) acceptConnection() (net.Conn, error) {
	for {
		listener := s.currentListener()
		if listener == nil {
			return nil, net.ErrClosed
		}
		conn, err := listener.Accept()
		if err == nil {
			return conn, nil
		}
		if s.isClosed() {
			return nil, err
		}
		if current := s.currentListener(); current != nil && current != listener {
			continue
		}
		return nil, err
	}
}

func (s *muxServer) startSocketRepublisher() {
	s.socketRepublishers.Add(1)
	go func() {
		defer s.socketRepublishers.Done()
		s.republishSocketLoop()
	}()
}

// republishSocketLoop puts the session path back when it no longer names this
// listener. An outgoing helper that still unlinks by path can delete the name
// after this process rebound it, leaving a live server that nobody can dial.
func (s *muxServer) republishSocketLoop() {
	ticker := time.NewTicker(socketRepublishInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if !s.republishSocketIfMissing() {
				return
			}
		}
	}
}

func (s *muxServer) republishSocketIfMissing() bool {
	s.mu.Lock()
	closed := s.closed
	listener := s.listener
	path := s.socketPath
	identity := s.socketIdentity
	s.mu.Unlock()
	if closed || listener == nil || path == "" {
		return false
	}
	if current, err := socketFileIdentity(path); err == nil {
		if !identity.valid() || current == identity {
			return true
		}
		// Another process already rebound the name. Leave it alone.
		return true
	} else if !errors.Is(err, os.ErrNotExist) {
		return true
	}
	replacement, err := net.Listen("unix", path)
	if err != nil {
		return true
	}
	disableUnixListenerUnlink(replacement)
	rebound, reboundErr := socketFileIdentity(path)
	_ = os.Chmod(path, 0o600)
	if hook := s.beforeInstallRepublishedSocket; hook != nil {
		hook()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.listener != listener {
		_ = replacement.Close()
		// Even without inode identity, use the guarded path-only cleanup. A
		// different helper may have rebound the name while this goroutine waited
		// for s.mu; unlinking by name would orphan that live listener.
		removeSocketPathIfUnchanged(path, rebound)
		return !s.closed
	}
	s.listener = replacement
	if reboundErr == nil {
		s.socketIdentity = rebound
	}
	_ = listener.Close()
	return true
}

type runningServerStatus struct {
	version      string
	capabilities []string
}

func (s runningServerStatus) displayVersion() string {
	if strings.TrimSpace(s.version) == "" {
		return "unknown"
	}
	return s.version
}

func (s runningServerStatus) supportsCapability(capability string) bool {
	for _, value := range s.capabilities {
		if value == capability {
			return true
		}
	}
	return false
}

func promptForServerUpdate(
	reader io.Reader,
	writer io.Writer,
	session string,
	status runningServerStatus,
) bool {
	fmt.Fprintf(
		writer,
		"\r\nMonkeyMux session %q is running with helper %s; this app includes helper %s.\r\n",
		session,
		status.displayVersion(),
		monkeyMuxVersion,
	)
	if status.supportsCapability("shutdown") {
		fmt.Fprint(
			writer,
			"Update now? MonkeyMux will try to restore existing windows in the new helper. [y/N] ",
		)
	} else {
		fmt.Fprint(
			writer,
			"Update now? This old helper cannot close itself; MonkeyMux will try to restore windows but may abandon the old ones. [y/N] ",
		)
	}
	answer, err := bufio.NewReader(reader).ReadString('\n')
	if err != nil {
		fmt.Fprint(writer, "\r\nmonkeymux: update skipped; continuing existing session.\r\n")
		return false
	}
	answer = strings.ToLower(strings.TrimSpace(answer))
	if answer == "y" || answer == "yes" {
		return true
	}
	fmt.Fprint(writer, "monkeymux: update skipped; continuing existing session.\r\n")
	return false
}

func shouldUpdateRunningServer(
	reader io.Reader,
	writer io.Writer,
	session string,
	status runningServerStatus,
	updatePolicy string,
) bool {
	switch updatePolicy {
	case serverUpdatePolicyNever:
		return false
	case serverUpdatePolicyAlways:
		return true
	default:
		return promptForServerUpdate(reader, writer, session, status)
	}
}

func normalizeServerUpdatePolicy(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", serverUpdatePolicyPrompt:
		return serverUpdatePolicyPrompt, nil
	case serverUpdatePolicyNever:
		return serverUpdatePolicyNever, nil
	case serverUpdatePolicyAlways:
		return serverUpdatePolicyAlways, nil
	default:
		return "", fmt.Errorf("invalid update policy %q", value)
	}
}

func queryRunningServerStatus(session string) (runningServerStatus, error) {
	conn, err := dialSession(session)
	if err != nil {
		return runningServerStatus{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return runningServerStatus{}, err
	}
	var hello controlResponse
	if err := dec.Decode(&hello); err != nil {
		return runningServerStatus{}, err
	}
	return runningServerStatus{
		version:      hello.Version,
		capabilities: hello.Capabilities,
	}, nil
}

// terminalWindowIDsForNativeAcpHandoff selects only windows whose terminal
// processes must be recreated by the replacement helper.
func terminalWindowIDsForNativeAcpHandoff(
	restore *serverRestore,
) ([]string, error) {
	terminalWindowIDs := make([]string, 0, len(restore.Windows))
	for _, window := range restore.Windows {
		if window.NativeAcpBridgeID != "" && window.NativeAcpProviderID != "" {
			continue
		}
		if window.ID == "" {
			return nil, errors.New("terminal restore window is missing its id")
		}
		terminalWindowIDs = append(terminalWindowIDs, window.ID)
	}
	return terminalWindowIDs, nil
}

// requestNativeAcpUpgradeHandoff reduces the outgoing workspace to its
// native ACP windows. Their in-process bridges remain alive while the new
// helper recreates terminal windows and starts placeholders that wait on those
// same bridge sockets. The outgoing helper exits naturally after its last
// native bridge/window closes.
func requestNativeAcpUpgradeHandoff(
	session string,
	restore *serverRestore,
) error {
	terminalWindowIDs, err := terminalWindowIDsForNativeAcpHandoff(restore)
	if err != nil {
		return err
	}
	if len(terminalWindowIDs) == 0 {
		return nil
	}

	conn, err := dialSession(session)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))
	return closeOutgoingTerminalWindows(conn, session, terminalWindowIDs)
}

func closeOutgoingTerminalWindows(
	conn net.Conn,
	session string,
	windowIDs []string,
) error {
	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return err
	}
	if _, err := readControlHello(dec); err != nil {
		return err
	}
	for index, windowID := range windowIDs {
		requestID := fmt.Sprintf("native-handoff-%d-%d", time.Now().UnixNano(), index)
		if err := enc.Encode(controlMessage{
			ID:       requestID,
			Type:     "close_window",
			Session:  session,
			WindowID: windowID,
		}); err != nil {
			return err
		}
		for {
			var response controlResponse
			if err := dec.Decode(&response); err != nil {
				return err
			}
			if response.ID != requestID {
				continue
			}
			if response.Status == "error" || response.Type == "error" {
				return errors.New(firstNonEmptyString(response.Error, "unable to close outgoing terminal window"))
			}
			if response.Type != "window_closed" {
				return errors.New("unexpected terminal-window handoff response")
			}
			break
		}
	}
	return nil
}

func requestServerShutdown(session string) {
	conn, err := dialSession(session)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return
	}
	var ignored controlResponse
	if err := dec.Decode(&ignored); err != nil {
		return
	}
	_ = enc.Encode(controlMessage{
		ID:      strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:    "shutdown",
		Session: session,
	})
}

func waitForServerExit(session string, timeout time.Duration) bool {
	owner, _ := sessionServerOwner(session)
	return waitForServerProcessExit(session, owner, timeout)
}

// waitForServerProcessExit waits until the outgoing helper is gone, not just
// until its socket path stops answering. After an upgrade the old process can
// still be inside close() and later unlink a replacement that already rebound
// the same path.
func waitForServerProcessExit(
	session string,
	owner pidRecord,
	timeout time.Duration,
) bool {
	deadline := time.Now().Add(timeout)
	hasExited := func() bool {
		switch {
		case owner.pid > 0 && pidRecordOwnership(owner, session) == pidOwnershipGone:
			return true
		case owner.pid <= 0:
			conn, err := dialSession(session)
			if err != nil {
				return true
			}
			_ = conn.Close()
		}
		return false
	}
	for time.Now().Before(deadline) {
		if hasExited() {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	// The process can exit during the final sleep that crosses the deadline.
	// Check once more before reporting a timeout and retaining a helper that is
	// no longer running.
	return hasExited()
}

func inheritedEnvironment(base []string) []string {
	result := make([]string, len(base))
	copy(result, base)
	return result
}

func terminalEnvironment(base []string) []string {
	env := inheritedEnvironment(base)
	env = appendEnvironmentDefault(env, "TERM", "xterm-256color", terminalTermIsUsable)
	env = appendEnvironmentDefault(env, "COLORTERM", "truecolor", terminalColorTermIsTrueColor)
	env = appendEnvironmentDefault(env, "TERM_PROGRAM", "kitty", terminalProgramSupportsInlineImages)
	env = appendEnvironmentDefault(env, "KITTY_WINDOW_ID", "1", terminalEnvironmentValueIsPresent)
	env = appendEnvironmentDefault(env, "FORCE_HYPERLINK", "1", terminalEnvironmentValueIsPresent)
	return env
}

func appendEnvironmentDefault(
	env []string,
	key string,
	value string,
	valid func(string) bool,
) []string {
	prefix := key + "="
	defaultEntry := prefix + value
	replacement := defaultEntry
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) && valid(strings.TrimPrefix(entry, prefix)) {
			replacement = entry
			break
		}
	}

	result := make([]string, 0, len(env)+1)
	inserted := false
	for _, entry := range env {
		if !strings.HasPrefix(entry, prefix) {
			result = append(result, entry)
			continue
		}
		if !inserted {
			result = append(result, replacement)
			inserted = true
		}
	}
	if !inserted {
		result = append(result, defaultEntry)
	}
	return result
}

func terminalColorTermIsTrueColor(value string) bool {
	normalized := strings.TrimSpace(strings.ToLower(value))
	return normalized == "truecolor" || normalized == "24bit"
}

func terminalTermIsUsable(value string) bool {
	normalized := strings.TrimSpace(strings.ToLower(value))
	return normalized != "" && normalized != "dumb"
}

func terminalProgramSupportsInlineImages(value string) bool {
	normalized := strings.TrimSpace(strings.ToLower(value))
	switch normalized {
	case "kitty", "wezterm", "ghostty":
		return true
	default:
		return false
	}
}

func terminalEnvironmentValueIsPresent(value string) bool {
	return strings.TrimSpace(value) != ""
}

func expandHomePath(path string) (string, error) {
	if path != "~" && !strings.HasPrefix(path, "~/") {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path, err
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~/")), nil
}

// resolveStartupDirectory returns a directory that exists and can be used as a
// new window's working directory. A restored window can reference a directory
// that no longer exists — a git worktree, temp build dir, or scratch checkout
// removed between sessions is common — and starting the PTY there fails with
// "chdir: no such file or directory", which previously dropped the window from
// the restore entirely. To keep every window, fall back to the nearest existing
// ancestor of the requested directory, then the home directory, then the serve
// process's own working directory.
func resolveStartupDirectory(requested string) string {
	candidate := strings.TrimSpace(requested)
	if candidate == "" {
		// No directory requested: preserve the historical behavior of
		// inheriting the serve process's working directory.
		if current, err := os.Getwd(); err == nil && directoryExists(current) {
			return current
		}
		if home, err := os.UserHomeDir(); err == nil && directoryExists(home) {
			return home
		}
		return ""
	}
	if expanded, err := expandHomePath(candidate); err == nil {
		candidate = expanded
	}
	if directoryExists(candidate) {
		return candidate
	}
	// The requested directory is gone. Walk up to the nearest existing ancestor
	// so a removed leaf directory falls back close to where the window used to
	// live, then fall back to home, then the process's own working directory.
	for candidate != "" {
		parent := filepath.Dir(candidate)
		if parent == candidate {
			break
		}
		candidate = parent
		if directoryExists(candidate) {
			return candidate
		}
	}
	if home, err := os.UserHomeDir(); err == nil && directoryExists(home) {
		return home
	}
	if current, err := os.Getwd(); err == nil && directoryExists(current) {
		return current
	}
	return ""
}

func directoryExists(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func firstShellWord(command string) string {
	if command := agentCommandNameFromProcessArgs(command); command != "" {
		return command
	}
	if command := commandNameFromShellCommand(command); command != "" {
		return command
	}
	if strings.TrimSpace(command) == "" {
		return "shell"
	}
	return cleanProcessCommandName(command)
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func makeTerminalRaw() func() {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return func() {}
	}
	state, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return func() {}
	}
	return func() {
		_ = term.Restore(int(os.Stdin.Fd()), state)
	}
}

func sendResize(session string, clientID string, width int, height int) {
	conn, err := dialSession(session)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))
	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	_ = enc.Encode(controlMessage{Role: "control", Session: session})
	_ = dec.Decode(&controlResponse{})
	_ = dec.Decode(&controlResponse{})
	_ = enc.Encode(controlMessage{
		ID:       strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:     "resize",
		ClientID: clientID,
		Width:    width,
		Height:   height,
		Session:  session,
	})
}

func socketPath(session string) (string, error) {
	dir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(session))
	return filepath.Join(dir, "monkeymux-"+hex.EncodeToString(sum[:])[:24]+".sock"), nil
}

// socketIdentity names a specific unix-socket inode so a helper can tell
// whether the path still refers to the listener it created. Go's default
// UnixListener.Close unlinks by path, so an outgoing upgrade that still
// holds the old fd will delete a replacement's freshly rebound name.
type socketIdentity struct {
	device uint64
	inode  uint64
}

func socketFileIdentity(path string) (socketIdentity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return socketIdentity{}, err
	}
	return socketInfoIdentity(info)
}

func disableUnixListenerUnlink(listener net.Listener) {
	unix, ok := listener.(*net.UnixListener)
	if !ok {
		return
	}
	unix.SetUnlinkOnClose(false)
}

func removeSocketPathIfUnchanged(path string, identity socketIdentity) {
	if identity.valid() {
		current, err := socketFileIdentity(path)
		if err != nil || current != identity {
			return
		}
		_ = os.Remove(path)
		return
	}
	removeAbandonedSessionSocket(path)
}

// removeAbandonedSessionSocket deletes a session socket only when nothing is
// accepting on it. An upgrade that rebound the path must not be unlinked by
// the outgoing helper, or the replacement is left listening on an orphaned
// inode and attach reports "not accepting connections".
func removeAbandonedSessionSocket(path string) {
	conn, err := net.DialTimeout("unix", path, 150*time.Millisecond)
	if err == nil {
		_ = conn.Close()
		return
	}
	// A timeout, permission failure, full backlog, or local resource error does
	// not prove the listener is abandoned. Only remove when the OS conclusively
	// reports a missing path or a socket with no listener.
	if errors.Is(err, os.ErrNotExist) || isStaleUnixSocketError(err) {
		_ = os.Remove(path)
	}
}

func runtimeDirectory() (string, error) {
	if dir := os.Getenv("XDG_RUNTIME_DIR"); strings.TrimSpace(dir) != "" {
		path := filepath.Join(dir, "monkeyssh", "monkeymux")
		return path, os.MkdirAll(path, 0o700)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(home, ".monkeyssh", "run")
	return path, os.MkdirAll(path, 0o700)
}

func dialSession(session string) (net.Conn, error) {
	socket, err := socketPath(session)
	if err != nil {
		return nil, err
	}
	return net.DialTimeout("unix", socket, 500*time.Millisecond)
}

func ptrWindowSnapshot(snapshot windowSnapshot) *windowSnapshot {
	return &snapshot
}

func snapshotByID(snapshots []windowSnapshot, id string) *windowSnapshot {
	for i := range snapshots {
		if snapshots[i].ID == id {
			return &snapshots[i]
		}
	}
	return nil
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "monkeymux: %v\n", err)
	os.Exit(1)
}
