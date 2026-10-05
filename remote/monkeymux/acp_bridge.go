package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	acpBridgeProtocolVersion    = 1
	acpMaxFrameBytes            = 20 * 1024 * 1024
	acpReplayEventOverheadBytes = 128
	acpReplayMaxBytes           = 40 * 1024 * 1024
	acpAdaptiveReplayMaxBytes   = 1 * 1024 * 1024
	// Tiny streaming deltas used to hit a 1,024-event cap long before the
	// memory budget, making ordinary sessions unreplayable after an app restart.
	// Charge every event for its payload plus estimated object overhead so the
	// byte budget remains the effective, bounded retention limit.
	acpReplayMaxEvents        = acpReplayMaxBytes / acpReplayEventOverheadBytes
	acpPendingReplayMaxEvents = 256
	acpPendingReplayMaxBytes  = acpReplayMaxBytes
	acpIdleTimeout            = 24 * time.Hour
	acpProviderDrainTimeout   = 2 * time.Second
	acpRequestTimeout         = 500 * time.Millisecond
	acpWaitMaxFailures        = 5
	// The live queue only has to absorb output published while the writer
	// drains the retained replay, which it reads from the bridge's own event
	// slice rather than a copy.
	acpClientLiveQueueCapacity = 1024 + 4
	// Provider requests the bridge answered as cancelled, remembered so a
	// late client response is not forwarded as a second answer.
	acpCancelledRequestMemory = 1024
	// Bounds on the frames queued for the provider's stdin. A client write
	// waits for its own frame, so the queue fills only with the -32800
	// answers to provider cancellations, which a provider that never reads
	// its input could otherwise pile up without end.
	acpProviderInputMaxFrames = 1024
	acpProviderInputMaxBytes  = acpMaxFrameBytes + 1024*1024
	acpCancelRequestMethod    = "$/cancel_request"
	acpRequestCancelledCode   = -32800
)

var acpBridgeIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

var (
	errAcpProviderInputClosed = errors.New("closed")
	errAcpProviderInputFull   = errors.New("ACP provider input queue is full")
)

// acpProviderInput is one frame queued for the provider's stdin; done, when
// set, receives the result of writing it.
type acpProviderInput struct {
	data json.RawMessage
	done chan<- error
}

// acpWireMessage is the versioned NDJSON protocol spoken over an SSH exec
// channel. Data is intentionally opaque: MonkeyMux relays it but never logs or
// writes ACP content to disk.
type acpWireMessage struct {
	Version       int             `json:"version,omitempty"`
	Type          string          `json:"type"`
	BridgeID      string          `json:"bridgeId,omitempty"`
	WindowID      string          `json:"windowId,omitempty"`
	ClientID      string          `json:"clientId,omitempty"`
	Sequence      uint64          `json:"sequence,omitempty"`
	Ack           uint64          `json:"ack,omitempty"`
	LastAck       uint64          `json:"lastAck,omitempty"`
	RetainedFrom  uint64          `json:"retainedFrom,omitempty"`
	Data          json.RawMessage `json:"data,omitempty"`
	State         string          `json:"state,omitempty"`
	CanSend       bool            `json:"canSend,omitempty"`
	Error         string          `json:"error,omitempty"`
	Command       string          `json:"command,omitempty"`
	Bridge        *acpBridgeInfo  `json:"bridge,omitempty"`
	Bridges       []acpBridgeInfo `json:"bridges,omitempty"`
	ProviderState string          `json:"providerState,omitempty"`
	ReplayMode    string          `json:"replayMode,omitempty"`
	ExitCode      *int            `json:"exitCode,omitempty"`
}

// acpBridgeInfo contains only bounded bridge/session metadata. It excludes the
// launch command, stderr, prompts, responses, and all other ACP payloads.
type acpBridgeInfo struct {
	ID             string `json:"id"`
	ProviderID     string `json:"providerId,omitempty"`
	SessionID      string `json:"sessionId,omitempty"`
	Cwd            string `json:"cwd,omitempty"`
	Provider       string `json:"provider,omitempty"`
	CommandHash    string `json:"commandHash,omitempty"`
	State          string `json:"state"`
	ClientCount    int    `json:"clientCount"`
	PendingRequest int    `json:"pendingRequestCount"`
	InFlightTurn   int    `json:"inFlightTurnCount"`
	LastActivity   int64  `json:"lastActivityUnix"`
	StartedAt      int64  `json:"startedAtUnix"`
	NextSequence   uint64 `json:"nextSequence"`
}

// acpLaunchConfig is sent once through the detached daemon's private stdin
// pipe. Keeping it out of command-line arguments avoids exposing the approved
// provider command or working directory in process listings.
type acpLaunchConfig struct {
	ProviderID string `json:"providerId,omitempty"`
	Provider   string `json:"provider"`
	Command    string `json:"command"`
	Cwd        string `json:"cwd"`
}

type acpReplayEvent struct {
	message       acpWireMessage
	bytes         int
	pendingID     string
	clientRequest bool
}

type acpBridgeClient struct {
	id       string
	conn     net.Conn
	send     chan acpWireMessage
	done     chan struct{}
	doneOnce sync.Once
	// primed is written before anything else: the hello, then the markers
	// and pending requests the attach composed. replay is the retained
	// events snapshotted at attach, of which those after replayAfter are
	// written next, before the live send queue is read.
	primed      []acpWireMessage
	replay      []acpReplayEvent
	replayAfter uint64
}

func (c *acpBridgeClient) cancel() {
	c.doneOnce.Do(func() {
		close(c.done)
		_ = c.conn.Close()
	})
}

type acpBridge struct {
	id          string
	providerID  string
	provider    string
	commandHash string
	cwd         string
	sessionID   string

	cmd   *exec.Cmd
	stdin io.WriteCloser

	mu sync.Mutex
	// providerInput holds the frames queued for stdin, which one writer
	// goroutine writes in order while providerInputWriting is set.
	providerInput        []acpProviderInput
	providerInputBytes   int
	providerInputWriting bool
	state                string
	startedAt            time.Time
	lastActivity         time.Time
	nextSequence         uint64
	replay               []acpReplayEvent
	replayBytes          int
	pendingReplayEvents  int
	pendingReplayBytes   int
	clients              map[string]*acpBridgeClient
	writerClientID       string
	pendingRequests      map[string]struct{}
	cancelledRequests    map[string]struct{}
	cancelledOrder       []string
	inFlightTurns        map[string]struct{}
	sessionSetupRequests map[string]string
	initializeRequestIDs map[string]struct{}
	initializeResult     json.RawMessage
	// replayReaders counts attach writers still draining a replay snapshot;
	// while any is active, trimming must not rewrite the shared event array.
	replayReaders        int
	providerDone         chan struct{}
	providerDoneOnce     sync.Once
	providerReapMu       sync.Mutex
	providerReapAllowed  bool
	providerReapReady    chan struct{}
	providerOutput       io.ReadCloser
	providerOutputDone   chan struct{}
	beforeClientVisible  func()
	beforePublishVisible func(acpWireMessage)
	stopOnce             sync.Once
	done                 chan struct{}
}

func acpCommand(args []string) {
	if len(args) == 0 {
		acpUsageAndExit()
	}
	switch args[0] {
	case "start":
		acpStartCommand(args[1:])
	case "attach", "connect":
		acpAttachCommand(args[1:])
	case "list":
		acpListCommand()
	case "status":
		acpStatusCommand(args[1:])
	case "wait":
		acpWaitCommand(args[1:])
	case "stop":
		acpStopCommand(args[1:])
	case "gc":
		acpGCCommand()
	case "serve":
		acpServeCommand(args[1:])
	default:
		acpUsageAndExit()
	}
}

func acpUsageAndExit() {
	fmt.Fprintln(os.Stderr, "usage: monkeymux acp start --provider LABEL --command COMMAND --cwd DIR | attach <bridge-id> | connect <bridge-id> | list | status <bridge-id> | wait <bridge-id> | stop <bridge-id> | gc")
	os.Exit(2)
}

func acpStartCommand(args []string) {
	fs := flag.NewFlagSet("acp start", flag.ExitOnError)
	providerID := fs.String("provider-id", "", "stable ACP provider id")
	provider := fs.String("provider", "", "approved provider label")
	command := fs.String("command", "", "approved ACP provider command")
	cwd := fs.String("cwd", "", "provider working directory")
	_ = fs.Parse(args)
	if fs.NArg() != 0 {
		acpUsageAndExit()
	}
	if err := validateAcpLaunch(*provider, *command, *cwd); err != nil {
		fatal(err)
	}
	if err := validateAcpProviderID(*providerID); err != nil {
		fatal(err)
	}
	id, err := newAcpBridgeID()
	if err != nil {
		fatal(errors.New("unable to allocate ACP bridge"))
	}
	exe, err := os.Executable()
	if err != nil {
		fatal(errors.New("unable to start ACP bridge"))
	}
	launch := acpLaunchConfig{
		ProviderID: *providerID,
		Provider:   *provider,
		Command:    *command,
		Cwd:        *cwd,
	}
	buildCommand := func() (*exec.Cmd, io.WriteCloser, error) {
		// #nosec G204 -- exe is os.Executable(), never provider or user input.
		cmd := exec.Command(exe, "acp", "serve", "--id", id) // nosemgrep
		stdin, err := cmd.StdinPipe()
		if err != nil {
			return nil, nil, err
		}
		cmd.Stdout = nil
		cmd.Stderr = nil
		cmd.Env = inheritedEnvironment(os.Environ())
		return cmd, stdin, nil
	}
	var started *exec.Cmd
	for _, attr := range detachedDaemonSysProcAttrs() {
		candidate, stdin, err := buildCommand()
		if err != nil {
			continue
		}
		candidate.SysProcAttr = attr
		if err := candidate.Start(); err == nil {
			if err := json.NewEncoder(stdin).Encode(launch); err == nil {
				_ = stdin.Close()
				started = candidate
				break
			}
			_ = stdin.Close()
			_ = candidate.Process.Kill()
			_ = candidate.Process.Release()
		} else {
			_ = stdin.Close()
		}
	}
	if started == nil {
		fatal(errors.New("unable to start ACP bridge"))
	}
	_ = started.Process.Release()
	deadline := time.Now().Add(socketTimeout)
	for time.Now().Before(deadline) {
		if _, err := dialAcpBridge(id); err == nil {
			printAcpJSON(acpWireMessage{
				Version:  acpBridgeProtocolVersion,
				Type:     "started",
				BridgeID: id,
			})
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	fatal(errors.New("ACP bridge did not start"))
}

func acpAttachCommand(args []string) {
	if len(args) != 1 || !validAcpBridgeID(args[0]) {
		acpUsageAndExit()
	}
	conn, err := dialAcpBridge(args[0])
	if err != nil {
		fatal(errors.New("ACP bridge is not running"))
	}
	defer conn.Close()
	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(conn, os.Stdin)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(os.Stdout, conn)
		errs <- err
	}()
	if err := <-errs; err != nil && !errors.Is(err, io.EOF) {
		fatal(errors.New("ACP bridge connection failed"))
	}
}

func acpListCommand() {
	ids, err := listAcpBridgeIDs()
	if err != nil {
		fatal(errors.New("unable to list ACP bridges"))
	}
	bridges := make([]acpBridgeInfo, 0, len(ids))
	for _, id := range ids {
		info, err := acpBridgeStatus(id)
		if err == nil {
			bridges = append(bridges, info)
		}
	}
	printAcpJSON(acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "list",
		Bridges: bridges,
	})
}

func acpStatusCommand(args []string) {
	if len(args) != 1 || !validAcpBridgeID(args[0]) {
		acpUsageAndExit()
	}
	info, err := acpBridgeStatus(args[0])
	if err != nil {
		fatal(errors.New("ACP bridge is not running"))
	}
	printAcpJSON(acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "status",
		BridgeID: args[0],
		Bridge:   &info,
	})
}

func acpWaitCommand(args []string) {
	if len(args) != 1 || !validAcpBridgeID(args[0]) {
		acpUsageAndExit()
	}
	id := args[0]
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	if err := waitForAcpBridge(id, acpBridgeStatus, ticker.C, os.Stdout); err != nil {
		fatal(err)
	}
}

func waitForAcpBridge(id string, status func(string) (acpBridgeInfo, error), ticks <-chan time.Time, output io.Writer) error {
	introduced := false
	consecutiveFailures := 0
	for {
		info, err := status(id)
		if err == nil {
			consecutiveFailures = 0
			if !introduced {
				fmt.Fprintf(output, "Native agent window: %s\r\n", info.Provider)
				fmt.Fprint(output, "Open this MonkeyMux window in MonkeySSH for the native interface.\r\n")
				fmt.Fprint(output, "The agent keeps running when this terminal disconnects.\r\n")
				introduced = true
			}
			switch info.State {
			case "exited", "stopped", "protocol_error":
				return nil
			}
		} else if isStaleUnixSocketError(err) {
			return nil
		} else if errors.Is(err, os.ErrNotExist) {
			if socket, resolveErr := acpSocketPath(id); resolveErr == nil {
				if _, statErr := os.Stat(socket); errors.Is(statErr, os.ErrNotExist) {
					return nil
				}
			}
		}
		if err != nil {
			var protocolErr *protocolFrameError
			if errors.As(err, &protocolErr) {
				return err
			}
			if !isTransientAcpStatusError(err) {
				consecutiveFailures++
				if consecutiveFailures >= acpWaitMaxFailures {
					return err
				}
			}
		}
		<-ticks
	}
}

func isTransientAcpStatusError(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EAGAIN) ||
		errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EINTR) {
		return true
	}
	// Winsock uses different errno values from Go's portable syscall constants.
	if runtime.GOOS == "windows" && (errors.Is(err, syscall.Errno(10054)) || // WSAECONNRESET
		errors.Is(err, syscall.Errno(10035)) || // WSAEWOULDBLOCK
		errors.Is(err, syscall.Errno(10004))) { // WSAEINTR
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr) && (netErr.Timeout() || netErr.Temporary())
}

// protocolFrameError distinguishes malformed frames from transport failures.
type protocolFrameError struct {
	err error
}

func (e *protocolFrameError) Error() string { return e.err.Error() }
func (e *protocolFrameError) Unwrap() error { return e.err }

func requestAcpBridgeStop(id string) error {
	conn, err := dialAcpBridge(id)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(acpRequestTimeout)); err != nil {
		return err
	}
	return writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "command",
		Command: "stop",
	})
}

func requestAcpBridgeStopAndWait(id string) error {
	socket, err := acpSocketPath(id)
	if err != nil {
		return err
	}
	if err := requestAcpBridgeStop(id); err != nil {
		// Closing a restored native window is idempotent only when its resolved
		// socket is conclusively gone or abandoned. A path-resolution failure can
		// also wrap os.ErrNotExist while the provider is still running, so resolve
		// first and verify the socket itself before discarding the placeholder.
		if isStaleUnixSocketError(err) {
			_ = os.Remove(socket)
			return nil
		}
		if errors.Is(err, os.ErrNotExist) {
			if _, statErr := os.Stat(socket); errors.Is(statErr, os.ErrNotExist) {
				return nil
			}
		}
		return err
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := acpBridgeStatus(id); err != nil {
			if isStaleUnixSocketError(err) {
				return nil
			}
			if errors.Is(err, os.ErrNotExist) {
				if _, statErr := os.Stat(socket); errors.Is(statErr, os.ErrNotExist) {
					return nil
				}
			}
			return err
		}
		time.Sleep(10 * time.Millisecond)
	}
	return errors.New("ACP bridge did not stop")
}

func acpStopCommand(args []string) {
	if len(args) != 1 || !validAcpBridgeID(args[0]) {
		acpUsageAndExit()
	}
	if err := requestAcpBridgeStop(args[0]); err != nil {
		fatal(errors.New("unable to stop ACP bridge"))
	}
	printAcpJSON(acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "stopping",
		BridgeID: args[0],
	})
}

func acpGCCommand() {
	runDir, err := runtimeDirectory()
	if err != nil {
		fatal(errors.New("unable to clean ACP bridges"))
	}
	gcAcpArtifacts(runDir)
}

func acpServeCommand(args []string) {
	fs := flag.NewFlagSet("acp serve", flag.ExitOnError)
	id := fs.String("id", "", "bridge ID")
	_ = fs.Parse(args)
	if fs.NArg() != 0 || !validAcpBridgeID(*id) {
		acpUsageAndExit()
	}
	line, err := readBoundedAcpLine(bufio.NewReader(os.Stdin))
	if err != nil {
		fatal(errors.New("unable to read ACP bridge configuration"))
	}
	var launch acpLaunchConfig
	if err := json.Unmarshal(line, &launch); err != nil {
		fatal(errors.New("unable to read ACP bridge configuration"))
	}
	if err := validateAcpLaunch(launch.Provider, launch.Command, launch.Cwd); err != nil {
		fatal(err)
	}
	if err := validateAcpProviderID(launch.ProviderID); err != nil {
		fatal(err)
	}
	bridge, err := newAcpBridge(
		*id,
		launch.ProviderID,
		launch.Provider,
		launch.Command,
		launch.Cwd,
	)
	if errors.Is(err, errCursorAgentKeychainLocked) {
		fatal(errCursorAgentKeychainLocked)
	}
	if err != nil {
		fatal(errors.New("unable to start ACP provider"))
	}
	bridge.providerID = launch.ProviderID
	if err := serveAcpBridge(bridge); err != nil {
		fatal(errors.New("ACP bridge stopped unexpectedly"))
	}
}

func validateAcpProviderID(providerID string) error {
	if len(providerID) > 128 || strings.ContainsRune(providerID, 0) {
		return errors.New("provider id is invalid")
	}
	return nil
}

func validateAcpLaunch(provider string, command string, cwd string) error {
	if strings.TrimSpace(provider) == "" || len(provider) > 128 {
		return errors.New("provider label is required")
	}
	if strings.TrimSpace(command) == "" || len(command) > 8192 || strings.ContainsRune(command, 0) {
		return errors.New("approved provider command is required")
	}
	if strings.TrimSpace(cwd) == "" || len(cwd) > 4096 || strings.ContainsRune(cwd, 0) {
		return errors.New("working directory is required")
	}
	expanded, err := expandHomePath(cwd)
	if err != nil || !directoryExists(expanded) {
		return errors.New("working directory is unavailable")
	}
	return nil
}

func newAcpBridgeID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}

func validAcpBridgeID(id string) bool {
	return acpBridgeIDPattern.MatchString(id)
}

const cursorAgentAcpProviderID = "builtin:cursor-agent-acp"

var errCursorAgentKeychainLocked = errors.New("Cursor Agent login keychain is locked")
var acpRuntimeGOOS = runtime.GOOS
var cursorAgentKeychainProbe = func() int {
	command := exec.Command(
		"/usr/bin/security",
		"find-generic-password",
		"-a", "cursor-user",
		"-s", "cursor-access-token",
		"-g",
	)
	command.Env = inheritedEnvironment(os.Environ())
	if err := command.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			return exitError.ExitCode()
		}
		return -1
	}
	return 0
}

func validateAcpProviderEnvironment(providerID string) error {
	if providerID != cursorAgentAcpProviderID || acpRuntimeGOOS != "darwin" ||
		strings.TrimSpace(os.Getenv("CURSOR_API_KEY")) != "" ||
		strings.EqualFold(strings.TrimSpace(os.Getenv("AGENT_CLI_CREDENTIAL_STORE")), "file") {
		return nil
	}
	// macOS `security` status 36 is the same lock state Cursor Agent reports.
	// Output is discarded by exec.Cmd; only this fixed numeric status is used.
	if cursorAgentKeychainProbe() == 36 {
		return errCursorAgentKeychainLocked
	}
	return nil
}

// newAcpProviderCommand uses ordinary pipes to preserve NDJSON framing.
func newAcpProviderCommand(command string) *exec.Cmd {
	return newRunCommand(command)
}

func newAcpBridge(
	id string,
	providerID string,
	provider string,
	command string,
	cwd string,
) (*acpBridge, error) {
	expandedCwd, err := expandHomePath(cwd)
	if err != nil {
		return nil, err
	}
	if err := validateAcpProviderEnvironment(providerID); err != nil {
		return nil, err
	}
	cmd := newAcpProviderCommand(command)
	cmd.Dir = expandedCwd
	cmd.Env = inheritedEnvironment(os.Environ())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, stdoutWriter, err := os.Pipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	stderrSink, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stdoutWriter.Close()
		return nil, err
	}
	cmd.Stdout = stdoutWriter
	// Provider stderr can contain prompts, paths, or tool data and must never
	// enter diagnostics or the ACP protocol stream.
	cmd.Stderr = stderrSink
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stdoutWriter.Close()
		_ = stderrSink.Close()
		return nil, err
	}
	// Cmd.Wait closes descriptors created by StdoutPipe, which can discard
	// unread tail frames. Keep ownership of the read end and close only the
	// parent's writer copy so the reader drains to a real child-process EOF.
	_ = stdoutWriter.Close()
	_ = stderrSink.Close()
	now := time.Now()
	hash := sha256.Sum256([]byte(command))
	bridge := &acpBridge{
		id:                   id,
		provider:             provider,
		commandHash:          hex.EncodeToString(hash[:]),
		cwd:                  expandedCwd,
		cmd:                  cmd,
		stdin:                stdin,
		state:                "running",
		startedAt:            now,
		lastActivity:         now,
		clients:              map[string]*acpBridgeClient{},
		pendingRequests:      map[string]struct{}{},
		inFlightTurns:        map[string]struct{}{},
		sessionSetupRequests: map[string]string{},
		providerDone:         make(chan struct{}),
		providerReapReady:    make(chan struct{}),
		providerOutput:       stdout,
		providerOutputDone:   make(chan struct{}),
		done:                 make(chan struct{}),
	}
	go func() {
		defer stdout.Close()
		defer close(bridge.providerOutputDone)
		bridge.readProviderOutput(stdout)
	}()
	go bridge.waitForProvider()
	return bridge, nil
}

func serveAcpBridge(bridge *acpBridge) error {
	// The provider is already running, so even socket setup failures must stop it.
	defer bridge.stop()
	socket, err := acpSocketPath(bridge.id)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return err
	}
	_ = os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	_ = os.Chmod(socket, 0o600)
	defer func() {
		_ = listener.Close()
		_ = os.Remove(socket)
	}()
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	go func() {
		select {
		case <-signals:
			bridge.stop()
		case <-bridge.done:
		}
		_ = listener.Close()
	}()
	// Native ACP sessions persist like MonkeyMux windows. Idle cleanup runs only
	// through an explicit `monkeymux acp gc`, never from a hidden timer.

	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-bridge.done:
				return nil
			default:
				return err
			}
		}
		go bridge.handleConnection(conn)
	}
}

func (b *acpBridge) readProviderOutput(stdout io.Reader) {
	reader := bufio.NewReader(stdout)
	for {
		raw, err := readBoundedAcpLine(reader)
		if len(raw) > 0 {
			if json.Valid(raw) {
				if !b.publish("output", raw, "", nil) {
					b.failProviderProtocol()
					return
				}
			} else {
				b.failProviderProtocol()
				return
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				b.failProviderProtocol()
			}
			return
		}
	}
}

func readBoundedAcpLine(reader *bufio.Reader) ([]byte, error) {
	return readBoundedProtocolLine(reader, acpMaxFrameBytes)
}

func readBoundedProtocolLine(reader *bufio.Reader, limit int) ([]byte, error) {
	var line []byte
	for {
		fragment, err := reader.ReadSlice('\n')
		if len(line)+len(fragment) > limit {
			// Every caller terminates this stream on an oversized frame. Draining
			// to a newline could block forever on a peer that stops sending.
			return nil, &protocolFrameError{errors.New("protocol frame exceeds limit")}
		}
		line = append(line, fragment...)
		if !errors.Is(err, bufio.ErrBufferFull) {
			line = bytes.TrimSpace(line)
			return line, err
		}
	}
}

func (b *acpBridge) waitForProvider() {
	b.awaitProviderReapReady()
	err := b.cmd.Wait()
	b.providerDoneOnce.Do(func() { close(b.providerDone) })
	b.waitForProviderOutput()
	exitCode := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exitCode = exitErr.ExitCode()
	}
	b.mu.Lock()
	if b.state != "stopped" {
		b.state = "exited"
		b.lastActivity = time.Now()
	}
	b.pendingRequests = map[string]struct{}{}
	b.cancelledRequests = nil
	b.cancelledOrder = nil
	b.inFlightTurns = map[string]struct{}{}
	b.releaseAllPendingReplayLocked()
	b.mu.Unlock()
	b.publish("state", nil, "exited", &exitCode)
}

func (b *acpBridge) awaitProviderReapReady() {
	if b.providerReapReady == nil {
		return
	}
	select {
	case <-b.providerReapReady:
		return
	case <-b.providerOutputDone:
	}

	// Output EOF usually means the wrapper exited. Keep its leader unreaped
	// until every non-zombie group member is gone, reserving the PGID while a
	// concurrent explicit stop may still need to signal surviving descendants.
	pollDelay := 50 * time.Millisecond
	pollTimer := time.NewTimer(pollDelay)
	defer pollTimer.Stop()
	for {
		live, err := acpProviderProcessGroupHasLiveMember(b.cmd)
		if err != nil {
			// If process inspection is unavailable, reaping without any later
			// group signal is safer than guessing at a recycled PGID.
			b.allowProviderReap()
			return
		}
		if !live {
			b.allowProviderReap()
			return
		}
		select {
		case <-b.providerReapReady:
			return
		case <-pollTimer.C:
			if pollDelay < time.Second {
				pollDelay *= 2
				if pollDelay > time.Second {
					pollDelay = time.Second
				}
			}
			pollTimer.Reset(pollDelay)
		}
	}
}

func (b *acpBridge) allowProviderReap() {
	b.providerReapMu.Lock()
	defer b.providerReapMu.Unlock()
	b.allowProviderReapLocked()
}

func (b *acpBridge) allowProviderReapLocked() {
	if b.providerReapAllowed || b.providerReapReady == nil {
		return
	}
	b.providerReapAllowed = true
	close(b.providerReapReady)
}

func (b *acpBridge) stopProviderProcess() {
	if b.providerReapReady == nil {
		stopAcpProvider(b.cmd, b.providerOutputDone)
		return
	}
	b.providerReapMu.Lock()
	defer b.providerReapMu.Unlock()
	if !b.providerReapAllowed {
		stopAcpProvider(b.cmd, b.providerOutputDone)
	}
	b.allowProviderReapLocked()
}

func (b *acpBridge) waitForProviderOutput() {
	if b.providerOutputDone == nil {
		return
	}
	timer := time.NewTimer(acpProviderDrainTimeout)
	defer timer.Stop()
	select {
	case <-b.providerOutputDone:
		return
	case <-timer.C:
	}
	if b.providerOutput != nil {
		_ = b.providerOutput.Close()
	}
	<-b.providerOutputDone
}

type acpEnvelope struct {
	ID     json.RawMessage `json:"id"`
	Method json.RawMessage `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
	method string
}

// acpRequestKey canonicalizes a JSON-RPC id so equivalent spellings of one
// string match while the string "1" and the number 1 stay distinct. Ids that
// are neither strings nor numbers keep their raw bytes.
func acpRequestKey(raw json.RawMessage) string {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if decoder.Decode(&value) == nil {
		switch typed := value.(type) {
		case string:
			if encoded, err := json.Marshal(typed); err == nil {
				return string(encoded)
			}
		case json.Number:
			return typed.String()
		}
	}
	return string(raw)
}

// parseAcpProviderOutput parses one provider frame. It returns the request or
// response envelope, or, for a `$/cancel_request` notification, the key of the
// provider request it withdraws.
func parseAcpProviderOutput(raw json.RawMessage) (acpEnvelope, string) {
	var envelope acpEnvelope
	if json.Unmarshal(raw, &envelope) != nil {
		return acpEnvelope{}, ""
	}
	if len(envelope.Method) > 0 {
		_ = json.Unmarshal(envelope.Method, &envelope.method)
	}
	if len(envelope.ID) > 0 && string(envelope.ID) != "null" {
		return envelope, ""
	}
	if envelope.method != acpCancelRequestMethod {
		return acpEnvelope{}, ""
	}
	var params struct {
		RequestID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(envelope.Params, &params) != nil || len(params.RequestID) == 0 ||
		string(params.RequestID) == "null" {
		return acpEnvelope{}, ""
	}
	return acpEnvelope{}, acpRequestKey(params.RequestID)
}

func parseAcpEnvelope(raw json.RawMessage) acpEnvelope {
	var envelope acpEnvelope
	if json.Unmarshal(raw, &envelope) != nil || len(envelope.ID) == 0 || string(envelope.ID) == "null" {
		return acpEnvelope{}
	}
	if len(envelope.Method) > 0 {
		_ = json.Unmarshal(envelope.Method, &envelope.method)
	}
	return envelope
}

func acpSessionID(raw json.RawMessage) string {
	var session struct {
		SessionID string `json:"sessionId"`
	}
	if json.Unmarshal(raw, &session) != nil || !validAcpSessionID(session.SessionID) {
		return ""
	}
	return session.SessionID
}

// Register requests before writing stdin: a provider can respond before Write
// returns. Only a successful setup response commits the session identity;
// failed writes release all registrations.
func (b *acpBridge) trackClientRequest(envelope acpEnvelope) (string, bool) {
	if len(envelope.ID) == 0 || len(envelope.Method) == 0 {
		return "", false
	}
	id := acpRequestKey(envelope.ID)
	b.mu.Lock()
	b.inFlightTurns[id] = struct{}{}
	if isAcpSessionSetupMethod(envelope.method) {
		b.sessionSetupRequests[id] = acpSessionID(envelope.Params)
	}
	if envelope.method == "initialize" {
		if b.initializeRequestIDs == nil {
			b.initializeRequestIDs = map[string]struct{}{}
		}
		b.initializeRequestIDs[id] = struct{}{}
	}
	b.mu.Unlock()
	return id, true
}

func (b *acpBridge) untrackClientRequest(id string) {
	b.mu.Lock()
	delete(b.inFlightTurns, id)
	delete(b.sessionSetupRequests, id)
	delete(b.initializeRequestIDs, id)
	b.mu.Unlock()
}

func (b *acpBridge) cachedInitializeResponse(envelope acpEnvelope) json.RawMessage {
	if len(envelope.ID) == 0 || envelope.method != "initialize" {
		return nil
	}
	b.mu.Lock()
	result := b.initializeResult
	b.mu.Unlock()
	if len(result) == 0 {
		return nil
	}
	response, err := json.Marshal(map[string]json.RawMessage{
		"jsonrpc": json.RawMessage(`"2.0"`),
		"id":      envelope.ID,
		"result":  result,
	})
	if err != nil {
		return nil
	}
	return response
}

func (b *acpBridge) observeClientMessage(envelope acpEnvelope) {
	if len(envelope.ID) == 0 {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(envelope.Method) == 0 {
		id := acpRequestKey(envelope.ID)
		delete(b.pendingRequests, id)
		b.releasePendingReplayLocked(id)
	}
	b.lastActivity = time.Now()
}

// claimClientResponse reports whether a client frame may reach the provider.
// A response to a provider request the bridge already answered as cancelled
// is dropped, so the provider never sees two answers. The marker stays until
// the provider reuses the id or the bounded memory evicts it: each attachment
// that resumes from before the cancel replays the request and answers it
// again. Any other response claims its request before the write, so a racing
// provider cancellation cannot also answer it.
func (b *acpBridge) claimClientResponse(envelope acpEnvelope) bool {
	if len(envelope.ID) == 0 || len(envelope.Method) > 0 {
		return true
	}
	key := acpRequestKey(envelope.ID)
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, cancelled := b.cancelledRequests[key]; cancelled {
		return false
	}
	delete(b.pendingRequests, key)
	return true
}

// cancelPendingRequestLocked handles a provider `$/cancel_request` for one of
// its own requests that no client has answered. The bridge answers it with
// -32800 on the client's behalf, because the app may be detached for a long
// time, and unpins its replay event so a reconnecting app is never shown a
// withdrawn prompt as live. The cancel notification itself is still published
// in sequence after the request, so a client resuming from before both sees
// the request and then its cancellation, and drops the prompt.
func (b *acpBridge) cancelPendingRequestLocked(key string) json.RawMessage {
	if _, pending := b.pendingRequests[key]; !pending {
		return nil
	}
	response, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(key),
		"error": map[string]any{
			"code":    acpRequestCancelledCode,
			"message": "Request cancelled",
		},
	})
	if err != nil {
		return nil
	}
	delete(b.pendingRequests, key)
	b.releasePendingReplayLocked(key)
	if b.cancelledRequests == nil {
		b.cancelledRequests = map[string]struct{}{}
	}
	if _, known := b.cancelledRequests[key]; !known {
		for len(b.cancelledOrder) >= acpCancelledRequestMemory {
			delete(b.cancelledRequests, b.cancelledOrder[0])
			b.cancelledOrder = b.cancelledOrder[1:]
		}
		b.cancelledOrder = append(b.cancelledOrder, key)
	}
	b.cancelledRequests[key] = struct{}{}
	return response
}

// forgetCancelledRequestLocked drops the cancelled marker for key and its
// eviction record. Leaving the record would let a later eviction delete the
// marker of a newer request that reused the id and was cancelled again.
func (b *acpBridge) forgetCancelledRequestLocked(key string) {
	if _, ok := b.cancelledRequests[key]; !ok {
		return
	}
	delete(b.cancelledRequests, key)
	for index, candidate := range b.cancelledOrder {
		if candidate == key {
			b.cancelledOrder = append(b.cancelledOrder[:index], b.cancelledOrder[index+1:]...)
			break
		}
	}
}

func isAcpSessionSetupMethod(method string) bool {
	switch method {
	case "session/new", "session/load", "session/resume", "session/fork":
		return true
	default:
		return false
	}
}

func validAcpSessionID(sessionID string) bool {
	return sessionID != "" && len(sessionID) <= 4096 &&
		!strings.ContainsRune(sessionID, 0)
}

func (b *acpBridge) publish(
	eventType string,
	data json.RawMessage,
	state string,
	exitCode *int,
) bool {
	pendingID := ""
	providerResponseID := ""
	cancelledID := ""
	var envelope acpEnvelope
	if eventType == "output" {
		envelope, cancelledID = parseAcpProviderOutput(data)
		if len(envelope.ID) > 0 {
			if len(envelope.Method) > 0 {
				pendingID = acpRequestKey(envelope.ID)
			} else {
				providerResponseID = acpRequestKey(envelope.ID)
			}
		}
	}
	// The event must fit the wire once wrapped and encoded, or every client,
	// and every resume from an earlier ACK, would fail on it. Checked before
	// it takes a sequence; the caller fails the provider instead.
	if !acpWireFrameFits(acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     eventType,
		BridgeID: b.id,
		Sequence: math.MaxUint64,
		Data:     data,
		State:    state,
		ExitCode: exitCode,
	}) {
		return false
	}
	messageBytes := len(data) + acpReplayEventOverheadBytes
	b.mu.Lock()
	if pendingID != "" &&
		(b.pendingReplayEvents >= acpPendingReplayMaxEvents ||
			b.pendingReplayBytes+messageBytes > acpPendingReplayMaxBytes) {
		b.mu.Unlock()
		return false
	}
	if pendingID != "" {
		b.pendingRequests[pendingID] = struct{}{}
		// A reused id names a new request; only an older one was cancelled.
		b.forgetCancelledRequestLocked(pendingID)
	}
	var cancelResponse json.RawMessage
	if cancelledID != "" {
		cancelResponse = b.cancelPendingRequestLocked(cancelledID)
	}
	if providerResponseID != "" {
		delete(b.inFlightTurns, providerResponseID)
		if _, ok := b.initializeRequestIDs[providerResponseID]; ok {
			if len(envelope.Error) == 0 && len(envelope.Result) > 0 && string(envelope.Result) != "null" {
				b.initializeResult = envelope.Result
			}
			delete(b.initializeRequestIDs, providerResponseID)
		}
		if requestedSessionID, ok := b.sessionSetupRequests[providerResponseID]; ok {
			if len(envelope.Error) == 0 && len(envelope.Result) > 0 {
				if sessionID := acpSessionID(envelope.Result); sessionID != "" {
					b.sessionID = sessionID
				} else if validAcpSessionID(requestedSessionID) {
					b.sessionID = requestedSessionID
				}
			}
			delete(b.sessionSetupRequests, providerResponseID)
		}
	}
	b.nextSequence++
	message := acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     eventType,
		BridgeID: b.id,
		Sequence: b.nextSequence,
		Data:     data,
		State:    state,
		ExitCode: exitCode,
	}
	b.appendReplayLocked(message, pendingID)
	b.lastActivity = time.Now()
	if b.beforePublishVisible != nil {
		b.beforePublishVisible(message)
	}
	detached := make([]*acpBridgeClient, 0)
	for clientID, client := range b.clients {
		if tryEnqueueAcpClient(client, message) {
			continue
		}
		delete(b.clients, clientID)
		if b.writerClientID == clientID {
			b.writerClientID = ""
		}
		detached = append(detached, client)
	}
	b.mu.Unlock()
	for _, client := range detached {
		client.cancel()
	}
	if cancelResponse != nil {
		// Never block the provider-output reader on provider stdin: a provider
		// blocked writing output while its input pipe is full would deadlock.
		// A provider that keeps cancelling without reading fills the queue
		// and fails.
		if errors.Is(b.queueProviderInput(cancelResponse, nil), errAcpProviderInputFull) {
			return false
		}
	}
	return true
}

func tryEnqueueAcpClient(client *acpBridgeClient, message acpWireMessage) bool {
	select {
	case <-client.done:
		return false
	default:
	}
	select {
	case <-client.done:
		return false
	case client.send <- message:
		return true
	default:
		return false
	}
}

func (b *acpBridge) failProviderProtocol() {
	b.mu.Lock()
	if b.state == "running" {
		b.state = "protocol_error"
		b.lastActivity = time.Now()
	}
	b.mu.Unlock()
	b.publish("state", nil, "protocol_error", nil)
	b.closeProviderInput()
	b.stopProviderProcess()
}

func (b *acpBridge) appendReplayLocked(message acpWireMessage, pendingID string) {
	size := len(message.Data) + acpReplayEventOverheadBytes
	b.replay = append(b.replay, acpReplayEvent{
		message:       message,
		bytes:         size,
		pendingID:     pendingID,
		clientRequest: pendingID != "",
	})
	b.replayBytes += size
	if pendingID != "" {
		b.pendingReplayEvents++
		b.pendingReplayBytes += size
	}
	b.trimReplayLocked()
}

func (b *acpBridge) trimReplayLocked() {
	if len(b.replay) <= acpReplayMaxEvents &&
		(b.replayBytes <= acpReplayMaxBytes || len(b.replay) <= 1) {
		return
	}
	// An attach writer still draining a snapshot of the array reads it
	// without the lock, so evicted slots are left intact and compaction goes
	// to a fresh array until it finishes.
	shared := b.replayReaders > 0
	for len(b.replay) > acpReplayMaxEvents ||
		(b.replayBytes > acpReplayMaxBytes && len(b.replay) > 1) {
		if b.replay[0].pendingID != "" {
			break
		}
		b.replayBytes -= b.replay[0].bytes
		if !shared {
			b.replay[0] = acpReplayEvent{}
		}
		b.replay = b.replay[1:]
	}
	if len(b.replay) <= acpReplayMaxEvents &&
		(b.replayBytes <= acpReplayMaxBytes || len(b.replay) <= 1) {
		return
	}
	remainingEvents := len(b.replay)
	retained := b.replay
	if shared {
		retained = make([]acpReplayEvent, len(b.replay))
	}
	kept := 0
	for _, event := range b.replay {
		// Leave room for streaming appends before another pinned compaction.
		overLimit := remainingEvents > acpReplayMaxEvents*7/8 ||
			(b.replayBytes > acpReplayMaxBytes*7/8 && remainingEvents > 1)
		// Unresolved provider requests must survive detachment verbatim.
		if overLimit && event.pendingID == "" {
			remainingEvents--
			b.replayBytes -= event.bytes
			continue
		}
		retained[kept] = event
		kept++
	}
	// Reuse the event array without retaining evicted payloads in its tail.
	clear(retained[kept:])
	b.replay = retained[:kept]
}

func (b *acpBridge) releasePendingReplayLocked(id string) {
	for index := range b.replay {
		if b.replay[index].pendingID == id {
			b.pendingReplayEvents--
			b.pendingReplayBytes -= b.replay[index].bytes
			b.replay[index].pendingID = ""
		}
	}
	b.trimReplayLocked()
}

func (b *acpBridge) releaseAllPendingReplayLocked() {
	for index := range b.replay {
		if b.replay[index].pendingID == "" {
			continue
		}
		b.replay[index].pendingID = ""
	}
	b.pendingReplayEvents = 0
	b.pendingReplayBytes = 0
	b.trimReplayLocked()
}

func (b *acpBridge) handleConnection(conn net.Conn) {
	defer conn.Close()
	if err := conn.SetReadDeadline(time.Now().Add(socketTimeout)); err != nil {
		return
	}
	reader := bufio.NewReader(conn)
	first, err := readAcpWireFrame(reader)
	if err != nil {
		return
	}
	if err := conn.SetReadDeadline(time.Time{}); err != nil {
		return
	}
	if first.Type == "command" {
		b.handleCommand(conn, first)
		return
	}
	if first.Type != "hello" || first.Version != acpBridgeProtocolVersion ||
		(first.BridgeID != "" && first.BridgeID != b.id) {
		_ = writeAcpWireFrame(conn, acpWireMessage{
			Version: acpBridgeProtocolVersion,
			Type:    "error",
			Error:   "unsupported ACP bridge protocol",
		})
		return
	}
	b.handleAttach(conn, reader, first)
}

func (b *acpBridge) handleCommand(conn net.Conn, message acpWireMessage) {
	switch message.Command {
	case "status":
		info := b.snapshot()
		_ = writeAcpWireFrame(conn, acpWireMessage{
			Version: acpBridgeProtocolVersion,
			Type:    "status",
			Bridge:  &info,
		})
	case "gc":
		if b.shouldIdleShutdown(time.Now()) {
			b.stop()
		}
	case "stop":
		_ = writeAcpWireFrame(conn, acpWireMessage{
			Version:  acpBridgeProtocolVersion,
			Type:     "stopping",
			BridgeID: b.id,
		})
		b.stop()
	default:
		_ = writeAcpWireFrame(conn, acpWireMessage{
			Version: acpBridgeProtocolVersion,
			Type:    "error",
			Error:   "unknown ACP bridge command",
		})
	}
}

func (b *acpBridge) handleAttach(
	conn net.Conn,
	reader *bufio.Reader,
	hello acpWireMessage,
) {
	clientID, err := newAcpBridgeID()
	if err != nil {
		return
	}
	b.mu.Lock()
	// A connection accepted before stop may not send its hello until afterward.
	// Pair registration with stop's state transition under the same lock.
	if b.state == "stopped" {
		b.mu.Unlock()
		return
	}
	if b.writerClientID == "" {
		b.writerClientID = clientID
	}
	canSend := b.writerClientID == clientID
	b.lastActivity = time.Now()
	replay := b.replay
	retainedFrom := b.nextSequence + 1
	if len(replay) > 0 {
		retainedFrom = replay[0].message.Sequence
	}
	snapshot := b.snapshotLocked()
	snapshot.ClientCount++
	replayIncomplete := hello.LastAck+1 < retainedFrom ||
		replayHasGap(replay, hello.LastAck, b.nextSequence)
	replayMode := replayModeForAttach(
		hello,
		b.replayBytes,
		replayIncomplete,
		replayContainsClientRequest(replay),
	)
	pendingOnly := replayMode == "pending"
	primed := []acpWireMessage{{
		Version:    acpBridgeProtocolVersion,
		Type:       "hello",
		BridgeID:   b.id,
		ClientID:   clientID,
		CanSend:    canSend,
		Bridge:     &snapshot,
		ReplayMode: replayMode,
	}}
	if pendingOnly {
		// A fresh native view rebuilds transcript history with session/load.
		// Replaying up to 40 MiB of superseded responses first delays that
		// request behind stale bytes. Preserve only unresolved provider requests
		// (notably permissions), delivered outside the live sequence baseline.
		for _, event := range replay {
			if event.pendingID == "" || event.message.Type != "output" {
				continue
			}
			primed = append(primed, acpWireMessage{
				Version:  acpBridgeProtocolVersion,
				Type:     "pending",
				BridgeID: b.id,
				Data:     event.message.Data,
			})
		}
		// The client commits and ACKs the high-water baseline only after this
		// marker. A disconnect before it causes a new pending-only attach, so no
		// unresolved request can disappear between hello and delivery.
		primed = append(primed, acpWireMessage{
			Version:    acpBridgeProtocolVersion,
			Type:       "replay_end",
			BridgeID:   b.id,
			ReplayMode: "pending",
		})
	} else {
		if replayIncomplete {
			primed = append(primed, acpWireMessage{
				Version:      acpBridgeProtocolVersion,
				Type:         "overflow",
				BridgeID:     b.id,
				RetainedFrom: retainedFrom,
			})
		}
	}
	client := &acpBridgeClient{
		id:     clientID,
		conn:   conn,
		send:   make(chan acpWireMessage, acpClientLiveQueueCapacity),
		done:   make(chan struct{}),
		primed: primed,
	}
	if !pendingOnly {
		// The writer reads the retained events straight from this snapshot:
		// publish appends only beyond its length, and trimReplayLocked leaves
		// its array untouched while replayReaders counts it, so nothing is
		// copied under the lock however large the backlog is. Events
		// published from here on reach the client through send, after it.
		client.replay = replay
		client.replayAfter = hello.LastAck
		if replay != nil {
			// writeClientReplay releases the hold only for a non-nil
			// snapshot; an attach before any provider output has nothing
			// to drain and must not pin the replay for the bridge lifetime.
			b.replayReaders++
		}
	}
	if b.beforeClientVisible != nil {
		b.beforeClientVisible()
	}
	b.clients[clientID] = client
	b.mu.Unlock()
	go b.writeClient(client)

	for {
		message, err := readAcpWireFrame(reader)
		if err != nil {
			b.detachClient(clientID)
			return
		}

		if message.Version != acpBridgeProtocolVersion {
			b.enqueue(client, acpWireMessage{
				Version: acpBridgeProtocolVersion,
				Type:    "error",
				Error:   "unsupported ACP bridge protocol",
			})
			continue
		}
		switch message.Type {
		case "ack":
			b.recordAck(clientID, message.Ack)
		case "input":
			if !b.clientCanSend(clientID) {
				b.enqueue(client, acpWireMessage{
					Version: acpBridgeProtocolVersion,
					Type:    "error",
					Error:   "ACP bridge is attached by another writer",
				})
				continue
			}
			if len(message.Data) == 0 || len(message.Data) > acpMaxFrameBytes ||
				!json.Valid(message.Data) {
				b.enqueue(client, acpWireMessage{
					Version: acpBridgeProtocolVersion,
					Type:    "error",
					Error:   "invalid ACP input frame",
				})
				continue
			}
			envelope := parseAcpEnvelope(message.Data)
			if response := b.cachedInitializeResponse(envelope); len(response) > 0 {
				b.publish("output", response, "", nil)
				continue
			}
			if !b.claimClientResponse(envelope) {
				// The provider already received -32800 for this request.
				b.observeClientMessage(envelope)
				continue
			}
			requestID, trackedRequest := b.trackClientRequest(envelope)
			if err := b.writeProvider(message.Data); err != nil {
				if trackedRequest {
					b.untrackClientRequest(requestID)
				}
				b.enqueue(client, acpWireMessage{
					Version: acpBridgeProtocolVersion,
					Type:    "error",
					Error:   "ACP provider is unavailable",
				})
				continue
			}
			b.observeClientMessage(envelope)
		case "status":
			info := b.snapshot()
			b.enqueue(client, acpWireMessage{
				Version: acpBridgeProtocolVersion,
				Type:    "status",
				Bridge:  &info,
			})
		default:
			b.enqueue(client, acpWireMessage{
				Version: acpBridgeProtocolVersion,
				Type:    "error",
				Error:   "unknown ACP bridge message",
			})
		}
	}
}

func replayModeForAttach(
	hello acpWireMessage,
	replayBytes int,
	replayIncomplete bool,
	containsClientRequest bool,
) string {
	if hello.LastAck != 0 {
		return ""
	}
	if hello.ReplayMode == "pending" {
		return "pending"
	}
	if hello.ReplayMode != "adaptive" {
		return ""
	}
	if replayBytes > acpAdaptiveReplayMaxBytes || replayIncomplete || containsClientRequest {
		return "pending"
	}
	return "direct"
}

func replayContainsClientRequest(replay []acpReplayEvent) bool {
	for _, event := range replay {
		if event.clientRequest {
			return true
		}
	}
	return false
}

func replayHasGap(replay []acpReplayEvent, after uint64, highWater uint64) bool {
	if after >= highWater {
		return false
	}
	expected := after + 1
	for _, event := range replay {
		if event.message.Sequence <= after {
			continue
		}
		if event.message.Sequence != expected {
			return true
		}
		expected++
	}
	return expected != highWater+1
}

func (b *acpBridge) writeClient(client *acpBridgeClient) {
	if !b.writeClientReplay(client) {
		return
	}
	for {
		// Prefer cancellation when both it and a queued message are ready. This
		// avoids retaining a writer goroutine for a disconnected idle client.
		select {
		case <-client.done:
			return
		default:
		}
		var message acpWireMessage
		select {
		case <-client.done:
			return
		case message = <-client.send:
		}
		if err := writeAcpWireFrame(client.conn, message); err != nil {
			b.detachClient(client.id)
			return
		}
	}
}

// writeClientReplay writes the attach's primed messages and the retained
// replay snapshot, releasing the snapshot's hold on the event array when done.
// It reports false once the client is cancelled or its connection failed.
func (b *acpBridge) writeClientReplay(client *acpBridgeClient) bool {
	replay := client.replay
	client.replay = nil
	if replay != nil {
		defer func() {
			b.mu.Lock()
			b.replayReaders--
			b.mu.Unlock()
		}()
	}
	write := func(message acpWireMessage) bool {
		select {
		case <-client.done:
			return false
		default:
		}
		if err := writeAcpWireFrame(client.conn, message); err != nil {
			b.detachClient(client.id)
			return false
		}
		return true
	}
	for _, message := range client.primed {
		if !write(message) {
			return false
		}
	}
	client.primed = nil
	for index := range replay {
		if replay[index].message.Sequence <= client.replayAfter {
			continue
		}
		if !write(replay[index].message) {
			return false
		}
	}
	return true
}

func (b *acpBridge) enqueue(client *acpBridgeClient, message acpWireMessage) {
	b.mu.Lock()
	current, attached := b.clients[client.id]
	b.mu.Unlock()
	if !attached || current != client {
		return
	}
	if !tryEnqueueAcpClient(client, message) {
		// A slow SSH client can reconnect and resume from its last ACK.
		b.detachClient(client.id)
	}
}

func (b *acpBridge) detachClient(clientID string) {
	b.mu.Lock()
	client, ok := b.clients[clientID]
	if ok {
		delete(b.clients, clientID)
		if b.writerClientID == clientID {
			b.writerClientID = ""
		}
		b.lastActivity = time.Now()
	}
	b.mu.Unlock()
	if ok {
		client.cancel()
	}
}

func (b *acpBridge) clientCanSend(clientID string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, attached := b.clients[clientID]; !attached {
		return false
	}
	if b.writerClientID == "" {
		b.writerClientID = clientID
	}
	return b.writerClientID == clientID
}

func (b *acpBridge) recordAck(clientID string, sequence uint64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.clients[clientID]; ok && sequence <= b.nextSequence {
		b.lastActivity = time.Now()
	}
}

// writeProvider writes one frame to the provider's stdin, in order behind any
// queued frame, and returns the result.
func (b *acpBridge) writeProvider(data json.RawMessage) error {
	done := make(chan error, 1)
	if err := b.queueProviderInput(data, done); err != nil {
		return err
	}
	return <-done
}

// queueProviderInput queues data for the provider's stdin and starts the
// writer if it is idle. done, when set, receives the write's result.
func (b *acpBridge) queueProviderInput(data json.RawMessage, done chan<- error) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stdin == nil {
		return errAcpProviderInputClosed
	}
	if len(b.providerInput) >= acpProviderInputMaxFrames ||
		b.providerInputBytes+len(data)+1 > acpProviderInputMaxBytes {
		return errAcpProviderInputFull
	}
	b.providerInput = append(b.providerInput, acpProviderInput{data: data, done: done})
	b.providerInputBytes += len(data) + 1
	if !b.providerInputWriting {
		b.providerInputWriting = true
		go b.writeProviderInput()
	}
	return nil
}

// writeProviderInput is the provider's single stdin writer. It writes the
// queued frames in order and exits once the queue is empty.
func (b *acpBridge) writeProviderInput() {
	for {
		b.mu.Lock()
		if len(b.providerInput) == 0 {
			b.providerInputWriting = false
			b.mu.Unlock()
			return
		}
		frame := b.providerInput[0]
		b.providerInput[0] = acpProviderInput{}
		b.providerInput = b.providerInput[1:]
		b.providerInputBytes -= len(frame.data) + 1
		stdin := b.stdin
		b.mu.Unlock()
		err := errAcpProviderInputClosed
		if stdin != nil {
			if _, err = stdin.Write(frame.data); err == nil {
				_, err = stdin.Write([]byte{'\n'})
			}
		}
		if frame.done != nil {
			frame.done <- err
		}
	}
}

func (b *acpBridge) snapshot() acpBridgeInfo {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.snapshotLocked()
}

func (b *acpBridge) snapshotLocked() acpBridgeInfo {
	return acpBridgeInfo{
		ID:             b.id,
		ProviderID:     b.providerID,
		SessionID:      b.sessionID,
		Cwd:            b.cwd,
		Provider:       b.provider,
		CommandHash:    b.commandHash,
		State:          b.state,
		ClientCount:    len(b.clients),
		PendingRequest: len(b.pendingRequests),
		InFlightTurn:   len(b.inFlightTurns),
		LastActivity:   b.lastActivity.Unix(),
		StartedAt:      b.startedAt.Unix(),
		NextSequence:   b.nextSequence,
	}
}

func (b *acpBridge) shouldIdleShutdown(now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.clients) == 0 && len(b.pendingRequests) == 0 &&
		len(b.inFlightTurns) == 0 && now.Sub(b.lastActivity) >= acpIdleTimeout
}

func (b *acpBridge) stop() {
	b.stopOnce.Do(func() {
		b.mu.Lock()
		b.state = "stopped"
		b.lastActivity = time.Now()
		clients := make([]*acpBridgeClient, 0, len(b.clients))
		for _, client := range b.clients {
			clients = append(clients, client)
		}
		b.clients = map[string]*acpBridgeClient{}
		b.mu.Unlock()
		b.closeProviderInput()
		b.stopProviderProcess()
		close(b.done)
		for _, client := range clients {
			client.cancel()
		}
	})
}

// closeProviderInput closes stdin, which interrupts a blocked write, and fails
// every frame still queued behind it.
func (b *acpBridge) closeProviderInput() {
	b.mu.Lock()
	stdin := b.stdin
	b.stdin = nil
	queued := b.providerInput
	b.providerInput = nil
	b.providerInputBytes = 0
	b.mu.Unlock()
	if stdin != nil {
		_ = stdin.Close()
	}
	for _, frame := range queued {
		if frame.done != nil {
			frame.done <- errAcpProviderInputClosed
		}
	}
}

func acpSocketPath(id string) (string, error) {
	if !validAcpBridgeID(id) {
		return "", errors.New("invalid bridge ID")
	}
	dir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "monkeymux-acp-"+id+".sock"), nil
}

func dialAcpBridge(id string) (net.Conn, error) {
	path, err := acpSocketPath(id)
	if err != nil {
		return nil, err
	}
	return net.DialTimeout("unix", path, acpRequestTimeout)
}

func listAcpBridgeIDs() ([]string, error) {
	dir, err := runtimeDirectory()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0)
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "monkeymux-acp-") ||
			!strings.HasSuffix(name, ".sock") {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(name, "monkeymux-acp-"), ".sock")
		if validAcpBridgeID(id) {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids, nil
}

func acpBridgeStatus(id string) (acpBridgeInfo, error) {
	conn, err := dialAcpBridge(id)
	if err != nil {
		return acpBridgeInfo{}, err
	}
	defer conn.Close()
	return acpBridgeStatusFromConn(conn)
}

func acpBridgeStatusFromConn(conn net.Conn) (acpBridgeInfo, error) {
	if err := conn.SetDeadline(time.Now().Add(acpRequestTimeout)); err != nil {
		return acpBridgeInfo{}, err
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "command",
		Command: "status",
	}); err != nil {
		return acpBridgeInfo{}, err
	}
	message, err := readAcpWireFrame(bufio.NewReader(conn))
	if err != nil {
		return acpBridgeInfo{}, fmt.Errorf("invalid status response: %w", err)
	}
	if message.Type != "status" || message.Version != acpBridgeProtocolVersion || message.Bridge == nil {
		return acpBridgeInfo{}, &protocolFrameError{errors.New("invalid status response")}
	}
	return *message.Bridge, nil
}

func gcAcpArtifacts(runDir string) {
	gcAcpArtifactsWithSocketIdentity(runDir, socketFileIdentity)
}

func gcAcpArtifactsWithSocketIdentity(runDir string, identify func(string) (socketIdentity, error)) {
	entries, err := os.ReadDir(runDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "monkeymux-acp-") ||
			!strings.HasSuffix(name, ".sock") {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(name, "monkeymux-acp-"), ".sock")
		path := filepath.Join(runDir, name)
		if !validAcpBridgeID(id) {
			_ = os.Remove(path)
			continue
		}
		identity, _ := identify(path)
		conn, err := dialAcpBridge(id)
		if err != nil {
			if isStaleUnixSocketError(err) {
				removeSocketPathIfUnchanged(path, identity)
			}
			continue
		}
		_ = conn.SetDeadline(time.Now().Add(acpRequestTimeout))
		_ = writeAcpWireFrame(conn, acpWireMessage{
			Version: acpBridgeProtocolVersion,
			Type:    "command",
			Command: "gc",
		})
		_ = conn.Close()
	}
}

func readAcpWireFrame(reader *bufio.Reader) (acpWireMessage, error) {
	line, err := readBoundedAcpLine(reader)
	if err != nil {
		return acpWireMessage{}, err
	}
	if len(line) == 0 {
		return acpWireMessage{}, &protocolFrameError{errors.New("empty ACP bridge frame")}
	}
	var message acpWireMessage
	if err := json.Unmarshal(line, &message); err != nil {
		return acpWireMessage{}, &protocolFrameError{err}
	}
	return message, nil
}

// acpWireFrameFits reports whether message stays within the wire limit once
// written. Encoding compacts the opaque data but escapes <, > and & to six
// bytes each (U+2028 and U+2029 to twice their size), so data under an eighth
// of the limit always fits and only larger frames are encoded to check.
func acpWireFrameFits(message acpWireMessage) bool {
	if len(message.Data) < acpMaxFrameBytes/8 {
		return true
	}
	data, err := json.Marshal(message)
	return err == nil && len(data)+1 <= acpMaxFrameBytes
}

func writeAcpWireFrame(writer io.Writer, message acpWireMessage) error {
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	if len(data)+1 > acpMaxFrameBytes {
		return errors.New("ACP bridge frame exceeds limit")
	}
	_, err = writer.Write(append(data, '\n'))
	return err
}

func printAcpJSON(message acpWireMessage) {
	_ = writeAcpWireFrame(os.Stdout, message)
}
