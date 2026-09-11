//go:build !windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/creack/pty"
)

func assertInputActions(t *testing.T, routing attachInputRouting, want []attachInputAction) {
	t.Helper()
	if !reflect.DeepEqual(routing.actions, want) {
		t.Fatalf("input actions = %#v, want %#v", routing.actions, want)
	}
	claimsFocus := false
	for _, action := range want {
		claimsFocus = claimsFocus || action.userInput
	}
	if routing.claimsFocus != claimsFocus {
		t.Fatalf("claims focus = %v, want %v", routing.claimsFocus, claimsFocus)
	}
}

func replayPrefixForTest(window *muxWindow) string {
	return activeWindowReplayPrefix + string(terminalTitleReplaySequence(window))
}

func replayPostHistorySuffixForTest(cursorVisible bool) string {
	return terminalParserResetSequence + terminalCharacterSetResetSequence +
		cursorVisibilityReplaySequence(cursorVisible)
}

// orderRecordingPty is a write-only muxPty that appends "hint-write" to a shared
// event log on every Write, so a test can assert the theme hint reaches the pty
// before the synthetic redraw dance runs.
type orderRecordingPty struct {
	mu  *sync.Mutex
	log *[]string
}

func (p *orderRecordingPty) Read([]byte) (int, error) { return 0, io.EOF }

func (p *orderRecordingPty) Write(b []byte) (int, error) {
	p.mu.Lock()
	*p.log = append(*p.log, "hint-write")
	p.mu.Unlock()
	return len(b), nil
}

func (p *orderRecordingPty) Close() error          { return nil }
func (p *orderRecordingPty) Resize(int, int) error { return nil }
func (p *orderRecordingPty) Fd() uintptr           { return 0 }

func synchronizedTerminalOutputForTest(data string) string {
	return terminalSynchronizedOutputBegin + data + terminalSynchronizedOutputEnd
}

func synchronizedTerminalOutputAfterPrefixForTest(
	prefix string,
	data string,
) string {
	return prefix + synchronizedTerminalOutputForTest(data)
}

func openTestPty(t *testing.T) muxPty {
	t.Helper()
	ptmx, tty, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	wrapped := &unixPty{file: ptmx}
	t.Cleanup(func() {
		_ = wrapped.Close()
		_ = tty.Close()
	})
	return wrapped
}

// wrapPty adapts a raw *os.File (typically an os.Pipe writer) to the muxPty
// interface used by muxWindow in tests, and takes ownership of closing it.
//
// The wrapper's mutex and closed flag are what make a resize safe against a
// concurrent close, so the file must never be closed directly: a redraw pause
// leaves a resize timer pending for foregroundRedrawResizeDelay, and that timer
// can fire after the test that armed it has finished. Closing the raw file
// bypasses the guard and races the timer's ioctl; closing through the wrapper
// makes the late resize a no-op instead.
func wrapPty(t *testing.T, file *os.File) muxPty {
	t.Helper()
	wrapped := &unixPty{file: file}
	t.Cleanup(func() {
		_ = wrapped.Close()
	})
	return wrapped
}

// ptyFile extracts the underlying *os.File from a test muxPty for direct pty
// ioctls in assertions.
func ptyFile(t *testing.T, p muxPty) *os.File {
	t.Helper()
	up, ok := p.(*unixPty)
	if !ok {
		t.Fatalf("pty %T is not a *unixPty", p)
	}
	return up.file
}

func assertPtySize(t *testing.T, p muxPty, columns int, rows int) {
	t.Helper()
	file := ptyFile(t, p)
	size, err := pty.GetsizeFull(file)
	if err != nil {
		t.Fatal(err)
	}
	if int(size.Cols) != columns || int(size.Rows) != rows {
		t.Fatalf(
			"pty size = %dx%d, want %dx%d",
			size.Cols,
			size.Rows,
			columns,
			rows,
		)
	}
}

func assertPtySizeEventually(t *testing.T, p muxPty, columns int, rows int) {
	t.Helper()
	file := ptyFile(t, p)
	deadline := time.Now().Add(250 * time.Millisecond)
	var lastSize *pty.Winsize
	var lastErr error
	for time.Now().Before(deadline) {
		size, err := pty.GetsizeFull(file)
		if err == nil && int(size.Cols) == columns && int(size.Rows) == rows {
			return
		}
		lastSize = size
		lastErr = err
		time.Sleep(5 * time.Millisecond)
	}
	if lastErr != nil {
		t.Fatal(lastErr)
	}
	if lastSize == nil {
		t.Fatalf("pty size unavailable, want %dx%d", columns, rows)
	}
	t.Fatalf(
		"pty size = %dx%d, want %dx%d",
		lastSize.Cols,
		lastSize.Rows,
		columns,
		rows,
	)
}

func setPtySize(t *testing.T, p muxPty, columns int, rows int) {
	t.Helper()
	file := ptyFile(t, p)
	if err := pty.Setsize(file, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(columns),
	}); err != nil {
		t.Fatal(err)
	}
}

func TestInheritedEnvironmentPassesThroughLaunchEnvironment(t *testing.T) {
	base := []string{
		"PATH=/custom/bin:/usr/bin",
		"TERM=screen-256color",
		"COLORTERM=24bit",
		"SHELL=/bin/zsh",
		"EMPTY=",
		"PATH=/second-path-entry",
	}

	env := inheritedEnvironment(base)

	if !reflect.DeepEqual(env, base) {
		t.Fatalf("environment = %#v, want exact pass-through %#v", env, base)
	}
	env[0] = "PATH=/changed"
	if base[0] == env[0] {
		t.Fatal("inherited environment aliases source slice")
	}
}

func TestInheritedEnvironmentDoesNotAddMissingValues(t *testing.T) {
	env := inheritedEnvironment([]string{"USER=test"})

	if !reflect.DeepEqual(env, []string{"USER=test"}) {
		t.Fatalf("environment = %#v, want no synthesized values", env)
	}
}

func TestTerminalEnvironmentAddsTerminalCapabilityDefaults(t *testing.T) {
	base := []string{"USER=test"}

	env := terminalEnvironment(base)

	if !slices.Contains(env, "TERM=xterm-256color") {
		t.Fatalf("terminal environment = %#v, want TERM=xterm-256color", env)
	}
	if !slices.Contains(env, "COLORTERM=truecolor") {
		t.Fatalf("terminal environment = %#v, want COLORTERM=truecolor", env)
	}
	if !slices.Contains(env, "TERM_PROGRAM=kitty") {
		t.Fatalf("terminal environment = %#v, want TERM_PROGRAM=kitty", env)
	}
	if !slices.Contains(env, "KITTY_WINDOW_ID=1") {
		t.Fatalf("terminal environment = %#v, want KITTY_WINDOW_ID=1", env)
	}
	if !slices.Contains(env, "FORCE_HYPERLINK=1") {
		t.Fatalf("terminal environment = %#v, want FORCE_HYPERLINK=1", env)
	}
	if !reflect.DeepEqual(base, []string{"USER=test"}) {
		t.Fatalf("terminal environment mutated base = %#v", base)
	}
}

func TestTerminalEnvironmentPreservesExistingForceHyperlink(t *testing.T) {
	env := terminalEnvironment([]string{"FORCE_HYPERLINK=0", "USER=test"})

	if !slices.Contains(env, "FORCE_HYPERLINK=0") {
		t.Fatalf(
			"terminal environment = %#v, want existing FORCE_HYPERLINK=0 preserved",
			env,
		)
	}
}

func TestTerminalEnvironmentPreservesExistingTrueColorHints(t *testing.T) {
	base := []string{
		"TERM=screen-256color",
		"COLORTERM=24bit",
		"USER=test",
	}

	env := terminalEnvironment(base)

	if !slices.Contains(env, "TERM=screen-256color") {
		t.Fatalf("terminal environment = %#v, want existing TERM preserved", env)
	}
	if !slices.Contains(env, "COLORTERM=24bit") {
		t.Fatalf("terminal environment = %#v, want existing COLORTERM preserved", env)
	}
	if !slices.Contains(env, "TERM_PROGRAM=kitty") {
		t.Fatalf("terminal environment = %#v, want TERM_PROGRAM=kitty", env)
	}
	if !slices.Contains(env, "KITTY_WINDOW_ID=1") {
		t.Fatalf("terminal environment = %#v, want KITTY_WINDOW_ID=1", env)
	}
}

func TestTerminalEnvironmentReplacesUnusableTerminalHints(t *testing.T) {
	env := terminalEnvironment([]string{
		"TERM=dumb",
		"COLORTERM=color",
		"USER=test",
		"TERM=",
		"COLORTERM=maybe",
	})

	if got := envValues(env, "TERM"); !reflect.DeepEqual(got, []string{"xterm-256color"}) {
		t.Fatalf("TERM values = %#v in %#v, want only xterm-256color", got, env)
	}
	if got := envValues(env, "COLORTERM"); !reflect.DeepEqual(got, []string{"truecolor"}) {
		t.Fatalf("COLORTERM values = %#v in %#v, want only truecolor", got, env)
	}
	if got := envValues(env, "TERM_PROGRAM"); !reflect.DeepEqual(got, []string{"kitty"}) {
		t.Fatalf("TERM_PROGRAM values = %#v in %#v, want only kitty", got, env)
	}
	if got := envValues(env, "KITTY_WINDOW_ID"); !reflect.DeepEqual(got, []string{"1"}) {
		t.Fatalf("KITTY_WINDOW_ID values = %#v in %#v, want only 1", got, env)
	}
	if !slices.Contains(env, "USER=test") {
		t.Fatalf("terminal environment = %#v, want USER preserved", env)
	}
}

func TestTerminalEnvironmentKeepsExistingUsableTerminalHints(t *testing.T) {
	env := terminalEnvironment([]string{
		"TERM=dumb",
		"TERM=xterm-ghostty",
		"COLORTERM=color",
		"COLORTERM=24bit",
		"USER=test",
	})

	if got := envValues(env, "TERM"); !reflect.DeepEqual(got, []string{"xterm-ghostty"}) {
		t.Fatalf("TERM values = %#v in %#v, want only xterm-ghostty", got, env)
	}
	if got := envValues(env, "COLORTERM"); !reflect.DeepEqual(got, []string{"24bit"}) {
		t.Fatalf("COLORTERM values = %#v in %#v, want only 24bit", got, env)
	}
	if got := envValues(env, "TERM_PROGRAM"); !reflect.DeepEqual(got, []string{"kitty"}) {
		t.Fatalf("TERM_PROGRAM values = %#v in %#v, want only kitty", got, env)
	}
	if got := envValues(env, "KITTY_WINDOW_ID"); !reflect.DeepEqual(got, []string{"1"}) {
		t.Fatalf("KITTY_WINDOW_ID values = %#v in %#v, want only 1", got, env)
	}
}

func TestTerminalEnvironmentPreservesExistingKittyCompatibleHints(t *testing.T) {
	env := terminalEnvironment([]string{
		"TERM_PROGRAM=WezTerm",
		"KITTY_WINDOW_ID=99",
		"USER=test",
	})

	if got := envValues(env, "TERM_PROGRAM"); !reflect.DeepEqual(got, []string{"WezTerm"}) {
		t.Fatalf("TERM_PROGRAM values = %#v in %#v, want existing WezTerm", got, env)
	}
	if got := envValues(env, "KITTY_WINDOW_ID"); !reflect.DeepEqual(got, []string{"99"}) {
		t.Fatalf("KITTY_WINDOW_ID values = %#v in %#v, want existing 99", got, env)
	}
}

func TestExpandHomePath(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	expanded, err := expandHomePath("~/Code/flutty")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, "Code/flutty"); expanded != want {
		t.Fatalf("expanded path = %q, want %q", expanded, want)
	}

	unchanged, err := expandHomePath("~other/project")
	if err != nil {
		t.Fatal(err)
	}
	if unchanged != "~other/project" {
		t.Fatalf("non-current-user expansion = %q", unchanged)
	}
}

func TestShellCommandUsesLoginShell(t *testing.T) {
	cmd := shellCommand("/bin/zsh")

	if got := cmd.Path; got != "/bin/zsh" {
		t.Fatalf("path = %q, want shell path", got)
	}
	if got := cmd.Args[0]; got != "-zsh" {
		t.Fatalf("argv0 = %q, want login shell argv0", got)
	}
}

func TestShellCommandForScriptUsesInteractiveLoginShellWithoutTypingCommand(t *testing.T) {
	cmd := shellCommandForScript("/bin/zsh", "codex --yolo")

	if got := cmd.Path; got != "/bin/zsh" {
		t.Fatalf("path = %q, want shell path", got)
	}
	if got := cmd.Args[0]; got != "-zsh" {
		t.Fatalf("argv0 = %q, want login shell argv0", got)
	}
	if got := cmd.Args[1]; got != "-i" {
		t.Fatalf("shell interactive flag = %q, want -i", got)
	}
	if got := cmd.Args[2]; got != "-c" {
		t.Fatalf("shell command flag = %q, want -c", got)
	}
	if got := cmd.Args[3]; got != "codex --yolo" {
		t.Fatalf("script = %q, want launch command", got)
	}
}

func envValues(env []string, key string) []string {
	prefix := key + "="
	values := []string{}
	for _, candidate := range env {
		if strings.HasPrefix(candidate, prefix) {
			values = append(values, strings.TrimPrefix(candidate, prefix))
		}
	}
	return values
}

func TestDefaultShellPathFallsBackToSh(t *testing.T) {
	t.Setenv("SHELL", "")

	if got := defaultShellPath(); got != "/bin/sh" {
		t.Fatalf("default shell path = %q, want /bin/sh", got)
	}
}

func TestNormalizeServerUpdatePolicy(t *testing.T) {
	for _, test := range []struct {
		input string
		want  string
	}{
		{"", serverUpdatePolicyPrompt},
		{"prompt", serverUpdatePolicyPrompt},
		{" never ", serverUpdatePolicyNever},
		{"ALWAYS", serverUpdatePolicyAlways},
		{"force", serverUpdatePolicyForce},
		{" FORCE ", serverUpdatePolicyForce},
	} {
		got, err := normalizeServerUpdatePolicy(test.input)
		if err != nil {
			t.Fatalf("normalizeServerUpdatePolicy(%q) error: %v", test.input, err)
		}
		if got != test.want {
			t.Fatalf("normalizeServerUpdatePolicy(%q) = %q, want %q", test.input, got, test.want)
		}
	}

	if _, err := normalizeServerUpdatePolicy("sometimes"); err == nil {
		t.Fatal("invalid update policy succeeded")
	}
}

func TestDecodeArgsBase64PreservesArgumentBoundaries(t *testing.T) {
	want := []string{"printf", "%s", "a b", "", "x; echo unsafe"}
	encoded, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}

	got, err := decodeArgsBase64(base64.StdEncoding.EncodeToString(encoded))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("decoded argv = %#v, want %#v", got, want)
	}
}

func TestShouldUpdateRunningServerNeverIsSilent(t *testing.T) {
	var output bytes.Buffer
	update := shouldUpdateRunningServer(
		strings.NewReader("y\n"),
		&output,
		"work",
		runningServerStatus{version: "0.1.0"},
		serverUpdatePolicyNever,
	)

	if update {
		t.Fatal("never policy requested update")
	}
	if output.Len() != 0 {
		t.Fatalf("never policy wrote prompt: %q", output.String())
	}
}

func TestShouldUpdateRunningServerAlwaysSkipsPrompt(t *testing.T) {
	var output bytes.Buffer
	update := shouldUpdateRunningServer(
		strings.NewReader("n\n"),
		&output,
		"work",
		runningServerStatus{version: "0.1.0"},
		serverUpdatePolicyAlways,
	)

	if !update {
		t.Fatal("always policy did not request update")
	}
	if output.Len() != 0 {
		t.Fatalf("always policy wrote prompt: %q", output.String())
	}
}

func TestShouldUpdateRunningServerPromptUsesTerminalPrompt(t *testing.T) {
	var output bytes.Buffer
	update := shouldUpdateRunningServer(
		strings.NewReader("y\n"),
		&output,
		"work",
		runningServerStatus{
			version:      "0.1.0",
			capabilities: []string{"shutdown"},
		},
		serverUpdatePolicyPrompt,
	)

	if !update {
		t.Fatal("prompt policy did not honor yes answer")
	}
	if !strings.Contains(output.String(), "Update now?") {
		t.Fatalf("prompt policy output = %q, want update prompt", output.String())
	}
}

func TestShouldUpdateRunningServerForceSkipsPrompt(t *testing.T) {
	for _, version := range []string{"0.1.0", monkeyMuxVersion} {
		t.Run(version, func(t *testing.T) {
			var output bytes.Buffer
			input := strings.NewReader("n\n")
			if !shouldUpdateRunningServer(input, &output, "work", runningServerStatus{version: version}, serverUpdatePolicyForce) {
				t.Fatal("force policy did not request reload")
			}
			if input.Len() != 2 {
				t.Fatal("force policy read stdin")
			}
			want := fmt.Sprintf("monkeymux: forcing reload of session %q on helper %s\r\n", "work", version)
			if output.String() != want {
				t.Fatalf("force output = %q, want %q", output.String(), want)
			}
		})
	}
}

func TestEnsureServerExistingOnlyRejectsMissingSession(t *testing.T) {
	session := fmt.Sprintf(
		"missing-existing-%d-%d",
		os.Getpid(),
		time.Now().UnixNano(),
	)

	err := ensureServer(
		session,
		createWindowOptions{},
		serverUpdatePolicyNever,
		false,
		80,
		24,
		true,
	)
	if err == nil {
		t.Fatal("existing-only attach created a missing session")
	}
	if !strings.Contains(err.Error(), "is not running") {
		t.Fatalf("existing-only error = %q, want missing-session message", err)
	}
}

func TestHasAttachClientByIDRequiresAnExactClientID(t *testing.T) {
	server := newMuxServer("test")
	if server.hasAttachClientByID("") {
		t.Fatal("new server reported attach client for an empty ID")
	}

	registerTestAttachClient(t, server, &recordingConn{}, "primary", server.width, server.height)

	if server.hasAttachClientByID("") {
		t.Fatal("unidentified query reported another connection's attach")
	}
	if server.hasAttachClientByID("someone-else") {
		t.Fatal("server reported attach for an unknown client ID")
	}
}

func TestHasAttachClientByIDScopesForegroundState(t *testing.T) {
	server := newMuxServer("test")
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		120,
		40,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)

	if !server.hasAttachClientByID("first") {
		t.Fatal("server did not report first client")
	}
	if server.hasAttachClientByID("missing") {
		t.Fatal("server reported a missing client")
	}

	server.removeAttachClient(first)

	if server.hasAttachClientByID("first") {
		t.Fatal("server retained detached first client")
	}
	if !server.hasAttachClientByID("second") {
		t.Fatal("server lost remaining second client")
	}
}

func TestMultipleAttachClientsReceiveActiveOutput(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	firstConn := &recordingConn{}
	secondConn := &recordingConn{}
	registerTestAttachClient(t, server, firstConn, "first", 120, 40)
	registerTestAttachClient(t, server, secondConn, "second", 80, 24)

	server.handleWindowOutput("@1", []byte("shared output"))

	waitForRecordedOutput(t, firstConn, "shared output")
	waitForRecordedOutput(t, secondConn, "shared output")
	if got := server.attachCount(); got != 2 {
		t.Fatalf("attach count = %d, want 2", got)
	}
}

func TestMultipleAttachClientsRouteTerminalQueriesOnlyToPrimary(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	primaryConn := &recordingConn{}
	registerTestAttachClient(t, server, secondaryConn, "secondary", 120, 40)
	registerTestAttachClient(t, server, primaryConn, "primary", 80, 24)

	server.handleWindowOutput(
		"@1",
		[]byte(
			"before\x1b[cafter\x1b[14tmode\x1b[?2031$p"+
				"theme\x1b[?996ncolor\x1b]10;?\x07"+
				"kitty\x1b_Ga=q,i=31;AAAA\x1b\\done",
		),
	)

	waitForRecordedOutput(
		t,
		primaryConn,
		"before\x1b[cafter\x1b[14tmode\x1b[?2031$p"+
			"theme\x1b[?996ncolor\x1b]10;?\x07"+
			"kitty\x1b_Ga=q,i=31;AAAA\x1b\\done",
	)
	waitForRecordedOutput(
		t,
		secondaryConn,
		"beforeaftermodethemecolorkittydone",
	)
}

func TestMultipleAttachClientsRouteC1QueriesOnlyToPrimary(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	primaryConn := &recordingConn{}
	registerTestAttachClient(t, server, secondaryConn, "secondary", 120, 40)
	registerTestAttachClient(t, server, primaryConn, "primary", 80, 24)
	query := []byte{0x9b, 'c'}

	server.handleWindowOutput("@1", append([]byte("before"), append(query, []byte("after")...)...))

	waitForRecordedOutput(
		t,
		primaryConn,
		string(append([]byte("before"), append(query, []byte("after")...)...)),
	)
	waitForRecordedOutput(t, secondaryConn, "beforeafter")
}

func TestRequestedImagesUseNewestMatchingClientID(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		lastActivity: time.Now(),
		kittyImages: map[string][]byte{
			"7": []byte("retained-image"),
		},
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	staleConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		staleConn,
		"same-client",
		80,
		24,
	)
	currentConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		currentConn,
		"same-client",
		80,
		24,
	)

	served := server.replayRequestedImages("same-client", []string{"7"})

	if !reflect.DeepEqual(served, []string{"7"}) {
		t.Fatalf("served image ids = %#v, want [7]", served)
	}
	waitForRecordedOutput(t, currentConn, "retained-image")
	time.Sleep(10 * time.Millisecond)
	if got := staleConn.String(); got != "" {
		t.Fatalf("stale matching client received image replay: %q", got)
	}
}

func TestRequestedImagesWaitForAttachWriteCompletion(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:           "@1",
			index:        0,
			lastActivity: time.Now(),
			kittyImages: map[string][]byte{
				"7": []byte("retained-image"),
			},
		},
	}
	server.activeID = "@1"
	gate := make(chan struct{})
	started := make(chan struct{})
	conn := &gatedConn{
		recordingConn: &recordingConn{},
		gate:          gate,
		started:       started,
	}
	registerTestAttachClient(
		t,
		server,
		conn,
		"image-client",
		80,
		24,
	)

	served := make(chan []string, 1)
	go func() {
		served <- server.replayRequestedImages(
			"image-client",
			[]string{"7"},
		)
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("image replay write did not start")
	}
	select {
	case ids := <-served:
		t.Fatalf("image replay acknowledged before write completed: %#v", ids)
	case <-time.After(50 * time.Millisecond):
	}
	lockAcquired := make(chan struct{})
	go func() {
		server.attachMu.Lock()
		server.attachMu.Unlock()
		close(lockAcquired)
	}()
	select {
	case <-lockAcquired:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("image replay wait held the server-wide attach lock")
	}

	close(gate)
	select {
	case ids := <-served:
		if !reflect.DeepEqual(ids, []string{"7"}) {
			t.Fatalf("served image ids = %#v, want [7]", ids)
		}
	case <-time.After(time.Second):
		t.Fatal("image replay did not finish after attach write completed")
	}
}

func TestC1QueryScannerPreservesUtf8ContinuationBytes(t *testing.T) {
	window := &muxWindow{}
	input := []byte{'a', 0xc5, 0x9b, 0xf0, 0x9f, 0x98, 0x80, 'b'}

	filtered := window.secondaryAttachOutputLocked(input)

	if !bytes.Equal(filtered, input) {
		t.Fatalf("UTF-8 output = %q, want %q", filtered, input)
	}
	window.appendPendingTerminalQueriesLocked(input, nil, nil)
	if queries := window.pendingTerminalQueries; len(queries) != 0 {
		t.Fatalf("UTF-8 output produced terminal queries: %q", queries)
	}
}

func TestC1QueryScannerPreservesUtf8SplitAcrossChunks(t *testing.T) {
	window := &muxWindow{}
	first := []byte{'a', 0xf0}
	second := []byte{0x9f, 0x98, 0x80, 'b'}

	filtered := append(
		[]byte(nil),
		window.secondaryAttachOutputLocked(first)...,
	)
	filtered = append(
		filtered,
		window.secondaryAttachOutputLocked(second)...,
	)

	want := append(append([]byte(nil), first...), second...)
	if !bytes.Equal(filtered, want) {
		t.Fatalf("split UTF-8 output = %q, want %q", filtered, want)
	}
	if len(window.secondaryQueryCarry) != 0 {
		t.Fatalf(
			"split UTF-8 left query carry: %q",
			window.secondaryQueryCarry,
		)
	}
}

func TestPendingQueryScannerIgnoresUtf8SplitAcrossChunks(t *testing.T) {
	window := &muxWindow{}

	window.appendPendingTerminalQueriesLocked([]byte{'a', 0xc2}, nil, nil)
	window.appendPendingTerminalQueriesLocked([]byte{0x9b, 'b'}, nil, nil)

	if len(window.pendingTerminalQueries) != 0 {
		t.Fatalf(
			"split UTF-8 buffered a false query: %q",
			window.pendingTerminalQueries,
		)
	}
	if len(window.pendingTerminalQueryCarry) != 0 {
		t.Fatalf(
			"split UTF-8 left pending query carry: %q",
			window.pendingTerminalQueryCarry,
		)
	}
}

func TestQueryScannersPreserveUtf8AcrossThreeChunks(t *testing.T) {
	liveWindow := &muxWindow{}
	filtered := append(
		[]byte(nil),
		liveWindow.secondaryAttachOutputLocked([]byte{0xe2})...,
	)
	filtered = append(
		filtered,
		liveWindow.secondaryAttachOutputLocked([]byte{0x80})...,
	)
	filtered = append(
		filtered,
		liveWindow.secondaryAttachOutputLocked([]byte{0x9b, 'c'})...,
	)
	want := []byte{0xe2, 0x80, 0x9b, 'c'}
	if !bytes.Equal(filtered, want) {
		t.Fatalf("three-chunk UTF-8 output = %q, want %q", filtered, want)
	}

	pendingWindow := &muxWindow{}
	pendingWindow.appendPendingTerminalQueriesLocked([]byte{0xe2}, nil, nil)
	pendingWindow.appendPendingTerminalQueriesLocked([]byte{0x80}, nil, nil)
	pendingWindow.appendPendingTerminalQueriesLocked([]byte{0x9b, 'c'}, nil, nil)
	if len(pendingWindow.pendingTerminalQueries) != 0 ||
		len(pendingWindow.pendingTerminalQueryCarry) != 0 {
		t.Fatalf(
			"three-chunk UTF-8 became pending query %q carry %q",
			pendingWindow.pendingTerminalQueries,
			pendingWindow.pendingTerminalQueryCarry,
		)
	}
}

func TestUtf8QueryStateTransfersFromPendingToLiveRouting(t *testing.T) {
	window := &muxWindow{}

	window.appendPendingTerminalQueriesLocked([]byte{'a', 0xc2}, nil, nil)
	filtered := window.secondaryAttachOutputLocked([]byte{0x9b, 'c'})

	if !bytes.Equal(filtered, []byte{0x9b, 'c'}) {
		t.Fatalf("pending-to-live UTF-8 output = %q", filtered)
	}
	if len(window.secondaryQueryCarry) != 0 {
		t.Fatalf(
			"pending-to-live transition left query carry: %q",
			window.secondaryQueryCarry,
		)
	}
}

func TestSecondaryAttachQueryFilterCarriesSplitQueries(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	primaryConn := &recordingConn{}
	secondary := registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	registerTestAttachClient(t, server, primaryConn, "primary", 80, 24)

	server.handleWindowOutput("@1", []byte("left\x1b[>"))
	waitForRecordedOutput(t, primaryConn, "left\x1b[>")
	waitForRecordedOutput(t, secondaryConn, "left")
	secondaryConn.Reset()
	server.promoteAttachClient(secondary)
	server.handleWindowOutput("@1", []byte("qright"))

	waitForRecordedOutput(t, primaryConn, "left\x1b[>qright")
	waitForRecordedContains(t, secondaryConn, activeWindowReplayPrefix)
	if strings.Contains(secondaryConn.String(), "\x1b[>q") {
		t.Fatalf(
			"secondary client received split terminal query: %q",
			secondaryConn.String(),
		)
	}
}

func TestTerminalQueryDeliveryFailsOverFromClosedPrimary(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	primaryConn := &recordingConn{}
	secondary := registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	primary := registerTestAttachClient(
		t,
		server,
		primaryConn,
		"primary",
		80,
		24,
	)
	primary.close()

	server.handleWindowOutput("@1", []byte("before\x1b[cafter"))

	waitForRecordedOutput(t, secondaryConn, "before\x1b[cafter")
	server.removeAttachClient(primary)
	server.mu.Lock()
	gotPrimary := server.attachConn
	width, height := server.width, server.height
	server.mu.Unlock()
	if gotPrimary != secondary.conn || width != 120 || height != 40 {
		t.Fatalf(
			"query failover client = %v at %dx%d, want secondary at 120x40",
			gotPrimary,
			width,
			height,
		)
	}
}

func TestPrimaryDetachDropsItsDeferredViewport(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 50)
	replacementConn := &recordingConn{}
	replacement := registerTestAttachClient(
		t,
		server,
		replacementConn,
		"replacement",
		160,
		50,
	)
	primary := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"primary",
		80,
		24,
	)
	replacement.focusSequence.Store(primary.focusSequence.Load() - 1)
	server.width = 80
	server.height = 24
	server.pendingResizeWidth = 80
	server.pendingResizeHeight = 24

	server.removeAttachClient(primary)

	server.mu.Lock()
	width, height := server.width, server.height
	pendingWidth, pendingHeight :=
		server.pendingResizeWidth, server.pendingResizeHeight
	active := server.attachConn
	server.mu.Unlock()
	if active != replacement.conn {
		t.Fatal("replacement client did not become primary")
	}
	if width != 160 || height != 50 {
		t.Fatalf("replacement viewport = %dx%d, want 160x50", width, height)
	}
	if pendingWidth != 0 || pendingHeight != 0 {
		t.Fatalf(
			"detached viewport remained pending at %dx%d",
			pendingWidth,
			pendingHeight,
		)
	}
	if got := replacementConn.String(); got != "" {
		t.Fatalf("already-published replacement viewport was replayed: %q", got)
	}
}

func TestTerminalQueryDeliveryRetriesAfterAcceptedWriteFails(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	registerTestAttachClient(
		t,
		server,
		failingConn{},
		"primary",
		80,
		24,
	)

	server.handleWindowOutput("@1", []byte("before\x1b[cafter"))

	waitForRecordedOutput(t, secondaryConn, "before\x1b[cafter")
}

func TestSplitTerminalQueryFailsOverWithItsCarriedPrefix(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	primaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	primary := registerTestAttachClient(
		t,
		server,
		primaryConn,
		"primary",
		80,
		24,
	)

	server.handleWindowOutput("@1", []byte("left\x1b[>"))
	primary.close()
	server.handleWindowOutput("@1", []byte("qright"))

	waitForRecordedOutput(t, secondaryConn, "left\x1b[>qright")
}

func TestLiveQueryCarryTransfersToPendingWhenWindowBecomesHidden(t *testing.T) {
	server := newMuxServer("test")
	first := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	second := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{first, second}
	server.activeID = "@1"
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "primary", 80, 24)

	server.handleWindowOutput("@1", []byte("left\x1b[>"))
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	server.handleWindowOutput("@1", []byte("qright"))

	server.mu.Lock()
	pending := string(first.pendingTerminalQueries)
	carry := string(first.secondaryQueryCarry)
	server.mu.Unlock()
	if pending != "\x1b[>q" {
		t.Fatalf("pending hidden query = %q, want complete XTVERSION query", pending)
	}
	if carry != "" {
		t.Fatalf("live query carry remained after hiding window: %q", carry)
	}
}

func TestPendingQueryCarryTransfersToLiveWhenClientAttaches(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("left\x1b[>"))
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "primary", 80, 24)
	server.handleWindowOutput("@1", []byte("qright"))

	waitForRecordedOutput(t, conn, "\x1b[>qright")
	server.mu.Lock()
	carry := string(window.pendingTerminalQueryCarry)
	server.mu.Unlock()
	if carry != "" {
		t.Fatalf("pending query carry remained after attach: %q", carry)
	}
}

func TestWindowOutputSkipsClientsThatJoinedAfterObservation(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	firstConn := &recordingConn{}
	first := registerTestAttachClient(t, server, firstConn, "first", 80, 24)
	observedSequence := first.sequence
	joiningConn := &recordingConn{}
	registerTestAttachClient(t, server, joiningConn, "joining", 80, 24)

	server.writeAttachOutputIfActive(
		"@1",
		first.conn,
		[]byte("once"),
		[]byte("once"),
		[]byte("once"),
		nil,
		observedSequence,
		0,
	)

	waitForRecordedOutput(t, firstConn, "once")
	time.Sleep(10 * time.Millisecond)
	if got := joiningConn.String(); got != "" {
		t.Fatalf("joining client received already-replayed output: %q", got)
	}
}

func TestTerminalQueryRetryCanUseClientThatJoinedAfterObservation(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	primary := registerTestAttachClient(
		t,
		server,
		failingConn{},
		"primary",
		80,
		24,
	)
	observedSequence := primary.sequence
	joiningConn := &recordingConn{}
	registerTestAttachClient(t, server, joiningConn, "joining", 80, 24)

	server.writeAttachOutputIfActive(
		"@1",
		primary.conn,
		[]byte("\x1b[c"),
		[]byte("\x1b[c"),
		nil,
		[]byte("\x1b[c"),
		observedSequence,
		0,
	)

	waitForRecordedOutput(t, joiningConn, "\x1b[c")
}

func TestLiveQueryWaitDoesNotHoldAttachLock(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	gate := make(chan struct{})
	started := make(chan struct{})
	primaryConn := &gatedConn{
		recordingConn: &recordingConn{},
		gate:          gate,
		started:       started,
	}
	primary := registerTestAttachClient(
		t,
		server,
		primaryConn,
		"primary",
		80,
		24,
	)

	written := make(chan struct{})
	go func() {
		server.writeAttachOutputIfActive(
			"@1",
			primary.conn,
			[]byte("before\x1b[>qafter"),
			[]byte("before\x1b[>qafter"),
			[]byte("beforeafter"),
			[]byte("\x1b[>q"),
			primary.sequence,
			0,
		)
		close(written)
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("primary query write did not start")
	}
	lockAcquired := make(chan struct{})
	go func() {
		server.attachMu.Lock()
		server.attachMu.Unlock()
		close(lockAcquired)
	}()
	select {
	case <-lockAcquired:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("live query write wait held the server-wide attach lock")
	}
	close(gate)
	select {
	case <-written:
	case <-time.After(time.Second):
		t.Fatal("live query forwarding did not finish")
	}
	waitForRecordedOutput(
		t,
		primaryConn.recordingConn,
		"before\x1b[>qafter",
	)
	waitForRecordedOutput(t, secondaryConn, "beforeafter")
}

func TestPrimaryDetachPublishesAlreadyPendingReplacementViewport(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	replacementConn := &recordingConn{}
	replacement := registerTestAttachClient(
		t,
		server,
		replacementConn,
		"replacement",
		160,
		50,
	)
	replacement.clipViewport = true
	primary := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"primary",
		80,
		24,
	)
	replacement.focusSequence.Store(primary.focusSequence.Load() - 1)
	server.width = 160
	server.height = 50
	server.pendingResizeWidth = 160
	server.pendingResizeHeight = 50

	server.removeAttachClient(primary)

	server.mu.Lock()
	width, height := server.width, server.height
	publishedWidth, publishedHeight :=
		server.publishedWidth, server.publishedHeight
	server.mu.Unlock()
	if width != 160 || height != 50 ||
		publishedWidth != 160 || publishedHeight != 50 {
		t.Fatalf(
			"replacement viewport = desired %dx%d published %dx%d, want 160x50",
			width,
			height,
			publishedWidth,
			publishedHeight,
		)
	}
	waitForRecordedContains(
		t,
		replacementConn,
		string(terminalViewportResizeSequence(160, 50, false)),
	)
}

func TestPausedRedrawFallbackPreservesQueryOrder(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                              "@1",
		index:                           0,
		lastActivity:                    time.Now(),
		redrawForwardingPaused:          true,
		redrawForwardingGeneration:      1,
		redrawForwardingBuffer:          []byte("before\x1b[>qafter"),
		redrawForwardingFailoverBuffer:  []byte("before\x1b[>qafter"),
		redrawForwardingSecondaryBuffer: []byte("beforeafter"),
		redrawForwardingQueryBuffer:     []byte("\x1b[>q"),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	primary := registerTestAttachClient(
		t,
		server,
		failingConn{},
		"primary",
		80,
		24,
	)
	window.redrawForwardingPrimaryConn = primary.conn

	server.resumePausedAttachForwarding("@1", 1)

	waitForRecordedOutput(
		t,
		secondaryConn,
		synchronizedTerminalOutputForTest("before\x1b[>qafter"),
	)
}

func TestEmptyForegroundRedrawFallbackPreservesQueryFailover(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                         "@1",
		index:                      0,
		agentTool:                  "copilot",
		history:                    []byte("\x1b[Hlast known query frame"),
		lastActivity:               time.Now(),
		redrawForwardingPaused:     true,
		redrawForwardingGeneration: 1,
		redrawForwardingReplay:     []byte("clear-only replay"),
		redrawForwardingBuffer:     []byte("\x1b[>q"),
		redrawForwardingFailoverBuffer: []byte(
			"\x1b[>q",
		),
		redrawForwardingQueryBuffer: []byte("\x1b[>q"),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.mu.Lock()
	window.redrawForwardingFallbackHistory =
		server.foregroundHistoryFallbackHistoryLocked(window)
	fallback := string(
		server.foregroundHistoryFallbackReplayLocked(
			window,
			window.redrawForwardingFallbackHistory,
		),
	)
	server.mu.Unlock()

	secondaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"secondary",
		120,
		40,
	)
	primary := registerTestAttachClient(
		t,
		server,
		failingConn{},
		"primary",
		80,
		24,
	)
	window.redrawForwardingPrimaryConn = primary.conn

	server.resumePausedAttachForwarding("@1", 1)

	waitForRecordedOutput(
		t,
		secondaryConn,
		synchronizedTerminalOutputForTest(fallback+"\x1b[>q"),
	)
}

func TestPausedRedrawQueryWaitDoesNotHoldAttachLock(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                              "@1",
		index:                           0,
		lastActivity:                    time.Now(),
		redrawForwardingPaused:          true,
		redrawForwardingGeneration:      1,
		redrawForwardingBuffer:          []byte("\x1b[>q"),
		redrawForwardingFailoverBuffer:  []byte("\x1b[>q"),
		redrawForwardingSecondaryBuffer: []byte("visible"),
		redrawForwardingQueryBuffer:     []byte("\x1b[>q"),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"secondary",
		120,
		40,
	)
	gate := make(chan struct{})
	started := make(chan struct{})
	primaryConn := &gatedConn{
		recordingConn: &recordingConn{},
		gate:          gate,
		started:       started,
	}
	primary := registerTestAttachClient(
		t,
		server,
		primaryConn,
		"primary",
		80,
		24,
	)
	window.redrawForwardingPrimaryConn = primary.conn

	resumed := make(chan struct{})
	go func() {
		server.resumePausedAttachForwarding("@1", 1)
		close(resumed)
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("primary query write did not start")
	}
	lockAcquired := make(chan struct{})
	go func() {
		server.attachMu.Lock()
		server.attachMu.Unlock()
		close(lockAcquired)
	}()
	select {
	case <-lockAcquired:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("query write wait held the server-wide attach lock")
	}
	close(gate)
	select {
	case <-resumed:
	case <-time.After(time.Second):
		t.Fatal("paused redraw did not finish after primary write resumed")
	}
}

func TestPausedRedrawUsesFailoverBufferForReboundPrimary(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                                   "@1",
		index:                                0,
		lastActivity:                         time.Now(),
		redrawForwardingPaused:               true,
		redrawForwardingGeneration:           1,
		redrawForwardingBuffer:               []byte("qright"),
		redrawForwardingFailoverBuffer:       []byte("\x1b[>qright"),
		redrawForwardingSecondaryBuffer:      []byte("right"),
		redrawForwardingQueryBuffer:          []byte("\x1b[>q"),
		redrawForwardingPrimaryNeedsFailover: true,
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	primary := registerTestAttachClient(
		t,
		server,
		conn,
		"replacement",
		80,
		24,
	)
	window.redrawForwardingPrimaryConn = primary.conn

	server.resumePausedAttachForwarding("@1", 1)

	waitForRecordedOutput(
		t,
		conn,
		synchronizedTerminalOutputForTest("\x1b[>qright"),
	)
}

func TestPausedRedrawKeepsSplitQueryBoundToOriginalClient(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                         "@1",
		index:                      0,
		lastActivity:               time.Now(),
		redrawForwardingPaused:     true,
		redrawForwardingGeneration: 1,
		secondaryQueryCarry:        []byte("\x1b[>"),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	originalConn := &recordingConn{}
	original := registerTestAttachClient(
		t,
		server,
		originalConn,
		"original",
		120,
		40,
	)
	replacementConn := &recordingConn{}
	replacement := registerTestAttachClient(
		t,
		server,
		replacementConn,
		"replacement",
		80,
		24,
	)
	window.secondaryQueryPrimary = original.conn
	window.redrawForwardingPrimaryConn = replacement.conn
	_, _ = originalConn.Write([]byte("\x1b[>"))

	server.handleWindowOutput("@1", []byte("qright"))

	if window.redrawForwardingPrimaryConn != original.conn {
		t.Fatal("redraw did not retain the split query's original client")
	}
	server.resumePausedAttachForwarding("@1", 1)
	waitForRecordedOutput(
		t,
		originalConn,
		"\x1b[>"+
			synchronizedTerminalOutputForTest("qright"),
	)
	waitForRecordedOutput(
		t,
		replacementConn,
		synchronizedTerminalOutputForTest("right"),
	)
}

func TestPendingTerminalQueryFlushIsSingleFlight(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                     "@1",
		index:                  0,
		lastActivity:           time.Now(),
		pendingTerminalQueries: []byte("\x1b[c"),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	gate := make(chan struct{})
	conn := &gatedConn{recordingConn: &recordingConn{}, gate: gate}
	registerTestAttachClient(t, server, conn, "primary", 80, 24)

	server.attachMu.Lock()
	server.flushPendingTerminalQueriesLocked(conn, "@1")
	server.flushPendingTerminalQueriesLocked(conn, "@1")
	server.attachMu.Unlock()
	server.mu.Lock()
	server.storePendingTerminalQueriesLocked(window, []byte("\x1b[14t"))
	inFlight := string(window.pendingTerminalQueriesInFlight)
	server.mu.Unlock()
	if inFlight != "\x1b[c" {
		t.Fatalf("in-flight query = %q, want one device query", inFlight)
	}

	close(gate)
	waitForRecordedOutput(t, conn.recordingConn, "\x1b[c")
	waitForPendingQueryState(t, server, window, "", "\x1b[14t")

	server.attachMu.Lock()
	server.flushPendingTerminalQueriesLocked(conn, "@1")
	server.attachMu.Unlock()
	waitForRecordedOutput(t, conn.recordingConn, "\x1b[c\x1b[14t")
}

func TestAttachQueueRejectsOversizedBacklog(t *testing.T) {
	client := newAttachClient(
		&recordingConn{},
		controlMessage{ClientID: "bounded"},
	)
	t.Cleanup(client.close)

	if _, queued := client.enqueue(
		make([]byte, attachWriteQueueLimitBytes+1),
		false,
	); queued {
		t.Fatal("oversized attach write was queued")
	}
	select {
	case <-client.done:
	default:
		t.Fatal("oversized attach write did not disconnect the client")
	}
}

func TestAttachQueueAcceptsLiveOutputBurstDuringReplay(t *testing.T) {
	gate := make(chan struct{})
	started := make(chan struct{})
	conn := &gatedConn{
		recordingConn: &recordingConn{},
		gate:          gate,
		started:       started,
	}
	client := newAttachClient(conn, controlMessage{ClientID: "replay"})
	t.Cleanup(client.close)

	if _, queued := client.enqueue(
		bytes.Repeat([]byte{'R'}, attachWriteChunkBytes),
		false,
	); !queued {
		t.Fatal("initial replay was not queued")
	}
	<-started

	const liveWrites = 1024
	for i := 0; i < liveWrites; i++ {
		if _, queued := client.enqueue([]byte{'L'}, false); !queued {
			t.Fatalf("live output write %d was rejected", i)
		}
	}
	select {
	case <-client.done:
		t.Fatal("bounded live output burst disconnected the attach client")
	default:
	}
	close(gate)
}

func TestAttachWriteRenewsDeadlineWhileReplayMakesProgress(t *testing.T) {
	conn := &deadlineBudgetConn{
		recordingConn:     &recordingConn{},
		maxWriteBytes:     attachWriteChunkBytes / 2,
		writesPerDeadline: 2,
	}
	client := newAttachClient(conn, controlMessage{ClientID: "paced"})
	t.Cleanup(client.close)
	payload := bytes.Repeat([]byte{'R'}, attachWriteChunkBytes*8+123)

	completion, queued := client.enqueue(payload, true)
	if !queued {
		t.Fatal("replay was not queued")
	}
	if !client.waitForWrite(completion) {
		t.Fatal("progressing replay write failed")
	}
	if got := conn.recordingConn.String(); got != string(payload) {
		t.Fatalf("replay output length = %d, want %d", len(got), len(payload))
	}
	if conn.deadlineRefreshCount() < 9 {
		t.Fatalf(
			"write deadline refreshed %d times, want at least 9",
			conn.deadlineRefreshCount(),
		)
	}
	select {
	case <-client.done:
		t.Fatal("progressing replay disconnected the attach client")
	default:
	}
}

func TestAttachSizeFollowsPrimaryClient(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"wide",
		200,
		20,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"tall",
		80,
		50,
	)

	server.resizeForClient("wide", 200, 20, false)

	server.mu.Lock()
	width, height := server.width, server.height
	server.mu.Unlock()
	if width != 80 || height != 50 {
		t.Fatalf("shared size after background resize = %dx%d, want 80x50", width, height)
	}

	server.promoteAttachClient(first)
	server.mu.Lock()
	width, height = server.width, server.height
	primary := server.attachConn
	server.mu.Unlock()
	if primary != first.conn || width != 200 || height != 20 {
		t.Fatalf(
			"focused client = %v at %dx%d, want wide client at 200x20",
			primary,
			width,
			height,
		)
	}

	server.removeAttachClient(first)
	server.mu.Lock()
	width, height = server.width, server.height
	server.mu.Unlock()
	if width != 80 || height != 50 {
		t.Fatalf("size after detach = %dx%d, want 80x50", width, height)
	}
}

func TestClippingClientReceivesInitialCanonicalViewport(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	conn := &recordingConn{}
	client := newAttachClient(
		conn,
		controlMessage{
			ClientID:     "phone",
			Width:        80,
			Height:       24,
			ClipViewport: true,
		},
	)
	t.Cleanup(client.close)

	server.attachMu.Lock()
	server.mu.Lock()
	server.attachClients[conn] = client
	server.attachConn = conn
	server.enqueueAttachViewportResizeLocked(80, 24)
	server.mu.Unlock()
	server.attachMu.Unlock()

	waitForRecordedOutput(t, conn, "\x1b[?8;24;80t")
}

func TestLegacyResizeWithoutClientIDOnlyUpdatesPrimaryClient(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	background := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"background",
		120,
		40,
	)
	primary := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"primary",
		80,
		24,
	)

	server.resizeForClient("", 90, 30, false)

	server.mu.Lock()
	width, height := server.width, server.height
	backgroundWidth, backgroundHeight := background.width, background.height
	primaryWidth, primaryHeight := primary.width, primary.height
	server.mu.Unlock()
	if width != 90 || height != 30 {
		t.Fatalf("shared size = %dx%d, want 90x30", width, height)
	}
	if backgroundWidth != 120 || backgroundHeight != 40 {
		t.Fatalf(
			"background size = %dx%d, want 120x40",
			backgroundWidth,
			backgroundHeight,
		)
	}
	if primaryWidth != 90 || primaryHeight != 30 {
		t.Fatalf(
			"primary size = %dx%d, want 90x30",
			primaryWidth,
			primaryHeight,
		)
	}
}

func TestConcurrentClientResizesLeavePrimarySize(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	registerTestAttachClient(t, server, &recordingConn{}, "first", 120, 40)
	registerTestAttachClient(t, server, &recordingConn{}, "second", 80, 50)

	var updates sync.WaitGroup
	for index := 0; index < 100; index++ {
		updates.Add(2)
		go func(value int) {
			defer updates.Done()
			server.resizeForClient("first", 100+value%10, 30+value%7, false)
		}(index)
		go func(value int) {
			defer updates.Done()
			server.resizeForClient("second", 70+value%8, 45+value%5, false)
		}(index)
	}
	updates.Wait()

	server.mu.Lock()
	wantWidth, wantHeight := server.primaryAttachSizeLocked()
	gotWidth, gotHeight := server.width, server.height
	server.mu.Unlock()
	if gotWidth != wantWidth || gotHeight != wantHeight {
		t.Fatalf(
			"shared size = %dx%d, primary size = %dx%d",
			gotWidth,
			gotHeight,
			wantWidth,
			wantHeight,
		)
	}
}

func TestClippingResizeWaitsForTerminalSequenceBoundary(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(
		t,
		server,
		conn,
		"primary",
		80,
		24,
	)
	client.clipViewport = true

	server.handleWindowOutput("@1", []byte("\x1b["))
	waitForRecordedOutput(t, conn, "\x1b[")

	server.resizeForClient("primary", 100, 30, false)
	server.mu.Lock()
	width, height := server.width, server.height
	server.mu.Unlock()
	if width != 100 || height != 30 {
		t.Fatalf("desired size = %dx%d, want pending 100x30", width, height)
	}
	if got := conn.String(); got != "\x1b[" {
		t.Fatalf("mid-sequence output = %q, want no injected viewport CSI", got)
	}

	server.handleWindowOutput("@1", []byte("0mX"))

	waitForRecordedOutput(t, conn, "\x1b[0mX\x1b[?8;30;100t")
	server.mu.Lock()
	width, height = server.width, server.height
	server.mu.Unlock()
	if width != 100 || height != 30 {
		t.Fatalf("settled size = %dx%d, want 100x30", width, height)
	}
}

func TestClippingResizeWaitsForBoundaryChunkToBeForwarded(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		terminalOutputForwarding: true,
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(
		t,
		server,
		conn,
		"primary",
		80,
		24,
	)
	client.clipViewport = true

	server.resizeForClient("primary", 100, 30, false)

	if got := conn.String(); got != "" {
		t.Fatalf("forwarding resize output = %q, want deferred viewport", got)
	}
	server.mu.Lock()
	window.terminalOutputForwarding = false
	server.mu.Unlock()

	server.refreshPendingViewportResize()

	waitForRecordedOutput(t, conn, "\x1b[?8;30;100t")
}

func TestWindowSwitchResetsParserBeforePendingViewport(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	first := &muxWindow{
		id:                  "@1",
		index:               0,
		terminalOutputState: terminalOutputParserOsc,
		lastActivity:        time.Now(),
	}
	second := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{first, second}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(
		t,
		server,
		conn,
		"primary",
		80,
		24,
	)
	client.clipViewport = true
	server.width = 100
	server.height = 30
	server.pendingResizeWidth = 100
	server.pendingResizeHeight = 30

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	wantPrefix := terminalParserResetSequence + "\x1b[?8;30;100t" +
		activeWindowReplayPrefix
	waitForRecordedContains(t, conn, wantPrefix)
}

func TestFocusClientControlPromotesAndResizesClient(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		132,
		43,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)

	server.handleControlRequest(
		newControlClient(nil),
		controlMessage{
			Type:     "focus_client",
			ClientID: "first",
			Width:    132,
			Height:   43,
		},
	)
	server.mu.Lock()
	primary := server.attachConn
	width, height := server.width, server.height
	server.mu.Unlock()
	if primary != first.conn || width != 132 || height != 43 {
		t.Fatalf(
			"focused client = %v at %dx%d, want first client at 132x43",
			primary,
			width,
			height,
		)
	}
}

func TestFocusClientResultReportsOnlyPrimaryChange(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		132,
		43,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)

	first := server.focusAttachClientByIDWithResult("first", 132, 43, true)
	second := server.focusAttachClientByIDWithResult("first", 132, 43, true)

	if !first.focused || !first.primaryChanged {
		t.Fatalf("first focus result = %#v, want changed focus", first)
	}
	if !second.focused || second.primaryChanged {
		t.Fatalf("second focus result = %#v, want unchanged focus", second)
	}
}

func TestClientFocusHandoffImmediatelyReplaysAndRedrawsWindow(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      []byte("stale desktop layout"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	focusedConn := &recordingConn{}
	focused := registerTestAttachClient(
		t,
		server,
		focusedConn,
		"phone",
		72,
		28,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"desktop",
		160,
		50,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalDeliverForegroundGeometry := deliverForegroundGeometry
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		deliverForegroundGeometry = originalDeliverForegroundGeometry
	}()
	var simulated []string
	signalForegroundResize = func(int) {}
	deliverForegroundGeometry = func(
		window *muxWindow,
		width int,
		height int,
	) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}

	server.promoteAttachClient(focused)

	waitForRecordedOutput(
		t,
		focusedConn,
		replayPrefixForTest(window)+replayPostHistorySuffixForTest(true),
	)
	if strings.Contains(focusedConn.String(), "stale desktop layout") {
		t.Fatalf(
			"focus replay retained stale TUI layout: %q",
			focusedConn.String(),
		)
	}
	if !reflect.DeepEqual(simulated, []string{"@1:72x28"}) {
		t.Fatalf("focus redraws = %#v, want [@1:72x28]", simulated)
	}
	server.mu.Lock()
	width, height := server.width, server.height
	server.mu.Unlock()
	if width != 72 || height != 28 {
		t.Fatalf("focused PTY size = %dx%d, want 72x28", width, height)
	}

	focusedConn.Reset()
	simulated = nil
	server.promoteAttachClient(focused)
	time.Sleep(10 * time.Millisecond)
	if got := focusedConn.String(); got != "" {
		t.Fatalf("already-focused client replayed again: %q", got)
	}
	if len(simulated) != 0 {
		t.Fatalf("already-focused client redrew again: %#v", simulated)
	}
}

func TestClientFocusBroadcastsSharedViewportToClippingClients(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 50)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("shared layout"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	phoneConn := &recordingConn{}
	phone := registerTestAttachClient(
		t,
		server,
		phoneConn,
		"phone",
		72,
		28,
	)
	desktopConn := &recordingConn{}
	desktop := registerTestAttachClient(
		t,
		server,
		desktopConn,
		"desktop",
		160,
		50,
	)
	phone.clipViewport = true
	desktop.clipViewport = true

	server.promoteAttachClient(phone)

	const viewportResize = "\x1b[?8;28;72t"
	waitForRecordedOutput(t, desktopConn, viewportResize)
	waitForRecordedContains(t, phoneConn, viewportResize+activeWindowReplayPrefix)
	if got := phoneConn.String(); !strings.HasPrefix(got, viewportResize) {
		t.Fatalf("focused client output = %q, want viewport resize first", got)
	}
}

func TestClientFocusReplaySuppressesAlreadyReplayedShellOutput(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:               "@1",
		index:            0,
		history:          []byte("prompt\nnew output"),
		outputGeneration: 1,
		lastActivity:     time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	secondaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		secondaryConn,
		"desktop",
		120,
		40,
	)
	focusedConn := &recordingConn{}
	focused := registerTestAttachClient(
		t,
		server,
		focusedConn,
		"phone",
		72,
		28,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.replayFocusedWindowToClient(focused, 72, 28)
	wantReplay := replayPrefixForTest(window) +
		"prompt\nnew output" +
		replayPostHistorySuffixForTest(true)
	waitForRecordedOutput(t, focusedConn, wantReplay)

	server.writeAttachOutputIfActive(
		"@1",
		focused.conn,
		[]byte("new output"),
		[]byte("new output"),
		[]byte("new output"),
		nil,
		^uint64(0),
		1,
	)

	time.Sleep(10 * time.Millisecond)
	if got := focusedConn.String(); got != wantReplay {
		t.Fatalf("focused client duplicated replayed output: %q", got)
	}
	waitForRecordedOutput(t, secondaryConn, "new output")

	server.writeAttachOutputIfActive(
		"@1",
		focused.conn,
		[]byte("next"),
		[]byte("next"),
		[]byte("next"),
		nil,
		^uint64(0),
		2,
	)
	waitForRecordedOutput(t, focusedConn, wantReplay+"next")
	waitForRecordedOutput(t, secondaryConn, "new outputnext")
}

func TestClientFocusReplayStillDeliversReplayedTerminalQuery(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	query := []byte("\x1b[c")
	window := &muxWindow{
		id:               "@1",
		index:            0,
		history:          append([]byte("prompt"), query...),
		outputGeneration: 1,
		lastActivity:     time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	focusedConn := &recordingConn{}
	focused := registerTestAttachClient(
		t,
		server,
		focusedConn,
		"phone",
		72,
		28,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.replayFocusedWindowToClient(focused, 72, 28)
	wantReplay := replayPrefixForTest(window) +
		"prompt" +
		replayPostHistorySuffixForTest(true)
	waitForRecordedOutput(t, focusedConn, wantReplay)

	server.writeAttachOutputIfActive(
		"@1",
		focused.conn,
		query,
		query,
		nil,
		query,
		^uint64(0),
		1,
	)

	waitForRecordedOutput(t, focusedConn, wantReplay+string(query))
}

func TestClientFocusHandoffDefersReplayUntilSplitQueryCompletes(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	focusedConn := &recordingConn{}
	focused := registerTestAttachClient(
		t,
		server,
		focusedConn,
		"phone",
		72,
		28,
	)
	primaryConn := &recordingConn{}
	registerTestAttachClient(
		t,
		server,
		primaryConn,
		"desktop",
		120,
		40,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.handleWindowOutput("@1", []byte("left\x1b[>"))
	waitForRecordedOutput(t, focusedConn, "left")
	focusedConn.Reset()
	server.promoteAttachClient(focused)
	time.Sleep(10 * time.Millisecond)
	if got := focusedConn.String(); got != "" {
		t.Fatalf("focus replay ran during split query: %q", got)
	}
	server.mu.Lock()
	pending := server.pendingFocusRefreshConn
	server.mu.Unlock()
	if pending != focused.conn {
		t.Fatal("focused refresh was not deferred to the phone client")
	}

	server.handleWindowOutput("@1", []byte("qright"))

	waitForRecordedContains(t, focusedConn, activeWindowReplayPrefix)
	if strings.Contains(focusedConn.String(), "\x1b[>q") {
		t.Fatalf(
			"deferred focus replay leaked terminal query: %q",
			focusedConn.String(),
		)
	}
	waitForRecordedContains(t, primaryConn, "\x1b[>q")
	if !strings.Contains(primaryConn.String(), "\x1b[>q") {
		t.Fatalf(
			"original query recipient did not receive complete query: %q",
			primaryConn.String(),
		)
	}
}

func TestDeferredFocusUsesPrimarySizeForWindowSwitch(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	nextPty := openTestPty(t)
	setPtySize(t, nextPty, 120, 40)
	first := &muxWindow{
		id:                  "@1",
		index:               0,
		secondaryQueryCarry: []byte("\x1b[>"),
		lastActivity:        time.Now(),
	}
	next := &muxWindow{
		id:           "@2",
		index:        1,
		pty:          nextPty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{first, next}
	server.activeID = "@1"
	phone := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"phone",
		72,
		28,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"desktop",
		120,
		40,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.promoteAttachClient(phone)
	server.mu.Lock()
	width, height := server.width, server.height
	pending := server.pendingFocusRefreshConn
	server.mu.Unlock()
	if width != 72 || height != 28 || pending != phone.conn {
		t.Fatalf(
			"deferred viewport = %dx%d pending %v, want 72x28 pending phone",
			width,
			height,
			pending,
		)
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	assertPtySizeEventually(t, nextPty, 72, 28)
	server.mu.Lock()
	pending = server.pendingFocusRefreshConn
	server.mu.Unlock()
	if pending != nil {
		t.Fatal("window switch did not consume deferred focused refresh")
	}
}

func TestClientFocusHandoffDefersReplayUntilUtf8Completes(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:                 "@1",
		index:              0,
		agentTool:          "copilot",
		queryUtf8Remaining: 1,
		lastActivity:       time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	focusedConn := &recordingConn{}
	focused := registerTestAttachClient(
		t,
		server,
		focusedConn,
		"phone",
		72,
		28,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"desktop",
		120,
		40,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.promoteAttachClient(focused)
	time.Sleep(10 * time.Millisecond)
	if got := focusedConn.String(); got != "" {
		t.Fatalf("focus replay split UTF-8 output: %q", got)
	}

	server.handleWindowOutput("@1", []byte{0x9b, 'x'})

	waitForRecordedContains(t, focusedConn, activeWindowReplayPrefix)
}

func TestClientFocusHandoffDefersReplayUntilEscapeSequenceCompletes(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	focusedConn := &recordingConn{}
	focused := registerTestAttachClient(
		t,
		server,
		focusedConn,
		"phone",
		72,
		28,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"desktop",
		120,
		40,
	)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.handleWindowOutput("@1", []byte("\x1b("))
	waitForRecordedOutput(t, focusedConn, "\x1b(")
	focusedConn.Reset()
	server.promoteAttachClient(focused)
	time.Sleep(10 * time.Millisecond)
	if got := focusedConn.String(); got != "" {
		t.Fatalf("focus replay split ESC intermediate sequence: %q", got)
	}

	server.handleWindowOutput("@1", []byte("B"))

	waitForRecordedContains(t, focusedConn, activeWindowReplayPrefix)
}

func TestTerminalOutputGroundStateTracksSplitSequences(t *testing.T) {
	window := &muxWindow{}
	window.observeTerminalOutputStateLocked([]byte("\x1b("))
	if window.terminalOutputIsGroundLocked() {
		t.Fatal("ESC intermediate sequence incorrectly reported ground")
	}
	window.observeTerminalOutputStateLocked([]byte("B"))
	if !window.terminalOutputIsGroundLocked() {
		t.Fatal("completed ESC intermediate sequence did not return to ground")
	}

	window.observeTerminalOutputStateLocked([]byte("\x1b[31"))
	if window.terminalOutputIsGroundLocked() {
		t.Fatal("split CSI sequence incorrectly reported ground")
	}
	window.observeTerminalOutputStateLocked([]byte("m"))
	if !window.terminalOutputIsGroundLocked() {
		t.Fatal("completed CSI sequence did not return to ground")
	}

	window.observeTerminalOutputStateLocked([]byte("\x1bPpayload\a"))
	if window.terminalOutputIsGroundLocked() {
		t.Fatal("BEL incorrectly terminated DCS output")
	}
	window.observeTerminalOutputStateLocked([]byte("\x1b\\"))
	if !window.terminalOutputIsGroundLocked() {
		t.Fatal("ST did not terminate DCS output")
	}

	window.observeTerminalOutputStateLocked([]byte{0xf0, 0x9f})
	if window.terminalOutputIsGroundLocked() {
		t.Fatal("split UTF-8 output incorrectly reported ground")
	}
	window.observeTerminalOutputStateLocked([]byte{0x98, 0x80})
	if !window.terminalOutputIsGroundLocked() {
		t.Fatal("completed UTF-8 output did not return to ground")
	}

	for _, cancel := range []byte{0x18, 0x1a} {
		for _, prefix := range [][]byte{
			[]byte("\x1b[31"),
			[]byte("\x1b]title"),
			[]byte("\x1bPpayload"),
		} {
			window.observeTerminalOutputStateLocked(prefix)
			if window.terminalOutputIsGroundLocked() {
				t.Fatalf("prefix %q did not enter parser state", prefix)
			}
			window.observeTerminalOutputStateLocked([]byte{cancel})
			if !window.terminalOutputIsGroundLocked() {
				t.Fatalf(
					"cancel byte 0x%x did not reset prefix %q",
					cancel,
					prefix,
				)
			}
		}
	}
}

func TestTerminalOutputHasVisibleContent(t *testing.T) {
	tests := []struct {
		name string
		data string
		want bool
	}{
		{name: "empty", data: "", want: false},
		{
			name: "clear and title only",
			data: "\x1b[H\x1b[2J\x1b]0;agent\x07",
			want: false,
		},
		{name: "spaces only", data: "\x1b[H   ", want: false},
		{
			name: "spaces under a background color",
			data: "\x1b[44m   \x1b[0m",
			want: true,
		},
		{
			name: "spaces under a 256 color background",
			data: "\x1b[48;5;236m   \x1b[0m",
			want: true,
		},
		{
			name: "spaces under a truecolor background",
			data: "\x1b[48;2;10;20;30m   \x1b[0m",
			want: true,
		},
		{
			// 44 would be read as "blue background" if the 256-color parameters
			// were not skipped, so this pins the skip rather than the outcome.
			name: "spaces under a 256 color foreground only",
			data: "\x1b[38;5;44m   \x1b[0m",
			want: false,
		},
		{
			name: "spaces under a truecolor foreground only",
			data: "\x1b[38;2;44;7;41m   \x1b[0m",
			want: false,
		},
		{
			name: "spaces under a colon form truecolor foreground only",
			data: "\x1b[38:2::44:7:41m   \x1b[0m",
			want: false,
		},
		{
			name: "spaces under a colon form 256 color background",
			data: "\x1b[48:5:236m   \x1b[0m",
			want: true,
		},
		{
			// A foreground color must not mask a background set afterwards.
			name: "spaces under a foreground then a background",
			data: "\x1b[38;5;44;48;5;236m   \x1b[0m",
			want: true,
		},
		{
			name: "spaces under reverse video",
			data: "\x1b[7m   \x1b[27m",
			want: true,
		},
		{
			name: "spaces under an underline",
			data: "\x1b[4m   \x1b[24m",
			want: true,
		},
		{
			name: "spaces after the background is reset",
			data: "\x1b[44m\x1b[49m   ",
			want: false,
		},
		{
			name: "spaces after a full rendition reset",
			data: "\x1b[44m\x1b[0m   ",
			want: false,
		},
		{
			name: "spaces after a cancelled underline",
			data: "\x1b[4:3m\x1b[4:0m   ",
			want: false,
		},
		{
			name: "spaces after a foreground color only",
			data: "\x1b[38;5;236m   ",
			want: false,
		},
		{
			name: "spaces after a private mode report",
			data: "\x1b[>4;2m   ",
			want: false,
		},
		{name: "ascii text", data: "\x1b[Hagent ready", want: true},
		{name: "unicode text", data: "\x1b[H│", want: true},
		{
			name: "kitty store only",
			data: "\x1b_Ga=t,i=7,f=100;AAAA\x1b\\",
			want: false,
		},
		{
			name: "kitty transmit and display",
			data: "\x1b_Ga=T,i=7,f=100;AAAA\x1b\\",
			want: true,
		},
		{
			name: "eight bit kitty store only",
			data: "\x9fGa=t,i=7,f=100;AAAA\x9c",
			want: false,
		},
		{
			name: "eight bit kitty transmit and display",
			data: "\x9fGa=T,i=7,f=100;AAAA\x9c",
			want: true,
		},
		{
			name: "seven bit kitty transmit and display with eight bit terminator",
			data: "\x1b_Ga=T,i=7,f=100;AAAA\x9c",
			want: true,
		},
		{
			name: "text after a cancelled kitty transmission",
			data: "\x1b_Ga=t,i=7,f=100;AAAA\x18agent ready",
			want: true,
		},
		{
			name: "text after a cancelled kitty transmission before a later st",
			data: "\x1b_Ga=t,i=7,f=100;AAAA\x18agent ready\x1b\\",
			want: true,
		},
		{
			name: "text after a substituted kitty transmission",
			data: "\x1b_Ga=t,i=7,f=100;AAAA\x1aagent ready\x1b\\",
			want: true,
		},
		{
			name: "truncated kitty transmission",
			data: "\x1b_Ga=t,i=7,f=100;AAAA",
			want: false,
		},
		{
			name: "kitty transmission with an implicit store only action",
			data: "\x1b_Gi=7,f=100;AAAA\x1b\\",
			want: false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := terminalOutputHasVisibleContent([]byte(test.data)); got != test.want {
				t.Fatalf("terminalOutputHasVisibleContent() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestTerminalBellParserHonorsControlSequenceCancellation(t *testing.T) {
	for _, cancel := range []byte{0x18, 0x1a} {
		window := &muxWindow{}
		observed := window.observeTerminalOutputStateLocked(
			append([]byte("\x1b]title"), cancel, '\a'),
		)
		if !observed {
			t.Fatalf(
				"BEL after cancel byte 0x%x was treated as an OSC terminator",
				cancel,
			)
		}
	}
}

func TestTerminalProtocolResponseDoesNotStealClientFocus(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	oldPrimary := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"old",
		120,
		40,
	)
	newPrimary := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"new",
		80,
		24,
	)
	oldPrimary.expectTerminalResponses("@1", 1)

	if oldPrimary.routeInput([]byte("\x1b[?62;4c")).claimsFocus {
		server.promoteAttachClient(oldPrimary)
	}

	server.mu.Lock()
	primary := server.attachConn
	width, height := server.width, server.height
	server.mu.Unlock()
	if primary != newPrimary.conn || width != 80 || height != 24 {
		t.Fatalf(
			"protocol response changed focus to %v at %dx%d",
			primary,
			width,
			height,
		)
	}
}

func TestTerminalResponseRoutesToOriginatingWindowAfterSwitch(t *testing.T) {
	originReader, originWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	activeReader, activeWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = originReader.Close()
		_ = originWriter.Close()
		_ = activeReader.Close()
		_ = activeWriter.Close()
	})
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:           "@1",
			index:        0,
			pty:          wrapPty(t, originWriter),
			lastActivity: time.Now(),
		},
		{
			id:           "@2",
			index:        1,
			pty:          wrapPty(t, activeWriter),
			lastActivity: time.Now(),
		},
	}
	server.activeID = "@2"
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	response := []byte("\x1b[?62;4c")

	routing := client.routeInput(response)
	for _, routed := range routing.actions {
		if routed.windowID == "" {
			server.writeActiveFromAttach(routed.data)
		} else if err := server.writeWindow(routed.windowID, routed.data); err != nil {
			t.Fatal(err)
		}
	}

	if routing.claimsFocus {
		t.Fatalf("response routing = %#v, want response-only input", routing)
	}
	got := readPipeUntil(t, originReader, func(output string) bool {
		return output == string(response)
	})
	if got != string(response) {
		t.Fatalf("origin window input = %q, want %q", got, response)
	}
	_ = activeReader
}

func TestCoalescedTerminalResponsesRouteToEachOriginWindow(t *testing.T) {
	client := newAttachClient(
		&recordingConn{},
		controlMessage{ClientID: "coalesced-responses"},
	)
	t.Cleanup(client.close)
	paletteQuery := []byte("\x1b]4;0;?;7;?\x1b\\")
	paletteResponseCount := terminalQueryResponseCount(paletteQuery)
	if paletteResponseCount != 2 {
		t.Fatalf(
			"palette response count = %d, want 2",
			paletteResponseCount,
		)
	}
	firstCompletion, queued := client.enqueueTerminalQuery(
		paletteQuery,
		true,
		"@1",
		paletteResponseCount,
	)
	if !queued || !client.waitForWrite(firstCompletion) {
		t.Fatal("first window queries were not written")
	}
	secondCompletion, queued := client.enqueueTerminalQuery(
		[]byte("\x1b[>q"),
		true,
		"@2",
		1,
	)
	if !queued || !client.waitForWrite(secondCompletion) {
		t.Fatal("second window query was not written")
	}

	responses := [][]byte{
		[]byte("\x1b]4;0;rgb:0000/0000/0000\x1b\\"),
		[]byte("\x1b]4;7;rgb:ffff/ffff/ffff\x1b\\"),
		[]byte("\x1b[?1;2c"),
	}
	routing := client.routeInput(bytes.Join(responses, nil))

	if routing.claimsFocus {
		t.Fatalf("response routing = %#v, want response-only input", routing)
	}
	if len(routing.actions) != 3 {
		t.Fatalf(
			"routed response count = %d, want 3",
			len(routing.actions),
		)
	}
	wantWindows := []string{"@1", "@1", "@2"}
	for index, routed := range routing.actions {
		if routed.userInput || routed.windowID != wantWindows[index] {
			t.Errorf(
				"response %d window = %q, want %q",
				index,
				routed.windowID,
				wantWindows[index],
			)
		}
		if !bytes.Equal(routed.data, responses[index]) {
			t.Errorf(
				"response %d data = %q, want %q",
				index,
				routed.data,
				responses[index],
			)
		}
	}
}

func TestSeparateTermcapResponsesStayWithOriginWindow(t *testing.T) {
	client := newAttachClient(
		&recordingConn{},
		controlMessage{ClientID: "termcap-responses"},
	)
	t.Cleanup(client.close)
	termcapQuery := []byte("\x1bP+q544e;436f\x1b\\")
	responseCount := terminalQueryResponseCount(termcapQuery)
	if responseCount != 2 {
		t.Fatalf("termcap response count = %d, want 2", responseCount)
	}
	completion, queued := client.enqueueTerminalQuery(
		termcapQuery,
		true,
		"@1",
		responseCount,
	)
	if emptyCount := terminalQueryResponseCount(
		[]byte("\x1bP+q;;\x1b\\"),
	); emptyCount != 0 {
		t.Fatalf("empty termcap response count = %d, want 0", emptyCount)
	}
	if !queued || !client.waitForWrite(completion) {
		t.Fatal("termcap query was not written")
	}
	completion, queued = client.enqueueTerminalQuery(
		[]byte("\x1b[c"),
		true,
		"@2",
		1,
	)
	if !queued || !client.waitForWrite(completion) {
		t.Fatal("second window query was not written")
	}

	responses := []struct {
		windowID string
		data     []byte
	}{
		{
			windowID: "@1",
			data:     []byte("\x1bP1+r544e=787465726d\x1b\\"),
		},
		{
			windowID: "@1",
			data:     []byte("\x1bP0+r436f\x1b\\"),
		},
		{
			windowID: "@2",
			data:     []byte("\x1b[?62;4c"),
		},
	}
	for index, response := range responses {
		routing := client.routeInput(response.data)
		if routing.claimsFocus ||
			len(routing.actions) != 1 {
			t.Fatalf("response %d routing = %#v", index, routing)
		}
		routed := routing.actions[0]
		if routed.userInput || routed.windowID != response.windowID ||
			!bytes.Equal(routed.data, response.data) {
			t.Fatalf(
				"response %d = %#v, want %s %q",
				index,
				routed,
				response.windowID,
				response.data,
			)
		}
	}
}

func TestCombinedTermcapResponseConsumesOriginExpectations(t *testing.T) {
	client := newAttachClient(
		&recordingConn{},
		controlMessage{ClientID: "combined-termcap-response"},
	)
	t.Cleanup(client.close)
	termcapQuery := []byte("\x1bP+q544e;436f\x1b\\")
	completion, queued := client.enqueueTerminalQuery(
		termcapQuery,
		true,
		"@1",
		terminalQueryResponseCount(termcapQuery),
	)
	if !queued || !client.waitForWrite(completion) {
		t.Fatal("termcap query was not written")
	}
	completion, queued = client.enqueueTerminalQuery(
		[]byte("\x1b[c"),
		true,
		"@2",
		1,
	)
	if !queued || !client.waitForWrite(completion) {
		t.Fatal("second window query was not written")
	}

	combined := []byte(
		"\x1bP1+r544e=787465726d;436f=323536\x1b\\",
	)
	routing := client.routeInput(combined)
	if routing.claimsFocus ||
		len(routing.actions) != 1 ||
		routing.actions[0].userInput || routing.actions[0].windowID != "@1" {
		t.Fatalf("combined termcap response routing = %#v", routing)
	}
	next := client.routeInput([]byte("\x1b[?62;4c"))
	if len(next.actions) != 1 ||
		next.actions[0].userInput || next.actions[0].windowID != "@2" ||
		next.claimsFocus {
		t.Fatalf("next-window response routing = %#v", next)
	}
}

func TestExpiredTerminalResponseWindowsAreNotRevived(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()
	client.expectTerminalResponses("@2", 1)

	routing := client.routeInput([]byte("\x1b[?62;4c"))

	if len(routing.actions) != 1 {
		t.Fatalf("routed response count = %d, want 1", len(routing.actions))
	}
	if routing.actions[0].userInput || routing.actions[0].windowID != "@2" {
		t.Fatalf(
			"response window = %q, want @2",
			routing.actions[0].windowID,
		)
	}
}

func TestRenewedTerminalResponseDeadlineReschedulesHeldPrefix(t *testing.T) {
	passthrough := make(chan []byte, 1)
	client := &attachClient{
		done: make(chan struct{}),
		inputPassthrough: func(data []byte) {
			passthrough <- append([]byte(nil), data...)
		},
	}
	client.expectTerminalResponses("@1", 1)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(40 * time.Millisecond)
	client.activityMu.Unlock()
	firstRouting := client.routeInput([]byte{'\x1b'})
	if len(firstRouting.actions) != 0 {
		t.Fatalf("held prefix actions = %#v", firstRouting.actions)
	}
	time.Sleep(10 * time.Millisecond)

	client.expectTerminalResponses("@2", 1)
	select {
	case data := <-passthrough:
		t.Fatalf("renewed prefix was released early: %q", data)
	case <-time.After(60 * time.Millisecond):
	}

	routing := client.routeInput([]byte("[?62;4c"))
	if len(routing.actions) != 1 ||
		routing.actions[0].userInput || routing.actions[0].windowID != "@1" ||
		string(routing.actions[0].data) != "\x1b[?62;4c" {
		t.Fatalf("renewed response routing = %#v", routing)
	}
	close(client.done)
}

func TestResponseCarryFragmentRenewsInactivityDeadline(t *testing.T) {
	passthrough := make(chan []byte, 1)
	client := &attachClient{
		done: make(chan struct{}),
		inputPassthrough: func(data []byte) {
			passthrough <- append([]byte(nil), data...)
		},
	}
	client.expectTerminalResponses("@1", 1)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(20 * time.Millisecond)
	client.activityMu.Unlock()

	routing := client.routeInput([]byte("\x1b]52;c;AAAA"))

	if len(routing.actions) != 0 ||
		routing.claimsFocus {
		t.Fatalf("partial response routing = %#v, want held input", routing)
	}
	client.activityMu.Lock()
	renewedUntil := client.terminalResponseUntil
	client.activityMu.Unlock()
	if time.Until(renewedUntil) < time.Second {
		t.Fatalf("response deadline was not renewed: %v", renewedUntil)
	}
	select {
	case data := <-passthrough:
		t.Fatalf("response carry expired at the original deadline: %q", data)
	case <-time.After(50 * time.Millisecond):
	}
	routing = client.routeInput([]byte{'\a'})
	if len(routing.actions) != 1 ||
		routing.actions[0].userInput || routing.actions[0].windowID != "@1" ||
		string(routing.actions[0].data) != "\x1b]52;c;AAAA\a" {
		t.Fatalf("completed response routing = %#v", routing)
	}
	close(client.done)
}

func TestStreamingResponseFragmentsRenewInactivityDeadline(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(20 * time.Millisecond)
	client.activityMu.Unlock()
	largePrefix := append(
		[]byte("\x1b]52;c;"),
		bytes.Repeat([]byte{'A'}, terminalResponseCarryLimitBytes+1)...,
	)

	first := client.routeInput(largePrefix)

	if len(first.actions) != 1 ||
		first.actions[0].userInput || first.actions[0].windowID != "@1" ||
		first.claimsFocus {
		t.Fatalf("large response prefix routing = %#v", first)
	}
	client.activityMu.Lock()
	firstDeadline := client.terminalResponseUntil
	client.activityMu.Unlock()
	if time.Until(firstDeadline) < time.Second {
		t.Fatalf("streaming response deadline was not renewed: %v", firstDeadline)
	}
	time.Sleep(50 * time.Millisecond)

	second := client.routeInput([]byte("BBBB"))

	if len(second.actions) != 1 ||
		second.actions[0].userInput || second.actions[0].windowID != "@1" ||
		second.claimsFocus {
		t.Fatalf("streaming response continuation routing = %#v", second)
	}
	client.activityMu.Lock()
	secondDeadline := client.terminalResponseUntil
	client.activityMu.Unlock()
	if !secondDeadline.After(firstDeadline) {
		t.Fatalf(
			"continuation deadline %v did not advance past %v",
			secondDeadline,
			firstDeadline,
		)
	}
	final := client.routeInput([]byte{'\a'})
	if len(final.actions) != 1 ||
		final.actions[0].userInput || final.actions[0].windowID != "@1" ||
		final.claimsFocus {
		t.Fatalf("streaming response terminator routing = %#v", final)
	}
}

func TestExpiredHeldResponsePrefixIsPassedThroughBeforeRenewal(t *testing.T) {
	passthrough := make(chan []byte, 1)
	client := &attachClient{
		done: make(chan struct{}),
		inputPassthrough: func(data []byte) {
			passthrough <- append([]byte(nil), data...)
		},
	}
	client.expectTerminalResponses("@1", 1)
	if routing := client.routeInput([]byte{'\x1b'}); len(routing.actions) != 0 {
		t.Fatalf("held prefix actions = %#v", routing.actions)
	}
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()

	client.expectTerminalResponses("@2", 1)

	select {
	case data := <-passthrough:
		if !bytes.Equal(data, []byte{'\x1b'}) {
			t.Fatalf("expired prefix passthrough = %q", data)
		}
	case <-time.After(time.Second):
		t.Fatal("expired prefix was dropped")
	}
	routing := client.routeInput([]byte("\x1b[?62;4c"))
	if len(routing.actions) != 1 ||
		routing.actions[0].userInput || routing.actions[0].windowID != "@2" {
		t.Fatalf("renewed response routing = %#v", routing)
	}
	close(client.done)
}

func TestExpiredResponseFlushesAmbiguousPrefixAsOrdinaryInput(t *testing.T) {
	ordinary := make(chan []byte, 1)
	client := &attachClient{
		inputPassthrough: func(data []byte) {
			ordinary <- append([]byte(nil), data...)
		},
	}
	client.activityMu.Lock()
	client.terminalResponseCarry = []byte("reply")
	client.terminalResponsePasteStartCarry = []byte("\x1b[20")
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()

	client.expectTerminalResponses("@2", 1)

	select {
	case data := <-ordinary:
		if !bytes.Equal(data, []byte("reply\x1b[20")) {
			t.Fatalf("ordinary expired input = %q, want reply + ESC[20", data)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ordinary expired input")
	}

	routing := client.routeInput([]byte("0~hello\x1b[201~"))
	if len(routing.actions) != 1 ||
		routing.actions[0].bracketedPaste ||
		!bytes.Equal(
			routing.actions[0].data,
			[]byte("0~hello\x1b[201~"),
		) {
		t.Fatalf("late ordinary remainder routing = %#v", routing)
	}
}

func TestBracketedPasteStartIndex(t *testing.T) {
	tests := []struct {
		name              string
		data              []byte
		leadingUtf8Prefix int
		want              int
	}{
		{name: "none", data: []byte("plain text"), want: -1},
		{name: "seven bit", data: []byte("\x1b[200~x"), want: 0},
		{
			name: "seven bit with prefix",
			data: []byte("ab\x1b[200~x"),
			want: 2,
		},
		{name: "eight bit", data: []byte("\x9b200~x"), want: 0},
		{
			name: "partial is not a match",
			data: []byte("\x1b[20"),
			want: -1,
		},
		{
			name: "end marker is not a start",
			data: []byte("\x1b[201~"),
			want: -1,
		},
		{
			name: "eight bit byte inside UTF-8 is not a marker",
			data: []byte("Û200~"),
			want: -1,
		},
		{
			name:              "leading UTF-8 continuation is not a marker",
			data:              []byte("\x9b200~"),
			leadingUtf8Prefix: 1,
			want:              -1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := bracketedPasteStart(
				test.data,
				test.leadingUtf8Prefix,
			).index; got != test.want {
				t.Fatalf(
					"bracketedPasteStart(%q) = %d, want %d",
					test.data,
					got,
					test.want,
				)
			}
		})
	}
}

func enterStreamingTerminalResponseContinuation(
	t *testing.T,
	client *attachClient,
) {
	t.Helper()
	prefix := append(
		[]byte("\x1b]52;c;"),
		bytes.Repeat([]byte{'A'}, terminalResponseCarryLimitBytes+1)...,
	)
	routing := client.routeInput(prefix)
	if len(routing.actions) != 1 ||
		routing.actions[0].userInput || routing.actions[0].windowID != "@1" ||
		!bytes.Equal(routing.actions[0].data, prefix) {
		t.Fatalf("streaming prefix routing = %#v", routing)
	}
	if client.terminalResponseContinuation != ']' {
		t.Fatalf(
			"response continuation = %q, want OSC",
			client.terminalResponseContinuation,
		)
	}
}

// A bracketed paste that arrives while an incomplete query reply is held as
// carry must reach the pane intact instead of being swallowed by the reply's
// terminator search (which would strip the CSI 200~/201~ markers so an agent
// CLI renders the pasted path as plain text instead of an attachment).
func TestBracketedPastePassesThroughWhilePartialResponseHeld(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)

	held := client.routeInput([]byte("\x1b]11;rgb:1234/5678/9abc"))
	assertInputActions(t, held, nil)
	client.activityMu.Lock()
	heldCarry := len(client.terminalResponseCarry)
	client.activityMu.Unlock()
	if heldCarry == 0 {
		t.Fatal("partial reply was not held as carry")
	}

	paste := []byte(
		"\x1b[200~/home/u/.cache/monkeyssh/uploads/a.png\x1b[201~ ",
	)
	routing := client.routeInput(paste)
	assertInputActions(t, routing, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: paste[:len(paste)-1]},
		{userInput: true, data: []byte(" ")},
	})
	client.activityMu.Lock()
	remainingCarry := len(client.terminalResponseCarry)
	client.activityMu.Unlock()
	if remainingCarry != 0 {
		t.Fatalf(
			"aborted reply carry was not cleared: %d bytes",
			remainingCarry,
		)
	}

	// The window's reply expectation must survive the aborting paste: a real
	// reply that arrives afterwards still routes to the querying window, and
	// plain input keeps flowing through to the pane.
	reply := []byte("\x1b[?62;4c")
	replyRouting := client.routeInput(reply)
	assertInputActions(t, replyRouting, []attachInputAction{
		{windowID: "@1", data: reply},
	})

	typed := client.routeInput([]byte("ls\r"))
	assertInputActions(t, typed, []attachInputAction{
		{userInput: true, data: []byte("ls\r")},
	})
}

func TestSplitBracketedPastePassesThroughStreamingResponse(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)

	first := client.routeInput([]byte("more-data\x1b[20"))
	assertInputActions(t, first, []attachInputAction{
		{windowID: "@1", data: []byte("more-data")},
	})

	pasteRemainder := []byte("0~/tmp/a.png\x1b[201~ ")
	second := client.routeInput(pasteRemainder)
	wantPaste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: wantPaste[:len(wantPaste)-1]},
		{userInput: true, data: []byte(" ")},
	})

	terminator := client.routeInput([]byte{'\a'})
	assertInputActions(t, terminator, []attachInputAction{
		{windowID: "@1", data: []byte{'\a'}},
	})
}

func TestSplitBracketedPasteAtStreamingTransition(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	responsePrefix := append(
		[]byte("\x1b]52;c;"),
		bytes.Repeat([]byte{'A'}, terminalResponseCarryLimitBytes+1)...,
	)
	input := append(append([]byte(nil), responsePrefix...), []byte("\x1b[20")...)

	first := client.routeInput(input)
	assertInputActions(t, first, []attachInputAction{
		{windowID: "@1", data: responsePrefix},
	})

	remainder := []byte("0~/tmp/a.png\x1b[201~ ")
	second := client.routeInput(remainder)
	wantPaste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: wantPaste[:len(wantPaste)-1]},
		{userInput: true, data: []byte(" ")},
	})
}

func TestStreamingResponseCompletesBeforePasteAndPreservesUserPrefix(
	t *testing.T,
) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)

	paste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	input := append([]byte("\ahello "), paste...)
	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: []byte{'\a'}},
		{userInput: true, data: []byte("hello ")},
		{userInput: true, bracketedPaste: true, data: paste[:len(paste)-1]},
		{userInput: true, data: []byte(" ")},
	})
}

func TestStreamingResponseRoutesSecondReplyBeforePaste(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)
	client.expectTerminalResponses("@2", 1)

	secondReply := []byte("\x1b[?62;4c")
	paste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	input := append(append([]byte{'\a'}, secondReply...), paste...)
	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: []byte{'\a'}},
		{windowID: "@2", data: secondReply},
		{userInput: true, bracketedPaste: true, data: paste[:len(paste)-1]},
		{userInput: true, data: []byte(" ")},
	})
}

func TestResponseAfterPasteInSameReadIsRoutedAfterUserInput(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	paste := []byte("\x1b[200~/tmp/a.png\x1b[201~")
	response := []byte("\x1b[?62;4c")
	input := append(append([]byte(nil), paste...), response...)

	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: paste},
		{windowID: "@1", data: response},
	})
}

func TestResponseAfterPasteSeparatorInSameReadIsRouted(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	paste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	response := []byte("\x1b[?62;4c")
	input := append(append([]byte(nil), paste...), response...)

	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: paste[:len(paste)-1]},
		{userInput: true, data: []byte(" ")},
		{windowID: "@1", data: response},
	})
}

func TestConsecutivePasteAfterCompletedPasteIsTracked(t *testing.T) {
	client := &attachClient{}
	firstPaste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	secondPasteStart := []byte("\x1b[200~/tmp/b")
	input := append(
		append([]byte(nil), firstPaste...),
		secondPasteStart...,
	)
	first := client.routeInput(input)
	assertInputActions(t, first, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: firstPaste[:len(firstPaste)-1]},
		{userInput: true, data: []byte(" ")},
		{userInput: true, bracketedPaste: true, data: secondPasteStart},
	})
	if !client.inputBracketedPasteActive {
		t.Fatal("unexpected paste tracking state")
	}

	client.expectTerminalResponses("@1", 1)
	secondPasteEnd := []byte("\x1b[?62;4c.png\x1b[201~")
	second := client.routeInput(secondPasteEnd)
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: secondPasteEnd},
	})
	if client.inputBracketedPasteActive {
		t.Fatal("unexpected paste tracking state")
	}
}

func TestResponseAfterMultiReadPasteEndIsRouted(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	start := []byte("\x1b[200~/tmp/a")
	first := client.routeInput(start)
	assertInputActions(t, first, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: start},
	})

	end := []byte(".png\x1b[201~")
	response := []byte("\x1b[?62;4c")
	second := client.routeInput(
		append(append([]byte(nil), end...), response...),
	)
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: end},
		{windowID: "@1", data: response},
	})
}

func TestStreamingResponseTerminatorAfterPasteEndIsRouted(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)

	start := []byte("\x1b[200~/tmp/a")
	first := client.routeInput(start)
	assertInputActions(t, first, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: start},
	})
	end := []byte(".png\x1b[201~")
	second := client.routeInput(append(append([]byte(nil), end...), '\a'))
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: end},
		{windowID: "@1", data: []byte{'\a'}},
	})
}

func TestStreamingResponsePayloadAfterPasteEndIsRouted(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)

	start := []byte("\x1b[200~/tmp/a")
	first := client.routeInput(start)
	assertInputActions(t, first, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: start},
	})
	end := []byte(".png\x1b[201~ ")
	responseTail := []byte("payload\a")
	second := client.routeInput(
		append(append([]byte(nil), end...), responseTail...),
	)
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: end[:len(end)-1]},
		{userInput: true, data: []byte(" ")},
		{windowID: "@1", data: responseTail},
	})
}

func TestResponseLikeBytesInsideMultiReadPasteRemainOpaque(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)

	firstPaste := []byte("\x1b[200~/tmp/")
	first := client.routeInput(firstPaste)
	assertInputActions(t, first, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: firstPaste},
	})

	secondPaste := []byte("aÛ201~\x1b[?62;4c.png\x1b[201~ ")
	second := client.routeInput(secondPaste)
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: secondPaste[:len(secondPaste)-1]},
		{userInput: true, data: []byte(" ")},
	})

	terminator := client.routeInput([]byte{'\a'})
	assertInputActions(t, terminator, []attachInputAction{
		{windowID: "@1", data: []byte{'\a'}},
	})
}

func TestCompletedCarriedReplyDoesNotLeakBeforePaste(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	client.expectTerminalResponses("@2", 1)
	held := client.routeInput([]byte("\x1b[?6"))
	assertInputActions(t, held, nil)

	secondReplyPrefix := []byte("\x1b]11;rgb:12")
	paste := []byte("\x1b[200~x\x1b[201~")
	input := append([]byte("2;4c"), secondReplyPrefix...)
	input = append(input, paste...)
	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: []byte("\x1b[?62;4c")},
		{userInput: true, bracketedPaste: true, data: paste},
	})
}

func TestUserPrefixBeforePasteAfterHeldResponseIsPreserved(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	held := client.routeInput([]byte("\x1b]11;rgb:12"))
	assertInputActions(t, held, nil)

	input := []byte("abc\x1b[200~/tmp/a.png\x1b[201~ ")
	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{userInput: true, data: input[:3]},
		{userInput: true, bracketedPaste: true, data: input[3 : len(input)-1]},
		{userInput: true, data: input[len(input)-1:]},
	})
}

func TestSplitUtf8BeforeC1LikeTextDoesNotStartPaste(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	first := client.routeInput([]byte{0xc5})
	assertInputActions(t, first, []attachInputAction{
		{userInput: true, data: []byte{0xc5}},
	})
	second := client.routeInput([]byte{0x9b, '2', '0', '0'})
	assertInputActions(t, second, []attachInputAction{
		{userInput: true, data: []byte{0x9b, '2', '0', '0'}},
	})
	third := client.routeInput([]byte{'~'})
	assertInputActions(t, third, []attachInputAction{
		{userInput: true, data: []byte{'~'}},
	})
	if client.inputBracketedPasteActive {
		t.Fatal("unexpected paste tracking state")
	}

	response := []byte("\x1b[?62;4c")
	routing := client.routeInput(response)
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: response},
	})
}

func TestSplitPasteStartAfterUserInputActivatesOpaquePaste(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)

	first := []byte("abc\x1b[20")
	firstRouting := client.routeInput(first)
	assertInputActions(t, firstRouting, []attachInputAction{
		{userInput: true, data: []byte("abc")},
	})
	second := []byte("0~/tmp/a")
	secondRouting := client.routeInput(second)
	wantSecond := []byte("\x1b[200~/tmp/a")
	assertInputActions(t, secondRouting, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: wantSecond},
	})
	fakeResponseAndEnd := []byte("\x1b[?62;4c.png\x1b[201~")
	thirdRouting := client.routeInput(fakeResponseAndEnd)
	assertInputActions(t, thirdRouting, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: fakeResponseAndEnd},
	})
}

func TestPasteStartCarryFlushesOnResponseDeadline(t *testing.T) {
	passthrough := make(chan []byte, 1)
	client := &attachClient{
		done: make(chan struct{}),
		inputPassthrough: func(data []byte) {
			passthrough <- append([]byte(nil), data...)
		},
	}
	client.expectTerminalResponses("@1", 1)
	enterStreamingTerminalResponseContinuation(t, client)
	client.activityMu.Lock()
	generationBefore := client.terminalResponseCarryGeneration
	client.activityMu.Unlock()
	routing := client.routeInput([]byte("more\x1b[20"))
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: []byte("more")},
	})
	client.activityMu.Lock()
	generation := client.terminalResponseCarryGeneration
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()
	if generation <= generationBefore {
		t.Fatal("paste-start carry did not schedule a deadline resolver")
	}

	client.resolveAmbiguousTerminalResponseInput(generation, 0)
	select {
	case data := <-passthrough:
		if !bytes.Equal(data, []byte("\x1b[20")) {
			t.Fatalf("deadline passthrough = %q", data)
		}
	case <-time.After(time.Second):
		t.Fatal("paste-start carry was not flushed")
	}

	client.expectTerminalResponses("@2", 1)
	remainder := []byte("0~payload\x1b[?62;4c\x1b[201~")
	pasteRouting := client.routeInput(remainder)
	assertInputActions(t, pasteRouting, []attachInputAction{
		{userInput: true, data: remainder},
	})
	response := []byte("\x1b[?62;4c")
	responseRouting := client.routeInput(response)
	assertInputActions(t, responseRouting, []attachInputAction{
		{windowID: "@2", data: response},
	})
	close(client.done)
}

func TestExpiredCarryPreservesSplitBracketedPasteStart(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	held := client.routeInput([]byte("\x1b]11;rgb:12\x1b[20"))
	assertInputActions(t, held, nil)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()

	remainder := []byte("0~/tmp/a.png\x1b[201~ ")
	routing := client.routeInput(remainder)
	want := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: []byte("\x1b]11;rgb:12")},
		{userInput: true, bracketedPaste: true, data: want[:len(want)-1]},
		{userInput: true, data: []byte(" ")},
	})
}

// Content that trails the paste in the same read (after CSI 201~) must survive
// the abort and reach the pane along with the paste.
func TestTrailingInputAfterAbortingPasteIsPreserved(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	held := client.routeInput([]byte("\x1b]11;rgb:12"))
	assertInputActions(t, held, nil)

	input := []byte("\x1b[200~/tmp/a.png\x1b[201~ done\r")
	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{userInput: true, bracketedPaste: true, data: input[:len(input)-6]},
		{userInput: true, data: []byte(" ")},
		{userInput: true, data: []byte("done\r")},
	})
}

// A partial reply that expires while held must not prefix (and corrupt) a
// bracketed paste that arrives afterwards.
func TestBracketedPasteAfterExpiredCarryHasNoStalePrefix(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	held := client.routeInput([]byte("\x1b]11;rgb:12"))
	assertInputActions(t, held, nil)
	client.activityMu.Lock()
	client.terminalResponseUntil = time.Now().Add(-time.Second)
	client.activityMu.Unlock()

	paste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")
	routing := client.routeInput(paste)
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: []byte("\x1b]11;rgb:12")},
		{userInput: true, bracketedPaste: true, data: paste[:len(paste)-1]},
		{userInput: true, data: []byte(" ")},
	})
}

// A query reply that completes before a paste in the same read is still routed
// to its window, and the paste passes through untouched.
func TestCompleteResponseThenBracketedPasteRoutesBoth(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	response := []byte("\x1b[?62;4c")
	paste := []byte("\x1b[200~/tmp/a.png\x1b[201~ ")

	routing := client.routeInput(append(append([]byte(nil), response...), paste...))
	assertInputActions(t, routing, []attachInputAction{
		{windowID: "@1", data: response},
		{userInput: true, bracketedPaste: true, data: paste[:len(paste)-1]},
		{userInput: true, data: []byte(" ")},
	})
}

// Plain user input typed before a paste while a reply is expected must not be
// dropped by the paste-abort handling.
func TestUserInputBeforeBracketedPasteIsPreserved(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	input := []byte("abc\x1b[200~/tmp/a.png\x1b[201~ ")

	routing := client.routeInput(input)
	assertInputActions(t, routing, []attachInputAction{
		{userInput: true, data: input[:3]},
		{userInput: true, bracketedPaste: true, data: input[3 : len(input)-1]},
		{userInput: true, data: input[len(input)-1:]},
	})
}

func TestSplitTerminalResponseIntroducerIsRoutedOnce(t *testing.T) {
	tests := []struct {
		name     string
		first    []byte
		second   []byte
		response []byte
	}{
		{
			name:     "escape",
			first:    []byte{'\x1b'},
			second:   []byte("[?62;4c"),
			response: []byte("\x1b[?62;4c"),
		},
		{
			name:     "escape csi",
			first:    []byte("\x1b["),
			second:   []byte("?62;4c"),
			response: []byte("\x1b[?62;4c"),
		},
		{
			name:     "c1 csi",
			first:    []byte{0x9b},
			second:   []byte("?62;4c"),
			response: []byte{0x9b, '?', '6', '2', ';', '4', 'c'},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			client := &attachClient{}
			client.expectTerminalResponses("@1", 1)

			firstRouting := client.routeInput(test.first)
			if len(firstRouting.actions) != 0 ||
				firstRouting.claimsFocus {
				t.Fatalf(
					"first fragment routing = %#v, want held input",
					firstRouting,
				)
			}
			secondRouting := client.routeInput(test.second)
			if secondRouting.claimsFocus ||
				len(secondRouting.actions) != 1 {
				t.Fatalf(
					"completed response routing = %#v",
					secondRouting,
				)
			}
			routed := secondRouting.actions[0]
			if routed.userInput || routed.windowID != "@1" ||
				!bytes.Equal(routed.data, test.response) {
				t.Fatalf(
					"routed response = %#v, want @1 %q",
					routed,
					test.response,
				)
			}
		})
	}
}

func TestSplitUtf8ContinuationIsNotTreatedAsC1Response(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	encoded := []byte("丝")

	firstRouting := client.routeInput(encoded[:2])
	assertInputActions(t, firstRouting, []attachInputAction{
		{userInput: true, data: encoded[:2]},
	})
	secondRouting := client.routeInput(encoded[2:])
	assertInputActions(t, secondRouting, []attachInputAction{
		{userInput: true, data: encoded[2:]},
	})
	client.activityMu.Lock()
	carry := append([]byte(nil), client.terminalResponseCarry...)
	client.activityMu.Unlock()
	if len(carry) != 0 {
		t.Fatalf("UTF-8 continuation was held as a C1 response: %x", carry)
	}
}

func TestTerminalResponseFollowedByInputRoutesBoth(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	response := []byte("\x1b[?62;4c")

	routing := client.routeInput(append(response, 'x'))

	assertInputActions(t, routing, []attachInputAction{

		{windowID: "@1", data: response},

		{userInput: true, data: []byte("x")},
	})
}

func TestRealInputClaimsFocusDuringTerminalResponseGrace(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		120,
		40,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)
	first.expectTerminalResponses("@1", 1)

	for _, input := range [][]byte{
		[]byte("x"),
		[]byte("P"),
		[]byte("_"),
		[]byte("["),
		[]byte("\x1b[A"),
		[]byte("\x1b[I"),
		[]byte("\x1b[<0;2;3M"),
	} {
		if !first.routeInput(input).claimsFocus {
			t.Fatalf("real input %q was mistaken for a terminal response", input)
		}
	}
	server.promoteAttachClient(first)

	server.mu.Lock()
	primary := server.attachConn
	width, height := server.width, server.height
	server.mu.Unlock()
	if primary != first.conn || width != 120 || height != 40 {
		t.Fatalf(
			"real input focused %v at %dx%d, want first client at 120x40",
			primary,
			width,
			height,
		)
	}
}

func TestFocusOutDoesNotClaimClientFocus(t *testing.T) {
	for _, input := range [][]byte{
		[]byte("\x1b[O"),
		[]byte{0x9b, 'O'},
	} {
		client := &attachClient{}
		if client.routeInput(input).claimsFocus {
			t.Fatalf("focus-out report %q claimed client focus", input)
		}
	}
}

func TestSplitFocusOutDoesNotClaimClientFocus(t *testing.T) {
	client := &attachClient{}
	for _, chunk := range [][]byte{
		[]byte{'\x1b'},
		[]byte{'['},
		[]byte{'O'},
		[]byte{0x9b},
		[]byte{'O'},
	} {
		if client.routeInput(chunk).claimsFocus {
			t.Fatalf("split focus-out chunk %q claimed client focus", chunk)
		}
	}
	if !client.routeInput([]byte("x")).claimsFocus {
		t.Fatal("real input after split focus-out did not claim focus")
	}
}

func TestStandaloneEscapeClaimsFocusWithoutPoisoningLaterFocusOut(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		120,
		40,
	)
	second := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)

	if first.routeInput([]byte{'\x1b'}).claimsFocus {
		t.Fatal("ambiguous Escape claimed focus before its carry delay")
	}
	waitForPrimaryClient(t, server, first.conn, 120, 40)

	server.promoteAttachClient(second)
	if first.routeInput([]byte("\x1b[O")).claimsFocus {
		t.Fatal("later focus-out claimed focus")
	}
	waitForPrimaryClient(t, server, second.conn, 80, 24)
}

func TestDelayedEscapeDoesNotOverwriteNewerClientFocus(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		120,
		40,
	)
	second := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)

	if first.routeInput([]byte{'\x1b'}).claimsFocus {
		t.Fatal("ambiguous Escape claimed focus before its carry delay")
	}
	server.promoteAttachClient(second)
	time.Sleep(focusInputCarryDelay + 25*time.Millisecond)

	waitForPrimaryClient(t, server, second.conn, 80, 24)
}

func TestSplitTerminalProtocolResponseDoesNotClaimFocus(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)

	if client.routeInput([]byte("\x1b]11;rgb:ffff/")).claimsFocus {
		t.Fatal("partial terminal response claimed focus")
	}
	if client.routeInput([]byte("ffff/ffff\x1b\\")).claimsFocus {
		t.Fatal("completed split terminal response claimed focus")
	}
}

func TestSplitResponseEscapeDoesNotClaimFocusDuringGrace(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	responder := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"responder",
		120,
		40,
	)
	active := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"active",
		80,
		24,
	)
	responder.expectTerminalResponses("@1", 1)

	if responder.routeInput([]byte{'\x1b'}).claimsFocus {
		t.Fatal("split response Escape claimed focus immediately")
	}
	time.Sleep(focusInputCarryDelay + 25*time.Millisecond)
	waitForPrimaryClient(t, server, active.conn, 80, 24)
	if responder.routeInput([]byte("[?62;4c")).claimsFocus {
		t.Fatal("completed split terminal response claimed focus")
	}
	waitForPrimaryClient(t, server, active.conn, 80, 24)
}

func TestSupportedTerminalResponseFormsDoNotClaimFocus(t *testing.T) {
	responses := [][]byte{
		[]byte("\x1b[5;768;1024t"),
		[]byte("\x1b]Licon title\x1b\\"),
		[]byte("\x1b]lwindow title\x1b\\"),
		[]byte("\x1bP!|00000000\x1b\\"),
		[]byte{0x9b, '?', '6', '2', ';', '4', 'c'},
		[]byte{0x9d, '1', '1', ';', 'r', 'g', 'b', ':', 'f', 'f', 0x9c},
		[]byte{0x90, '!', '|', '0', '0', 0x9c},
	}
	for _, response := range responses {
		client := &attachClient{}
		client.expectTerminalResponses("@1", 1)
		if client.routeInput(response).claimsFocus {
			t.Fatalf("terminal response %q claimed focus", response)
		}
	}
}

func TestLargeSplitClipboardResponseUsesBoundedFocusParserState(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	payload := append(
		[]byte("\x1b]52;c;"),
		bytes.Repeat([]byte{'A'}, terminalResponseCarryLimitBytes+1024)...,
	)
	for len(payload) > 0 {
		size := 32 * 1024
		if len(payload) < size {
			size = len(payload)
		}
		if client.routeInput(payload[:size]).claimsFocus {
			t.Fatal("large split clipboard response claimed focus")
		}
		payload = payload[size:]
	}
	if client.routeInput([]byte{'\a'}).claimsFocus {
		t.Fatal("clipboard response terminator claimed focus")
	}
	if !client.routeInput([]byte("x")).claimsFocus {
		t.Fatal("real input after clipboard response did not claim focus")
	}
}

func TestLargeSplitResponseDoesNotTreatUtf8ContinuationAsC1ST(t *testing.T) {
	client := &attachClient{}
	client.expectTerminalResponses("@1", 1)
	payload := append(
		[]byte("\x1b]52;c;"),
		bytes.Repeat([]byte{'A'}, terminalResponseCarryLimitBytes)...,
	)
	payload = append(payload, 0xc5)
	for len(payload) > 0 {
		size := 32 * 1024
		if len(payload) < size {
			size = len(payload)
		}
		if client.routeInput(payload[:size]).claimsFocus {
			t.Fatal("large UTF-8 response prefix claimed focus")
		}
		payload = payload[size:]
	}
	if client.routeInput([]byte{0x9c, '\a'}).claimsFocus {
		t.Fatal("UTF-8 continuation byte was mistaken for C1 ST")
	}
}

func TestTerminalStringTerminatorsIgnoreUtf8ContinuationBytes(t *testing.T) {
	payload := []byte{'a', 0xc5, 0x9c, 'b', '\a'}
	end, length, ok := findOscTerminator(payload)
	if !ok || end != 4 || length != 1 {
		t.Fatalf(
			"OSC terminator = end %d length %d ok %v, want BEL at 4",
			end,
			length,
			ok,
		)
	}
	payload = []byte{'a', 0xc5, 0x9c, 'b', 0x9c}
	end, length, ok = findStringTerminator(payload)
	if !ok || end != 4 || length != 1 {
		t.Fatalf(
			"string terminator = end %d length %d ok %v, want C1 ST at 4",
			end,
			length,
			ok,
		)
	}
}

func TestQueryWriteArmsResponseGraceBeforeSocketWrite(t *testing.T) {
	conn := &responseCheckConn{}
	client := newAttachClient(conn, controlMessage{ClientID: "response-check"})
	conn.client = client
	t.Cleanup(client.close)

	completion, queued := client.enqueueTerminalQuery(
		[]byte("\x1b[c"),
		true,
		"@1",
		1,
	)
	if !queued || !client.waitForWrite(completion) {
		t.Fatal("terminal query was not written")
	}
	if conn.responseClaimedFocus {
		t.Fatal("immediate terminal response claimed focus before grace was armed")
	}
}

func TestSuccessfulQueryWriteWinsConcurrentClientClose(t *testing.T) {
	conn := &closeOnSuccessfulWriteConn{}
	client := newAttachClient(
		conn,
		controlMessage{ClientID: "close-after-write"},
	)
	conn.client = client

	completion, queued := client.enqueueTerminalQuery(
		[]byte("\x1b[c"),
		true,
		"@1",
		1,
	)
	if !queued || !client.waitForWrite(completion) {
		t.Fatal("successful query write was reported as failed after close")
	}
}

func TestAttachCloseCompletesQueuedWriteWaiters(t *testing.T) {
	client := newAttachClient(
		discardConn{},
		controlMessage{ClientID: "queued-close"},
	)
	gate := &attachWriteGate{done: make(chan struct{})}
	completion, queued := client.enqueueConditionalTerminalQuery(
		[]byte("\x1b[c"),
		true,
		"@1",
		1,
		gate,
	)
	if !queued {
		t.Fatal("conditional query was not queued")
	}

	client.close()

	select {
	case err := <-completion:
		if !errors.Is(err, io.ErrClosedPipe) {
			t.Fatalf("queued write error = %v, want closed pipe", err)
		}
	case <-time.After(time.Second):
		t.Fatal("queued write completion was not resolved on close")
	}
}

func TestWindowSelectionPromotesRequestingClient(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		120,
		40,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)

	windowIndex := 1
	server.handleControlRequest(
		newControlClient(nil),
		controlMessage{
			Type:        "select_window",
			ClientID:    "first",
			WindowIndex: &windowIndex,
		},
	)

	server.mu.Lock()
	primary := server.attachConn
	width, height := server.width, server.height
	activeID := server.activeID
	server.mu.Unlock()
	if primary != first.conn || width != 120 || height != 40 {
		t.Fatalf(
			"selecting client = %v at %dx%d, want first client at 120x40",
			primary,
			width,
			height,
		)
	}
	if activeID != "@2" {
		t.Fatalf("active window = %q, want @2", activeID)
	}
}

func TestNativeWindowSelectionSuppressesTerminalReplay(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("visible terminal"), lastActivity: time.Now()},
		{
			id:                  "@2",
			index:               1,
			history:             []byte("native placeholder replay"),
			nativeAcpBridgeID:   "0123456789abcdef0123456789abcdef",
			nativeAcpProviderID: "pi",
			alert:               true,
			lastActivity:        time.Now(),
		},
	}
	server.activeID = "@1"
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "native-client", 120, 40)
	conn.Reset()

	windowIndex := 1
	server.handleControlRequest(
		newControlClient(nil),
		controlMessage{
			Type:           "select_window",
			ClientID:       "native-client",
			WindowIndex:    &windowIndex,
			SuppressReplay: true,
		},
	)

	server.mu.Lock()
	activeID := server.activeID
	lastActiveID := server.lastActiveID
	alert := server.windows[1].alert
	server.mu.Unlock()
	if activeID != "@2" || lastActiveID != "@1" || alert {
		t.Fatalf(
			"selection state = active %q, last %q, alert %v; want @2, @1, false",
			activeID,
			lastActiveID,
			alert,
		)
	}
	if got := conn.String(); got != "" {
		t.Fatalf("suppressed native selection wrote terminal replay %q", got)
	}
}

func TestMostRecentlyFocusedRemainingClientTakesOverAfterDetach(t *testing.T) {
	server := newMuxServerWithSize("test", 160, 60)
	first := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"first",
		120,
		40,
	)
	second := registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"second",
		80,
		24,
	)
	registerTestAttachClient(
		t,
		server,
		&recordingConn{},
		"third",
		100,
		30,
	)

	server.promoteAttachClient(first)
	server.promoteAttachClient(second)
	server.removeAttachClient(second)

	server.mu.Lock()
	primary := server.attachConn
	width, height := server.width, server.height
	server.mu.Unlock()
	if primary != first.conn || width != 120 || height != 40 {
		t.Fatalf(
			"fallback client = %v at %dx%d, want prior focused client at 120x40",
			primary,
			width,
			height,
		)
	}
}

func TestAttachPrefixSwitchesWindowsAndSendsLiteralPrefix(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:           "@1",
			index:        0,
			pty:          wrapPty(t, inputWriter),
			lastActivity: time.Now(),
		},
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	client := &attachClient{prefixEnabled: true}

	if detached := server.handleAttachInput(client, []byte{0x02}); detached {
		t.Fatal("prefix byte detached the client")
	}
	if detached := server.handleAttachInput(client, []byte{'n'}); detached {
		t.Fatal("next-window command detached the client")
	}
	if got := server.activeWindowID(); got != "@2" {
		t.Fatalf("active window = %q, want @2", got)
	}
	if detached := server.handleAttachInput(client, []byte{0x02, 'p'}); detached {
		t.Fatal("previous-window command detached the client")
	}
	if got := server.activeWindowID(); got != "@1" {
		t.Fatalf("active window = %q, want @1", got)
	}
	if detached := server.handleAttachInput(client, []byte{0x02, 0x02}); detached {
		t.Fatal("literal-prefix command detached the client")
	}
	got := readPipeUntil(t, inputReader, func(output string) bool {
		return output == "\x02"
	})
	if got != "\x02" {
		t.Fatalf("literal prefix output = %q, want Ctrl-B", got)
	}
}

func TestAttachPrefixSelectsLastIndexClosesAndDetaches(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
		{id: "@3", index: 2, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "keys", 80, 24)

	server.handleAttachInput(client, []byte{0x02, '2'})
	if got := server.activeWindowID(); got != "@3" {
		t.Fatalf("indexed active window = %q, want @3", got)
	}
	server.handleAttachInput(client, []byte{0x02, 'l'})
	if got := server.activeWindowID(); got != "@1" {
		t.Fatalf("last active window = %q, want @1", got)
	}
	server.handleAttachInput(client, []byte{0x02, '&'})
	if got := server.activeWindowID(); got != "@1" {
		t.Fatalf("window closed before confirmation: active = %q", got)
	}
	server.handleAttachInput(client, []byte{'y'})
	if got := server.activeWindowID(); got != "@2" {
		t.Fatalf("active window after close = %q, want @2", got)
	}
	if detached := server.handleAttachInput(client, []byte{0x02, 'd'}); !detached {
		t.Fatal("detach prefix command did not detach")
	}
	select {
	case <-client.done:
	default:
		t.Fatal("detach prefix command left client open")
	}
}

func TestInactiveWindowOutputIsBufferedForSwitch(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@2", []byte("background output"))

	waitForTestAttachWrites(t, server)
	if got := attach.String(); got != "" {
		t.Fatalf("inactive output was written to attach: %q", got)
	}
	if got := string(inactiveWindow.history); got != "background output" {
		t.Fatalf("inactive history = %q, want buffered output", got)
	}
	if inactiveWindow.alert {
		t.Fatal("ordinary inactive output marked the window alert")
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	want := replayPrefixForTest(inactiveWindow) + "background output" +
		replayPostHistorySuffixForTest(true)
	waitForRecordedOutput(t, attach, want)
	if inactiveWindow.alert {
		t.Fatal("selected window alert was not cleared")
	}
}

func TestSelectWindowSignalsResizeAfterReplay(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	inactiveWindow.history = []byte("background output")

	originalSignalForegroundResize := signalForegroundResize
	originalDeliverForegroundGeometry := deliverForegroundGeometry
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		deliverForegroundGeometry = originalDeliverForegroundGeometry
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	wantReplay := replayPrefixForTest(inactiveWindow) + "background output" +
		replayPostHistorySuffixForTest(true)
	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(window *muxWindow) int {
		if window == inactiveWindow {
			return 4242
		}
		return 0
	}
	deliverForegroundGeometry = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	server.handleWindowOutput("@2", []byte("after resize"))
	waitForRecordedOutput(t, attach, wantReplay+"after resize")

	if !reflect.DeepEqual(signaled, []int{4242}) {
		t.Fatalf("signaled process groups = %#v, want [4242]", signaled)
	}
	if !reflect.DeepEqual(simulated, []string{"@2:80x24"}) {
		t.Fatalf("simulated resizes = %#v, want [@2:80x24]", simulated)
	}
}

func TestSelectWindowSkipsSimulatedResizeWithoutAttach(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		history:      []byte("background output"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
	}()

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	if len(simulated) != 0 {
		t.Fatalf("simulated resizes = %#v, want none without attach", simulated)
	}
}

func TestSelectWindowSimulatedResizeUsesLatestServerSize(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		history:      []byte("background output"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	originalDeliverForegroundGeometry := deliverForegroundGeometry
	defer func() {
		deliverForegroundGeometry = originalDeliverForegroundGeometry
	}()

	var simulated []string
	deliverForegroundGeometry = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}

	server.resize(100, 30)
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	if !reflect.DeepEqual(simulated, []string{"@2:100x30"}) {
		t.Fatalf("simulated resizes = %#v, want [@2:100x30]", simulated)
	}
}

func TestSelectWindowUsesForegroundRedrawReplayForAgentWindows(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("stale tui screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()

	wantReplay := replayPrefixForTest(inactiveWindow) +
		replayPostHistorySuffixForTest(true)
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		if got := attach.String(); got != "" {
			t.Fatalf("resize simulated after premature replay write: got %q", got)
		}
	}
	signalForegroundResize = func(processGroup int) {
		if got := attach.String(); got != "" {
			t.Fatalf("resize signaled after premature replay write: got %q", got)
		}
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(attach.String(), "stale tui screen") {
		t.Fatalf("redraw replay retained stale TUI history: %q", attach.String())
	}
	waitForTestAttachWrites(t, server)
	if got := attach.String(); got != "" {
		t.Fatalf("foreground redraw replay was written before redraw settled: %q", got)
	}

	server.handleWindowOutput("@2", []byte("settled tui screen"))
	waitForTestAttachWrites(t, server)
	if got := attach.String(); got != "" {
		t.Fatalf("foreground redraw output was forwarded before replay settled: %q", got)
	}

	server.mu.Lock()
	generation := inactiveWindow.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@2", generation)

	want := synchronizedTerminalOutputAfterPrefixForTest(
		wantReplay,
		"settled tui screen",
	)
	waitForRecordedOutput(t, attach, want)
	if strings.Contains(attach.String(), "stale tui screen") {
		t.Fatalf("settled foreground replay retained stale TUI history: %q", attach.String())
	}
}

func TestSelectWindowFallsBackToHistoryWhenForegroundRedrawIsEmpty(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("\x1b[Hlast known tui screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(processGroup int) {}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	// A TUI can acknowledge the resize with only reset/clear metadata while its
	// two SIGWINCH notifications are coalesced. That is still not a usable frame.
	server.handleWindowOutput(
		"@2",
		[]byte("\x1b[H\x1b[2J\x1b]0;agent\x07"),
	)

	server.mu.Lock()
	generation := inactiveWindow.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@2", generation)

	waitForTestAttachWrites(t, server)
	got := attach.String()
	if !strings.Contains(got, "last known tui screen") {
		t.Fatalf("empty foreground redraw left no visible fallback: %q", got)
	}
	if strings.Contains(got, "\x1b[H\x1b[2J\x1b]0;agent\x07") {
		t.Fatalf("failed redraw was replayed verbatim: %q", got)
	}
	// The title the TUI set during the failed redraw is real window state, so
	// the rebuilt frame carries it as a structured title replay rather than as
	// the raw redraw bytes rejected above.
	if !strings.Contains(got, "\x1b]0;agent\x07\x1b]1;agent\x07\x1b]2;agent\x07") {
		t.Fatalf("fallback frame dropped the window title: %q", got)
	}
	if !strings.HasPrefix(got, terminalSynchronizedOutputBegin) ||
		!strings.HasSuffix(got, terminalSynchronizedOutputEnd) {
		t.Fatalf("fallback replay was not painted atomically: %q", got)
	}
}

func TestEmptyForegroundRedrawFallbackReachesEveryAttachClient(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("\x1b[Hlast known shared frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	firstConn := &recordingConn{}
	secondConn := &recordingConn{}
	registerTestAttachClient(t, server, firstConn, "first", 120, 40)
	registerTestAttachClient(t, server, secondConn, "second", 120, 40)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(processGroup int) {}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	server.mu.Lock()
	generation := inactiveWindow.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@2", generation)

	for name, conn := range map[string]*recordingConn{
		"first":  firstConn,
		"second": secondConn,
	} {
		waitForRecordedContains(t, conn, "last known shared frame")
		got := conn.String()
		if !strings.HasPrefix(got, terminalSynchronizedOutputBegin) ||
			!strings.HasSuffix(got, terminalSynchronizedOutputEnd) {
			t.Fatalf("%s client fallback was not atomic: %q", name, got)
		}
	}
}

// TestEmptyThemeRedrawFallsBackToHistory covers a redraw pause that is started
// directly by resizeWithRedraw's synthetic dance (a theme change) rather than by
// a deferred window-switch replay. That path has no reset replay to send, so an
// empty redraw would otherwise leave every client blank until the next output.
func TestEmptyThemeRedrawFallsBackToHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      []byte("\x1b[Hlast known themed frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "phone", 120, 40)
	server.mu.Lock()
	server.publishedWidth = 120
	server.publishedHeight = 40
	server.mu.Unlock()

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.forceForegroundThemeRedraw("@1")
	server.mu.Lock()
	paused := window.redrawForwardingPaused
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	if !paused {
		t.Fatal("theme redraw did not pause attach forwarding")
	}
	// The TUI coalesces both SIGWINCHes and answers with metadata only.
	server.handleWindowOutput("@1", []byte("\x1b[H\x1b[2J\x1b]0;agent\x07"))
	server.resumePausedAttachForwarding("@1", generation)

	waitForRecordedContains(t, conn, "last known themed frame")
	got := conn.String()
	if strings.Contains(got, "\x1b[H\x1b[2J\x1b]0;agent\x07") {
		t.Fatalf("failed redraw was replayed verbatim: %q", got)
	}
	// The dance writes its mode replay first, so the transaction starts partway
	// through the stream; the fallback frame must sit entirely inside it.
	begin := strings.Index(got, terminalSynchronizedOutputBegin)
	if begin < 0 || !strings.HasSuffix(got, terminalSynchronizedOutputEnd) {
		t.Fatalf("theme fallback replay was not painted atomically: %q", got)
	}
	transaction := got[begin+len(terminalSynchronizedOutputBegin) : len(got)-len(terminalSynchronizedOutputEnd)]
	if !strings.Contains(transaction, "last known themed frame") {
		t.Fatalf("fallback frame painted outside the transaction: %q", got)
	}
	if strings.Contains(transaction, terminalSynchronizedOutputEnd) {
		t.Fatalf("fallback frame spanned more than one transaction: %q", got)
	}
}

// TestRestartedRedrawPauseKeepsOriginalFallback verifies a second pause started
// while the first is still in flight does not re-snapshot a history the first
// (empty) redraw already cleared, which would hand back a blank frame instead of
// the last complete one.
func TestRestartedRedrawPauseKeepsOriginalFallback(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      []byte("\x1b[Holdest complete frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)

	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	first := string(window.redrawForwardingFallbackHistory)
	// The first redraw produced only a clear, so the history no longer holds a
	// usable frame.
	window.history = []byte("\x1b[H\x1b[2J")
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	second := string(window.redrawForwardingFallbackHistory)
	server.mu.Unlock()

	if !strings.Contains(first, "oldest complete frame") {
		t.Fatalf("first pause captured no fallback: %q", first)
	}
	if second != first {
		t.Fatalf("restarted pause re-snapshotted fallback = %q, want %q", second, first)
	}
}

// TestRestartedRedrawPauseRefreshesUsableFallback is the complement: when the
// redraw during the first pause did paint a real frame, the restarted pause must
// adopt it rather than pinning the user to the older screen.
func TestRestartedRedrawPauseRefreshesUsableFallback(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      []byte("\x1b[Holdest complete frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)

	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	window.history = []byte("\x1b[Hnewer complete frame")
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	second := string(window.redrawForwardingFallbackHistory)
	server.mu.Unlock()

	if !strings.Contains(second, "newer complete frame") {
		t.Fatalf("restarted pause kept a stale fallback = %q", second)
	}
}

func TestClosedWindowsReleaseStorage(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprint(explicit), func(t *testing.T) {
			server := newMuxServer("test")
			server.windows = []*muxWindow{{id: "@anchor"}}
			server.activeID = "@anchor"
			for i := 0; i < 20; i++ {
				window := &muxWindow{id: fmt.Sprintf("@%d", i)}
				window.appendHistoryLocked([]byte("history"))
				window.observeKittyGraphicsLocked([]byte("\x1b_Gi=7,f=100;AAAA\x1b\\"))
				if len(window.kittyImages) == 0 {
					t.Fatal("image not retained before close")
				}
				server.windows = append(server.windows, window)
				storage := server.windows[:cap(server.windows)]
				if explicit {
					if _, err := server.closeWindow(window.id); err != nil {
						t.Fatal(err)
					}
				} else {
					server.markWindowClosed(window.id)
				}
				server.markWindowClosed(window.id)
				server.handleWindowOutput(window.id, []byte("late output"))
				if len(server.windows) != 1 || storage[1] != nil || !window.closed ||
					window.history != nil || window.kittyImages != nil || window.kittyImageToken != nil {
					t.Fatal("closed window retained storage")
				}
			}
		})
	}
}

func TestClosedWindowReleasesRedrawFallback(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      []byte("\x1b[Hretained frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)

	originalSimulateForegroundResize := simulateForegroundResize
	originalSignalForegroundResize := signalForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
		signalForegroundResize = originalSignalForegroundResize
	}()
	simulateForegroundResize = func(*muxWindow, int, int) {}
	signalForegroundResize = func(int) {}

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	window.redrawForwardingBuffer = []byte("buffered")
	captured := len(window.redrawForwardingFallbackHistory)
	server.mu.Unlock()
	if captured == 0 {
		t.Fatal("pause captured no fallback history to release")
	}

	server.markWindowClosed("@1")

	server.mu.Lock()
	defer server.mu.Unlock()
	if window.redrawForwardingFallbackHistory != nil ||
		window.redrawForwardingBuffer != nil ||
		window.redrawForwardingPaused {
		t.Fatalf(
			"closed window retained redraw state: history=%d buffer=%d paused=%v",
			len(window.redrawForwardingFallbackHistory),
			len(window.redrawForwardingBuffer),
			window.redrawForwardingPaused,
		)
	}
}

// TestPartialSequenceRedrawKeepsNormalForwarding verifies the fallback does not
// replace a redraw that ended mid escape sequence. Discarding it would drop the
// head of a sequence whose tail is still to come and corrupt the client, so such
// a redraw must forward normally even though it has no visible content yet.
func TestPartialSequenceRedrawKeepsNormalForwarding(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("\x1b[Hlast known tui screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	// The chunk ends inside an unterminated OSC, so its tail arrives later.
	server.handleWindowOutput("@2", []byte("\x1b[H\x1b]0;partial"))

	server.mu.Lock()
	generation := inactiveWindow.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@2", generation)

	waitForTestAttachWrites(t, server)
	got := attach.String()
	if strings.Contains(got, "last known tui screen") {
		t.Fatalf("fallback replaced a redraw that ended mid sequence: %q", got)
	}
	// The complete prefix still forwards normally; the unterminated OSC tail is
	// carried until the rest of it arrives.
	if !strings.HasSuffix(
		got,
		terminalSynchronizedOutputBegin+"\x1b[H"+terminalSynchronizedOutputEnd,
	) {
		t.Fatalf("buffered redraw prefix was not forwarded normally: %q", got)
	}
}

// TestRedrawFallbackSnapshotSurvivesHistoryRewrite pins the snapshot against
// aliasing: the history helpers can return slices backed by window.history, and
// appendHistoryLocked rewrites that buffer in place as the redraw arrives, so an
// aliased snapshot would mutate into the redraw it exists to recover from.
func TestRedrawFallbackSnapshotSurvivesHistoryRewrite(t *testing.T) {
	server := newMuxServer("test")
	// A real window's history buffer is grown to twice the limit so trims are
	// amortized; that spare capacity is what lets later appends rewrite the
	// buffer in place rather than reallocating.
	history := make([]byte, 0, 2*windowFullReplayHistoryLimitBytes)
	history = append(history, "\x1b[Hlast known tui screen"...)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)

	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	simulateForegroundResize = func(*muxWindow, int, int) {}

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	snapshot := string(window.redrawForwardingFallbackHistory)
	// Output landing while the pause is in flight rewrites the history buffer
	// starting at index 0, over the bytes an aliased snapshot would point at.
	window.appendHistoryLocked(
		bytes.Repeat([]byte("x"), windowFullReplayHistoryLimitBytes),
	)
	after := string(window.redrawForwardingFallbackHistory)
	server.mu.Unlock()

	if !strings.Contains(snapshot, "last known tui screen") {
		t.Fatalf("pause captured no fallback frame: %q", snapshot)
	}
	if after != snapshot {
		t.Fatal("history rewrite mutated the retained fallback snapshot")
	}
}

func TestAttachSignalsResizeAfterReplay(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("foreground output"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	originalSignalForegroundResize := signalForegroundResize
	originalDeliverForegroundGeometry := deliverForegroundGeometry
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		deliverForegroundGeometry = originalDeliverForegroundGeometry
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	wantReplay := replayPrefixForTest(window) + "foreground output" +
		replayPostHistorySuffixForTest(true)
	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 4343
		}
		return 0
	}
	deliverForegroundGeometry = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
		if got := attach.String(); got != wantReplay {
			t.Fatalf("resize simulated before replay was written: got %q, want %q", got, wantReplay)
		}
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
		if got := attach.String(); got != wantReplay {
			t.Fatalf("resize signaled before replay was written: got %q, want %q", got, wantReplay)
		}
	}

	server.handleAttach(
		attach,
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 120, Height: 40},
	)

	if !reflect.DeepEqual(signaled, []int{4343}) {
		t.Fatalf("signaled process groups = %#v, want [4343]", signaled)
	}
	if !reflect.DeepEqual(simulated, []string{"@1:120x40"}) {
		t.Fatalf("simulated resizes = %#v, want [@1:120x40]", simulated)
	}
}

func TestResizeOnlyUpdatesActiveWindowPty(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	setPtySize(t, inactivePty, 80, 24)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	server.resize(132, 43)

	assertPtySize(t, activePty, 132, 43)
	assertPtySize(t, inactivePty, 80, 24)
}

func TestSelectWindowResizesSelectedWindowToLatestTerminalSize(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	setPtySize(t, inactivePty, 80, 24)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(_ *muxWindow) int {
		return 0
	}
	signalForegroundResize = func(_ int) {}

	server.resize(132, 43)
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	assertPtySizeEventually(t, inactivePty, 132, 43)
}

func TestAttachOnlyUpdatesActiveWindowPty(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	setPtySize(t, inactivePty, 80, 24)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	server.handleAttach(
		&recordingConn{},
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 132, Height: 43},
	)

	assertPtySizeEventually(t, activePty, 132, 43)
	assertPtySize(t, inactivePty, 80, 24)
}

func TestAttachIgnoresOversizedThemeHint(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{{id: "@1", index: 0, lastActivity: time.Now()}}
	server.activeID = "@1"

	server.handleAttach(
		&recordingConn{},
		bufio.NewReader(strings.NewReader("")),
		controlMessage{
			Width:  132,
			Height: 43,
			Data:   strings.Repeat("x", themeHintLimitBytes+1),
		},
	)

	if len(server.themeHint) != 0 {
		t.Fatalf("theme hint length = %d, want 0", len(server.themeHint))
	}
}

func TestAttachRefreshesFocusAwareThemeHint(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "unknown-tui",
		pty:               wrapPty(t, inputWriter),
		lastActivity:      time.Now(),
	}
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	server.handleAttach(
		&recordingConn{},
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Data: backgroundReport},
	)

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[O") && strings.Contains(output, "\x1b[I")
	})
	if strings.Contains(got, backgroundReport) {
		t.Fatalf("theme hint = %q, did not expect background report", got)
	}
	if !strings.Contains(got, "\x1b[O") {
		t.Fatalf("theme hint = %q, expected focus-lost for focus-aware window", got)
	}
}

func TestCreateWindowUsesServerTerminalSize(t *testing.T) {
	server := newMuxServerWithSize("test", 132, 43)
	t.Cleanup(server.close)

	window, err := server.createWindow(createWindowOptions{
		args: []string{"/bin/sh", "-c", "sleep 0.2"},
	})
	if err != nil {
		t.Fatal(err)
	}

	assertPtySize(t, window.pty, 132, 43)
}

func TestHoldAgentWindowCommandWrapsFastFailure(t *testing.T) {
	wrapped := holdAgentWindowCommand("/bin/zsh", "cursor-agent --resume abc")

	for _, needle := range []string{
		"cursor-agent --resume abc", // runs the original command
		"__mm_rc=$?",                // captures the exit status
		"[ \"$__mm_rc\" -ne 0 ]",    // only holds on a non-zero exit
		"-lt 12 ]",                  // ...that happened quickly after launch
		"stty sane",                 // restores the terminal before the shell
		"exec '/bin/zsh' -i",        // drops to an interactive shell
	} {
		if !strings.Contains(wrapped, needle) {
			t.Fatalf("wrapped command missing %q\n got: %s", needle, wrapped)
		}
	}

	if got := holdAgentWindowCommand("/bin/zsh", "   "); got != "" {
		t.Fatalf("blank command should stay empty, got %q", got)
	}
}

func TestCreateWindowHoldsAgentWindowOpenOnFastFailure(t *testing.T) {
	setTestHomeDir(t, t.TempDir())
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("ENV", "")
	t.Setenv("BASH_ENV", "")
	server := newMuxServer("test")
	t.Cleanup(server.close)

	// `false` exits non-zero immediately; an agent window must stay open (the
	// wrapper drops to a shell) so the failure output remains readable.
	window, err := server.createWindow(createWindowOptions{
		agentTool: "cursor-agent",
		command:   "false",
	})
	if err != nil {
		t.Fatal(err)
	}

	if err := server.writeWindow(window.id, []byte("printf '%s%s\\n' round4- ready\n")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		server.mu.Lock()
		closed := window.closed
		history := string(window.history)
		server.mu.Unlock()
		if closed {
			t.Fatal("agent window closed after a fast failure")
		}
		if strings.Contains(history, "round4-ready") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("fallback shell did not execute marker: %q", history)
		}
		time.Sleep(time.Millisecond)
	}
}

// TestCloseMarksWindowsClosedSoLateWatchersAreInert covers the bounded wait: a
// child that ignores SIGHUP can outlive close, and its watcher still calls
// markWindowClosed afterwards. Closing the windows during shutdown makes that
// late call return before it touches any server state.
func TestCloseMarksWindowsClosedSoLateWatchersAreInert(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.close()

	server.mu.Lock()
	closed := window.closed
	server.mu.Unlock()
	if !closed {
		t.Fatal("close left the window open, so a late watcher would mutate server state")
	}

	// A watcher that overran the wait would call this. It must be inert rather
	// than reading the process-group hook, which tests swap between runs.
	originalPgrp := foregroundProcessGroupForWindow
	t.Cleanup(func() { foregroundProcessGroupForWindow = originalPgrp })
	foregroundProcessGroupForWindow = func(*muxWindow) int {
		t.Error("late markWindowClosed read server state after shutdown")
		return 0
	}
	server.markWindowClosed("@1")
}

func TestCreateWindowClosesNonAgentWindowOnExit(t *testing.T) {
	server := newMuxServer("test")
	t.Cleanup(server.close)

	// A non-agent window is not wrapped, so it closes when its command exits.
	window, err := server.createWindow(createWindowOptions{
		command: "false",
	})
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		server.mu.Lock()
		closed := window.closed
		server.mu.Unlock()
		if closed {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("non-agent window stayed open after its command exited")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSameSizeResizeDoesNotSignalFocusAwareTui(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		focusModeEnabled:  true,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40
	server.publishedWidth = 120
	server.publishedHeight = 40

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resize(120, 40)

	if len(signaled) != 0 {
		t.Fatalf("signaled process groups = %#v, want none", signaled)
	}
}

func TestChangedSizeResizeDoesNotBounceForegroundTui(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		privateModes:      map[string]bool{"1002": true, "1006": true, "2004": true},
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resize(120, 55)

	// A genuine size change relies on the real PTY resize (SIGWINCH at the new
	// size) to repaint the TUI. It must NOT drive the synthetic width-1 redraw
	// dance, which would produce a visible one-cell bounce on every keyboard or
	// pinch-zoom resize.
	if len(simulated) != 0 {
		t.Fatalf("changed-size resize performed synthetic dance = %#v, want none", simulated)
	}
	if !reflect.DeepEqual(signaled, []int{5151}) {
		t.Fatalf("signaled process groups = %#v, want [5151]", signaled)
	}
	waitForTestAttachWrites(t, server)
	modeReplay := attach.String()
	for _, sequence := range []string{"\x1b[?1002h", "\x1b[?1006h", "\x1b[?2004h"} {
		if !strings.Contains(modeReplay, sequence) {
			t.Fatalf("mode replay %q does not contain %q", modeReplay, sequence)
		}
	}
}

func TestChangedSizeResizeForwardsReflowImmediately(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40
	server.publishedWidth = 120
	server.publishedHeight = 40
	conn := &recordingConn{}
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {
		t.Fatal("changed-size resize must not perform the synthetic redraw dance")
	}

	server.resize(120, 55)

	// After a genuine resize the TUI's reflow must forward to attach clients
	// immediately, not be buffered behind the synchronized-redraw tail that hides
	// same-size dances. A held reflow is exactly the perceived "extra resize".
	server.handleWindowOutput("@1", []byte("reflowed line"))
	waitForTestAttachWrites(t, server)
	if got := conn.String(); !strings.Contains(got, "reflowed line") {
		t.Fatalf("changed-size reflow was withheld from attach = %q", got)
	}
	server.mu.Lock()
	paused := window.redrawForwardingPaused
	server.mu.Unlock()
	if paused {
		t.Fatal("changed-size resize paused attach forwarding")
	}
}

type failingResizePty struct{ muxPty }

func (failingResizePty) Resize(int, int) error { return io.ErrClosedPipe }

func TestFailedPtyResizePreservesCachedGeometry(t *testing.T) {
	window := &muxWindow{pty: failingResizePty{}, ptyWidth: 80, ptyHeight: 24}
	generation := window.resizeGeneration.Load()
	window.resizePty(120, 40)
	if !window.ptySizeIs(80, 24) || window.resizeGeneration.Load() == generation {
		t.Fatal("failed resize changed geometry or did not invalidate generation")
	}
	window.resizePtyIfCurrent(window.resizeGeneration.Load(), 100, 30)
	if !window.ptySizeIs(80, 24) {
		t.Fatal("failed conditional resize changed cached geometry")
	}
}

func TestForegroundRedrawDoesNotRestoreStalePtySize(t *testing.T) {
	windowPty := openTestPty(t)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          windowPty,
		lastActivity: time.Now(),
	}

	simulateForegroundResize(window, 120, 40)
	window.resizePty(80, 24)
	time.Sleep(foregroundRedrawResizeDelay + 20*time.Millisecond)

	assertPtySize(t, windowPty, 80, 24)
}

func TestForegroundRedrawDoesNotResizeClosedPty(t *testing.T) {
	windowPty := openTestPty(t)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          windowPty,
		lastActivity: time.Now(),
	}

	simulateForegroundResize(window, 120, 40)
	if err := window.closePty(windowPty); err != nil {
		t.Fatal(err)
	}
	time.Sleep(foregroundRedrawResizeDelay + 20*time.Millisecond)
}

func TestClosedUnixPtyUsesInvalidFileDescriptorSentinel(t *testing.T) {
	windowPty := openTestPty(t)

	if err := windowPty.Close(); err != nil {
		t.Fatal(err)
	}

	if got := windowPty.Fd(); got != ^uintptr(0) {
		t.Fatalf("closed pty fd = %d, want invalid sentinel", got)
	}
	if got := foregroundProcessGroupForWindow(&muxWindow{pty: windowPty}); got != 0 {
		t.Fatalf("closed pty foreground process group = %d, want 0", got)
	}
}

func TestForcedSameSizeRedrawUsesExplicitSignalWhenAvailable(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40
	// The published grid is already at the current size, so sizeChanged is false.
	server.publishedWidth = 120
	server.publishedHeight = 40

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	// A client "settle" forced redraw uses SIGWINCH on this platform instead of
	// bouncing the PTY through an intermediate size.
	server.resizeWithRedraw(120, 40, true, false, "")
	if len(simulated) != 0 {
		t.Fatalf(
			"settle redraw performed synthetic dance = %#v, want none",
			simulated,
		)
	}
	if !reflect.DeepEqual(signaled, []int{5151}) {
		t.Fatalf("signaled process groups = %#v, want [5151]", signaled)
	}

	// A restore-style forced redraw (syntheticRedraw=true) must dance so a
	// freshly relaunched agent repaints its screen.
	signaled = nil
	simulated = nil
	server.resizeWithRedraw(120, 40, true, true, "")
	if !reflect.DeepEqual(simulated, []string{"@1:120x40"}) {
		t.Fatalf("synthetic redraw dance = %#v, want [@1:120x40]", simulated)
	}
	if !reflect.DeepEqual(signaled, []int{5151}) {
		t.Fatalf("signaled process groups = %#v, want [5151]", signaled)
	}
}

func TestShouldSimulateForegroundRedraw(t *testing.T) {
	tests := []struct {
		name                   string
		forceRedraw            bool
		syntheticRedraw        bool
		dimensionsChanged      bool
		supportsExplicitSignal bool
		want                   bool
	}{
		{
			name:              "normal resize",
			dimensionsChanged: true,
		},
		{
			name:                   "same-size redraw with explicit signal",
			forceRedraw:            true,
			supportsExplicitSignal: true,
		},
		{
			name:        "same-size redraw without explicit signal",
			forceRedraw: true,
			want:        true,
		},
		{
			name:                   "changed-size redraw without explicit signal",
			forceRedraw:            true,
			dimensionsChanged:      true,
			supportsExplicitSignal: false,
		},
		{
			name:              "synthetic restore redraw",
			syntheticRedraw:   true,
			dimensionsChanged: true,
			want:              true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := shouldSimulateForegroundRedraw(
				test.forceRedraw,
				test.syntheticRedraw,
				test.dimensionsChanged,
				test.supportsExplicitSignal,
			)
			if got != test.want {
				t.Fatalf("shouldSimulateForegroundRedraw() = %t, want %t", got, test.want)
			}
		})
	}
}

func TestThemeChangedRedrawForcesForegroundRepaint(t *testing.T) {
	server := newMuxServer("test")
	var logMu sync.Mutex
	var events []string
	// A DEC 2031 window receives a synchronous color-scheme mode report as its
	// theme hint, written to the pty before the redraw.
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "copilot",
		focusModeEnabled:  true,
		pty:               &orderRecordingPty{mu: &logMu, log: &events},
		lastActivity:      time.Now(),
	}
	window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)
	server.mu.Lock()
	// The published grid already matches the client, so sizeChanged is false and
	// only the synthetic dance can force a repaint.
	server.publishedWidth = 120
	server.publishedHeight = 40
	server.mu.Unlock()

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	simulateForegroundResize = func(w *muxWindow, width int, height int) {
		logMu.Lock()
		events = append(events, fmt.Sprintf("dance:%s:%dx%d", w.id, width, height))
		logMu.Unlock()
	}
	signalForegroundResize = func(int) {}

	// theme_changed with redraw must deliver the hint to the pty AND force the
	// synthetic repaint dance even at an unchanged size, so an agent (Copilot
	// CLI) re-emits its explicitly colored header/footer bars in the new theme.
	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:   "theme_changed",
		Data:   "\x1b[?997;2n",
		Redraw: true,
	})

	logMu.Lock()
	recorded := append([]string(nil), events...)
	logMu.Unlock()
	firstWrite := slices.Index(recorded, "hint-write")
	danceIndex := slices.Index(recorded, "dance:@1:120x40")
	if firstWrite < 0 {
		t.Fatalf("theme hint was not written to the pty; events = %#v", recorded)
	}
	if danceIndex < 0 {
		t.Fatalf("theme_changed redraw did not dance; events = %#v", recorded)
	}
	if firstWrite > danceIndex {
		t.Fatalf(
			"redraw dance ran before the theme hint was delivered; events = %#v",
			recorded,
		)
	}

	// Without the redraw flag the theme hint is still delivered, but no repaint
	// dance is forced (preserving the pre-existing behavior for callers that do
	// not need a repaint).
	logMu.Lock()
	events = nil
	logMu.Unlock()
	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type: "theme_changed",
		Data: "\x1b[?997;1n",
	})
	logMu.Lock()
	recorded = append([]string(nil), events...)
	logMu.Unlock()
	for _, e := range recorded {
		if strings.HasPrefix(e, "dance:") {
			t.Fatalf(
				"theme_changed without redraw performed dance; events = %#v",
				recorded,
			)
		}
	}
}

func TestThemeChangedRedrawSkipsPlainShell(t *testing.T) {
	server := newMuxServer("test")
	// A plain shell (no agent, no alternate screen) is not a foreground-redraw
	// window, so a theme redraw must not bounce its prompt with a resize dance.
	window := &muxWindow{
		id:           "@1",
		index:        0,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)
	server.mu.Lock()
	server.publishedWidth = 120
	server.publishedHeight = 40
	server.mu.Unlock()

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	var simulated []string
	simulateForegroundResize = func(w *muxWindow, width int, height int) {
		simulated = append(simulated, w.id)
	}
	signalForegroundResize = func(int) {}

	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:   "theme_changed",
		Data:   "\x1b[?997;2n",
		Redraw: true,
	})
	if len(simulated) != 0 {
		t.Fatalf("plain shell theme redraw danced = %#v, want none", simulated)
	}
}

// TestForceForegroundThemeRedrawPinsToHintWindow verifies the redraw is pinned
// to the window that received the theme hint: if a concurrent window switch has
// changed the active window, the redraw must not dance the (now different)
// active window.
func TestForceForegroundThemeRedrawPinsToHintWindow(t *testing.T) {
	server := newMuxServer("test")
	windowA := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "copilot",
		lastActivity:      time.Now(),
	}
	windowB := &muxWindow{
		id:                "@2",
		index:             1,
		foregroundCommand: "copilot",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{windowA, windowB}
	server.activeID = "@1"
	registerTestAttachClient(t, server, &recordingConn{}, "phone", 120, 40)
	server.mu.Lock()
	server.publishedWidth = 120
	server.publishedHeight = 40
	server.mu.Unlock()

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	var simulated []string
	simulateForegroundResize = func(w *muxWindow, width int, height int) {
		simulated = append(simulated, w.id)
	}
	signalForegroundResize = func(int) {}

	// The hint targeted @1, but the active window has since switched to @2.
	// Pinning to @1 must skip the redraw rather than dance @2.
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.forceForegroundThemeRedraw("@1")
	if len(simulated) != 0 {
		t.Fatalf("redraw danced after active window changed = %#v, want none", simulated)
	}

	// When the pinned window is still active it dances normally.
	server.mu.Lock()
	server.activeID = "@1"
	server.mu.Unlock()
	server.forceForegroundThemeRedraw("@1")
	if !reflect.DeepEqual(simulated, []string{"@1"}) {
		t.Fatalf("pinned redraw dance = %#v, want [@1]", simulated)
	}
}

// TestThemeChangedRedrawSurvivesViewportDeferral covers the case where a theme
// redraw arrives while the active window is mid terminal-output-forwarding, so
// the resize is deferred (all app attaches clip the viewport). The synthetic
// redraw intent must be preserved so the replayed resize still dances; without
// it the replay drops the repaint and the stale theme remains.
func TestThemeChangedRedrawSurvivesViewportDeferral(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		foregroundCommand:        "copilot",
		terminalOutputForwarding: true,
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "primary", 80, 24)
	client.clipViewport = true
	server.mu.Lock()
	server.publishedWidth = 80
	server.publishedHeight = 24
	server.mu.Unlock()

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	var simulated []string
	simulateForegroundResize = func(w *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", w.id, width, height),
		)
	}
	signalForegroundResize = func(int) {}

	// The window is forwarding output, so the theme redraw is deferred.
	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:   "theme_changed",
		Data:   "\x1b[?997;2n",
		Redraw: true,
	})
	if len(simulated) != 0 {
		t.Fatalf("deferred theme redraw danced early = %#v, want none", simulated)
	}
	server.mu.Lock()
	pendingSynthetic := server.pendingResizeSyntheticRedraw
	window.terminalOutputForwarding = false
	server.mu.Unlock()
	if !pendingSynthetic {
		t.Fatal("deferred theme redraw did not preserve the synthetic-redraw bit")
	}

	// Once the transition is safe again, the replayed resize must still perform
	// the synthetic dance so the foreground TUI repaints in the new theme.
	server.refreshPendingViewportResize()
	if !reflect.DeepEqual(simulated, []string{"@1:80x24"}) {
		t.Fatalf("replayed theme redraw dance = %#v, want [@1:80x24]", simulated)
	}
}

// TestThemeChangedRedrawDeferralPinsToHintWindow verifies the pin survives the
// viewport deferral: if the active window changes before the deferred redraw is
// replayed, the replay must not dance the new window.
func TestThemeChangedRedrawDeferralPinsToHintWindow(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	windowA := &muxWindow{
		id:                       "@1",
		index:                    0,
		foregroundCommand:        "copilot",
		terminalOutputForwarding: true,
		lastActivity:             time.Now(),
	}
	windowB := &muxWindow{
		id:                "@2",
		index:             1,
		foregroundCommand: "copilot",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{windowA, windowB}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := registerTestAttachClient(t, server, conn, "primary", 80, 24)
	client.clipViewport = true
	server.mu.Lock()
	server.publishedWidth = 80
	server.publishedHeight = 24
	server.mu.Unlock()

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	var simulated []string
	simulateForegroundResize = func(w *muxWindow, width int, height int) {
		simulated = append(simulated, w.id)
	}
	signalForegroundResize = func(int) {}

	// Defer a theme redraw pinned to @1.
	server.handleControlRequest(newControlClient(nil), controlMessage{
		Type:   "theme_changed",
		Data:   "\x1b[?997;2n",
		Redraw: true,
	})
	server.mu.Lock()
	if server.pendingResizeThemeWindowID != "@1" {
		got := server.pendingResizeThemeWindowID
		server.mu.Unlock()
		t.Fatalf("pending theme window id = %q, want @1", got)
	}
	// Simulate the active window changing (a switch that raced the replay) while
	// the pending redraw still targets @1, and make @1's transition safe again.
	windowA.terminalOutputForwarding = false
	server.activeID = "@2"
	server.mu.Unlock()

	server.refreshPendingViewportResize()
	if len(simulated) != 0 {
		t.Fatalf("deferred redraw danced the wrong window = %#v, want none", simulated)
	}
}

func TestForegroundRedrawTemporarySize(t *testing.T) {
	tests := []struct {
		name       string
		width      int
		height     int
		wantWidth  int
		wantHeight int
		wantOK     bool
	}{
		{
			name:       "uses narrower width",
			width:      120,
			height:     40,
			wantWidth:  119,
			wantHeight: 40,
			wantOK:     true,
		},
		{
			name:       "falls back to shorter height",
			width:      1,
			height:     40,
			wantWidth:  1,
			wantHeight: 39,
			wantOK:     true,
		},
		{
			name:       "expands single cell",
			width:      1,
			height:     1,
			wantWidth:  2,
			wantHeight: 1,
			wantOK:     true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			gotWidth, gotHeight, gotOK := foregroundRedrawTemporarySize(
				test.width,
				test.height,
			)
			if gotWidth != test.wantWidth ||
				gotHeight != test.wantHeight ||
				gotOK != test.wantOK {
				t.Fatalf(
					"foregroundRedrawTemporarySize(%d, %d) = (%d, %d, %t), want (%d, %d, %t)",
					test.width,
					test.height,
					gotWidth,
					gotHeight,
					gotOK,
					test.wantWidth,
					test.wantHeight,
					test.wantOK,
				)
			}
		})
	}
}

func TestRedrawResizeBuffersIntermediateAttachOutput(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("temporary layout"))
	server.handleWindowOutput("@1", []byte("final layout"))
	waitForTestAttachWrites(t, server)
	if got := conn.String(); got != "" {
		t.Fatalf("attach output before redraw settled = %q, want empty", got)
	}

	server.resumePausedAttachForwarding("@1", generation)

	want := synchronizedTerminalOutputForTest("temporary layoutfinal layout")
	waitForRecordedOutput(t, conn, want)
}

func TestRedrawResizeBoundsLongPiTranscriptRepaint(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "pi",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	window.redrawForwardingReplay = []byte("terminal reset")
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()

	oldLine := append(
		[]byte("UNIQUE_TRANSCRIPT_HEAD\r\n"),
		bytes.Repeat([]byte("old transcript line that is superseded\r\n"), 20000)...,
	)
	server.handleWindowOutput("@1", oldLine)
	server.handleWindowOutput("@1", []byte("\x1b[Hfinal visible Pi frame"))
	server.resumePausedAttachForwarding("@1", generation)

	waitForTestAttachWrites(t, server)
	got := conn.String()
	if !strings.Contains(got, "final visible Pi frame") {
		t.Fatalf("bounded redraw dropped the final frame")
	}
	if strings.Contains(got, "UNIQUE_TRANSCRIPT_HEAD") {
		t.Fatalf("bounded redraw retained the superseded transcript head")
	}
	max := foregroundRedrawBufferLimitBytes + len("terminal reset") + 128
	if len(got) > max {
		t.Fatalf("bounded redraw = %d bytes, want <= %d", len(got), max)
	}
}

func TestRedrawResizeWrapsBufferedRedrawAtomically(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("temporary layout"))

	server.resumePausedAttachForwarding("@1", generation)
	// Output that arrives after the redraw settles (the PTY is already back at
	// full size, so this is normal steady-state output, not a resize frame) is
	// forwarded verbatim after the closed transaction — the begin and end
	// markers are always written together, never left open by a timer.
	server.handleWindowOutput("@1", []byte("late canonical layout"))

	want := synchronizedTerminalOutputForTest("temporary layout") +
		"late canonical layout"
	waitForRecordedOutput(t, conn, want)
}

func TestRedrawResizePreservesOneShotKittyTransmit(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()

	const transmit = "\x1b_Ga=t,f=24,s=1,v=1,i=7;AAAA\x1b\\"
	const placeholder = "\U0010EEEE"
	server.handleWindowOutput("@1", []byte(transmit))
	server.handleWindowOutput("@1", []byte(placeholder))
	server.resumePausedAttachForwarding("@1", generation)

	want := synchronizedTerminalOutputForTest(transmit + placeholder)
	waitForRecordedOutput(t, conn, want)
}

func TestRedrawResizeDropsSupersededBufferedAttachOutput(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("old intermediate layout"))

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 41)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("new settled layout"))

	server.resumePausedAttachForwarding("@1", generation)

	want := synchronizedTerminalOutputForTest("new settled layout")
	waitForRecordedOutput(t, conn, want)
}

func TestRedrawResizePreservesBufferedTerminalQueries(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                             "@1",
		index:                          0,
		foregroundCommand:              "codex",
		lastActivity:                   time.Now(),
		redrawForwardingPaused:         true,
		redrawForwardingGeneration:     1,
		redrawForwardingBuffer:         []byte("\x1b[>q"),
		redrawForwardingFailoverBuffer: []byte("\x1b[>q"),
		redrawForwardingQueryBuffer:    []byte("\x1b[>q"),
		redrawForwardingPrimaryConn:    conn,
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 41)
	generation := window.redrawForwardingGeneration
	buffered := string(window.redrawForwardingQueryBuffer)
	server.mu.Unlock()
	if buffered != "\x1b[>q" {
		t.Fatalf("superseded redraw query buffer = %q", buffered)
	}

	server.resumePausedAttachForwarding("@1", generation)

	want := synchronizedTerminalOutputForTest("\x1b[>q")
	waitForRecordedOutput(t, conn, want)
}

func TestRedrawResizePreservesPendingReplay(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("stale tui screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		window,
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(processGroup int) {}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	server.handleWindowOutput("@2", []byte("first redraw"))

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 41)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.handleWindowOutput("@2", []byte("settled redraw"))

	server.resumePausedAttachForwarding("@2", generation)

	wantReplay := replayPrefixForTest(window) +
		replayPostHistorySuffixForTest(true)
	want := synchronizedTerminalOutputAfterPrefixForTest(
		wantReplay,
		"settled redraw",
	)
	waitForRecordedOutput(t, conn, want)
	if strings.Contains(conn.String(), "stale tui screen") ||
		strings.Contains(conn.String(), "first redraw") {
		t.Fatalf("settled replay retained stale output: %q", conn.String())
	}
}

func TestRedrawResizeDropsBufferedAttachOutputWhenInactive(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{
		window,
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, conn, "primary", server.width, server.height)

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("old active redraw"))
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@1", generation)

	waitForTestAttachWrites(t, server)
	if got := conn.String(); got != "" {
		t.Fatalf("inactive buffered output = %q, want empty", got)
	}
}

func TestSameSizeResizeDoesNotSignalShell(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "zsh",
		focusModeEnabled:  true,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resize(120, 40)

	if len(signaled) != 0 {
		t.Fatalf("signaled process groups = %#v, want none", signaled)
	}
}

func TestAttachWriteSkipsStaleActiveWindowOutput(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@2"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	stale := []byte("stale old output")
	fresh := []byte("fresh new output")
	server.writeAttachOutputIfActive("@1", attach, stale, stale, stale, nil, ^uint64(0), 0)
	server.writeAttachOutputIfActive("@2", attach, fresh, fresh, fresh, nil, ^uint64(0), 0)

	waitForRecordedOutput(t, attach, "fresh new output")
}

func TestAttachInputDropsFocusReportsUntilActiveWindowEnablesFocus(t *testing.T) {
	server := newMuxServer("test")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	window := &muxWindow{id: "@1", index: 0, pty: wrapPty(t, writer), lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.writeActiveFromAttach([]byte("typed\x1b[I\x1b[Oinput"))
	if err := window.pty.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}

	if got := string(output); got != "typedinput" {
		t.Fatalf("pty input = %q, want focus reports stripped", got)
	}
}

func TestBracketedPasteInputPreservesFocusReportBytes(t *testing.T) {
	server := newMuxServer("test")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	window := &muxWindow{id: "@1", index: 0, pty: wrapPty(t, writer), lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.writeActiveFromAttachInput(
		[]byte("\x1b[200~typed\x1b[I\x1b[Oinput\x1b[201~"),
		true,
	)
	if err := window.pty.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}

	if got := string(output); got != "\x1b[200~typed\x1b[I\x1b[Oinput\x1b[201~" {
		t.Fatalf("pty input = %q, want opaque bracketed paste", got)
	}
}

func TestBlockedInputWriteDoesNotBlockTerminalResponseRegistration(t *testing.T) {
	server := newMuxServer("test")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	window := &muxWindow{id: "@1", index: 0, pty: wrapPty(t, writer), lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	clientConn, peerConn := net.Pipe()
	defer peerConn.Close()
	client := &attachClient{
		conn:            clientConn,
		inputQueueReady: make(chan struct{}, 1),
		done:            make(chan struct{}),
	}
	go server.runAttachInputActions(client)
	if !client.enqueueInputActions([]attachInputAction{{
		userInput: true,
		data:      bytes.Repeat([]byte{'x'}, 1024*1024),
	}}) {
		t.Fatal("could not enqueue blocking input action")
	}

	deadline := time.Now().Add(time.Second)
	for client.inputMu.TryLock() {
		client.inputMu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("input worker did not enter the blocking pty write")
		}
		time.Sleep(time.Millisecond)
	}

	registered := make(chan struct{})
	go func() {
		client.expectTerminalResponses("@1", 1)
		close(registered)
	}()
	select {
	case <-registered:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("terminal response registration blocked behind pty input")
	}

	_ = window.pty.Close()
	client.close()
}

func TestAttachInputPreservesFocusReportsForActiveFocusAwareWindow(t *testing.T) {
	server := newMuxServer("test")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	defer reader.Close()
	window := &muxWindow{
		id:               "@1",
		index:            0,
		pty:              wrapPty(t, writer),
		lastActivity:     time.Now(),
		focusModeEnabled: true,
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.writeActiveFromAttach([]byte("typed\x1b[I\x1b[Oinput"))
	if err := window.pty.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}

	if got := string(output); got != "typed\x1b[I\x1b[Oinput" {
		t.Fatalf("pty input = %q, want focus reports preserved", got)
	}
}

func TestInactiveWindowBellParsing(t *testing.T) {
	for _, tt := range []struct {
		name      string
		chunks    [][]byte
		wantAlert bool
		wantTitle string
	}{
		{"bell marks alert", [][]byte{[]byte("background output\a")}, true, ""},
		{"UTF-8 before bell marks alert", [][]byte{{'x', 0xe2, 0x80, 0x9d, '\a'}}, true, ""},
		{"OSC terminator does not mark alert", [][]byte{[]byte("\x1b]0;build\x07")}, false, "build"},
		{"OSC UTF-8 payload does not mark alert", [][]byte{{'\x1b', ']', '0', ';', 'u', 't', 'f', '8', ' ', 0xc5, 0x9c, '\a'}}, false, ""},
		{"split OSC terminator does not mark alert", [][]byte{[]byte("\x1b]0;bui"), []byte("ld\x07")}, false, "build"},
		{"C1 OSC terminator does not mark alert", [][]byte{[]byte("\x9d0;build\a")}, false, ""},
		{"split C1 OSC terminator does not mark alert", [][]byte{[]byte("\x9d0;bui"), []byte("ld\a")}, false, ""},
		{"bell after C1 ST marks alert", [][]byte{[]byte("\x9d0;build\x9c\a")}, true, ""},
		{"split UTF-8 continuation does not start OSC", [][]byte{{0xe2, 0x80}, {0x9d, '\a'}}, true, ""},
		{"bell after OSC marks alert", [][]byte{[]byte("\x1b]0;build\x07\a")}, true, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			server := newMuxServer("test")
			inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
			server.windows = []*muxWindow{
				{id: "@1", index: 0, lastActivity: time.Now()},
				inactiveWindow,
			}
			server.activeID = "@1"

			for _, chunk := range tt.chunks {
				server.handleWindowOutput("@2", chunk)
			}

			if inactiveWindow.alert != tt.wantAlert {
				t.Fatalf("inactive window alert = %v, want %v", inactiveWindow.alert, tt.wantAlert)
			}
			if tt.wantTitle != "" && inactiveWindow.paneTitle != tt.wantTitle {
				t.Fatalf("pane title = %q, want %q", inactiveWindow.paneTitle, tt.wantTitle)
			}
		})
	}
}

func TestActiveReplayIncludesWindowHistory(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("previous screen"), lastActivity: time.Now()},
	}
	server.activeID = "@1"

	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	server.mu.Lock()
	replay := server.activeReplayLocked()
	server.mu.Unlock()
	server.writeAttach(attach, replay)

	window := server.windows[0]
	want := replayPrefixForTest(window) + "previous screen" +
		replayPostHistorySuffixForTest(true)
	waitForRecordedOutput(t, attach, want)
}

func TestActiveReplayIsCappedForResponsiveSwitching(t *testing.T) {
	server := newMuxServer("test")
	history := bytes.Repeat([]byte("a"), windowReplayLimitBytes+4096)
	copy(history[len(history)-6:], []byte("suffix"))
	server.windows = []*muxWindow{
		{
			id:                "@1",
			index:             0,
			foregroundCommand: "zsh",
			history:           history,
			lastActivity:      time.Now(),
		},
	}
	server.activeID = "@1"

	replay := server.activeReplayLocked()

	window := server.windows[0]
	if len(replay) > len(replayPrefixForTest(window))+windowReplayLimitBytes+2048 {
		t.Fatalf("replay length = %d, want capped near %d", len(replay), len(replayPrefixForTest(window))+windowReplayLimitBytes)
	}
	if !strings.HasSuffix(
		strings.TrimSuffix(string(replay), replayPostHistorySuffixForTest(true)),
		"suffix",
	) {
		t.Fatalf("replay did not preserve recent output suffix")
	}
}

func TestActiveReplayUsesForegroundRedrawForTrackedAlternateScreenHistory(t *testing.T) {
	for _, mode := range []string{"1047", "1049"} {
		t.Run(mode, func(t *testing.T) {
			server := newMuxServer("test")
			enterAlternateScreen := "\x1b[?" + mode + "h"
			history := []byte(
				enterAlternateScreen +
					"alternate-screen-start" +
					strings.Repeat("alternate-screen-history", windowReplayLimitBytes/8) +
					"alternate-screen-end",
			)
			window := &muxWindow{
				id:           "@1",
				index:        0,
				history:      history,
				lastActivity: time.Now(),
			}
			server.windows = []*muxWindow{window}
			server.activeID = "@1"

			window.observeTerminalModesLocked(history)
			replay := string(server.activeReplayLocked())

			if strings.Contains(replay, "alternate-screen-start") ||
				strings.Contains(replay, "alternate-screen-end") {
				t.Fatalf("alternate-screen redraw replay retained stale history: %q", replay)
			}
			if !strings.Contains(
				replay,
				enterAlternateScreen+terminalScreenClearSequence,
			) {
				t.Fatalf("alternate-screen redraw replay did not clear stale alternate buffer: %q", replay)
			}
			if got, want := len(window.history), len(history); got != want {
				t.Fatalf("history length = %d, want %d", got, want)
			}
		})
	}
}

func TestActiveReplayUsesForegroundRedrawForAgentHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"agent-main-screen-start" +
			strings.Repeat("conversation-history", windowHistoryLimitBytes/8) +
			"agent-main-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "codex",
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "agent-main-screen-start") ||
		strings.Contains(replay, "agent-main-screen-end") {
		t.Fatalf("agent redraw replay retained stale history: %q", replay)
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplayDropsAgentAlternateScreenHistory(t *testing.T) {
	server := newMuxServer("test")
	enterAlternateScreen := "\x1b[?1049h"
	history := []byte(
		enterAlternateScreen +
			"agent-alternate-screen-start" +
			strings.Repeat("conversation-history", windowReplayLimitBytes/8) +
			"agent-alternate-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "codex",
		history:      history,
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "agent-alternate-screen-start") ||
		strings.Contains(replay, "agent-alternate-screen-end") {
		t.Fatalf("agent alternate-screen replay retained stale history: %q", replay)
	}
	if !strings.Contains(replay, enterAlternateScreen+terminalScreenClearSequence) {
		t.Fatalf("agent alternate-screen replay did not clear stale alternate buffer: %q", replay)
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplaySkipsRunawayAgentHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"agent-main-screen-start" +
			strings.Repeat("conversation-history", windowFullReplayHistoryLimitBytes/4) +
			"agent-main-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := server.activeReplayLocked()

	if len(replay) > len(replayPrefixForTest(window))+2048 {
		t.Fatalf("redraw replay length = %d, want no retained history", len(replay))
	}
	if strings.Contains(string(replay), "agent-main-screen") {
		t.Fatalf("agent redraw replay retained runaway history: %q", replay)
	}
}

func TestActiveReplayUsesForegroundRedrawForVimAlternateScreenHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"interactive-main-screen-start" +
			strings.Repeat("tui-history", windowReplayLimitBytes/8) +
			"interactive-main-screen-end",
	)
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "vim",
		history:           history,
		privateModes:      map[string]bool{"1049": true},
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "interactive-main-screen-start") ||
		strings.Contains(replay, "interactive-main-screen-end") {
		t.Fatalf("interactive redraw replay retained stale history: %q", replay)
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplayPreservesNonRedrawForegroundHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte("tail output\nlatest line\n")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "tail",
		history:           history,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.Contains(replay, string(history)) {
		t.Fatalf("line-oriented foreground replay = %q, want history", replay)
	}
}

func TestActiveReplayPrefixClearsMainAndAlternateScreens(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("shell prompt"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.Contains(replayPrefixForTest(window), terminalAllScreensClearSequence) {
		t.Fatal("replay prefix does not clear both main and alternate screens")
	}
	clearIndex := strings.Index(replay, terminalAllScreensClearSequence)
	historyIndex := strings.Index(replay, "shell prompt")
	if clearIndex < 0 || historyIndex < 0 || clearIndex > historyIndex {
		t.Fatalf("main-screen replay did not clear stale alternate buffer before history: %q", replay)
	}
}

func TestActiveReplayCapsExitedAlternateScreenHistory(t *testing.T) {
	for _, mode := range []string{"1047", "1049"} {
		t.Run(mode, func(t *testing.T) {
			server := newMuxServer("test")
			history := []byte(
				"\x1b[?" + mode + "h" +
					"stale-alt-screen-start" +
					strings.Repeat("main-screen-output", windowReplayLimitBytes/8) +
					"main-screen-suffix",
			)
			window := &muxWindow{
				id:           "@1",
				index:        0,
				history:      history,
				lastActivity: time.Now(),
			}
			server.windows = []*muxWindow{window}
			server.activeID = "@1"

			window.observeTerminalModesLocked(
				[]byte("\x1b[?" + mode + "h" + "\x1b[?" + mode + "l"),
			)
			replay := string(server.activeReplayLocked())

			if strings.Contains(replay, "stale-alt-screen-start") {
				t.Fatalf("main-screen replay retained stale alternate-screen prefix")
			}
			if !strings.Contains(replay, "main-screen-suffix") {
				t.Fatalf("main-screen replay lost recent suffix")
			}
		})
	}
}

func TestReplayStripsTerminalResponseQueries(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:    "@1",
			index: 0,
			history: []byte(
				"before" +
					"\x1b[c" +
					"\x1b[>0c" +
					"\x1b[=c" +
					"\x1b[6n" +
					"\x1b[14t" +
					"\x1b[4$p" +
					"\x1b[?2031$p" +
					"\x1b[?996n" +
					"\x1b[?u" +
					"\x1b[>q" +
					"\x1b]11;?\x07" +
					"\x1b]52;c;?\x07" +
					"\x1bP$qm\x1b\\" +
					"\x1bP+q544e\x1b\\" +
					"\x1b_Ga=q,i=31;AAAA\x1b\\" +
					"\x1b]2;Gemini\x07" +
					"after",
			),
			lastActivity: time.Now(),
		},
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	for _, stripped := range []string{
		"\x1b[c",
		"\x1b[>0c",
		"\x1b[=c",
		"\x1b[6n",
		"\x1b[14t",
		"\x1b[4$p",
		"\x1b[?2031$p",
		"\x1b[?996n",
		"\x1b[?u",
		"\x1b[>q",
		"\x1b]11;?\x07",
		"\x1b]52;c;?\x07",
		"\x1bP$qm\x1b\\",
		"\x1bP+q544e\x1b\\",
		"\x1b_Ga=q,i=31;AAAA\x1b\\",
	} {
		if strings.Contains(replay, stripped) {
			t.Fatalf("replay retained terminal query %q in %q", stripped, replay)
		}
	}
	if !strings.Contains(replay, "\x1b]2;Gemini\x07") {
		t.Fatalf("replay stripped title update: %q", replay)
	}
	if !strings.Contains(replay, "before") || !strings.Contains(replay, "after") {
		t.Fatalf("replay = %q, want normal output preserved", replay)
	}
}

func TestReplayStripsC1TerminalQueries(t *testing.T) {
	query := []byte{0x9b, 'c'}
	history := append([]byte("before"), append(query, []byte("after")...)...)

	replay := stripTerminalQueriesFromReplay(history)

	if got := string(replay); got != "beforeafter" {
		t.Fatalf("C1 query replay = %q, want normal output only", got)
	}
}

func TestReplayStripDoesNotCopyCleanHistory(t *testing.T) {
	history := []byte("prompt\x1b]2;Gemini\x07safe")

	replay := stripTerminalQueriesFromReplay(history)

	if len(replay) == 0 {
		t.Fatal("replay is empty")
	}
	replay[0] = 'P'
	if history[0] != 'P' {
		t.Fatal("clean replay history was copied, want original slice reused")
	}
}

func TestReplayStripRemovesDesktopNotifications(t *testing.T) {
	history := []byte("before" +
		"\x1b]9;build finished\x07" +
		"\x1b]777;notify;Deploy;done\x07" +
		"\x1b]99;i=1:d=0;Tests\x1b\\" +
		"\x1b]99;i=1:p=body;412 ok\x1b\\" +
		"middle" +
		"\x1b]9;4;1;50\x07" + // ConEmu progress: not a notification
		"after")

	replay := string(stripTerminalQueriesFromReplay(history))

	for _, stripped := range []string{
		"build finished",
		"\x1b]777;notify;Deploy;done\x07",
		"412 ok",
	} {
		if strings.Contains(replay, stripped) {
			t.Fatalf("replay retained notification %q in %q", stripped, replay)
		}
	}
	if !strings.Contains(replay, "\x1b]9;4;1;50\x07") {
		t.Fatalf("replay stripped ConEmu OSC 9 progress: %q", replay)
	}
	if !strings.Contains(replay, "before") ||
		!strings.Contains(replay, "middle") ||
		!strings.Contains(replay, "after") {
		t.Fatalf("replay = %q, want normal output preserved", replay)
	}
}

func TestObserveKittyGraphicsRetainsImageAcrossHistoryEviction(t *testing.T) {
	window := &muxWindow{}

	transmit := []byte(
		"\x1b_Ga=T,U=1,i=10871563,c=8,r=4,f=100,q=2;iVBORw0KGgo=\x1b\\")
	window.observeKittyGraphicsLocked(transmit)
	// Flood with later output that would evict the transmit from any rolling
	// history; the retained cache must be unaffected.
	window.observeKittyGraphicsLocked(
		bytes.Repeat([]byte("placeholder frame "), 100000))

	replay := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "i=10871563") ||
		!strings.Contains(replay, "iVBORw0KGgo=") {
		t.Fatalf("retained image lost after eviction-scale output: %q", replay)
	}
	if strings.Contains(replay, "a=T") {
		t.Fatalf("retained transmit not downgraded to store-only: %q", replay)
	}
}

func TestObserveKittyGraphicsReassemblesSplitTransmission(t *testing.T) {
	window := &muxWindow{}

	// Split a single transmission across several observe calls, including a
	// break inside the base64 payload and between continuation chunks.
	full := "\x1b_Ga=T,U=1,i=5,c=8,r=4,f=100,m=1;AAAA\x1b\\" +
		"\x1b_Gm=1;BBBB\x1b\\" +
		"\x1b_Gm=0;CCCC\x1b\\"
	// Feed byte-by-byte to stress chunk-boundary handling.
	for i := 0; i < len(full); i++ {
		window.observeKittyGraphicsLocked([]byte{full[i]})
	}

	replay := string(window.kittyImageReplayLocked(nil))
	for _, want := range []string{"AAAA", "BBBB", "CCCC", "i=5"} {
		if !strings.Contains(replay, want) {
			t.Fatalf("split transmission missing %q: %q", want, replay)
		}
	}
}

func TestObserveKittyGraphicsRetainsAnimationCommandsInOrder(t *testing.T) {
	window := &muxWindow{}
	stream := []byte(
		"\x1b_Ga=T,U=1,i=7,f=100;ROOT\x1b\\" +
			"\x1b_Ga=f,i=7,f=100,m=1;FRAME-A\x1b\\" +
			"\x1b_Gm=0;FRAME-B\x1b\\" +
			"\x1b_Ga=c,i=7,r=2,c=1,w=1,h=1\x1b\\" +
			"\x1b_Ga=a,i=7,r=1,z=80,s=3,v=1\x1b\\")

	window.observeKittyGraphicsLocked(stream)
	replay := string(window.kittyImageReplayLocked(nil))

	parts := []string{"ROOT", "FRAME-A", "FRAME-B", "a=c", "a=a"}
	last := -1
	for _, part := range parts {
		index := strings.Index(replay, part)
		if index <= last {
			t.Fatalf("animation replay order lost at %q: %q", part, replay)
		}
		last = index
	}
	if strings.Contains(replay, "a=T") {
		t.Fatalf("root transmit must be replayed store-only: %q", replay)
	}
}

func TestObserveKittyGraphicsResolvesImageNumberAnimations(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,I=5,f=100;ROOT\x1b\\" +
			"\x1b_Ga=f,I=5,f=100;FRAME\x1b\\" +
			"\x1b_Ga=a,I=5,s=3,v=1\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	for _, want := range []string{"i=7,I=5", "a=f,f=100", "a=a,s=3", "i=7"} {
		if !strings.Contains(replay, want) {
			t.Fatalf("image-number animation missing %q: %q", want, replay)
		}
	}
	if strings.Count(replay, "I=5") != 2 {
		t.Fatalf("animation commands were not canonicalized to id 7: %q", replay)
	}
}

func TestObserveKittyGraphicsRetainsPlacementAndAnimationMappings(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,f=100;ROOT7\x1b\\" +
			"\x1b_Ga=t,i=8,f=100;ROOT8\x1b\\" +
			"\x1b_Ga=p,i=7,I=9,c=1,r=1\x1b\\" +
			"\x1b_Ga=f,i=8,I=9,f=100;FRAME8\x1b\\" +
			"\x1b_Ga=a,I=9,s=3,v=1\x1b\\"))

	if got := window.kittyImageNumberToID["9"]; got != "8" {
		t.Fatalf("image number 9 maps to %q, want 8", got)
	}
	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, "a=p") {
		t.Fatalf("placement command must not be replayed: %q", replay)
	}
	if !strings.Contains(replay, "FRAME8") ||
		!strings.Contains(replay, "a=a") ||
		!strings.Contains(replay, "i=8") {
		t.Fatalf("mapped animation history missing from image 8: %q", replay)
	}
	if !strings.Contains(replay, "i=8,I=9,q=2") {
		t.Fatalf("current image-number mapping missing from replay: %q", replay)
	}
}

func TestObserveKittyGraphicsRetainsImageNumberOnlyRoot(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,I=5,f=100;ROOT1\x1b\\" +
			"\x1b_Ga=t,I=5,f=100;ROOT2\x1b\\" +
			"\x1b_Ga=f,I=5,f=100;FRAME2\x1b\\" +
			"\x1b_Ga=a,I=5,s=3,v=1\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	for _, want := range []string{
		"ROOT1",
		"ROOT2",
		"a=f,I=5",
		"FRAME2",
		"a=a,I=5",
	} {
		if !strings.Contains(replay, want) {
			t.Fatalf("image-number-only replay missing %q: %q", want, replay)
		}
	}
	if len(window.kittyImages) != 2 {
		t.Fatalf("retained %d I-only roots, want 2", len(window.kittyImages))
	}
	if strings.Index(replay, "ROOT1") > strings.Index(replay, "ROOT2") {
		t.Fatalf("I-only root order changed: %q", replay)
	}
	latestID := window.kittyImageNumberToID["5"]
	if !strings.Contains(string(window.kittyImageAnimations[latestID]), "FRAME2") {
		t.Fatalf("latest I-only root did not retain its animation")
	}
}

func TestObserveKittyGraphicsKeepsImageNumberOnZeroIDAnimations(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=0,I=5,f=100;ROOT\x1b\\" +
			"\x1b_Ga=f,I=5,f=100;FRAME\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "a=f,I=5") {
		t.Fatalf("zero-id animation lost its image-number reference: %q", replay)
	}
	if strings.Contains(replay, "a=f,i=0") {
		t.Fatalf("zero id was treated as canonical during replay: %q", replay)
	}
}

func TestKittyAnimationReplaySuppressesProtocolResponses(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,i=7,I=5,f=100,q=0;ROOT\x1b\\" +
			"\x1b_Ga=f,i=7,f=100,q=0;FRAME\x1b\\" +
			"\x1b_Ga=a,i=7,s=3,v=1,q=0\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, "q=0") {
		t.Fatalf("replay retained response-producing quiet mode: %q", replay)
	}
	if got := strings.Count(replay, "q=2"); got != 4 {
		t.Fatalf("replay q=2 count = %d, want 4: %q", got, replay)
	}
	if strings.Contains(replay, "a=T") {
		t.Fatalf("root replay was not downgraded to store-only: %q", replay)
	}
}

func TestKittyAnimationDoesNotReorderImageNumberRoots(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,I=5,f=100;ROOT7\x1b\\" +
			"\x1b_Ga=t,i=8,I=5,f=100;ROOT8\x1b\\" +
			"\x1b_Ga=f,i=7,f=100;FRAME7\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	root8 := strings.Index(replay, "ROOT8")
	frame7 := strings.Index(replay, "FRAME7")
	if root8 < 0 || frame7 < 0 || frame7 > root8 {
		t.Fatalf("animation mutation reordered root mapping: %q", replay)
	}
	if got := window.kittyImageNumberToID["5"]; got != "8" {
		t.Fatalf("image number 5 maps to %q, want 8", got)
	}
}

func TestKittyReplayDoesNotRestoreStaleImageNumberMapping(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,I=5,f=100;ROOT7\x1b\\" +
			"\x1b_Ga=t,i=8,I=5,f=100;ROOT8\x1b\\"))
	for i := 0; i < maxReplayedKittyImages; i++ {
		window.observeKittyGraphicsLocked([]byte(fmt.Sprintf(
			"\x1b_Ga=t,i=%d,f=100;OTHER%d\x1b\\",
			100+i,
			i,
		)))
	}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=f,i=7,f=100;FRAME7\x1b\\"),
	)

	replay := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "ROOT7") || strings.Contains(replay, "ROOT8") {
		t.Fatalf("test precondition did not select only the older mapped root: %q", replay)
	}
	if strings.Contains(replay, "i=7,I=5") {
		t.Fatalf("older root restored stale image-number mapping: %q", replay)
	}
	if !strings.Contains(replay, "a=f,i=7") ||
		strings.Contains(replay, "a=f,I=5") {
		t.Fatalf("older animation was not canonicalized to image id 7: %q", replay)
	}
}

func TestObserveKittyGraphicsDropsAnimationThatExceedsPerIDBudget(t *testing.T) {
	originalBudget := kittyImagePerIDBudgetBytes
	kittyImagePerIDBudgetBytes = 160
	t.Cleanup(func() { kittyImagePerIDBudgetBytes = originalBudget })

	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=t,i=7,I=5,f=100;ROOT\x1b\\"),
	)
	for i := 0; i < 20 && len(window.kittyImages) > 0; i++ {
		window.observeKittyGraphicsLocked(
			[]byte("\x1b_Ga=a,I=5,s=3,v=1,q=2\x1b\\"),
		)
	}

	if len(window.kittyImages) != 0 ||
		len(window.kittyImageAnimations) != 0 ||
		len(window.kittyImageReplayLocked(nil)) != 0 {
		t.Fatalf("oversized animation replay cache was not dropped")
	}
	if _, ok := window.kittyImageNumberToID["5"]; ok {
		t.Fatalf("image-number mapping survived cache eviction")
	}
}

func TestObserveKittyGraphicsNewRootResetsRetainedAnimation(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,f=100;OLD-ROOT\x1b\\" +
			"\x1b_Ga=f,i=7,f=100;OLD-FRAME\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=t,i=7,f=100;NEW-ROOT\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "NEW-ROOT") {
		t.Fatalf("replacement root missing: %q", replay)
	}
	if strings.Contains(replay, "OLD-ROOT") || strings.Contains(replay, "OLD-FRAME") {
		t.Fatalf("replacement root retained stale animation state: %q", replay)
	}
}

func TestObserveKittyGraphicsSoftDeleteKeepsRetainedImage(t *testing.T) {
	window := &muxWindow{}

	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=7,f=100;PAYLOAD\x1b\\"))
	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=i,i=7\x1b\\"))
	if got := window.kittyImageReplayLocked(nil); !strings.Contains(string(got), "PAYLOAD") {
		t.Fatalf("soft-deleted image data was not retained: %q", got)
	}
}

func TestObserveKittyGraphicsHardDeleteRemovesRetainedImage(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=7,f=100;PAYLOAD\x1b\\"))

	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,d=I,i=7\x1b\\"))
	if got := window.kittyImageReplayLocked(nil); len(got) != 0 {
		t.Fatalf("hard-deleted image id=7 still retained: %q", got)
	}
}

func TestObserveKittyGraphicsPreservesSameChunkHardDeleteOrder(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=T,U=1,i=7,I=5,f=100;ROOT\x1b\\" +
			"\x1b_Ga=f,i=7,f=100;FRAME\x1b\\" +
			"\x1b_Ga=d,d=I,i=7\x1b\\"))

	if got := window.kittyImageReplayLocked(nil); len(got) != 0 {
		t.Fatalf("same-chunk hard delete resurrected retained image: %q", got)
	}
	if _, ok := window.kittyImageNumberToID["5"]; ok {
		t.Fatalf("same-chunk hard delete retained image-number mapping")
	}
}

func TestObserveKittyGraphicsAppliesDeleteAllInStreamOrder(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,I=5,f=100;ROOT7\x1b\\" +
			"\x1b_Ga=t,i=8,I=6,f=100;ROOT8\x1b\\" +
			"\x1b_Ga=d,d=A\x1b\\" +
			"\x1b_Ga=t,i=9,I=7,f=100;ROOT9\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, "ROOT7") || strings.Contains(replay, "ROOT8") {
		t.Fatalf("d=A retained image data transmitted before it: %q", replay)
	}
	if !strings.Contains(replay, "ROOT9") {
		t.Fatalf("d=A removed image data transmitted after it: %q", replay)
	}
	if len(window.kittyImageNumberToID) != 1 ||
		window.kittyImageNumberToID["7"] != "9" {
		t.Fatalf("d=A left stale image-number mappings: %#v", window.kittyImageNumberToID)
	}
}

func TestObserveKittyGraphicsInvalidatesForPositionalHardDeletes(t *testing.T) {
	for _, selector := range []string{"C", "P", "X", "Y"} {
		t.Run(selector, func(t *testing.T) {
			window := &muxWindow{}
			window.observeKittyGraphicsLocked([]byte(
				"\x1b_Ga=t,i=7,I=5,f=100;ROOT\x1b\\" +
					"\x1b_Ga=d,d=" + selector + ",x=1,y=1\x1b\\"))

			if got := window.kittyImageReplayLocked(nil); len(got) != 0 {
				t.Fatalf("d=%s retained conservatively matched image data: %q", selector, got)
			}
			if len(window.kittyImageNumberToID) != 0 {
				t.Fatalf("d=%s retained image-number mappings", selector)
			}
		})
	}
}

func TestObserveKittyGraphicsDeleteByNumberRemovesRetainedImage(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=t,i=7,I=5,f=100;PAYLOAD\x1b\\"),
	)

	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=d,d=N,I=5\x1b\\"),
	)

	if got := window.kittyImageReplayLocked(nil); len(got) != 0 {
		t.Fatalf("image deleted by number still retained: %q", got)
	}
	if _, ok := window.kittyImageNumberToID["5"]; ok {
		t.Fatalf("deleted image-number mapping still retained")
	}
}

func TestObserveKittyGraphicsHardDeleteByNumberKeepsUnrelatedImages(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,I=5,f=100;ROOT7\x1b\\" +
			"\x1b_Ga=t,i=8,I=6,f=100;ROOT8\x1b\\" +
			"\x1b_Ga=d,d=I,I=5\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, "ROOT7") {
		t.Fatalf("d=I,I=5 retained targeted image: %q", replay)
	}
	if !strings.Contains(replay, "ROOT8") {
		t.Fatalf("d=I,I=5 removed unrelated image: %q", replay)
	}
}

func TestObserveKittyGraphicsUnaddressedIDDeleteKeepsAllImages(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked([]byte(
		"\x1b_Ga=t,i=7,I=5,f=100;ROOT7\x1b\\" +
			"\x1b_Ga=t,i=8,I=6,f=100;ROOT8\x1b\\" +
			"\x1b_Ga=d,d=I\x1b\\"))

	replay := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "ROOT7") || !strings.Contains(replay, "ROOT8") {
		t.Fatalf("unaddressed d=I removed retained images: %q", replay)
	}
}

func TestObserveKittyGraphicsCapsRetainedImageCount(t *testing.T) {
	window := &muxWindow{}

	for i := 0; i < maxRetainedKittyImages+5; i++ {
		seq := fmt.Sprintf(
			"\x1b_Ga=T,U=1,i=%d,I=%d,f=100;DATA%d\x1b\\",
			i, i, i,
		)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	if len(window.kittyImageOrder) > maxRetainedKittyImages {
		t.Fatalf("retained %d images, want <= %d",
			len(window.kittyImageOrder), maxRetainedKittyImages)
	}
	// The oldest images are evicted; the most recent are kept.
	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, "DATA0") {
		t.Fatalf("oldest image should have been evicted: %q", replay)
	}
	if _, ok := window.kittyImageNumberToID["0"]; ok {
		t.Fatalf("evicted image-number mapping should be removed")
	}
	newest := fmt.Sprintf("DATA%d", maxRetainedKittyImages+4)
	if !strings.Contains(replay, newest) {
		t.Fatalf("newest image %q missing: %q", newest, replay)
	}
}

func TestObserveKittyGraphicsCapsMappingOnlyImageNumbers(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=t,i=7,f=100;ROOT\x1b\\"),
	)
	for i := 0; i < maxRetainedKittyImageNumbers+20; i++ {
		window.observeKittyGraphicsLocked([]byte(fmt.Sprintf(
			"\x1b_Ga=p,i=7,I=%d,c=1,r=1\x1b\\",
			i+1,
		)))
	}

	if got := len(window.kittyImageNumberToID); got > maxRetainedKittyImageNumbers {
		t.Fatalf("retained %d image-number mappings, want <= %d",
			got, maxRetainedKittyImageNumbers)
	}
	if _, ok := window.kittyImageNumberToID["1"]; ok {
		t.Fatalf("oldest image-number mapping survived bounded insertion")
	}
	if got := window.kittyImageNumberToID[fmt.Sprintf("%d", maxRetainedKittyImageNumbers+20)]; got != "7" {
		t.Fatalf("recent image-number mapping = %q, want 7", got)
	}
	if !strings.Contains(string(window.kittyImageReplayLocked(nil)), "i=7,I=") {
		t.Fatalf("bounded image-number mappings were not replayed")
	}

	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=t,i=8,I=999,f=100;NEWROOT\x1b\\"),
	)
	if got := window.kittyImageNumberToID["999"]; got != "8" {
		t.Fatalf("new root mapping at cap = %q, want 8", got)
	}
	if got := len(window.kittyImageNumberToID); got > maxRetainedKittyImageNumbers {
		t.Fatalf("new root grew mapping table to %d", got)
	}
	if !strings.Contains(string(window.kittyImageReplayLocked(nil)), "NEWROOT") {
		t.Fatalf("new root at mapping cap was not retained")
	}
}

func TestKittyImageReplayCapsCount(t *testing.T) {
	window := &muxWindow{}
	// Transmit more images than the replay count cap. Each is tiny so the byte
	// budget never binds; only the count cap should.
	const transmitted = maxReplayedKittyImages + 8
	for i := 0; i < transmitted; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;D%d\x1b\\", i, i)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	replay := string(window.kittyImageReplayLocked(nil))
	if got := strings.Count(replay, "i="); got > maxReplayedKittyImages {
		t.Fatalf("replayed %d images, want <= %d", got, maxReplayedKittyImages)
	}
	// The most-recent image is replayed; an image older than the cap is not.
	newest := fmt.Sprintf("D%d\x1b", transmitted-1)
	if !strings.Contains(replay, newest) {
		t.Fatalf("newest image %q missing from replay", newest)
	}
	oldestKept := transmitted - maxReplayedKittyImages
	tooOld := fmt.Sprintf("i=%d,", oldestKept-1)
	if strings.Contains(replay, tooOld) {
		t.Fatalf("image %q older than the replay cap should be omitted", tooOld)
	}

	// Mutating that older root makes it recent for selection without changing
	// the root transmission order used to preserve image-number mappings.
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=f,i=0,f=100;RECENT_FRAME\x1b\\"),
	)
	replay = string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "i=0,") ||
		!strings.Contains(replay, "RECENT_FRAME") {
		t.Fatalf("recently animated older root missing from replay: %q", replay)
	}
}

func TestKittyImageTransmissionsForReplaysRequestedIdsBeyondReplayCap(t *testing.T) {
	window := &muxWindow{}
	// Transmit more images than the replay caps would ever send at once, using
	// distinct payloads so a request can target an early (older-than-cap) id.
	const transmitted = maxReplayedKittyImages + 8
	for i := 0; i < transmitted; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;PAY%d\x1b\\", i, i)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	// An id well outside the "most recent N" replay window is omitted by the
	// bounded switch replay...
	const oldID = "0"
	if strings.Contains(string(window.kittyImageReplayLocked(nil)), "i=0,") {
		t.Fatalf("precondition: id 0 should be beyond the bounded replay cap")
	}
	// ...but a targeted request replays exactly it.
	payload, served := window.kittyImageTransmissionsForLocked([]string{oldID})
	got := string(payload)
	if !strings.Contains(got, "i=0,") || !strings.Contains(got, "PAY0") {
		t.Fatalf("requested id 0 not replayed: %q", got)
	}
	if strings.Contains(got, "PAY1") {
		t.Fatalf("only the requested id should be replayed: %q", got)
	}
	if strings.Contains(got, "a=T") {
		t.Fatalf("requested transmit must stay store-only (a=t): %q", got)
	}
	if !reflect.DeepEqual(served, []string{oldID}) {
		t.Fatalf("served ids = %#v, want [%s]", served, oldID)
	}
}

func TestKittyImageTransmissionsForSkipsUnknownAndDeduplicates(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=11,f=100;ALPHA\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=22,f=100;BETA\x1b\\"))

	// Unknown ids are skipped; a duplicated id is emitted once.
	payload, served := window.kittyImageTransmissionsForLocked(
		[]string{"11", "999", "11", ""},
	)
	got := string(payload)
	if strings.Count(got, "i=11,") != 1 {
		t.Fatalf("id 11 should be replayed exactly once: %q", got)
	}
	if strings.Contains(got, "i=22,") {
		t.Fatalf("unrequested id 22 must not be replayed: %q", got)
	}
	if strings.Contains(got, "i=999") {
		t.Fatalf("unknown id 999 must be skipped: %q", got)
	}
	if !reflect.DeepEqual(served, []string{"11"}) {
		t.Fatalf("served ids = %#v, want [11]", served)
	}
	// No ids requested replays nothing.
	payload, served = window.kittyImageTransmissionsForLocked(nil)
	if len(payload) != 0 || len(served) != 0 {
		t.Fatalf("empty request must replay nothing")
	}
}

func TestKittyImageReplayCapsBytes(t *testing.T) {
	window := &muxWindow{}
	// Use ~1 MiB images and transmit enough total to exceed the byte budget so
	// it binds before the count cap. Derived from the constant so the test stays
	// valid if the cap changes, while staying within the retention caps.
	const imgBytes = 1024 * 1024
	count := maxReplayedKittyImageBytes/imgBytes + 4
	if count > maxRetainedKittyImages {
		count = maxRetainedKittyImages
	}
	big := strings.Repeat("Z", imgBytes)
	for i := 0; i < count; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;%s\x1b\\", i, big)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	replay := window.kittyImageReplayLocked(nil)
	if len(replay) > maxReplayedKittyImageBytes {
		t.Fatalf("replay %d bytes exceeds budget %d",
			len(replay), maxReplayedKittyImageBytes)
	}
	// At least one image (the most recent) is always replayed.
	newest := fmt.Sprintf("i=%d,", count-1)
	if !strings.Contains(string(replay), newest) {
		t.Fatalf("most-recent image %q missing from byte-capped replay", newest)
	}
}

func TestLongAgentImageHistoryKeepsInitialAttachReplayBounded(t *testing.T) {
	window := &muxWindow{}
	// Mirrors the reproduced 100+ MiB Pi session: 27 retained screenshots
	// totaling roughly 10 MiB. Initial attach must not enqueue all of them.
	const imageCount = 27
	payload := strings.Repeat("P", 384*1024)
	for i := 0; i < imageCount; i++ {
		window.observeKittyGraphicsLocked([]byte(fmt.Sprintf(
			"\x1b_Ga=T,U=1,i=%d,f=100;%s\x1b\\",
			i+1,
			payload,
		)))
	}

	replay := window.kittyImageReplayLocked(nil)
	if len(replay) > maxReplayedKittyImageBytes {
		t.Fatalf("long-session replay = %d bytes, limit = %d",
			len(replay), maxReplayedKittyImageBytes)
	}
	if !strings.Contains(string(replay), fmt.Sprintf("i=%d,", imageCount)) {
		t.Fatalf("newest likely-visible image missing from bounded replay")
	}
	// An omitted older image remains available through post-attach repair.
	repair, served := window.kittyImageTransmissionsForLocked([]string{"1"})
	if len(repair) == 0 || !reflect.DeepEqual(served, []string{"1"}) {
		t.Fatalf("older image was not available for repair: served=%#v", served)
	}
}

func TestKittyImageReplaySkipsOversizedImageAndKeepsSmallerCandidate(t *testing.T) {
	window := &muxWindow{
		kittyImages: map[string][]byte{
			"1": []byte("\x1b_Ga=t,i=1,f=100;SMALL\x1b\\"),
			"2": bytes.Repeat([]byte{'X'}, maxReplayedKittyImageBytes+1),
		},
		kittyImageOrder: []string{"1", "2"},
		kittyImageSeq:   map[string]uint64{"1": 1, "2": 2},
	}

	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, strings.Repeat("X", 1024)) {
		t.Fatalf("oversized image was included in replay")
	}
	if !strings.Contains(replay, "SMALL") {
		t.Fatalf("smaller candidate was not replayed after oversized image")
	}
	if len(replay) > maxReplayedKittyImageBytes {
		t.Fatalf("replay exceeded attach-safe byte budget: %d", len(replay))
	}
}

func TestKittyImageReplaySkipsImagesClientAlreadyHolds(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=101,f=100;AAAABBBBCCCC\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=f,i=101,f=100;FRAME101\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=202,f=100;DDDDEEEEFFFF\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=303,I=5,f=100;ROOT303\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=f,i=303,f=100;FRAME303\x1b\\"))

	// The client reports holding image 101 with its true signature and image
	// 202 with a stale signature (different content). Only 101 may be skipped.
	clientHas := map[string]uint32{
		"101": window.kittyImageToken["101"],
		"202": window.kittyImageToken["202"] ^ 0x1,
		"303": window.kittyImageToken["303"],
	}
	replay := string(window.kittyImageReplayLocked(clientHas))
	if strings.Contains(replay, "AAAABBBBCCCC") {
		t.Fatalf("image 101 root should be skipped; client holds it: %q", replay)
	}
	if !strings.Contains(replay, "FRAME101") {
		t.Fatalf("image 101 animation updates must still be replayed: %q", replay)
	}
	if !strings.Contains(replay, "i=202") {
		t.Fatalf("image 202 has a stale client signature and must be re-sent: %q",
			replay)
	}
	if strings.Contains(replay, "ROOT303") ||
		!strings.Contains(replay, "i=303,I=5,q=2") ||
		!strings.Contains(replay, "FRAME303") {
		t.Fatalf("held root should replay mapping and animation only: %q", replay)
	}
	// A nil skip-set (fresh attach) still replays everything.
	full := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(full, "AAAABBBBCCCC") ||
		!strings.Contains(full, "DDDDEEEEFFFF") ||
		!strings.Contains(full, "ROOT303") {
		t.Fatalf("nil skip-set must replay every image: %q", full)
	}
}

func TestRequestedKittyImagesUsePostAttachRepairByteLimit(t *testing.T) {
	window := &muxWindow{
		kittyImages: map[string][]byte{
			"1": bytes.Repeat([]byte{'a'}, 5*1024*1024),
			"2": bytes.Repeat([]byte{'b'}, 5*1024*1024),
		},
	}

	payload, served := window.kittyImageTransmissionsForLocked(
		[]string{"1", "2"},
	)

	if len(payload) != 5*1024*1024 {
		t.Fatalf("requested image payload = %d bytes, want 5 MiB", len(payload))
	}
	if len(payload) > maxKittyImageRepairBytes {
		t.Fatalf("requested image payload exceeded repair limit: %d", len(payload))
	}
	if !reflect.DeepEqual(served, []string{"1"}) {
		t.Fatalf("served ids = %#v, want [1]", served)
	}
}

func TestKittyTransmissionPayloadSignatureMatchesClientHash(t *testing.T) {
	// "aGVsbG8=" is base64 for "hello"; the client's FNV-1a-32 over "hello" is
	// 3314369016 (verified against the Dart terminalGraphicsSourceSignature).
	buf := []byte("\x1b_Ga=t,i=1,f=100;aGVsbG8=\x1b\\")
	if got := kittyTransmissionPayloadSignature(buf); got != 3314369016 {
		t.Fatalf("payload signature = %d, want 3314369016 (client parity)", got)
	}
	// Whitespace in the payload is ignored, matching the client's lenient decode.
	spaced := []byte("\x1b_Ga=t,i=1,f=100;aGVs bG8=\n\x1b\\")
	if got := kittyTransmissionPayloadSignature(spaced); got != 3314369016 {
		t.Fatalf("whitespace payload signature = %d, want 3314369016", got)
	}
	// No payload yields 0, which never matches a client-reported signature.
	if got := kittyTransmissionPayloadSignature([]byte("\x1b_Ga=d,i=1\x1b\\")); got != 0 {
		t.Fatalf("payload-less transmission signature = %d, want 0", got)
	}
	// A multi-chunk (m=1) transmission must hash the concatenation of every
	// chunk's decoded payload, identically to the same image sent in one chunk.
	// The client appends each decoded chunk into one buffer before hashing, so
	// "hel" ("aGVs") + "lo" ("bG8=") must hash the same as "hello" above. Kitty
	// splits any payload over 4096 base64 bytes this way, so without covering
	// every chunk no real screenshot's signature would ever match the client.
	multi := []byte("\x1b_Ga=t,i=1,f=100,m=1;aGVs\x1b\\\x1b_Gm=0;bG8=\x1b\\")
	if got := kittyTransmissionPayloadSignature(multi); got != 3314369016 {
		t.Fatalf("multi-chunk payload signature = %d, want 3314369016", got)
	}
}

func TestGlobalKittyImageBudgetEvictsAcrossWindows(t *testing.T) {
	saved := kittyImageGlobalBudgetBytes
	defer func() { kittyImageGlobalBudgetBytes = saved }()
	// Tiny budget so a couple of ~1 MiB images exceed it across two windows.
	kittyImageGlobalBudgetBytes = 2 * 1024 * 1024

	w1 := &muxWindow{id: "@1"}
	w2 := &muxWindow{id: "@2"}
	server := newMuxServer("test")
	server.windows = []*muxWindow{w1, w2}

	big := strings.Repeat("Z", 1024*1024)
	store := func(w *muxWindow, id int) {
		w.observeKittyGraphicsLocked(
			[]byte(fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;%s\x1b\\", id, big)),
		)
		server.enforceGlobalKittyImageBudgetLocked()
	}

	// Store oldest in w1, then newer images in w2; the global cap must evict the
	// older w1 image even though w1 is under its own per-window cap.
	store(w1, 1)
	store(w2, 2)
	store(w2, 3)

	total := 0
	for _, w := range server.windows {
		for _, b := range w.kittyImages {
			total += len(b)
		}
	}
	if total > kittyImageGlobalBudgetBytes {
		t.Fatalf("global image bytes %d exceed budget %d", total,
			kittyImageGlobalBudgetBytes)
	}
	if _, ok := w1.kittyImages["1"]; ok {
		t.Fatalf("oldest image (w1 id=1) should have been globally evicted")
	}
	if _, ok := w2.kittyImages["3"]; !ok {
		t.Fatalf("newest image (w2 id=3) must be retained")
	}
}

func TestGlobalKittyImageBudgetKeepsAtLeastOne(t *testing.T) {
	saved := kittyImageGlobalBudgetBytes
	defer func() { kittyImageGlobalBudgetBytes = saved }()
	// Budget smaller than a single image: it must keep the one image rather than
	// drop everything (which would render blank).
	kittyImageGlobalBudgetBytes = 1024

	w := &muxWindow{id: "@1"}
	server := newMuxServer("test")
	server.windows = []*muxWindow{w}
	w.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=9,f=100;" + strings.Repeat("Z", 4096) + "\x1b\\"),
	)
	server.enforceGlobalKittyImageBudgetLocked()

	if len(w.kittyImages) != 1 {
		t.Fatalf("expected to keep the single image, have %d", len(w.kittyImages))
	}
}

func TestComputeKittyImageGlobalBudgetClampsToRange(t *testing.T) {
	const floor = 32 * 1024 * 1024
	const ceiling = 512 * 1024 * 1024
	got := computeKittyImageGlobalBudgetBytes()
	if got < floor || got > ceiling {
		t.Fatalf("budget %d out of clamp range [%d,%d]", got, floor, ceiling)
	}
}

func TestActiveOutputStillPassesTerminalQueriesThrough(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	server.handleWindowOutput("@1", []byte("live\x1b[c\x1b]11;?\x07query"))

	waitForRecordedOutput(t, attach, "live\x1b[c\x1b]11;?\x07query")
}

func newThemeQueryTestServer(t *testing.T, window *muxWindow) (*os.File, *muxServer) {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	original := foregroundProcessGroupForWindow
	pid := window.foregroundPid
	t.Cleanup(func() {
		foregroundProcessGroupForWindow = original
		_ = reader.Close()
		_ = writer.Close()
	})
	window.pty = wrapPty(t, writer)
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return pid
		}
		return 0
	}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	return reader, server
}

// TestActiveOutputStripsLocallyAnsweredThemeQueryFromAttach guards against the
// "hermes spew" regression: when MonkeyMux can answer an OSC theme query from
// its cached theme hint, the query bytes must be removed from the chunk
// forwarded to the attach (SSH client) side. Otherwise the client would also
// answer the query, and that duplicate response would round-trip back through
// the attach input pipe into the active window's PTY, where the TUI renders
// it as literal text.
func TestActiveOutputStripsLocallyAnsweredThemeQueryFromAttach(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		lastActivity:      time.Now(),
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	attach := &recordingConn{}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	server.themeHint = []byte(backgroundReport)

	server.handleWindowOutput("@1", []byte("hello\x1b]11;?\x1b\\world"))

	waitForRecordedOutput(t, attach, "helloworld")

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("window pty got = %q, want background report %q", got, backgroundReport)
	}
}

func TestActiveOutputStripsSplitLocallyAnsweredThemeQueryFromAttach(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		lastActivity:      time.Now(),
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	attach := &recordingConn{}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	server.themeHint = []byte(backgroundReport)

	server.handleWindowOutput("@1", []byte("hello\x1b]11;?"))
	waitForRecordedOutput(t, attach, "hello")

	server.handleWindowOutput("@1", []byte("\x1b\\world"))

	waitForRecordedOutput(t, attach, "helloworld")

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("window pty got = %q, want background report %q", got, backgroundReport)
	}
}

func TestThemeHintRefreshDataSuppressesOscUnderWin32InputMode(t *testing.T) {
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	// A focus-aware agent window normally receives an unsolicited OSC 11 refresh.
	baseline := &muxWindow{focusModeEnabled: true, agentTool: "codex"}
	if got := baseline.themeHintRefreshDataLocked(hint); len(got) == 0 {
		t.Fatalf("baseline themeHintRefreshDataLocked = %q, want an OSC push", got)
	}

	// Under win32-input-mode (Windows ConPTY) that OSC would be delivered to the
	// app as literal typed characters, so it must be suppressed.
	win32 := &muxWindow{
		focusModeEnabled: true,
		agentTool:        "codex",
		win32InputMode:   true,
	}
	if got := win32.themeHintRefreshDataLocked(hint); len(got) != 0 {
		t.Fatalf("win32 themeHintRefreshDataLocked = %q, want no OSC push", got)
	}
}

func TestThemeHintRefreshDataKeepsModeReportUnderWin32InputMode(t *testing.T) {
	hint := []byte("\x1b[?997;2n\x1b]11;rgb:1111/2222/3333\x1b\\")
	// Any DEC 2031 window receives the CSI color-scheme mode report (safe to
	// relay through ConPTY, which parses CSI into input events rather than typed
	// text) but not the OSC color report that would surface as literal composer
	// text. The gate is the mode itself, not a per-agent allowlist.
	window := &muxWindow{
		foregroundCommand: "unknown-tui",
		win32InputMode:    true,
	}
	window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	got := string(window.themeHintRefreshDataLocked(hint))
	if strings.Contains(got, "]11;") {
		t.Fatalf("themeHintRefreshDataLocked = %q, must not include OSC 11", got)
	}
	if !strings.Contains(got, "\x1b[?997;2n") {
		t.Fatalf("themeHintRefreshDataLocked = %q, want the mode report", got)
	}
}

// TestWin32InputModeAnswersPaletteQueryWithEncodedDefaults covers the ConPTY
// (Windows) theme path: conhost enables DEC private mode 9001 at startup,
// swallows the child's OSC 10/11 default-colour queries, forwards its OSC 4
// palette queries, and drops raw OSC written into the pty input. When a
// palette query is observed under win32-input-mode, the answer must volunteer
// the default foreground/background reports as well, and everything written
// into the pty must be win32-input-mode encoded.
func TestWin32InputModeAnswersPaletteQueryWithEncodedDefaults(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "copilot",
		foregroundPid:     42,
		lastActivity:      time.Now(),
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	const foregroundReport = "\x1b]10;rgb:aaaa/bbbb/cccc\x1b\\"
	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	const paletteReport = "\x1b]4;0;rgb:0000/0000/0000\x1b\\"
	server.themeHint = []byte(foregroundReport + backgroundReport + paletteReport)

	server.handleWindowOutput("@1", []byte("\x1b[?9001h\x1b]4;0;?\x1b\\"))

	encodedPalette := win32EncodeSequence(paletteReport)
	encodedForeground := win32EncodeSequence(foregroundReport)
	encodedBackground := win32EncodeSequence(backgroundReport)
	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, encodedPalette) &&
			strings.Contains(output, encodedForeground) &&
			strings.Contains(output, encodedBackground)
	})
	if strings.Contains(got, "\x1b]") {
		t.Fatalf("window pty got raw OSC bytes under win32-input-mode: %q", got)
	}
}

// TestWin32InputModeResetRestoresRawThemeAnswers verifies that once DEC
// private mode 9001 is reset, theme answers are written raw again and default
// colour reports are no longer volunteered.
func TestWin32InputModeResetRestoresRawThemeAnswers(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		lastActivity:      time.Now(),
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	server.themeHint = []byte(backgroundReport)

	server.handleWindowOutput("@1", []byte("\x1b[?9001h\x1b[?9001l\x1b]11;?\x1b\\"))

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("window pty got = %q, want raw background report %q", got, backgroundReport)
	}
}

// TestActiveOutputKeepsUnansweredPaletteQueryInAttach verifies that when the
// theme hint cannot answer every key in a multi-key OSC 4 palette query, the
// query is left intact so the SSH client can still reply.
func TestActiveOutputKeepsUnansweredPaletteQueryInAttach(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	server.themeHint = []byte("\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\")

	server.handleWindowOutput("@1", []byte("\x1b]4;0;?;7;?\x1b\\"))

	waitForRecordedOutput(t, attach, "\x1b]4;0;?;7;?\x1b\\")
}

func TestStripLocallyAnsweredThemeQueriesConsumesSplitPiIdentity(t *testing.T) {
	window := &muxWindow{}
	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("before\x1b]1337;MonkeyMuxPi=abc"),
		nil,
	)
	if got := string(first); got != "before" {
		t.Fatalf("first filtered output = %q, want before", got)
	}
	second := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("123\x07after"),
		nil,
	)
	if got := string(second); got != "after" {
		t.Fatalf("second filtered output = %q, want after", got)
	}
}

func TestStripLocallyAnsweredThemeQueriesLeavesNormalOutput(t *testing.T) {
	chunk := []byte("plain text without queries\x1b]2;Title\x07")
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	got := stripLocallyAnsweredThemeQueries(chunk, hint)
	if string(got) != string(chunk) {
		t.Fatalf("got = %q, want unchanged %q", got, chunk)
	}
}

func TestStripLocallyAnsweredThemeQueriesIsNoopWithoutHint(t *testing.T) {
	chunk := []byte("\x1b]11;?\x1b\\")

	got := stripLocallyAnsweredThemeQueries(chunk, nil)
	if string(got) != string(chunk) {
		t.Fatalf("got = %q, want unchanged %q", got, chunk)
	}
}

func TestStripLocallyAnsweredThemeQueriesStripsAnsweredQuery(t *testing.T) {
	chunk := []byte("before\x1b]11;?\x07middle\x1b]4;5;?\x1b\\after")
	hint := []byte(
		"\x1b]11;rgb:1111/2222/3333\x1b\\" +
			"\x1b]4;5;rgb:aaaa/bbbb/cccc\x1b\\",
	)

	got := stripLocallyAnsweredThemeQueries(chunk, hint)
	if string(got) != "beforemiddleafter" {
		t.Fatalf("got = %q, want %q", got, "beforemiddleafter")
	}
}

func TestStripLocallyAnsweredThemeQueriesBuffersSplitAnsweredQuery(t *testing.T) {
	window := &muxWindow{}
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("before\x1b]11;?"),
		hint,
	)
	if string(first) != "before" {
		t.Fatalf("first chunk = %q, want prefix only", first)
	}
	if string(window.attachOscBuffer) != "\x1b]11;?" {
		t.Fatalf("attach OSC buffer = %q, want split query", window.attachOscBuffer)
	}

	second := window.stripLocallyAnsweredThemeQueriesLocked([]byte("\x1b\\after"), hint)
	if string(second) != "after" {
		t.Fatalf("second chunk = %q, want answered query stripped", second)
	}
	if len(window.attachOscBuffer) != 0 {
		t.Fatalf("attach OSC buffer = %q, want empty", window.attachOscBuffer)
	}
}

func TestStripLocallyAnsweredThemeQueriesForwardsSplitUnansweredQuery(t *testing.T) {
	window := &muxWindow{}
	hint := []byte("\x1b]10;rgb:1111/2222/3333\x1b\\")

	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("before\x1b]11;?"),
		hint,
	)
	if string(first) != "before" {
		t.Fatalf("first chunk = %q, want prefix only", first)
	}

	second := window.stripLocallyAnsweredThemeQueriesLocked([]byte("\x1b\\after"), hint)
	if string(second) != "\x1b]11;?\x1b\\after" {
		t.Fatalf("second chunk = %q, want unanswered query forwarded", second)
	}
}

func TestStripLocallyAnsweredThemeQueriesPreservesOsc8Hyperlinks(t *testing.T) {
	// OSC 8 hyperlinks (BEL- and ST-terminated, with and without an id=
	// parameter) must pass through untouched even while an interleaved theme
	// query the daemon can answer is stripped.
	chunk := []byte(
		"\x1b]8;;https://example.com/a\x07A\x1b]8;;\x07 " +
			"\x1b]11;?\x07" +
			"\x1b]8;id=1;file:///tmp/x\x1b\\B\x1b]8;;\x1b\\",
	)
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	want := "\x1b]8;;https://example.com/a\x07A\x1b]8;;\x07 " +
		"\x1b]8;id=1;file:///tmp/x\x1b\\B\x1b]8;;\x1b\\"
	got := stripLocallyAnsweredThemeQueries(chunk, hint)
	if string(got) != want {
		t.Fatalf("got = %q, want %q", got, want)
	}
}

func TestStripLocallyAnsweredThemeQueriesPreservesSplitOsc8(t *testing.T) {
	// An OSC 8 hyperlink split across read chunks must survive: the partial
	// sequence is buffered, then forwarded intact (never dropped or treated as
	// an answerable theme query).
	window := &muxWindow{}
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("label \x1b]8;;https://exa"),
		hint,
	)
	if string(first) != "label " {
		t.Fatalf("first chunk = %q, want prefix before the split OSC 8", first)
	}

	second := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("mple.com/x\x07more"),
		hint,
	)
	if string(first)+string(second) != "label \x1b]8;;https://example.com/x\x07more" {
		t.Fatalf("reassembled = %q, want the OSC 8 hyperlink preserved", string(first)+string(second))
	}
	if len(window.attachOscBuffer) != 0 {
		t.Fatalf("attach OSC buffer = %q, want empty", window.attachOscBuffer)
	}
}

func TestCreateWindowClearsAttachBeforePromptOutput(t *testing.T) {
	server := newMuxServer("test")
	t.Cleanup(server.close)
	attach := &recordingConn{}
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("old"), lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.nextID = 1

	_, err := server.createWindow(createWindowOptions{
		args: []string{"/bin/sh", "-c", "printf monkeymux-prompt; sleep 0.2"},
	})
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(time.Second)
	for !strings.Contains(attach.String(), "monkeymux-prompt") &&
		time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}

	waitForTestAttachWrites(t, server)
	output := attach.String()
	wantPrefix := replayPrefixForTest(&muxWindow{name: "sh", paneTitle: "sh"}) +
		replayPostHistorySuffixForTest(true)
	if !strings.HasPrefix(output, wantPrefix) {
		t.Fatalf("attach output = %q, want replay prefix before prompt", output)
	}
	afterPrefix := strings.TrimPrefix(output, wantPrefix)
	if !strings.Contains(afterPrefix, "monkeymux-prompt") {
		t.Fatalf("attach output = %q, want prompt after replay prefix", output)
	}
	if strings.Contains(afterPrefix, activeWindowReplayPrefix) {
		t.Fatalf("attach output = %q, replay prefix repeated after prompt", output)
	}
}

func TestWindowHistoryTrimsToLimit(t *testing.T) {
	window := &muxWindow{}

	window.appendHistoryLocked(bytes.Repeat([]byte("a"), windowHistoryLimitBytes-2))
	window.appendHistoryLocked([]byte("bcdef"))

	if got := len(window.history); got > 2*windowHistoryLimitBytes {
		t.Fatalf("history length = %d, want <= %d", got, 2*windowHistoryLimitBytes)
	}
	if got := len(window.historyTailLocked()); got != windowHistoryLimitBytes {
		t.Fatalf("history tail length = %d, want %d", got, windowHistoryLimitBytes)
	}
	if got := string(window.history[len(window.history)-5:]); got != "bcdef" {
		t.Fatalf("history suffix = %q, want bcdef", got)
	}
}

func TestWindowHistoryKeepsLargerTailForForegroundRedrawWindows(t *testing.T) {
	window := &muxWindow{agentTool: "codex"}
	history := []byte(
		"agent-history-start" +
			strings.Repeat("conversation-history", windowHistoryLimitBytes/8) +
			"agent-history-end",
	)

	window.appendHistoryLocked(history)

	tail := string(window.historyTailLocked())
	if !strings.Contains(tail, "agent-history-start") {
		t.Fatalf("agent history tail was trimmed at the shell limit")
	}
	if !strings.Contains(tail, "agent-history-end") {
		t.Fatalf("agent history tail lost suffix")
	}
}

func TestWindowHistoryAmortizedTrim(t *testing.T) {
	window := &muxWindow{}
	chunk := bytes.Repeat([]byte("x"), 4096)
	// Fill past the soft limit so subsequent writes exercise the trim path.
	for i := 0; i < (3*windowHistoryLimitBytes)/len(chunk); i++ {
		window.appendHistoryLocked(chunk)
	}
	if got := len(window.history); got > 2*windowHistoryLimitBytes {
		t.Fatalf("history length = %d, exceeds amortization budget %d", got, 2*windowHistoryLimitBytes)
	}
	if got := len(window.historyTailLocked()); got != windowHistoryLimitBytes {
		t.Fatalf("history tail length = %d, want %d", got, windowHistoryLimitBytes)
	}
}

func TestHistoryTailAlignsToUtf8Boundary(t *testing.T) {
	// Place a "│" (U+2502, 0xE2 0x94 0x82) so the history-tail cut lands on
	// one of its continuation bytes, reproducing the malformed-UTF-8 replay
	// that breaks strict decoders on the client (composer border missing
	// until next resize).
	box := []byte{0xE2, 0x94, 0x82}
	window := &muxWindow{}
	window.appendHistoryLocked(bytes.Repeat([]byte{'a'}, windowHistoryLimitBytes-1))
	window.appendHistoryLocked(box)
	window.appendHistoryLocked(bytes.Repeat([]byte{'b'}, windowHistoryLimitBytes-2))

	if len(window.history) != 2*windowHistoryLimitBytes {
		t.Fatalf("history length = %d, want %d", len(window.history), 2*windowHistoryLimitBytes)
	}
	if window.history[windowHistoryLimitBytes]&0xC0 != 0x80 {
		t.Fatalf("setup error: byte at cut is not a continuation byte (0x%02x)", window.history[windowHistoryLimitBytes])
	}

	tail := window.historyTailLocked()
	if !utf8.Valid(tail) {
		t.Fatalf("history tail is not valid UTF-8: % x", tail[:min(len(tail), 32)])
	}
	if len(tail) >= windowHistoryLimitBytes {
		t.Fatalf("aligned tail length = %d, want < %d", len(tail), windowHistoryLimitBytes)
	}
}

func TestTrimReplayHistoryAlignsToUtf8WhenNoControlChars(t *testing.T) {
	// 32 KiB of "│" repeated, with no ESC/LF/CR available for the existing
	// scan-forward heuristic. The byte-exact cut would land on a UTF-8
	// continuation byte, so the function must advance to the next starter.
	box := []byte{0xE2, 0x94, 0x82}
	history := bytes.Repeat(box, (windowReplayLimitBytes*2)/len(box))

	trimmed := trimReplayHistoryForAttach(history)
	if !utf8.Valid(trimmed) {
		t.Fatalf("trimmed replay is not valid UTF-8: % x", trimmed[:min(len(trimmed), 32)])
	}
	if len(trimmed) > windowReplayLimitBytes {
		t.Fatalf("trimmed length = %d, want <= %d", len(trimmed), windowReplayLimitBytes)
	}
}

func TestTrimReplayHistorySkipsPartialKittyPayload(t *testing.T) {
	payload := bytes.Repeat([]byte("A"), windowReplayLimitBytes+4096)
	history := append(
		[]byte("before\x1b_Ga=f,i=7,f=32,m=0;"),
		payload...,
	)
	history = append(history, "\x1b\\\r\nprompt"...)

	rawStart := len(history) - windowReplayLimitBytes
	if history[rawStart] != 'A' {
		t.Fatalf("setup error: raw replay cut = 0x%02x, want payload", history[rawStart])
	}
	if bytes.Contains(history[rawStart:rawStart+2048], []byte{'\x1b'}) {
		t.Fatal("setup error: old scan window unexpectedly reaches APC terminator")
	}

	trimmed := trimReplayHistoryForAttach(history)
	if got, want := string(trimmed), "\r\nprompt"; got != want {
		t.Fatalf("trimmed replay = %q, want %q", got, want)
	}
}

func TestReplayHistoryRetainsParserStateAcrossKittyPayloadEviction(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "zsh",
		command:           "zsh",
		foregroundCommand: "zsh",
		lastActivity:      time.Now(),
	}
	payload := bytes.Repeat([]byte("A"), windowHistoryLimitBytes+4096)
	stream := append(
		[]byte("before\x1b_Ga=f,i=7,f=32,m=0;"),
		payload...,
	)
	stream = append(stream, "\x1b\\\r\nprompt"...)
	window.appendHistoryLocked(stream)

	if window.historyStartTerminalOutput.isGround() {
		t.Fatal("setup error: retained history should begin inside the Kitty APC")
	}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = window.id

	replay := server.replayBytesLocked(window)
	if bytes.Contains(replay, bytes.Repeat([]byte("A"), 128)) {
		t.Fatal("replay leaked evicted Kitty payload as terminal text")
	}
	if !bytes.Contains(replay, []byte("\r\nprompt")) {
		t.Fatalf("replay dropped settled shell output: %q", replay)
	}
	restore := server.restoreSnapshot()
	if len(restore.Windows) != 1 {
		t.Fatalf("restore window count = %d, want 1", len(restore.Windows))
	}
	if !restore.Windows[0].HistoryStartsAtGround {
		t.Fatal("restore history was not marked as parser-ground aligned")
	}
	if got, want := string(decodeRestoreHistory(restore.Windows[0].HistoryBase64)), "\r\nprompt"; got != want {
		t.Fatalf("restored history = %q, want %q", got, want)
	}
}

func TestAdvanceToUtf8BoundarySkipsContinuationBytes(t *testing.T) {
	// 0xE2 0x94 0x82 is "│". Starting in the middle should advance past the
	// continuation bytes to the next valid starter.
	data := []byte{'a', 0xE2, 0x94, 0x82, 'b'}
	if got := advanceToUtf8Boundary(data, 2); got != 4 {
		t.Fatalf("advanceToUtf8Boundary middle = %d, want 4", got)
	}
	if got := advanceToUtf8Boundary(data, 1); got != 1 {
		t.Fatalf("advanceToUtf8Boundary starter = %d, want 1", got)
	}
	if got := advanceToUtf8Boundary(data, 0); got != 0 {
		t.Fatalf("advanceToUtf8Boundary ascii = %d, want 0", got)
	}
}

func TestWindowMetadataTracksOscTitleAsPaneTitle(t *testing.T) {
	window := &muxWindow{name: "zsh", paneTitle: "zsh"}

	window.observeTerminalMetadataLocked([]byte("\x1b]2;Claude Code · flutty\x1b\\"))

	if window.name != "zsh" {
		t.Fatalf("name = %q, want stable window name", window.name)
	}
	if window.paneTitle != "Claude Code · flutty" {
		t.Fatalf("pane title = %q, want OSC title", window.paneTitle)
	}
}

func TestWindowMetadataTracksExactPiIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "resumed.jsonl")
	payload, err := json.Marshal(map[string]string{
		"id":   "session-id",
		"file": path,
	})
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	window := &muxWindow{
		command:            "monkeymux pi-agent",
		foregroundCommand:  "pi",
		agentTool:          "pi",
		agentToolConfirmed: true,
	}

	window.observeTerminalMetadataLocked(
		[]byte("\x1b]1337;MonkeyMuxPi=" + encoded + "\x07"),
	)

	if window.agentSessionID != "session-id" ||
		window.agentSessionPath != path ||
		window.agentSessionDir != filepath.Dir(path) ||
		!window.agentSessionIdentityExact {
		t.Fatalf("Pi identity = id:%q path:%q dir:%q", window.agentSessionID, window.agentSessionPath, window.agentSessionDir)
	}
}

func TestWindowMetadataRejectsPiIdentityFromOtherProcess(t *testing.T) {
	payload := base64.RawURLEncoding.EncodeToString(
		[]byte(`{"id":"session-id","file":"/tmp/session.jsonl"}`),
	)
	window := &muxWindow{command: "zsh", foregroundCommand: "zsh"}

	window.observeTerminalMetadataLocked(
		[]byte("\x1b]1337;MonkeyMuxPi=" + payload + "\x07"),
	)

	if window.agentSessionID != "" || window.agentSessionPath != "" {
		t.Fatalf("non-Pi process stored identity: %#v", window)
	}
}

func TestWindowTitleUpdatesStillBroadcast(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	control := &recordingConn{}
	client := newControlClient(control)
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "Copilot CLI",
		command:           "copilot",
		foregroundCommand: "copilot",
		foregroundPid:     4242,
		paneTitle:         "Copilot CLI",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)
	server.controls[client] = struct{}{}

	server.handleWindowOutput("@1", []byte("\x1b]2;Search one\x07"))
	firstBroadcasts := strings.Count(control.String(), `"type":"window_updated"`)
	if firstBroadcasts != 1 {
		t.Fatalf("first title update broadcasts = %d, want 1", firstBroadcasts)
	}

	server.handleWindowOutput("@1", []byte("\x1b]2;Search two\x07"))

	if got := strings.Count(control.String(), `"type":"window_updated"`); got != 2 {
		t.Fatalf("title update broadcasts = %d, want 2", got)
	}
	if window.name != "Copilot CLI" {
		t.Fatalf("name = %q, want stable window name", window.name)
	}
	if window.paneTitle != "Search two" {
		t.Fatalf("pane title = %q, want latest OSC title", window.paneTitle)
	}
}

func TestWindowMetadataTracksTerminalProgress(t *testing.T) {
	window := &muxWindow{name: "zsh"}

	window.observeTerminalMetadataLocked([]byte("\x1b]9;4;1;42\x07"))
	if window.terminalProgress == nil || window.terminalProgress.State != 1 ||
		window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 42 {
		t.Fatalf("normal progress = %#v, want state 1 at 42", window.terminalProgress)
	}

	window.observeTerminalMetadataLocked([]byte("\x1b]9;4;2\x1b\\"))
	if window.terminalProgress == nil || window.terminalProgress.State != 2 ||
		window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 42 {
		t.Fatalf("error progress = %#v, want state 2 preserving 42", window.terminalProgress)
	}

	window.observeTerminalMetadataLocked([]byte("\x1b]9;4;3\x07"))
	if window.terminalProgress == nil || window.terminalProgress.State != 3 ||
		window.terminalProgress.Percentage != nil {
		t.Fatalf("indeterminate progress = %#v, want state 3 without percentage", window.terminalProgress)
	}

	window.observeTerminalMetadataLocked([]byte("\x1b]9;4;4;77\x1b\\"))
	if window.terminalProgress == nil || window.terminalProgress.State != 4 ||
		window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 77 {
		t.Fatalf("paused progress = %#v, want state 4 at 77", window.terminalProgress)
	}

	window.observeTerminalMetadataLocked([]byte("\x1b]9;4;0\x07"))
	if window.terminalProgress != nil {
		t.Fatalf("cleared progress = %#v, want nil", window.terminalProgress)
	}
}

func TestWindowMetadataTracksC1TerminalProgress(t *testing.T) {
	window := &muxWindow{name: "zsh"}

	window.observeTerminalMetadataLocked([]byte{0x9d, '9', ';', '4', ';', '1', ';', '3', '7', 0x9c})

	if window.terminalProgress == nil || window.terminalProgress.State != 1 ||
		window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 37 {
		t.Fatalf("C1 progress = %#v, want state 1 at 37", window.terminalProgress)
	}
}

func TestWindowMetadataTracksSplitC1TerminalProgress(t *testing.T) {
	window := &muxWindow{name: "zsh"}

	window.observeTerminalMetadataLocked([]byte{0x9d})
	window.observeTerminalMetadataLocked([]byte("9;4;1;6"))
	if window.terminalProgress != nil {
		t.Fatalf("partial C1 progress applied early: %#v", window.terminalProgress)
	}
	window.observeTerminalMetadataLocked([]byte{'5', 0x9c})

	if window.terminalProgress == nil || window.terminalProgress.State != 1 ||
		window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 65 {
		t.Fatalf("split C1 progress = %#v, want state 1 at 65", window.terminalProgress)
	}
	if len(window.oscBuffer) != 0 {
		t.Fatalf("OSC buffer = %q, want empty", window.oscBuffer)
	}
}

func TestWindowMetadataC1LikeUtf8DoesNotRegressTitleParsing(t *testing.T) {
	window := &muxWindow{name: "zsh"}

	window.observeTerminalMetadataLocked([]byte{'x', 0xe2, 0x80, 0x9d, '\x1b', ']', '2', ';', 'b', 'u', 'i', 'l', 'd', '\a'})

	if window.paneTitle != "build" {
		t.Fatalf("pane title = %q, want build", window.paneTitle)
	}
}

func TestWindowMetadataSplitC1LikeUtf8DoesNotStartOsc(t *testing.T) {
	window := &muxWindow{
		name:                        "zsh",
		terminalOutputUtf8Remaining: 1,
	}

	window.observeTerminalMetadataLocked([]byte{0x9d, '9', ';', '4', ';', '1', ';', '8', '0', 0x9c})

	if window.terminalProgress != nil {
		t.Fatalf("split UTF-8 continuation became OSC progress: %#v", window.terminalProgress)
	}
}

func TestWindowMetadataTracksSplitTerminalProgress(t *testing.T) {
	for _, testCase := range []struct {
		name       string
		terminator []byte
	}{
		{name: "BEL", terminator: []byte{'\a'}},
		{name: "ST", terminator: []byte{'\x1b', '\\'}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			window := &muxWindow{name: "zsh"}

			window.observeTerminalMetadataLocked([]byte("prefix\x1b]9;4;1;6"))
			if window.terminalProgress != nil {
				t.Fatalf("partial progress applied early: %#v", window.terminalProgress)
			}
			window.observeTerminalMetadataLocked(append([]byte("5"), append(testCase.terminator, []byte("after")...)...))

			if window.terminalProgress == nil || window.terminalProgress.State != 1 ||
				window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 65 {
				t.Fatalf("split progress = %#v, want state 1 at 65", window.terminalProgress)
			}
			if len(window.oscBuffer) != 0 {
				t.Fatalf("OSC buffer = %q, want empty", window.oscBuffer)
			}
		})
	}
}

func TestWindowMetadataIgnoresMalformedTerminalProgress(t *testing.T) {
	percentage := 25
	window := &muxWindow{
		name: "zsh",
		terminalProgress: &terminalProgressSnapshot{
			State:      1,
			Percentage: &percentage,
		},
	}

	for _, sequence := range []string{
		"\x1b]9;4;1;101\x07",
		"\x1b]9;4;1;bad\x07",
		"\x1b]9;4;2;-1\x07",
		"\x1b]9;4;8;50\x07",
	} {
		window.observeTerminalMetadataLocked([]byte(sequence))
		if window.terminalProgress == nil || window.terminalProgress.State != 1 ||
			window.terminalProgress.Percentage == nil || *window.terminalProgress.Percentage != 25 {
			t.Fatalf("malformed %q changed progress to %#v", sequence, window.terminalProgress)
		}
	}
}

func TestTerminalProgressChangeBroadcastsWindowUpdate(t *testing.T) {
	server := newMuxServer("test")
	control := &recordingConn{}
	client := newControlClient(control)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "build",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.controls[client] = struct{}{}

	server.handleWindowOutput("@1", []byte("\x1b]9;4;1;50\x07"))
	if got := strings.Count(control.String(), `"type":"window_updated"`); got != 1 {
		t.Fatalf("progress broadcasts = %d, want 1", got)
	}
	if !strings.Contains(control.String(), `"terminalProgress":{"state":1,"percentage":50}`) {
		t.Fatalf("progress broadcast missing snapshot: %s", control.String())
	}

	server.handleWindowOutput("@1", []byte("\x1b]9;4;0\x07"))
	if got := strings.Count(control.String(), `"type":"window_updated"`); got != 2 {
		t.Fatalf("clear broadcasts = %d, want 2", got)
	}
}

func TestTerminalProgressSnapshotDoesNotSeedRestartedProcess(t *testing.T) {
	percentage := 73
	server := newMuxServer("test")
	server.windows = []*muxWindow{{
		id:           "@1",
		index:        0,
		name:         "build",
		lastActivity: time.Now(),
		terminalProgress: &terminalProgressSnapshot{
			State:      2,
			Percentage: &percentage,
		},
	}}
	server.activeID = "@1"

	restore := server.restoreSnapshot()
	if restore.Windows[0].TerminalProgress == nil ||
		restore.Windows[0].TerminalProgress.State != 2 ||
		restore.Windows[0].TerminalProgress.Percentage == nil ||
		*restore.Windows[0].TerminalProgress.Percentage != 73 {
		t.Fatalf("restore progress = %#v, want state 2 at 73", restore.Windows[0].TerminalProgress)
	}

	options := createWindowOptionsForRestore(restore.Windows[0], false)
	if options.terminalProgress != nil {
		t.Fatalf("restarted process inherited progress: %#v", options.terminalProgress)
	}
}

func TestRestoreWindowOptionsDropProcessOwnedTerminalModes(t *testing.T) {
	state := restoreWindowState{
		ID:    "@1",
		Index: 0,
		Name:  "shell",
		PrivateModes: map[string]bool{
			"1":    true,
			"1000": true,
			"1002": true,
			"1003": true,
			"1004": true,
			"1006": true,
			"1007": true,
			"1049": true,
			"2004": true,
			"2031": true,
			"7":    false,
		},
		InsertModeEnabled:        true,
		InsertModeKnown:          true,
		ApplicationKeypadEnabled: true,
		ApplicationKeypadKnown:   true,
	}

	options := createWindowOptionsForRestore(state, false)

	for _, mode := range []string{
		"1", "1000", "1002", "1003", "1004", "1006", "1007", "2004", "2031",
	} {
		if _, ok := options.privateModes[mode]; ok {
			t.Fatalf("restored options retained process-owned mode %s: %#v", mode, options.privateModes)
		}
	}
	if !options.privateModes["1049"] {
		t.Fatalf("restored options dropped display mode: %#v", options.privateModes)
	}
	if enabled, ok := options.privateModes["7"]; !ok || enabled {
		t.Fatalf("restored options wrap mode = %v, %v, want present false", enabled, ok)
	}
	if options.insertModeKnown || options.insertModeEnabled {
		t.Fatalf("restored options retained insert mode: known=%v enabled=%v", options.insertModeKnown, options.insertModeEnabled)
	}
	if options.applicationKeypadKnown || options.applicationKeypadEnabled {
		t.Fatalf("restored options retained application keypad: known=%v enabled=%v", options.applicationKeypadKnown, options.applicationKeypadEnabled)
	}
	window := &muxWindow{privateModes: options.privateModes}
	if got := window.themeHintRefreshDataLocked([]byte("\x1b[?997;1n")); len(got) != 0 {
		t.Fatalf("restored shell received stale theme reply %q", got)
	}
}

func TestWindowSnapshotReportsTerminalMouseModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Mouse app",
		privateModes: map[string]bool{"1002": true, "1006": true, "2004": true},
		lastActivity: time.Now(),
	}

	snapshot := server.snapshot(window)

	if !snapshot.TerminalReportsMouseWheel {
		t.Fatal("snapshot did not report mouse wheel mode")
	}
	if !snapshot.TerminalMouseReportSgr {
		t.Fatal("snapshot did not report SGR mouse mode")
	}
	if !snapshot.TerminalBracketedPaste {
		t.Fatal("snapshot did not report bracketed paste mode")
	}
	if !snapshot.PrivateModes["1002"] {
		t.Fatalf("snapshot private modes = %#v, want SGR drag mode", snapshot.PrivateModes)
	}
	if !snapshot.PrivateModes["1006"] {
		t.Fatalf("snapshot private modes = %#v, want SGR report mode", snapshot.PrivateModes)
	}
	if !snapshot.PrivateModes["2004"] {
		t.Fatalf("snapshot private modes = %#v, want bracketed paste mode", snapshot.PrivateModes)
	}
}

func TestMouseTrackingClearsWhenOwningProcessExits(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:            "@1",
		index:         0,
		name:          "tui",
		foregroundPid: 100,
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// A TUI in the foreground turns on mouse tracking + SGR reporting.
	window.observeTerminalModesLocked([]byte("\x1b[?1000h\x1b[?1006h"))

	if !window.reportsMouseWheelLocked() {
		t.Fatal("mouse wheel reporting should be active while the TUI is foreground")
	}
	snapshot := server.snapshot(window)
	if !snapshot.TerminalReportsMouseWheel || !snapshot.TerminalMouseReportSgr {
		t.Fatalf("snapshot = %+v, want mouse wheel + SGR while TUI foreground", snapshot)
	}
	replay := string(window.modeReplayForAttachedTerminalLocked())
	if !strings.Contains(replay, "\x1b[?1000h") {
		t.Fatalf("replay = %q, want mouse mode re-enabled while TUI foreground", replay)
	}

	// The TUI exits without disabling mouse mode; the shell returns to the
	// foreground with a different process group.
	window.foregroundPid = 200

	if window.reportsMouseWheelLocked() {
		t.Fatal("mouse wheel reporting must stop once the owning process exits")
	}
	if window.mouseTrackingActiveLocked() {
		t.Fatal("mouse tracking must not be active for a new foreground process")
	}
	snapshot = server.snapshot(window)
	if snapshot.TerminalReportsMouseWheel {
		t.Fatal("snapshot must not report mouse wheel after the owning process exits")
	}
	if snapshot.TerminalMouseReportSgr {
		t.Fatal("snapshot must not report SGR mouse after the owning process exits")
	}
	replay = string(window.modeReplayForAttachedTerminalLocked())
	if strings.Contains(replay, "\x1b[?1000h") {
		t.Fatalf("replay = %q, must not re-enable mouse mode after owner exits", replay)
	}
}

func TestMouseTrackingProcessIDClearsWhenModesDisabled(t *testing.T) {
	window := &muxWindow{id: "@1", foregroundPid: 100, lastActivity: time.Now()}

	window.observeTerminalModesLocked([]byte("\x1b[?1000h\x1b[?1002h"))
	if window.mouseTrackingProcessID != 100 {
		t.Fatalf("mouseTrackingProcessID = %d, want 100", window.mouseTrackingProcessID)
	}

	// Disabling one of several wheel modes keeps the owner while others remain.
	window.observeTerminalModesLocked([]byte("\x1b[?1000l"))
	if window.mouseTrackingProcessID != 100 {
		t.Fatalf("mouseTrackingProcessID = %d, want owner retained while 1002 stays on", window.mouseTrackingProcessID)
	}

	// Disabling the last wheel mode clears the recorded owner.
	window.observeTerminalModesLocked([]byte("\x1b[?1002l"))
	if window.mouseTrackingProcessID != 0 {
		t.Fatalf("mouseTrackingProcessID = %d, want cleared once no wheel mode remains", window.mouseTrackingProcessID)
	}
}

func TestRestorePreservesNativeAcpOwnershipAcrossUpgrade(t *testing.T) {
	const bridgeID = "0123456789abcdef0123456789abcdef"
	restore := restoreFromWindowSnapshots([]windowSnapshot{{
		ID:                  "@7",
		Index:               6,
		Name:                "Pi",
		CurrentPath:         "/repo",
		AgentTool:           "pi",
		NativeAcpBridgeID:   bridgeID,
		NativeAcpProviderID: "builtin:pi-acp",
	}})
	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	window := restore.Windows[0]
	if window.NativeAcpBridgeID != bridgeID ||
		window.NativeAcpProviderID != "builtin:pi-acp" {
		t.Fatalf("native ACP restore window = %#v", window)
	}
	if !restoreHasNativeAcpWindows(restore) {
		t.Fatal("native ACP restore did not request a bridge handoff")
	}
	if restoreHasNativeAcpWindows(&serverRestore{Windows: []restoreWindowState{{Name: "shell"}}}) {
		t.Fatal("plain terminal restore incorrectly requested a bridge handoff")
	}

	originalArguments := nativeAcpWindowArguments
	nativeAcpWindowArguments = func(id string) ([]string, error) {
		return []string{"monkeymux-new", "acp", "wait", id}, nil
	}
	t.Cleanup(func() { nativeAcpWindowArguments = originalArguments })
	options := createWindowOptionsForRestore(window, false)
	if !reflect.DeepEqual(options.args, []string{"monkeymux-new", "acp", "wait", bridgeID}) {
		t.Fatalf("native restore args = %#v", options.args)
	}
	if options.command != "" || options.nativeAcpBridgeID != bridgeID ||
		options.nativeAcpProviderID != "builtin:pi-acp" || options.cwd != "/repo" {
		t.Fatalf("native restore options = %#v", options)
	}
}

func TestNativeAcpUpgradeHandoffClosesOnlyTerminalWindows(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	serverDone := make(chan error, 1)
	go func() {
		defer serverConn.Close()
		dec := json.NewDecoder(serverConn)
		enc := json.NewEncoder(serverConn)
		var hello controlMessage
		if err := dec.Decode(&hello); err != nil {
			serverDone <- err
			return
		}
		if hello.Role != "control" || hello.Session != "workspace" {
			serverDone <- fmt.Errorf("hello = %#v", hello)
			return
		}
		if err := enc.Encode(controlResponse{Type: "hello", Status: "ok"}); err != nil {
			serverDone <- err
			return
		}
		for _, expectedID := range []string{"@1", "@3"} {
			var request controlMessage
			if err := dec.Decode(&request); err != nil {
				serverDone <- err
				return
			}
			if request.Type != "close_window" || request.WindowID != expectedID {
				serverDone <- fmt.Errorf("handoff request = %#v, want close %s", request, expectedID)
				return
			}
			// Real servers can interleave broadcasts with the command response.
			if err := enc.Encode(controlResponse{Type: "window_removed"}); err != nil {
				serverDone <- err
				return
			}
			if err := enc.Encode(controlResponse{
				ID: request.ID, Type: "window_closed", Status: "ok",
			}); err != nil {
				serverDone <- err
				return
			}
		}
		serverDone <- nil
	}()

	windowIDs, err := terminalWindowIDsForNativeAcpHandoff(&serverRestore{
		Windows: []restoreWindowState{
			{ID: "@1", Name: "shell"},
			{
				ID:                  "@2",
				Name:                "Pi",
				NativeAcpBridgeID:   "0123456789abcdef0123456789abcdef",
				NativeAcpProviderID: "builtin:pi-acp",
			},
			{ID: "@3", Name: "Codex"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(windowIDs, []string{"@1", "@3"}) {
		t.Fatalf("terminal handoff ids = %#v", windowIDs)
	}
	if err := closeOutgoingTerminalWindows(
		clientConn,
		"workspace",
		windowIDs,
	); err != nil {
		t.Fatalf("closeOutgoingTerminalWindows: %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestRestoreFromSnapshotPreservesMouseDragMode(t *testing.T) {
	restore := restoreFromWindowSnapshots([]windowSnapshot{
		{
			ID:                        "@1",
			Index:                     0,
			Name:                      "Mouse app",
			PrivateModes:              map[string]bool{"1002": true, "1006": true, "2004": true},
			TerminalReportsMouseWheel: true,
			TerminalMouseReportSgr:    true,
			TerminalBracketedPaste:    true,
		},
	})

	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	modes := restore.Windows[0].PrivateModes
	if !modes["1002"] {
		t.Fatalf("restore private modes = %#v, want SGR drag mode", modes)
	}
	if !modes["1006"] {
		t.Fatalf("restore private modes = %#v, want SGR report mode", modes)
	}
	if !modes["2004"] {
		t.Fatalf("restore private modes = %#v, want bracketed paste mode", modes)
	}
}

func TestRestoreFromLegacySnapshotPrefersSgrMouseDrag(t *testing.T) {
	restore := restoreFromWindowSnapshots([]windowSnapshot{
		{
			ID:                        "@1",
			Index:                     0,
			Name:                      "Mouse app",
			TerminalReportsMouseWheel: true,
			TerminalMouseReportSgr:    true,
			TerminalBracketedPaste:    true,
		},
	})

	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	modes := restore.Windows[0].PrivateModes
	if !modes["1002"] {
		t.Fatalf("restore private modes = %#v, want legacy SGR drag mode", modes)
	}
	if !modes["1006"] {
		t.Fatalf("restore private modes = %#v, want SGR report mode", modes)
	}
	if !modes["2004"] {
		t.Fatalf("restore private modes = %#v, want bracketed paste mode", modes)
	}
}

func TestRestoreSnapshotPreservesDisplayModesAndDropsProcessModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		name:                     "Mouse app",
		privateModes:             map[string]bool{"1049": true, "7": false, "9999": true},
		insertModeEnabled:        true,
		insertModeKnown:          true,
		applicationKeypadEnabled: true,
		applicationKeypadKnown:   true,
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	restore := server.restoreSnapshot()
	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	state := restore.Windows[0]
	if !state.PrivateModes["1049"] {
		t.Fatal("restore did not preserve alternate-screen mode")
	}
	if enabled, ok := state.PrivateModes["7"]; !ok || enabled {
		t.Fatalf("restore wrap mode = %v, %v, want present false", enabled, ok)
	}
	if _, ok := state.PrivateModes["9999"]; ok {
		t.Fatal("restore preserved untracked private mode")
	}
	if !state.InsertModeKnown || !state.InsertModeEnabled {
		t.Fatal("restore did not preserve insert mode")
	}
	if !state.ApplicationKeypadKnown || !state.ApplicationKeypadEnabled {
		t.Fatal("restore did not preserve application keypad mode")
	}

	options := createWindowOptionsForRestore(state, false)
	if enabled, ok := options.privateModes["7"]; !ok || enabled {
		t.Fatalf("restored options wrap mode = %v, %v, want present false", enabled, ok)
	}
	if !options.privateModes["1049"] {
		t.Fatalf("restored options private modes = %#v", options.privateModes)
	}
	if options.insertModeKnown || options.insertModeEnabled {
		t.Fatal("restored options retained process-owned insert mode")
	}
	if options.applicationKeypadKnown || options.applicationKeypadEnabled {
		t.Fatal("restored options retained process-owned application keypad mode")
	}
}

func TestActiveReplaySetsWindowTitle(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:           "@1",
			index:        0,
			name:         "Copilot CLI",
			paneTitle:    "Copilot CLI",
			history:      []byte("prompt"),
			lastActivity: time.Now(),
		},
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	for _, sequence := range []string{
		"\x1b]0;Copilot CLI\x07",
		"\x1b]1;Copilot CLI\x07",
		"\x1b]2;Copilot CLI\x07",
	} {
		if !strings.Contains(replay, sequence) {
			t.Fatalf("replay = %q, want title sequence %q", replay, sequence)
		}
	}
}

func TestAltScreenReplayRestoresKittyImageButNotHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Copilot CLI",
		paneTitle:    "Copilot CLI",
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// Stream the window output as the live path does: the image is transmitted
	// once and retained, followed by a flood of other output that evicts it
	// from the rolling visible history. The retained image must still replay.
	window.appendHistoryLocked([]byte("visible tui frame\r\n"))
	transmit := []byte(
		"\x1b_Ga=T,U=1,i=10871563,c=8,r=4,f=100,q=2;iVBORw0KGgo=\x1b\\")
	window.appendHistoryLocked(transmit)
	window.observeKittyGraphicsLocked(transmit)
	placeholders := []byte("\x1b[38;2;165;227;11m\U0010eeee\u0305\u0305 cells")
	window.appendHistoryLocked(placeholders)
	window.observeKittyGraphicsLocked(placeholders)
	// Evict the transmit from the rolling history with newer output.
	flood := bytes.Repeat([]byte("x"), windowFullReplayHistoryLimitBytes+1024)
	window.appendHistoryLocked(flood)
	window.observeKittyGraphicsLocked(flood)
	if bytes.Contains(window.historyTailLocked(), transmit) {
		t.Fatal("precondition failed: transmit should have been evicted from history")
	}

	if !window.usesForegroundRedrawReplayLocked() {
		t.Fatal("alt-screen window should use foreground-redraw replay")
	}

	replay := string(server.replayBytesLocked(window))

	// The image bytes are restored from the retained cache (surviving history
	// eviction) so redrawn placeholders have something to composite, but as a
	// store-only transmit (a=t, not a=T).
	if !strings.Contains(replay, "i=10871563") ||
		!strings.Contains(replay, "iVBORw0KGgo=") {
		t.Fatalf("replay dropped the Kitty image transmission: %q", replay)
	}
	if strings.Contains(replay, "a=T") {
		t.Fatalf("replay kept display action a=T (would place image): %q", replay)
	}
	// The visible TUI history and placeholder cells are NOT replayed; the app
	// redraws them itself.
	if strings.Contains(replay, "visible tui frame") ||
		strings.Contains(replay, "\U0010eeee") {
		t.Fatalf("alt-screen replay leaked visible history (double-draw): %q", replay)
	}
}

func TestTerminalTitleReplaySanitizesControlCharacters(t *testing.T) {
	window := &muxWindow{name: "bad\x1b\a title"}

	replay := string(terminalTitleReplaySequence(window))

	if strings.Contains(replay, "bad\x1b") || strings.Contains(replay, "\a title") {
		t.Fatalf("title replay retained payload control characters: %q", replay)
	}
	if !strings.Contains(replay, "bad title") {
		t.Fatalf("title replay = %q, want sanitized title text", replay)
	}
}

func TestWindowMetadataTracksSplitOscTitle(t *testing.T) {
	window := &muxWindow{name: "zsh", paneTitle: "zsh"}

	window.observeTerminalMetadataLocked([]byte("prefix\x1b]0;Copilot"))
	window.observeTerminalMetadataLocked([]byte(" CLI\aafter"))

	if window.name != "zsh" {
		t.Fatalf("name = %q, want stable window name", window.name)
	}
	if window.paneTitle != "Copilot CLI" {
		t.Fatalf("pane title = %q, want split OSC title", window.paneTitle)
	}
	if string(window.oscBuffer) != "" {
		t.Fatalf("osc buffer = %q, want empty", window.oscBuffer)
	}
}

func TestWindowMetadataTracksOsc7Path(t *testing.T) {
	for _, test := range []struct{ url, want string }{
		{"file://host/Users/depoll/Code/flutty", "/Users/depoll/Code/flutty"},
		{"file:///tmp/100%25", "/tmp/100%"},
		{"file:///tmp/a%2520b", "/tmp/a%20b"},
		{"file:///tmp/a%20b", "/tmp/a b"},
	} {
		t.Run(test.url, func(t *testing.T) {
			window := &muxWindow{cwd: "/tmp"}
			window.observeTerminalMetadataLocked([]byte("\x1b]7;" + test.url + "\x1b\\"))
			if window.cwd != test.want {
				t.Fatalf("cwd = %q, want %q", window.cwd, test.want)
			}
		})
	}
}

func TestActiveReplayRestoresCursorVisibility(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("prompt"), lastActivity: time.Now()},
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.HasSuffix(replay, cursorVisibilityReplaySequence(true)) {
		t.Fatalf("replay = %q, want visible cursor suffix", replay)
	}
}

func TestActiveReplayPreservesHiddenCursor(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("start\x1b[?25l"))
	replay := string(server.activeReplayLocked())

	if !strings.HasSuffix(replay, cursorVisibilityReplaySequence(false)) {
		t.Fatalf("replay = %q, want hidden cursor suffix", replay)
	}
}

func TestReplayPrefixResetsStaleInputModes(t *testing.T) {
	for _, sequence := range []string{
		"\x1b[?1000l",
		"\x1b[?1002l",
		"\x1b[?1003l",
		"\x1b[?1006l",
		"\x1b[?1004l",
		"\x1b[?1007l",
		"\x1b[?2004l",
		"\x1b[?1047l",
		"\x1b[?1l",
		"\x1b[?6l",
		"\x1b[?7h",
		"\x1b[4l",
	} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not reset %q", activeWindowReplayPrefix, sequence)
		}
	}
	if !strings.Contains(activeWindowReplayPrefix, "\x1b>") {
		t.Fatalf("replay prefix %q does not reset application keypad mode", activeWindowReplayPrefix)
	}
}

func TestReplayPrefixClearsScrollbackAndMargins(t *testing.T) {
	for _, sequence := range []string{"\x1b[r", "\x1b[2J", "\x1b[3J", "\x1b(B"} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not include %q", activeWindowReplayPrefix, sequence)
		}
	}
}

func TestReplayPrefixResetsCharacterSetShift(t *testing.T) {
	if !strings.HasPrefix(activeWindowReplayPrefix, terminalParserResetSequence) {
		t.Fatalf("replay prefix %q does not start by resetting parser state", activeWindowReplayPrefix)
	}
	for _, sequence := range []string{"\x0f", "\x1b(B", "\x1b)B"} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not reset character set with %q", activeWindowReplayPrefix, sequence)
		}
	}
}

func TestReplayParserFenceDoesNotEmitVisibleCancelByte(t *testing.T) {
	if terminalParserResetSequence != "\x1b\\" {
		t.Fatalf("parser fence = %q, want ST-only fence", terminalParserResetSequence)
	}
	if strings.ContainsAny(terminalParserResetSequence, "\x18\x1a") {
		t.Fatalf("parser fence = %q, must not include visible cancel controls", terminalParserResetSequence)
	}
}

func TestActiveReplayDoesNotRestoreStaleFocusMode(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                 "@1",
		index:              0,
		foregroundPid:      222,
		privateModes:       map[string]bool{"1004": true},
		focusModeEnabled:   true,
		focusModeProcessID: 111,
		lastActivity:       time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := strings.TrimPrefix(string(server.activeReplayLocked()), activeWindowReplayPrefix)

	if strings.Contains(replay, "\x1b[?1004h") {
		t.Fatalf("replay restored stale focus mode: %q", replay)
	}
}

func TestActiveReplayRestoresTrackedEditorModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("nano screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	window.observeTerminalModesLocked(
		[]byte("\x1b[?1049h\x1b[?1h\x1b[?1007h\x1b=\x1b[?2004h\x1b[4h"),
	)

	replay := string(server.activeReplayLocked())
	preModes := string(terminalModePreReplaySequence(window))
	preHistoryClear := string(terminalPreHistoryClearSequence(window))
	postModes := string(terminalModePostReplaySequence(window))
	want := replayPrefixForTest(window) + preModes + preHistoryClear +
		terminalParserResetSequence + postModes +
		terminalCharacterSetResetSequence + cursorVisibilityReplaySequence(true)
	if replay != want {
		t.Fatalf("replay = %q, want %q", replay, want)
	}
	if strings.Contains(replay, "nano screen") {
		t.Fatalf("editor redraw replay retained stale history: %q", replay)
	}
	for _, sequence := range []string{
		"\x1b[?1049h",
		"\x1b[?1h",
		"\x1b[?1007h",
		"\x1b[?2004h",
		"\x1b[4h",
		"\x1b=",
	} {
		if !strings.Contains(preModes, sequence) {
			t.Fatalf("pre-history modes = %q, want %q", preModes, sequence)
		}
	}
	for _, sequence := range []string{
		"\x1b[?1h",
		"\x1b[?1007h",
		"\x1b[?2004h",
		"\x1b[4h",
		"\x1b=",
	} {
		if !strings.Contains(postModes, sequence) {
			t.Fatalf("post-history modes = %q, want %q", postModes, sequence)
		}
	}
	if strings.Contains(postModes, "\x1b[?1049h") {
		t.Fatalf("post-history modes = %q, should not switch buffers after replay", postModes)
	}
}

func TestTerminalModeTrackingHandlesSplitSequences(t *testing.T) {
	window := &muxWindow{}

	window.observeTerminalModesLocked([]byte("\x1b[?1;200"))
	window.observeTerminalModesLocked([]byte("4h\x1b"))
	window.observeTerminalModesLocked([]byte("="))

	preModes := string(terminalModePreReplaySequence(window))
	for _, sequence := range []string{"\x1b[?1h", "\x1b[?2004h", "\x1b="} {
		if !strings.Contains(preModes, sequence) {
			t.Fatalf("pre-history modes = %q, want %q", preModes, sequence)
		}
	}
}

func TestTerminalModeReplayRestoresMouseTrackingAfterDisabledModes(t *testing.T) {
	window := &muxWindow{
		privateModes: map[string]bool{
			"1000": false,
			"1002": true,
			"1003": false,
			"1006": true,
		},
	}

	postModes := string(terminalModePostReplaySequence(window))
	if !strings.Contains(postModes, "\x1b[?1006h") {
		t.Fatalf("post-history modes = %q, want SGR mouse mode restored", postModes)
	}
	if got := lastSequence(
		postModes,
		"\x1b[?1000l",
		"\x1b[?1000h",
		"\x1b[?1002l",
		"\x1b[?1002h",
		"\x1b[?1003l",
		"\x1b[?1003h",
	); got != "\x1b[?1002h" {
		t.Fatalf("last mouse tracking replay = %q in %q, want ?1002h", got, postModes)
	}
}

func TestTerminalModePreReplayRestoresAltBufferAfterDisabledAltMode(t *testing.T) {
	window := &muxWindow{
		privateModes: map[string]bool{
			"1047": true,
			"1049": false,
		},
	}

	preModes := string(terminalModePreReplaySequence(window))
	if got := lastSequence(
		preModes,
		"\x1b[?1047l",
		"\x1b[?1047h",
		"\x1b[?1049l",
		"\x1b[?1049h",
	); got != "\x1b[?1047h" {
		t.Fatalf("last alternate-buffer replay = %q in %q, want ?1047h", got, preModes)
	}
}

func lastSequence(value string, candidates ...string) string {
	lastIndex := -1
	lastValue := ""
	for _, candidate := range candidates {
		if index := strings.LastIndex(value, candidate); index > lastIndex {
			lastIndex = index
			lastValue = candidate
		}
	}
	return lastValue
}

func TestActiveReplayRestoresResetEditorModesAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{id: "@1", history: []byte("stale\x1b[4h")}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	window.observeTerminalModesLocked([]byte("\x1b[4h\x1b[4l\x1b=\x1b>"))

	postModes := string(terminalModePostReplaySequence(window))
	for _, sequence := range []string{"\x1b[4l", "\x1b>"} {
		if !strings.Contains(postModes, sequence) {
			t.Fatalf("post-history modes = %q, want reset %q", postModes, sequence)
		}
	}
	if !strings.HasSuffix(
		string(server.activeReplayLocked()),
		"stale\x1b[4h"+terminalParserResetSequence+postModes+
			terminalCharacterSetResetSequence+cursorVisibilityReplaySequence(true),
	) {
		t.Fatalf("replay did not restore reset modes after history")
	}
}

func TestActiveReplayResetsCharacterSetAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	history := "prompt\x1b)0\x0eqqq"
	window := &muxWindow{id: "@1", history: []byte(history)}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	if !strings.HasSuffix(
		string(server.activeReplayLocked()),
		history+replayPostHistorySuffixForTest(true),
	) {
		t.Fatalf("replay did not reset shifted character set after history")
	}
}

func TestActiveReplayTerminatesUnfinishedControlStringAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	history := "screen\x1b]2;unterminated title"
	window := &muxWindow{id: "@1", history: []byte(history)}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	if !strings.HasSuffix(
		string(server.activeReplayLocked()),
		history+replayPostHistorySuffixForTest(true),
	) {
		t.Fatalf("replay did not terminate unfinished control string after history")
	}
}

func TestWindowProcessIDReportsShellPid(t *testing.T) {
	window := &muxWindow{
		proc: &unixProcess{cmd: &exec.Cmd{Process: &os.Process{Pid: 12345}}},
	}

	if got := window.processID(); got != 12345 {
		t.Fatalf("processID = %d, want 12345", got)
	}
}

func TestWindowSnapshotPrefersForegroundProcessMetadata(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "flutty",
		command:           "zsh",
		foregroundPid:     23456,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	snapshot := server.snapshot(window)

	if snapshot.CurrentCommand != "codex" {
		t.Fatalf("current command = %q, want codex", snapshot.CurrentCommand)
	}
	if snapshot.PanePid != 23456 {
		t.Fatalf("pane pid = %d, want foreground pid", snapshot.PanePid)
	}
	if snapshot.AgentTool != "codex" {
		t.Fatalf("agent tool = %q, want codex", snapshot.AgentTool)
	}
}

func TestWindowSnapshotIncludesLaunchAgentTool(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "Cursor Agent",
		command:           "zsh",
		agentTool:         "cursor-agent",
		foregroundPid:     23456,
		foregroundCommand: "zsh",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	snapshot := server.snapshot(window)

	if snapshot.AgentTool != "cursor-agent" {
		t.Fatalf("agent tool = %q, want cursor-agent", snapshot.AgentTool)
	}
}

func TestCommandNameFromProcessFieldsDetectsNodeBackedAgents(t *testing.T) {
	tests := []struct {
		name    string
		command string
		args    string
		want    string
	}{
		{
			name:    "codex node shim",
			command: "node",
			args:    "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js",
			want:    "codex",
		},
		{
			name:    "plain node script",
			command: "node",
			args:    "node /tmp/build.js",
			want:    "node",
		},
		{
			// Gemini CLI support was dropped; its node shim is a plain script.
			name:    "unsupported gemini node shim",
			command: "node",
			args:    "node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js",
			want:    "node",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := commandNameFromProcessFields(tt.command, tt.args); got != tt.want {
				t.Fatalf("commandNameFromProcessFields() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestFirstShellWordSkipsWrappers(t *testing.T) {
	tests := []struct {
		command string
		want    string
	}{
		{command: "cd ~/repo && codex resume abc", want: "codex"},
		{command: "cd ~/repo && npx @anthropic-ai/claude-code --resume abc", want: "claude"},
		{command: `CODEX_HOME=/tmp/codex codex --yolo`, want: "codex"},
		{command: `OPENCODE_PERMISSION='{"*":"allow"}' opencode`, want: "opencode"},
		{command: "cd ~/repo && cursor-agent --resume abc", want: "cursor-agent"},
		// Gemini CLI support was dropped: the npx wrapper is just npx now.
		{command: "cd ~/repo && npx @google/gemini-cli --yolo", want: "npx"},
	}

	for _, tt := range tests {
		if got := firstShellWord(tt.command); got != tt.want {
			t.Fatalf("firstShellWord(%q) = %q, want %q", tt.command, got, tt.want)
		}
	}
}

func TestAgentToolFromCommandTextDetectsWrappedNodeAgents(t *testing.T) {
	tests := []struct {
		command string
		want    string
	}{
		{command: "cd ~/repo && npx @anthropic-ai/claude-code --resume abc", want: "claude"},
		{command: "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js", want: "codex"},
		// Gemini CLI support was dropped, so its wrapper is not an agent.
		{command: "cd ~/repo && npx @google/gemini-cli --yolo", want: ""},
		{command: "node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js", want: ""},
	}

	for _, tt := range tests {
		if got := agentToolFromCommandText(tt.command); got != tt.want {
			t.Fatalf("agentToolFromCommandText(%q) = %q, want %q", tt.command, got, tt.want)
		}
	}
}

func TestAgentSessionIDFromArgsParsesResumeCommands(t *testing.T) {
	tests := []struct {
		tool string
		args string
		want string
	}{
		{tool: "claude", args: "claude --resume abc123", want: "abc123"},
		{tool: "copilot", args: "copilot --resume 'session one'", want: "session one"},
		{tool: "codex", args: "codex resume run-42", want: "run-42"},
		// Gemini CLI support was dropped, so no resume pattern is registered.
		{tool: "gemini", args: `gemini --resume="gemini session"`, want: ""},
		{tool: "opencode", args: "opencode --session opencode-9", want: "opencode-9"},
		{tool: "antigravity", args: `agy --conversation "antigravity session"`, want: "antigravity session"},
		{tool: "cursor-agent", args: "cursor-agent --resume chat-7", want: "chat-7"},
		{tool: "cursor-agent", args: `cursor-agent --resume="chat eight"`, want: "chat eight"},
	}

	for _, tt := range tests {
		if got := agentSessionIDFromArgs(tt.tool, tt.args); got != tt.want {
			t.Fatalf("agentSessionIDFromArgs(%q, %q) = %q, want %q", tt.tool, tt.args, got, tt.want)
		}
	}
}

func TestAgentProcessesByPaneSelectsUniqueShallowestProcess(t *testing.T) {
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude --resume outer"},
		300: {pid: 300, ppid: 200, comm: "claude", args: "claude --resume nested"},
	}
	got := agentProcessesByPane(processes, map[int]struct{}{100: {}}, "claude")
	if got[100].pid != 200 {
		t.Fatalf("selected process = %#v, want shallow pid 200", got)
	}
	processes[201] = processInfo{pid: 201, ppid: 100, comm: "claude", args: "claude --resume tie"}
	if got := agentProcessesByPane(processes, map[int]struct{}{100: {}}, "claude"); len(got) != 0 {
		t.Fatalf("same-depth process tie = %#v, want fail closed", got)
	}
}

func TestDiscoverCodexSessionIDsReservesArgvOwnedSiblingSession(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})
	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "123e4567-e89b-12d3-a456-426614174055"
	rolloutDir := filepath.Join(home, ".codex", "sessions", "2026", "08")
	if err := os.MkdirAll(rolloutDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(rolloutDir, "rollout-2026-08-18T00-00-00-"+sessionID+".jsonl")
	if err := os.WriteFile(path, []byte(`{"cwd":"/work/project","id":"`+sessionID+`"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(int) string { return "/work/project" }
	processStartedAtForMetadata = func(int) time.Time { return time.Now().Add(-time.Minute) }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "codex", args: "codex resume " + sessionID},
		201: {pid: 201, ppid: 101, comm: "codex", args: "codex"},
	}

	got := discoverAgentSessionIDs("codex", processes, map[int]struct{}{100: {}, 101: {}})
	if got[100] != sessionID || got[101] != "" {
		t.Fatalf("Codex sibling assignments = %#v, want only argv-owned pane", got)
	}
}

func TestDiscoverClaudeSessionIDsReservesArgvOwnedSiblingSession(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})
	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "de4e84a3-cf16-4cc2-8ba7-34587e984d4a"
	projectDir := filepath.Join(home, ".claude", "projects", "-work-project")
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(projectDir, sessionID+".jsonl"), []byte(`{"cwd":"/work/project","sessionId":"`+sessionID+`"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(int) string { return "/work/project" }
	processStartedAtForMetadata = func(int) time.Time { return time.Now().Add(-time.Minute) }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude --resume " + sessionID},
		201: {pid: 201, ppid: 101, comm: "claude", args: "claude"},
	}

	got := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}, 101: {}})
	if got[100] != sessionID || got[101] != "" {
		t.Fatalf("Claude sibling assignments = %#v, want only argv-owned pane", got)
	}
}

func TestDiscoverCodexSessionIDsUsesOpenRolloutFile(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	sessionID := "123e4567-e89b-12d3-a456-426614174000"
	processOpenFilePathsForMetadata = func(pid int) []string {
		if pid != 200 {
			return nil
		}
		return []string{
			"/Users/alice/.codex/sessions/2026/06/rollout-2026-06-01T06-50-00-" + sessionID + ".jsonl",
		}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {
			pid:  200,
			ppid: 100,
			comm: "node",
			args: "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js",
		},
	}

	sessions := discoverAgentSessionIDs("codex", processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("codex session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverCodexSessionIDsFallsBackToRecentRolloutForCwd(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalHome := os.Getenv("HOME")
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		_ = os.Setenv("HOME", originalHome)
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})

	home := t.TempDir()
	if err := os.Setenv("HOME", home); err != nil {
		t.Fatal(err)
	}
	sessionID := "123e4567-e89b-12d3-a456-426614174001"
	rolloutDir := filepath.Join(home, ".codex", "sessions", "2026", "06")
	if err := os.MkdirAll(rolloutDir, 0o700); err != nil {
		t.Fatal(err)
	}
	rolloutPath := filepath.Join(
		rolloutDir,
		"rollout-2026-06-01T06-50-00-"+sessionID+".jsonl",
	)
	if err := os.WriteFile(
		rolloutPath,
		[]byte(`{"cwd":"/work/project","id":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(pid int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return time.Now().Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "codex", args: "codex"},
	}
	processTableForMetadata = func() map[int]processInfo { return processes }
	processWorkingDirectoryForMetadata = func(int) string { return "" }

	sessions := discoverAgentSessionIDs("codex",
		processes,
		map[int]struct{}{100: {}},
		map[int]string{100: "/work/project"},
	)

	if got := sessions[100]; got != sessionID {
		t.Fatalf("codex session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverCodexSessionIDsSkipsAmbiguousCwdFallback(t *testing.T) {
	originalHome := os.Getenv("HOME")
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		_ = os.Setenv("HOME", originalHome)
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	home := t.TempDir()
	if err := os.Setenv("HOME", home); err != nil {
		t.Fatal(err)
	}
	sessionID := "123e4567-e89b-12d3-a456-426614174002"
	rolloutDir := filepath.Join(home, ".codex", "sessions", "2026", "06")
	if err := os.MkdirAll(rolloutDir, 0o700); err != nil {
		t.Fatal(err)
	}
	rolloutPath := filepath.Join(
		rolloutDir,
		"rollout-2026-06-01T06-50-00-"+sessionID+".jsonl",
	)
	if err := os.WriteFile(
		rolloutPath,
		[]byte(`{"cwd":"/work/project","id":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(pid int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		switch pid {
		case 200, 201:
			return "/work/project"
		default:
			return ""
		}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "codex", args: "codex"},
		201: {pid: 201, ppid: 101, comm: "codex", args: "codex"},
	}

	sessions := discoverAgentSessionIDs("codex",
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)

	if len(sessions) != 0 {
		t.Fatalf("codex sessions = %#v, want none for ambiguous cwd fallback", sessions)
	}
}

func TestUnixDatabaseTimeSupportsCommonPrecisions(t *testing.T) {
	want := time.Unix(1_787_030_000, 0)
	for name, value := range map[string]string{
		"seconds":      "1787030000",
		"milliseconds": "1787030000000",
		"microseconds": "1787030000000000",
		"nanoseconds":  "1787030000000000000",
	} {
		t.Run(name, func(t *testing.T) {
			if got := unixDatabaseTime(value); !got.Equal(want) {
				t.Fatalf("unixDatabaseTime(%s) = %s, want %s", value, got, want)
			}
		})
	}
}

func TestDiscoverOpenCodeSessionIDsUsesProcessArgs(t *testing.T) {
	originalReader := openCodeSessionEntriesReader
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		openCodeSessionEntriesReader = originalReader
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})
	openCodeSessionEntriesReader = func() []openCodeSessionEntry {
		t.Fatal("session store should not be read when the ID is in process args")
		return nil
	}
	processWorkingDirectoryForMetadata = func(int) string { return "" }

	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "opencode", args: "opencode --session ses_arg"},
	}

	sessions := discoverAgentSessionIDs("opencode", processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != "ses_arg" {
		t.Fatalf("opencode session id = %q, want ses_arg", got)
	}
}

func TestDiscoverOpenCodeSessionIDsUsesWorkingDirectory(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalReader := openCodeSessionEntriesReader
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		openCodeSessionEntriesReader = originalReader
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})
	now := time.Now()
	openCodeSessionEntriesReader = func() []openCodeSessionEntry {
		return []openCodeSessionEntry{
			{sessionID: "ses_new", directory: "/work/project", updatedAt: now},
			{sessionID: "ses_other", directory: "/tmp/other", updatedAt: now},
		}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "opencode", args: "opencode"},
	}
	processTableForMetadata = func() map[int]processInfo { return processes }

	processWorkingDirectoryForMetadata = func(int) string { return "" }
	sessions := discoverAgentSessionIDs("opencode",
		processes,
		map[int]struct{}{100: {}},
		map[int]string{100: "/work/project"},
	)

	if got := sessions[100]; got != "ses_new" {
		t.Fatalf("opencode session id = %q, want ses_new", got)
	}
}

func TestDiscoverOpenCodeSessionIDsSkipsAmbiguousWorkingDirectory(t *testing.T) {
	originalReader := openCodeSessionEntriesReader
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		openCodeSessionEntriesReader = originalReader
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})
	openCodeSessionEntriesReader = func() []openCodeSessionEntry {
		return []openCodeSessionEntry{{sessionID: "ses_new", directory: "/work/project"}}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		switch pid {
		case 200, 201:
			return "/work/project"
		default:
			return ""
		}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "opencode", args: "opencode"},
		201: {pid: 201, ppid: 101, comm: "opencode", args: "opencode"},
	}

	sessions := discoverAgentSessionIDs("opencode",
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)

	if len(sessions) != 0 {
		t.Fatalf("opencode sessions = %#v, want none for ambiguous cwd fallback", sessions)
	}
}

func TestDiscoverClaudeSessionIDsUsesOpenProjectFile(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	sessionID := "de4e84a3-cf16-4cc2-8ba7-34587e984d4a"
	processOpenFilePathsForMetadata = func(pid int) []string {
		if pid != 200 {
			return nil
		}
		return []string{
			"/Users/alice/.claude/projects/-Users-alice-Code-proj/" + sessionID + ".jsonl",
		}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}

	sessions := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("claude session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverClaudeSessionIDsFallsBackToRecentProjectFileForCwd(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "fa0a7327-666a-4439-8052-8d9e61c16d3f"
	projectDir := filepath.Join(home, ".claude", "projects", "-work-project")
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(projectDir, sessionID+".jsonl"),
		[]byte(`{"type":"user","cwd":"/work/project","sessionId":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return time.Now().Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}
	processTableForMetadata = func() map[int]processInfo { return processes }

	sessions := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("claude session id = %q, want %q", got, sessionID)
	}
}

// writeClaudeWorktreeSessionFile writes the shape Claude leaves behind after a
// session enters a git worktree: the file is moved into the worktree's project
// directory and keeps appending there, so its opening entries still name the
// directory the session started in and only the later ones name the worktree.
func writeClaudeWorktreeSessionFile(
	t *testing.T,
	home string,
	sessionID string,
	originalCwd string,
	worktreeCwd string,
) string {
	t.Helper()
	projectDir := filepath.Join(
		home,
		".claude",
		"projects",
		"-work-project--claude-worktrees-feature",
	)
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(projectDir, sessionID+".jsonl")
	lines := []string{
		`{"type":"user","cwd":"` + originalCwd + `","sessionId":"` + sessionID + `"}`,
		`{"type":"worktree-state","worktreeSession":{"originalCwd":"` + originalCwd +
			`","worktreePath":"` + worktreeCwd + `"},"sessionId":"` + sessionID + `"}`,
		`{"type":"user","cwd":"` + worktreeCwd + `","sessionId":"` + sessionID + `"}`,
	}
	if err := os.WriteFile(
		path,
		[]byte(strings.Join(lines, "\n")+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDiscoverClaudeSessionIDsResumesSessionThatMovedIntoWorktree(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "b3f0d1c6-2f4f-4d0e-9f0f-2f26f9b1f4c1"
	worktreeCwd := "/work/project/.claude/worktrees/feature"
	writeClaudeWorktreeSessionFile(t, home, sessionID, "/work/project", worktreeCwd)
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return worktreeCwd
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return time.Now().Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}
	processTableForMetadata = func() map[int]processInfo { return processes }

	sessions := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("claude session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverClaudeSessionIDsIgnoresSessionThatLeftTheWorkingDirectory(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "0d1b2f5c-9a0e-4c1a-8a6a-2b7f5c8d0e11"
	writeClaudeWorktreeSessionFile(
		t,
		home,
		sessionID,
		"/work/project",
		"/work/project/.claude/worktrees/feature",
	)
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return time.Now().Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}

	sessions := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}})

	if len(sessions) != 0 {
		t.Fatalf("relocated Claude session leaked to the original directory: %#v", sessions)
	}
}

func TestClaudeSessionMatchesWorkingDirectoryUsesProjectDirWithoutRecordedCwd(t *testing.T) {
	home := t.TempDir()
	projectDir := filepath.Join(
		home,
		".claude",
		"projects",
		"-work-project--claude-worktrees-feature",
	)
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionID := "6b1f0f2e-1c3a-4f6b-9d2e-7c4a1b8e5f30"
	path := filepath.Join(projectDir, sessionID+".jsonl")
	if err := os.WriteFile(
		path,
		[]byte(`{"type":"mode","mode":"normal","sessionId":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	worktreeCwd := "/work/project/.claude/worktrees/feature"
	if !claudeSessionMatchesWorkingDirectory(path, worktreeCwd) {
		t.Fatalf("session in %q did not match working directory %q", projectDir, worktreeCwd)
	}
	if claudeSessionMatchesWorkingDirectory(path, "/work/project") {
		t.Fatal("session matched the directory its project folder does not encode")
	}
}

// Claude's per-message cwd follows the agent's shell, so a `cd` inside a tool
// call leaves every later record naming a subdirectory while the pane's process
// stays where it launched. That must not cost the window its resume.
func TestDiscoverClaudeSessionIDsResumesAfterAgentChangedDirectory(t *testing.T) {
	originalTable := processTableForMetadata
	t.Cleanup(func() { processTableForMetadata = originalTable })
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "8c2e4d17-3b5a-4e7c-9f01-6d3b8a2c5e94"
	projectDir := filepath.Join(home, ".claude", "projects", "-work-project")
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	lines := []string{
		`{"type":"user","cwd":"/work/project","sessionId":"` + sessionID + `"}`,
		`{"type":"assistant","cwd":"/work/project/server","sessionId":"` + sessionID + `"}`,
		`{"type":"user","cwd":"/work/project/server","sessionId":"` + sessionID + `"}`,
	}
	if err := os.WriteFile(
		filepath.Join(projectDir, sessionID+".jsonl"),
		[]byte(strings.Join(lines, "\n")+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return time.Now().Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}
	processTableForMetadata = func() map[int]processInfo { return processes }

	sessions := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("claude session id = %q, want %q", got, sessionID)
	}
}

// A project directory this encoding cannot account for — a Claude release that
// names them differently — must fall back to the directories the session
// recorded rather than losing the resume outright.
func TestClaudeSessionMatchesWorkingDirectoryFallsBackForUnknownProjectDirName(t *testing.T) {
	projectDir := filepath.Join(t.TempDir(), ".claude", "projects", "7f3a9c22e1")
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionID := "2c7f4e91-5d0b-4a3e-8c16-9b5e2f7a1d40"
	path := filepath.Join(projectDir, sessionID+".jsonl")
	if err := os.WriteFile(
		path,
		[]byte(`{"type":"user","cwd":"/work/project","sessionId":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}

	if !claudeSessionMatchesWorkingDirectory(path, "/work/project") {
		t.Fatal("session did not fall back to its recorded working directory")
	}
	if claudeSessionMatchesWorkingDirectory(path, "/work/other") {
		t.Fatal("session matched a directory it never recorded")
	}
}

func TestJSONStringFieldValuesFromFileEndsCoversBothEnds(t *testing.T) {
	for _, size := range []int{
		sessionFileScanChunkBytes / 2,
		3 * sessionFileScanChunkBytes / 2,
		2 * sessionFileScanChunkBytes,
		3 * sessionFileScanChunkBytes,
	} {
		t.Run(strconv.Itoa(size), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "session.jsonl")
			head := "{\"cwd\":\"/work/project\"}\n"
			tail := "{\"cwd\":\"/work/project\"}\n{\"cwd\":\"/work/project/.claude/worktrees/feature\"}\n"
			filler := "{\"filler\":\"" + strings.Repeat("x", size-len(head)-len(tail)-14) + "\"}\n"
			contents := head + filler + tail
			if len(contents) != size {
				t.Fatalf("fixture size = %d, want %d", len(contents), size)
			}
			if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
				t.Fatal(err)
			}
			got := jsonStringFieldValuesFromFileEnds(path, "cwd")
			want := []string{"/work/project", "/work/project/.claude/worktrees/feature"}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("cwd values = %#v, want %#v", got, want)
			}
		})
	}
}

func TestDiscoverClaudeSessionIDsDoesNotResumeSessionFromBeforeFreshProcess(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
		processStartedAtForMetadata = originalProcessStart
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "a69d705a-1822-49de-83ba-c86bd51932bb"
	projectDir := filepath.Join(home, ".claude", "projects", "-work-project")
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionPath := filepath.Join(projectDir, sessionID+".jsonl")
	if err := os.WriteFile(
		sessionPath,
		[]byte(`{"type":"user","cwd":"/work/project","sessionId":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processStarted := time.Now().UTC().Truncate(time.Second)
	oldActivity := processStarted.Add(-time.Hour)
	if err := os.Chtimes(sessionPath, oldActivity, oldActivity); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return processStarted
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}

	sessions := discoverAgentSessionIDs("claude", processes, map[int]struct{}{100: {}})

	if len(sessions) != 0 {
		t.Fatalf("fresh Claude process inherited stale sessions %#v, want none", sessions)
	}
}

func TestAgentStoreFallbacksRejectSessionsFromBeforeProcess(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "project")
	processStarted := time.Now().UTC().Truncate(time.Second)
	stale := processStarted.Add(-time.Hour)

	if got := openCodeSessionIDForWorkingDirectory(
		[]openCodeSessionEntry{{sessionID: "stale-opencode", directory: project, updatedAt: stale}},
		project,
		processStarted,
	); got != "" {
		t.Fatalf("fresh OpenCode process inherited stale session %q", got)
	}
	if got := antigravitySessionIDForWorkspace(
		[]antigravityHistoryEntry{{conversationID: "stale-antigravity", workspace: project, updatedAt: stale}},
		project,
		processStarted,
	); got != "" {
		t.Fatalf("fresh Antigravity process inherited stale session %q", got)
	}
	if got := cursorSessionIDForWorkspace(
		[]cursorChatEntry{{chatID: "stale-cursor", cwd: project, updatedAt: stale.UnixMilli()}},
		project,
		processStarted,
	); got != "" {
		t.Fatalf("fresh Cursor process inherited stale session %q", got)
	}

	codexID := "123e4567-e89b-12d3-a456-426614174099"
	codexDir := filepath.Join(home, ".codex", "sessions", "2026", "08")
	if err := os.MkdirAll(codexDir, 0o700); err != nil {
		t.Fatal(err)
	}
	codexPath := filepath.Join(codexDir, "rollout-2026-08-18T00-00-00-"+codexID+".jsonl")
	if err := os.WriteFile(codexPath, []byte(`{"cwd":`+fmt.Sprintf("%q", project)+`,"id":"`+codexID+`"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(codexPath, stale, stale); err != nil {
		t.Fatal(err)
	}
	if got := codexRecentSessionIDForWorkingDirectory(project, processStarted); got != "" {
		t.Fatalf("fresh Codex process inherited stale session %q", got)
	}
}

func TestCloseNativeWindowWaitsForRetryableBridgeStop(t *testing.T) {
	originalStop := stopNativeAcpBridgeForWindow
	defer func() { stopNativeAcpBridgeForWindow = originalStop }()

	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:                "@1",
			index:             0,
			nativeAcpBridgeID: "bridge-1",
			lastActivity:      time.Now(),
		},
	}
	window := server.windows[0]
	server.activeID = "@1"

	stopNativeAcpBridgeForWindow = func(id string) error {
		if id != "bridge-1" {
			t.Fatalf("bridge id = %q, want bridge-1", id)
		}
		return errors.New("stop failed")
	}
	shouldShutdown, err := server.closeWindow("@1")
	if err == nil {
		t.Fatal("close succeeded despite bridge stop failure")
	}
	if shouldShutdown {
		t.Fatal("failed close requested server shutdown")
	}
	if window.closed || window.closing {
		t.Fatal("failed bridge stop did not preserve a retryable open window")
	}
	if snapshots := server.snapshots(); len(snapshots) != 1 {
		t.Fatalf("snapshot count after failed close = %d, want 1", len(snapshots))
	}

	stopNativeAcpBridgeForWindow = func(id string) error {
		if window.closed {
			t.Fatal("window closed before bridge stop succeeded")
		}
		return nil
	}
	shouldShutdown, err = server.closeWindow("@1")
	if err != nil {
		t.Fatal(err)
	}
	if !shouldShutdown {
		t.Fatal("successful native close did not request shutdown")
	}
	if !window.closed || len(server.windows) != 0 {
		t.Fatal("window remained open after bridge stop succeeded")
	}
}

func TestCloseActiveWindowSelectsNextWindowImmediately(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("one"), lastActivity: time.Now()},
		{id: "@2", index: 1, history: []byte("two"), lastActivity: time.Now()},
		{id: "@3", index: 2, history: []byte("three"), lastActivity: time.Now()},
	}
	closedWindow := server.windows[1]
	replacement := server.windows[2]
	server.activeID = "@2"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	shouldShutdown, err := server.closeWindow("@2")
	if err != nil {
		t.Fatal(err)
	}
	if shouldShutdown {
		t.Fatal("closing one of several windows requested shutdown")
	}

	if got := server.activeWindowID(); got != "@3" {
		t.Fatalf("active window = %q, want next window @3", got)
	}
	if !closedWindow.closed || len(server.windows) != 2 {
		t.Fatal("closed window was not marked closed immediately")
	}
	want := replayPrefixForTest(replacement) + "three" +
		replayPostHistorySuffixForTest(true)
	waitForRecordedOutput(t, attach, want)
}

func TestCloseLastIndexedActiveWindowWrapsToFirstWindow(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("one"), lastActivity: time.Now()},
		{id: "@2", index: 1, history: []byte("two"), lastActivity: time.Now()},
	}
	server.activeID = "@2"
	registerTestAttachClient(t, server, attach, "primary", server.width, server.height)

	shouldShutdown, err := server.closeWindow("@2")
	if err != nil {
		t.Fatal(err)
	}
	if shouldShutdown {
		t.Fatal("closing one of several windows requested shutdown")
	}

	if got := server.activeWindowID(); got != "@1" {
		t.Fatalf("active window = %q, want wrapped window @1", got)
	}
	want := replayPrefixForTest(server.windows[0]) + "one" +
		replayPostHistorySuffixForTest(true)
	waitForRecordedOutput(t, attach, want)
}

func TestCloseWindowRemovesFromSnapshotsImmediately(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
		{id: "@3", index: 2, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	shouldShutdown, err := server.closeWindow("@2")
	if err != nil {
		t.Fatal(err)
	}
	if shouldShutdown {
		t.Fatal("closing one of several windows requested shutdown")
	}

	snapshots := server.snapshots()
	if len(snapshots) != 2 {
		t.Fatalf("snapshot count = %d, want 2", len(snapshots))
	}
	if snapshots[0].ID != "@1" || snapshots[0].Index != 0 {
		t.Fatalf("first snapshot = %#v, want @1 at index 0", snapshots[0])
	}
	if snapshots[1].ID != "@3" || snapshots[1].Index != 1 {
		t.Fatalf("second snapshot = %#v, want @3 at index 1", snapshots[1])
	}
}

func TestCloseLastWindowRequestsShutdown(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	shouldShutdown, err := server.closeWindow("@1")
	if err != nil {
		t.Fatal(err)
	}
	if !shouldShutdown {
		t.Fatal("closing the last window did not request shutdown")
	}
	if got := server.activeWindowID(); got != "" {
		t.Fatalf("active window = %q, want none", got)
	}
	if snapshots := server.snapshots(); len(snapshots) != 0 {
		t.Fatalf("snapshot count = %d, want 0", len(snapshots))
	}
}

func TestRestoreSnapshotIncludesShellHistory(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:                    "@1",
			index:                 0,
			name:                  "zsh",
			command:               "zsh",
			foregroundCommand:     "zsh",
			history:               []byte("shell history"),
			lastActivity:          time.Now(),
			cursorVisible:         false,
			cursorVisibilityKnown: true,
		},
		{
			id:                "@2",
			index:             1,
			name:              "Codex",
			command:           "codex",
			foregroundCommand: "codex",
			agentTool:         "codex",
			history:           []byte("agent history"),
			lastActivity:      time.Now(),
		},
	}
	server.activeID = "@1"

	restore := server.restoreSnapshot()

	if got := len(restore.Windows); got != 2 {
		t.Fatalf("restore window count = %d, want 2", got)
	}
	if got := restore.Windows[0].HistoryBase64; got != base64.StdEncoding.EncodeToString([]byte("shell history")) {
		t.Fatalf("shell history = %q, want encoded shell history", got)
	}
	if !restore.Windows[0].Active {
		t.Fatal("active shell window was not marked active")
	}
	if !restore.Windows[0].CursorVisibilityKnown || restore.Windows[0].CursorVisible {
		t.Fatalf("cursor visibility = known:%v visible:%v, want known hidden", restore.Windows[0].CursorVisibilityKnown, restore.Windows[0].CursorVisible)
	}
	if got := restore.Windows[1].HistoryBase64; got != "" {
		t.Fatalf("agent history = %q, want no replayed agent history", got)
	}
}

func TestCreateWindowOptionsForRestorePreservesShellHistory(t *testing.T) {
	state := restoreWindowState{
		Name:                  "Project shell",
		Cwd:                   "/tmp/project",
		CurrentCommand:        "zsh",
		PaneTitle:             "Project shell",
		HistoryBase64:         base64.StdEncoding.EncodeToString([]byte("prompt")),
		CursorVisible:         false,
		CursorVisibilityKnown: true,
	}

	options := createWindowOptionsForRestore(state, false)

	if options.command != "" {
		t.Fatalf("command = %q, want login shell", options.command)
	}
	if got := string(options.history); got != "prompt" {
		t.Fatalf("history = %q, want prompt", got)
	}
	if options.cwd != "/tmp/project" {
		t.Fatalf("cwd = %q, want /tmp/project", options.cwd)
	}
	if !options.cursorVisibilityKnown || options.cursorVisible {
		t.Fatalf("cursor visibility = known:%v visible:%v, want known hidden", options.cursorVisibilityKnown, options.cursorVisible)
	}
}

func TestRestoreDropsUnsupportedAgentMetadata(t *testing.T) {
	for _, name := range []string{"Gemini CLI", "Codex"} {
		for _, command := range []string{"gemini", "zsh", "copilot"} {
			t.Run(name+"/"+command, func(t *testing.T) {
				state := restoreWindowState{
					Name: name, CurrentCommand: command, PaneTitle: "Claude Code", AgentTool: "gemini",
					AgentToolConfirmed: true, AgentSessionID: "legacy-session",
					AgentSessionDir: "/tmp/legacy", AgentSessionPath: "/tmp/legacy/session.json",
					AgentSessionIdentityExact: true,
					HistoryBase64:             base64.StdEncoding.EncodeToString([]byte("shell history")),
					HistoryStartsAtGround:     true,
				}
				options := createWindowOptionsForRestore(state, false)
				if options.command != "" || options.agentTool != "" {
					t.Fatalf("restored unsupported agent: command=%q tool=%q", options.command, options.agentTool)
				}
				if options.agentSessionID != "" || options.agentSessionDir != "" || options.agentSessionPath != "" || options.agentSessionIdentityExact {
					t.Fatal("unsupported agent session identity survived restore")
				}
				tool, confirmed := newWindowAgentTool(options, state.Name)
				if tool != "" || !confirmed {
					t.Fatalf("new window should confirm a plain shell, got tool=%q confirmed=%v", tool, confirmed)
				}
				if command == "zsh" && string(options.history) != "shell history" {
					t.Fatalf("shell history lost: %q", options.history)
				}
				if command != "zsh" && len(options.history) != 0 {
					t.Fatal("unsupported TUI history should not replay into a new shell")
				}
				window := &muxWindow{name: name, paneTitle: state.PaneTitle, command: "zsh", agentTool: tool, agentToolConfirmed: confirmed}
				nextState := restoreWindowState{Name: name, PaneTitle: window.paneTitle, CurrentCommand: window.currentCommandLocked(), AgentTool: window.agentToolLocked(), AgentToolConfirmed: window.agentToolConfirmedLocked()}
				next := createWindowOptionsForRestore(nextState, false)
				if next.command != "" || next.agentTool != "" {
					t.Fatalf("second restore substituted an agent: command=%q tool=%q", next.command, next.agentTool)
				}
				for _, unsupported := range []string{"gemini", "node"} {
					window.foregroundCommand = unsupported
					nextState.CurrentCommand = window.currentCommandLocked()
					nextState.AgentTool = window.agentToolLocked()
					next = createWindowOptionsForRestore(nextState, false)
					if next.command != "" || next.agentTool != "" {
						t.Fatalf("unsupported live command %q substituted an agent: command=%q tool=%q", unsupported, next.command, next.agentTool)
					}
				}
				window.foregroundCommand = "copilot"
				if window.agentToolLocked() != "copilot" {
					t.Fatal("explicit plain-shell identity must not block later live agent detection")
				}
			})
		}
	}
}

func TestCreateWindowOptionsForRestoreSanitizesLegacyKittyPayload(t *testing.T) {
	history := append(bytes.Repeat([]byte("A"), 512), "\x1b\\\r\nprompt"...)
	state := restoreWindowState{
		Name:           "Project shell",
		CurrentCommand: "zsh",
		HistoryBase64:  base64.StdEncoding.EncodeToString(history),
	}

	options := createWindowOptionsForRestore(state, false)

	if got, want := string(options.history), "\r\nprompt"; got != want {
		t.Fatalf("legacy restore history = %q, want %q", got, want)
	}
}

func TestCreateWindowOptionsForRestoreDropsIncompleteTrailingAPC(t *testing.T) {
	state := restoreWindowState{
		Name:                  "Project shell",
		CurrentCommand:        "zsh",
		HistoryBase64:         base64.StdEncoding.EncodeToString([]byte("prompt\r\n\x1b_Ga=f,i=7;AAAA")),
		HistoryStartsAtGround: true,
	}

	options := createWindowOptionsForRestore(state, false)

	if got, want := string(options.history), "prompt\r\n"; got != want {
		t.Fatalf("restore history = %q, want %q", got, want)
	}
}

func TestEnrichRestoreClearsUnvalidatedCarriedAgentSessions(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	restore := &serverRestore{Windows: []restoreWindowState{
		{Name: "Copilot CLI", AgentTool: "copilot", AgentSessionID: "stale-copilot"},
		{Name: "Codex", AgentTool: "codex", AgentSessionID: "stale-codex"},
		{Name: "OpenCode", AgentTool: "opencode", AgentSessionID: "stale-opencode"},
		{Name: "Claude Code", AgentTool: "claude", AgentSessionID: "stale-claude"},
		{Name: "Antigravity", AgentTool: "antigravity", AgentSessionID: "stale-antigravity"},
		{Name: "Cursor Agent", AgentTool: "cursor-agent", AgentSessionID: "stale-cursor"},
		{Name: "Pi", AgentTool: "pi", AgentSessionID: "stale-pi"},
	}}

	enrichRestoreWithAgentSessionIDs(restore)

	for i, window := range restore.Windows {
		if window.AgentSessionID != "" {
			t.Fatalf("window %d (%s) kept unvalidated session %q", i, window.AgentTool, window.AgentSessionID)
		}
	}
}

func TestCreateWindowOptionsForRestoreBuildsAgentResumeCommand(t *testing.T) {
	state := restoreWindowState{
		Name:           "Copilot CLI",
		Cwd:            "/tmp/project",
		CurrentCommand: "copilot",
		AgentTool:      "copilot",
		AgentSessionID: "session's id",
		HistoryBase64:  base64.StdEncoding.EncodeToString([]byte("old agent screen")),
	}

	options := createWindowOptionsForRestore(state, false)

	if got := options.command; got != monkeyMuxAgentLaunchCommand("copilot --resume 'session'\"'\"'s id'")+" || "+monkeyMuxAgentLaunchCommand("copilot") {
		t.Fatalf("command = %q, want quoted copilot resume with fresh fallback", got)
	}
	if len(options.history) != 0 {
		t.Fatalf("agent restore history length = %d, want 0", len(options.history))
	}
	if options.agentTool != "copilot" {
		t.Fatalf("agent tool = %q, want copilot", options.agentTool)
	}
}

func TestEnrichRestoreWithAgentSessionIDsUsesAntigravityHistory(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	originalProcessTable := processTableForMetadata
	t.Cleanup(func() {
		processStartedAtForMetadata = originalProcessStart
		processTableForMetadata = originalProcessTable
	})
	now := time.Now().UTC().Truncate(time.Second)
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			200: {pid: 200, ppid: 1, comm: "cmd.exe", args: "cmd.exe"},
			201: {pid: 201, ppid: 200, comm: "agy", args: "agy"},
		}
	}
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "project")
	historyDir := filepath.Join(home, ".gemini", "antigravity-cli")
	if err := os.MkdirAll(historyDir, 0o700); err != nil {
		t.Fatal(err)
	}
	history := strings.Join([]string{
		fmt.Sprintf(`{"conversationId":"old-session","workspace":%q,"timestamp":%d}`, project, now.Add(-30*time.Second).UnixMilli()),
		fmt.Sprintf(`{"conversationId":"new-session","workspace":%q,"timestamp":%d}`, project, now.UnixMilli()),
		fmt.Sprintf(`{"conversationId":"other-session","workspace":"/tmp/other","timestamp":%d}`, now.UnixMilli()),
	}, "\n")
	if err := os.WriteFile(
		filepath.Join(historyDir, "history.jsonl"),
		[]byte(history+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	restore := &serverRestore{
		Windows: []restoreWindowState{
			{
				Name:           "Antigravity",
				Cwd:            project,
				CurrentCommand: "agy",
				PanePid:        200,
				AgentTool:      "antigravity",
			},
		},
	}

	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "new-session" {
		t.Fatalf("agent session ID = %q, want new-session", got)
	}
	options := createWindowOptionsForRestore(restore.Windows[0], true)
	if got := options.command; got != "agy --dangerously-skip-permissions --conversation 'new-session' || agy --dangerously-skip-permissions" {
		t.Fatalf("command = %q, want Antigravity resume command with fresh fallback", got)
	}
}

func TestEnrichRestoreAntigravityRejectsOtherWorkspaceFileMtime(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	originalProcessTable := processTableForMetadata
	t.Cleanup(func() {
		processStartedAtForMetadata = originalProcessStart
		processTableForMetadata = originalProcessTable
	})
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			200: {pid: 200, ppid: 1, comm: "cmd.exe", args: "cmd.exe"},
			201: {pid: 201, ppid: 200, comm: "agy", args: "agy"},
		}
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "project")
	now := time.Now().UTC().Truncate(time.Second)
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	historyDir := filepath.Join(home, ".gemini", "antigravity-cli")
	if err := os.MkdirAll(historyDir, 0o700); err != nil {
		t.Fatal(err)
	}
	history := fmt.Sprintf(
		"{\"conversationId\":\"stale-project\",\"workspace\":%q,\"timestamp\":%d}\n"+
			"{\"conversationId\":\"current-other\",\"workspace\":\"/tmp/other\",\"timestamp\":%d}\n",
		project, now.Add(-time.Hour).UnixMilli(), now.UnixMilli(),
	)
	path := filepath.Join(historyDir, "history.jsonl")
	if err := os.WriteFile(path, []byte(history), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		Name: "Antigravity", Cwd: project, CurrentCommand: "agy", PanePid: 200, AgentTool: "antigravity",
	}}}

	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "" {
		t.Fatalf("fresh Antigravity pane inherited stale session %q", got)
	}
}

func TestCursorAgentToolMapping(t *testing.T) {
	for _, name := range []string{
		"cursor-agent",
		"/Users/demo/.local/bin/cursor-agent",
	} {
		if got := agentToolFromCommandName(name); got != "cursor-agent" {
			t.Fatalf("agentToolFromCommandName(%q) = %q, want cursor-agent", name, got)
		}
	}
	// The generic `agent` launcher is a Node wrapper; detect it by its
	// versioned install path rather than the ambiguous argv[0].
	nodeWrapper := "/Users/demo/.local/bin/agent --use-system-ca " +
		"/Users/demo/.local/share/cursor-agent/versions/2026.07.01/index.js"
	if got := agentToolFromCommandText(nodeWrapper); got != "cursor-agent" {
		t.Fatalf("agentToolFromCommandText(node wrapper) = %q, want cursor-agent", got)
	}
	// A bare `agent` command/window name is too generic to claim for Cursor.
	if got := agentToolFromCommandName("agent"); got != "" {
		t.Fatalf("agentToolFromCommandName(agent) = %q, want empty", got)
	}
	if got := agentToolFromTerminalTitle("Cursor Agent"); got != "cursor-agent" {
		t.Fatalf("agentToolFromTerminalTitle = %q, want cursor-agent", got)
	}
	if got := agentLaunchCommand("cursor-agent", false); got != "cursor-agent" {
		t.Fatalf("agentLaunchCommand = %q, want cursor-agent", got)
	}
	if got := agentLaunchCommand("cursor-agent", true); got != "cursor-agent --force" {
		t.Fatalf("agentLaunchCommand yolo = %q, want cursor-agent --force", got)
	}
}

func TestLiveCursorWindowPublishesSessionFromFalseConversationMetadata(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	originalProcessTable := processTableForMetadata
	t.Cleanup(func() {
		processStartedAtForMetadata = originalProcessStart
		processTableForMetadata = originalProcessTable
	})
	now := time.Now()
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Second)
		}
		return time.Time{}
	}
	// The live-agent rule only lets a running cursor-agent own a chat.
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			200: {pid: 200, ppid: 1, comm: "zsh", args: "zsh"},
			201: {pid: 201, ppid: 200, comm: "cursor-agent", args: "cursor-agent"},
		}
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "project", "named-subtree")
	chatDir := filepath.Join(home, ".cursor", "chats", "workspace", "live-chat")
	if err := os.MkdirAll(chatDir, 0o700); err != nil {
		t.Fatal(err)
	}
	meta := fmt.Sprintf(
		`{"cwd":%q,"updatedAtMs":%d,"hasConversation":false}`,
		project,
		now.UnixMilli(),
	)
	if err := os.WriteFile(filepath.Join(chatDir, "meta.json"), []byte(meta), 0o600); err != nil {
		t.Fatal(err)
	}

	window := &muxWindow{id: "@1", cwd: project, agentTool: "cursor-agent", foregroundPid: 201}
	_, server := newThemeQueryTestServer(t, window)
	server.refreshProcessMetadata(window.id)

	if window.agentSessionID != "live-chat" {
		t.Fatalf("live Cursor session = %q, want live-chat", window.agentSessionID)
	}
	if !window.agentSessionIdentityExact {
		t.Fatalf("live Cursor identity was not marked exact")
	}
}

func TestEnrichRestoreWithAgentSessionIDsUsesCursorChatStore(t *testing.T) {
	originalProcessStart := processStartedAtForMetadata
	originalProcessTable := processTableForMetadata
	t.Cleanup(func() {
		processStartedAtForMetadata = originalProcessStart
		processTableForMetadata = originalProcessTable
	})
	now := time.Now()
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	processTableForMetadata = func() map[int]processInfo {
		return map[int]processInfo{
			200: {pid: 200, ppid: 1, comm: "cmd.exe", args: "cmd.exe"},
			201: {pid: 201, ppid: 200, comm: "cursor-agent", args: "cursor-agent"},
		}
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "project")
	chatsDir := filepath.Join(home, ".cursor", "chats", "workspacehash")

	writeChat := func(chatID string, cwd string, updatedAtMs int64) {
		dir := filepath.Join(chatsDir, chatID)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		meta := fmt.Sprintf(
			`{"title":"Chat %s","cwd":%q,"updatedAtMs":%d,"hasConversation":false}`,
			chatID, cwd, updatedAtMs,
		)
		if err := os.WriteFile(
			filepath.Join(dir, "meta.json"),
			[]byte(meta),
			0o600,
		); err != nil {
			t.Fatal(err)
		}
	}

	writeChat("old-chat", project, now.Add(-30*time.Second).UnixMilli())
	writeChat("new-chat", project, now.UnixMilli())
	writeChat("other-chat", "/tmp/other", now.Add(time.Second).UnixMilli())

	restore := &serverRestore{
		Windows: []restoreWindowState{
			{
				Name:           "Cursor Agent",
				Cwd:            project,
				CurrentCommand: "cursor-agent",
				PanePid:        200,
				AgentTool:      "cursor-agent",
			},
		},
	}

	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "new-chat" {
		t.Fatalf("agent session ID = %q, want new-chat", got)
	}
	options := createWindowOptionsForRestore(restore.Windows[0], true)
	want := monkeyMuxAgentLaunchCommand("cursor-agent --force --resume 'new-chat'") + " || " + monkeyMuxAgentLaunchCommand("cursor-agent --force")
	if got := options.command; got != want {
		t.Fatalf("command = %q, want %q", got, want)
	}
}

func TestReadRestoreFileKeepsCallerOwnedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "caller-restore.json")
	restore := serverRestore{SchemaVersion: restoreSchemaVersion}
	data, err := json.Marshal(restore)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := readRestoreFile(path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("restore file was removed, want caller-owned file preserved: %v", err)
	}
}

func TestReadRestoreFileDeletesManagedFileOnlyAfterValidation(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	runDir, err := runtimeDirectory()
	if err != nil {
		t.Fatal(err)
	}
	invalidPath := filepath.Join(
		runDir,
		"monkeymux-restore-aaaaaaaaaaaaaaaaaaaaaaaa-1.json",
	)
	if err := os.WriteFile(invalidPath, []byte(`{"schemaVersion":999}`), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := readRestoreFile(invalidPath); err == nil {
		t.Fatal("readRestoreFile invalid schema error = nil, want error")
	}
	if _, err := os.Stat(invalidPath); err != nil {
		t.Fatalf("invalid restore file was removed before validation: %v", err)
	}

	validPath := filepath.Join(
		runDir,
		"monkeymux-restore-bbbbbbbbbbbbbbbbbbbbbbbb-2.json",
	)
	restore := serverRestore{SchemaVersion: restoreSchemaVersion}
	data, err := json.Marshal(restore)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(validPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := readRestoreFile(validPath); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(validPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("managed restore file stat error = %v, want not exist", err)
	}
}

func TestCreateWindowOptionsForRestoreBuildsYoloAgentCommands(t *testing.T) {
	tests := []struct {
		name      string
		state     restoreWindowState
		want      string
		agentTool string
	}{
		{
			name: "copilot resume",
			state: restoreWindowState{
				Name:           "Copilot CLI",
				CurrentCommand: "copilot",
				AgentTool:      "copilot",
				AgentSessionID: "session-123",
			},
			want:      "copilot --yolo --resume 'session-123' || copilot --yolo",
			agentTool: "copilot",
		},
		{
			name: "codex resume",
			state: restoreWindowState{
				Name:           "Codex",
				CurrentCommand: "codex",
				AgentTool:      "codex",
				AgentSessionID: "codex-session",
			},
			want:      "codex --yolo resume 'codex-session' || codex --yolo",
			agentTool: "codex",
		},
		{
			name: "opencode resume",
			state: restoreWindowState{
				Name:           "OpenCode",
				CurrentCommand: "opencode",
				AgentTool:      "opencode",
				AgentSessionID: "_continue",
			},
			want:      `OPENCODE_PERMISSION='{"*":"allow"}' opencode --continue || OPENCODE_PERMISSION='{"*":"allow"}' opencode`,
			agentTool: "opencode",
		},
		{
			name: "opencode resume by id",
			state: restoreWindowState{
				Name:           "OpenCode",
				CurrentCommand: "opencode",
				AgentTool:      "opencode",
				AgentSessionID: "ses_abc",
			},
			want:      `OPENCODE_PERMISSION='{"*":"allow"}' opencode --session 'ses_abc' || OPENCODE_PERMISSION='{"*":"allow"}' opencode`,
			agentTool: "opencode",
		},
		{
			name: "claude resume",
			state: restoreWindowState{
				Name:           "Claude Code",
				CurrentCommand: "claude",
				AgentTool:      "claude",
				AgentSessionID: "de4e84a3-cf16-4cc2-8ba7-34587e984d4a",
			},
			want:      `claude --dangerously-skip-permissions --resume 'de4e84a3-cf16-4cc2-8ba7-34587e984d4a' || claude --dangerously-skip-permissions`,
			agentTool: "claude",
		},
		{
			// Gemini CLI support was dropped: a Gemini window restores as a
			// plain shell instead of relaunching or resuming the agent.
			name: "unsupported gemini window",
			state: restoreWindowState{
				Name:           "Gemini CLI",
				AgentTool:      "gemini",
				CurrentCommand: "gemini",
				PaneTitle:      "Gemini CLI",
				AgentSessionID: "bc1ced23-25ac-4971-8f30-8af35ce2f2f1",
			},
			want:      "",
			agentTool: "",
		},
		{
			name: "antigravity resume",
			state: restoreWindowState{
				Name:           "Antigravity",
				CurrentCommand: "agy",
				AgentTool:      "antigravity",
				AgentSessionID: "session-456",
			},
			want:      `agy --dangerously-skip-permissions --conversation 'session-456' || agy --dangerously-skip-permissions`,
			agentTool: "antigravity",
		},
		{
			name: "antigravity resume continue",
			state: restoreWindowState{
				Name:           "Antigravity",
				CurrentCommand: "agy",
				AgentTool:      "antigravity",
				AgentSessionID: "_continue",
			},
			want:      `agy --dangerously-skip-permissions --continue || agy --dangerously-skip-permissions`,
			agentTool: "antigravity",
		},
		{
			name: "cursor-agent resume by id",
			state: restoreWindowState{
				Name:           "Cursor Agent",
				CurrentCommand: "cursor-agent",
				AgentTool:      "cursor-agent",
				AgentSessionID: "chat-9",
			},
			want:      "cursor-agent --force --resume 'chat-9' || cursor-agent --force",
			agentTool: "cursor-agent",
		},
		{
			name: "cursor-agent resume continue",
			state: restoreWindowState{
				Name:           "Cursor Agent",
				CurrentCommand: "cursor-agent",
				AgentTool:      "cursor-agent",
				AgentSessionID: "_continue",
			},
			want:      "cursor-agent --force --continue || cursor-agent --force",
			agentTool: "cursor-agent",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			options := createWindowOptionsForRestore(tc.state, true)
			if resume, launch, ok := strings.Cut(tc.want, " || "); ok {
				tc.want = monkeyMuxAgentLaunchCommand(resume) + " || " + monkeyMuxAgentLaunchCommand(launch)
			}
			if got := options.command; got != tc.want {
				t.Fatalf("command = %q, want %q", got, tc.want)
			}
			if options.agentTool != tc.agentTool {
				t.Fatalf("agent tool = %q, want %q", options.agentTool, tc.agentTool)
			}
		})
	}
}

func TestThemeHintVerifiesForegroundPidWithoutThrottle(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	window := &muxWindow{
		id:                         "@1",
		foregroundCommand:          "unknown-tui",
		foregroundPid:              42,
		themeColorQueryPid:         42,
		themeColorQueryKeys:        map[string]bool{"11": true},
		lastProcessMetadataRefresh: time.Now(),
		pty:                        wrapPty(t, inputWriter),
	}
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 43
		}
		return 0
	}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent with stale foreground pid")
	}
}

// TestThemeHintDoesNotReSendObservedBackgroundReport guards the
// "hermes spew on every resume" regression. Even when a TUI has
// previously issued an OSC 11 query (and the daemon answered it via
// the live-query path), sendThemeHint must NOT proactively re-push the
// cached response on subsequent theme refreshes unless the foreground
// tool is known to tolerate it. Many TUIs only handle the first response;
// later unsolicited pushes surface as literal "]11;rgb:..." text in their
// input composer.
func TestThemeHintDoesNotReSendObservedBackgroundReport(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	window.observeTerminalMetadataLocked([]byte("\x1b]11;?\x1b\\"))
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if !server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was not sent")
	}
	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[O") && strings.Contains(output, "\x1b[I")
	})
	if strings.Contains(got, backgroundReport) {
		t.Fatalf("theme hint = %q, did not expect unsolicited background report", got)
	}
	if !strings.Contains(got, "\x1b[O") {
		t.Fatalf("theme hint = %q, expected focus-lost for focus-aware window", got)
	}
	window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	foregroundProcessGroupForWindow = func(*muxWindow) int { return 43 }
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent using stale focus/DEC 2031/OSC capabilities")
	}

}

func TestThemeHintAnswersFutureBackgroundQuery(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent before the window requested a background color")
	}

	server.handleWindowOutput("@1", []byte("\x1b]11;?\x1b\\"))

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("theme hint = %q, want %q", got, backgroundReport)
	}
}

func TestThemeHintAnswersFuturePaletteQuery(t *testing.T) {
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
	}
	inputReader, server := newThemeQueryTestServer(t, window)

	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	const paletteReport0 = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	const paletteReport1 = "\x1b]4;1;rgb:dddd/eeee/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport + paletteReport0 + paletteReport1) {
		t.Fatal("theme hint was sent before the window requested a color")
	}

	server.handleWindowOutput("@1", []byte("\x1b]4;0;?\x1b\\"))

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, paletteReport0)
	})
	if got != paletteReport0 {
		t.Fatalf("theme hint = %q, want only palette response %q", got, paletteReport0)
	}
}

func TestThemeHintRefreshesAgentToolsWithoutColorSchemeUpdatesMode(t *testing.T) {
	const modeReport = "\x1b[?997;1n"
	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	const paletteReport = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	const whiteBackgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	for _, tt := range []struct {
		name             string
		command          string
		hint             string
		backgroundReport string
		wantBackground   bool
	}{
		// Focus reporting is the opt-in for FocusOut/FocusIn (including
		// unknown/future agents). Unsolicited OSC 11 stays limited to detected
		// coding agents so generic focus-aware TUIs do not get composer spew.
		{name: "copilot", command: "copilot", wantBackground: true},
		{name: "cursor-agent", command: "cursor-agent", wantBackground: true},
		{name: "claude", command: "claude", wantBackground: true},
		{name: "opencode", command: "opencode", wantBackground: true},
		{name: "antigravity", command: "antigravity", wantBackground: true},
		{name: "agy", command: "agy", wantBackground: true},
		{name: "codex", command: "codex", wantBackground: true},
		{name: "unknown-tui", command: "unknown-tui", wantBackground: false},
		// Gemini CLI support was dropped, so it is treated like any other TUI.
		{name: "unsupported gemini", command: "gemini", wantBackground: false},
		{name: "zsh", command: "zsh", wantBackground: false},
		{name: "zsh background only", command: "zsh", hint: whiteBackgroundReport, backgroundReport: whiteBackgroundReport},
		{name: "unknown-tui colors only", command: "unknown-tui", hint: foregroundReport + backgroundReport + paletteReport},
		{name: "unknown-tui mode only", command: "unknown-tui", hint: modeReport},
		{name: "zsh mode only", command: "zsh", hint: modeReport},
		{name: "codex mode only", command: "codex", hint: modeReport},
		{name: "claude mode only", command: "claude", hint: modeReport},
	} {
		t.Run(tt.name, func(t *testing.T) {
			window := &muxWindow{
				id:                "@1",
				foregroundCommand: tt.command,
			}
			window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
			if !window.themeHintFocusTransitionLocked() {
				t.Fatalf("%s focus-aware window did not request focus transition", tt.command)
			}
			hint := tt.hint
			if hint == "" {
				hint = modeReport + foregroundReport + backgroundReport + paletteReport
			}
			backgroundReport := backgroundReport
			if tt.backgroundReport != "" {
				backgroundReport = tt.backgroundReport
			}
			want := ""
			if tt.wantBackground {
				want = backgroundReport
			}
			if got := string(window.themeHintRefreshDataLocked([]byte(hint))); got != want {
				t.Fatalf("theme refresh = %q, want %q", got, want)
			}
		})
	}
}

func TestThemeHintFocusTransitionDefaultsToFocusReporting(t *testing.T) {
	noFocus := &muxWindow{foregroundCommand: "unknown-tui"}
	if noFocus.themeHintFocusTransitionLocked() {
		t.Fatal("window without focus reporting requested focus transition")
	}
}

func TestThemeHintSendsModeReportWhenColorSchemeUpdatesMode(t *testing.T) {
	// DEC 2031 is the general opt-in: any TUI that enables it gets the mode
	// report, including unknown future agents, without per-tool hardcoding.
	// Unsolicited OSC 11 is still withheld unless the window is a known agent
	// with focus mode or previously queried those colors under 2031.
	for _, tt := range []struct {
		name                string
		command             string
		enableFocus         bool
		wantBackground      bool
		wantFocusTransition bool
	}{
		{name: "unknown-tui", command: "unknown-tui"},
		// 2031 + focus: mode report for everyone; agents also keep OSC 11, and
		// focus transition comes from the 2031+focus capability clause (including Codex).
		{name: "copilot", command: "copilot", enableFocus: true, wantBackground: true, wantFocusTransition: true},
		{name: "cursor-agent", command: "cursor-agent", enableFocus: true, wantBackground: true, wantFocusTransition: true},
		{name: "claude", command: "claude", enableFocus: true, wantBackground: true, wantFocusTransition: true},
		{name: "opencode", command: "opencode", enableFocus: true, wantBackground: true, wantFocusTransition: true},
		{name: "antigravity", command: "antigravity", enableFocus: true, wantBackground: true, wantFocusTransition: true},
		{name: "codex-2031-focus", command: "codex", enableFocus: true, wantBackground: true, wantFocusTransition: true},
		// 2031 without focus: mode report only (no agent OSC 11, no focus pair).
		{name: "codex-2031-only", command: "codex"},
		{name: "claude-2031-only", command: "claude"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			window := &muxWindow{
				id:                "@1",
				foregroundCommand: tt.command,
			}
			window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
			if tt.enableFocus {
				window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
			}
			const modeReport = "\x1b[?997;2n"
			const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
			want := modeReport
			if tt.wantBackground {
				want += backgroundReport
			}
			if got := string(window.themeHintRefreshDataLocked([]byte(modeReport + backgroundReport))); got != want {
				t.Fatalf("theme refresh = %q, want %q", got, want)
			}
			if got := window.themeHintFocusTransitionLocked(); got != tt.wantFocusTransition {
				t.Fatalf("focus transition = %t, want %t", got, tt.wantFocusTransition)
			}
		})
	}
}

func TestThemeHintDoesNotSignalResizeRedraw(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "codex",
		pty:               wrapPty(t, inputWriter),
	}
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 6262
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	if !server.sendThemeHint(foregroundReport + backgroundReport) {
		t.Fatal("theme hint was not sent")
	}

	if len(signaled) != 0 {
		t.Fatalf("signaled process groups = %#v, want none", signaled)
	}
}

func TestSendThemeHintIgnoresOversizedPayload(t *testing.T) {
	server := newMuxServer("test")
	server.themeHint = []byte("existing")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	if server.sendThemeHint(strings.Repeat("x", themeHintLimitBytes+1)) {
		t.Fatal("oversized theme hint was sent")
	}
	if got := string(server.themeHint); got != "existing" {
		t.Fatalf("theme hint = %q, want existing", got)
	}
}

func TestThemeHintReSendsObservedPaletteReportsToColorSchemeUpdatesTui(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		pty:               wrapPty(t, inputWriter),
	}
	foregroundProcessGroup := 42
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return foregroundProcessGroup
		}
		return 0
	}
	window.observeTerminalMetadataLocked([]byte("\x1b]4;0;?\x1b\\"))
	window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	const paletteReport0 = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	const paletteReport1 = "\x1b]4;1;rgb:dddd/eeee/ffff\x1b\\"
	if !server.sendThemeHint(
		foregroundReport + backgroundReport + paletteReport0 + paletteReport1,
	) {
		t.Fatal("theme hint was not sent")
	}

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[I")
	})
	if !strings.HasPrefix(got, paletteReport0) {
		t.Fatalf(
			"theme hint = %q, want queried palette report prefix %q",
			got,
			paletteReport0,
		)
	}
	if strings.Contains(got, foregroundReport) || strings.Contains(got, backgroundReport) {
		t.Fatalf(
			"theme hint = %q, did not expect unqueried default color reports",
			got,
		)
	}
	if strings.Contains(got, paletteReport1) {
		t.Fatalf("theme hint = %q, did not expect unqueried palette report", got)
	}
	if !strings.Contains(got, "\x1b[O") || !strings.Contains(got, "\x1b[I") {
		t.Fatalf("theme hint = %q, want focus transition", got)
	}
}

func TestThemeHintIgnoresWindowsWithoutThemeCapabilities(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{id: "@1", foregroundCommand: "zsh", pty: wrapPty(t, inputWriter)}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent")
	}
}

func readPipeUntil(
	t *testing.T,
	reader *os.File,
	predicate func(output string) bool,
) string {
	t.Helper()
	result := make(chan string, 1)
	go func() {
		var output strings.Builder
		buffer := make([]byte, 64)
		for {
			n, err := reader.Read(buffer)
			if n > 0 {
				output.Write(buffer[:n])
				current := output.String()
				if predicate(current) {
					result <- current
					return
				}
			}
			if err != nil {
				result <- output.String()
				return
			}
		}
	}()

	select {
	case output := <-result:
		if !predicate(output) {
			t.Fatalf("pipe output = %q, predicate was not satisfied", output)
		}
		return output
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for pipe output")
		return ""
	}
}

func TestRunShellCommandUsesServerEnvironment(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("MONKEYMUX_TEST_ENV", "ok")
	server := newMuxServer("test")

	output, exitCode, err := server.runShellCommand("printf %s \"$MONKEYMUX_TEST_ENV\"")
	if err != nil {
		t.Fatalf("runShellCommand returned error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("exitCode = %d, want 0", exitCode)
	}
	if output != "ok" {
		t.Fatalf("output = %q, want ok", output)
	}
}

func BenchmarkStripTerminalQueriesFromReplayClean(b *testing.B) {
	history := bytes.Repeat([]byte("normal terminal output\n"), 4096)
	b.ReportAllocs()
	b.SetBytes(int64(len(history)))

	for i := 0; i < b.N; i++ {
		replay := stripTerminalQueriesFromReplay(history)
		if len(replay) != len(history) {
			b.Fatalf("replay length = %d, want %d", len(replay), len(history))
		}
	}
}

func BenchmarkStripTerminalQueriesFromReplayWithQueries(b *testing.B) {
	history := bytes.Repeat(
		[]byte("before\x1b[c\x1b[6n\x1b]11;?\x07after\n"),
		4096,
	)
	b.ReportAllocs()
	b.SetBytes(int64(len(history)))

	for i := 0; i < b.N; i++ {
		replay := stripTerminalQueriesFromReplay(history)
		if bytes.Contains(replay, []byte("\x1b[c")) {
			b.Fatal("unsafe device attribute query was not stripped")
		}
	}
}

func BenchmarkHandleWindowOutputActive(b *testing.B) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	registerTestAttachClient(b, server, discardConn{}, "primary", server.width, server.height)
	chunk := bytes.Repeat([]byte("screen output\n"), 2048)
	b.ReportAllocs()
	b.SetBytes(int64(len(chunk)))

	for i := 0; i < b.N; i++ {
		server.handleWindowOutput("@1", chunk)
	}
}

func TestRunShellCommandReportsExitCode(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")

	_, exitCode, err := server.runShellCommand("exit 7")
	if err != nil {
		t.Fatalf("runShellCommand returned error: %v", err)
	}
	if exitCode != 7 {
		t.Fatalf("exitCode = %d, want 7", exitCode)
	}
}

func TestRunShellCommandBoundsOutput(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")

	output, _, err := server.runShellCommand("yes x")
	if !errors.Is(err, errRunCommandOutputLimit) {
		t.Fatalf("runShellCommand error = %v, want output limit", err)
	}
	if len(output) != runCommandOutputMaxBytes {
		t.Fatalf(
			"output length = %d, want %d",
			len(output),
			runCommandOutputMaxBytes,
		)
	}
}

func TestControlRunCommandRequestsRunInParallel(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	fifo := filepath.Join(t.TempDir(), "release")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	releasePipe, err := os.OpenFile(fifo, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	var releaseOnce sync.Once
	release := func() {
		releaseOnce.Do(func() {
			if _, err := releasePipe.WriteString("ready\n"); err != nil {
				t.Error(err)
			}
		})
	}
	t.Cleanup(func() { release(); _ = releasePipe.Close() })
	server := newMuxServer("test")
	serverConn, clientConn := net.Pipe()
	defer func() {
		_ = clientConn.Close()
	}()
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleControl(serverConn, bufio.NewReader(serverConn))
	}()

	decoder := json.NewDecoder(clientConn)
	readResponse := func() controlResponse {
		t.Helper()
		if err := clientConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	writeRequest := func(request controlMessage) {
		t.Helper()
		if err := clientConn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		if err := json.NewEncoder(clientConn).Encode(request); err != nil {
			t.Fatal(err)
		}
	}

	if response := readResponse(); response.Type != "hello" {
		t.Fatalf("first response type = %q, want hello", response.Type)
	}
	if response := readResponse(); response.Type != "window_list" {
		t.Fatalf("second response type = %q, want window_list", response.Type)
	}

	writeRequest(controlMessage{
		ID:      "slow",
		Type:    "run_command",
		Command: "read -r release < " + shellQuote(fifo) + "; printf slow",
	})
	writeRequest(controlMessage{
		ID:      "fast",
		Type:    "run_command",
		Command: "printf fast",
	})

	if response := readResponse(); response.ID != "fast" || response.Data != "fast" {
		t.Fatalf("first command response = %#v, want fast command output", response)
	}
	release()
	if response := readResponse(); response.ID != "slow" || response.Data != "slow" {
		t.Fatalf("second command response = %#v, want slow command output", response)
	}

	_ = clientConn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("control handler did not stop")
	}
}

func TestControlStartAcpBridgeHostsProviderInServer(t *testing.T) {
	dir := shortUnixSocketDir(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("SHELL", "/bin/sh")
	originalWindowArguments := nativeAcpWindowArguments
	nativeAcpWindowArguments = func(string) ([]string, error) { return nil, nil }
	t.Cleanup(func() { nativeAcpWindowArguments = originalWindowArguments })
	server := newMuxServer("test")
	t.Cleanup(server.close)
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { _ = clientConn.Close(); _ = serverConn.Close() })
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleControl(serverConn, bufio.NewReader(serverConn))
	}()
	decoder := json.NewDecoder(clientConn)
	readResponse := func() controlResponse {
		t.Helper()
		if err := clientConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	if response := readResponse(); response.Type != "hello" {
		t.Fatalf("first response type = %q, want hello", response.Type)
	}
	if response := readResponse(); response.Type != "window_list" {
		t.Fatalf("second response type = %q, want window_list", response.Type)
	}
	request := controlMessage{
		ID:         "agent-start",
		Type:       "start_acp_bridge",
		ProviderID: "test:cat-acp",
		Provider:   "Test Agent",
		Command:    "cat",
		Cwd:        ".",
	}
	if err := json.NewEncoder(clientConn).Encode(request); err != nil {
		t.Fatal(err)
	}
	var response controlResponse
	for response.ID != request.ID {
		response = readResponse()
	}
	if response.Type != "acp_bridge_started" {
		t.Fatalf("start response = %#v", response)
	}
	var frame acpWireMessage
	if err := json.Unmarshal([]byte(response.Data), &frame); err != nil {
		t.Fatal(err)
	}
	if frame.Type != "started" || !validAcpBridgeID(frame.BridgeID) || frame.WindowID == "" {
		t.Fatalf("started frame = %#v", frame)
	}
	windows := server.snapshots()
	if len(windows) != 1 || windows[0].ID != frame.WindowID ||
		windows[0].NativeAcpBridgeID != frame.BridgeID ||
		windows[0].NativeAcpProviderID != request.ProviderID {
		t.Fatalf("native ACP windows = %#v", windows)
	}
	info, err := acpBridgeStatus(frame.BridgeID)
	if err != nil {
		t.Fatal(err)
	}
	if info.ProviderID != request.ProviderID || info.State != "running" {
		t.Fatalf("bridge status = %#v", info)
	}

	_ = clientConn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("first control handler did not stop")
	}
	if _, err := acpBridgeStatus(frame.BridgeID); err != nil {
		t.Fatalf("bridge stopped after client disconnect: %v", err)
	}

	serverConn2, clientConn2 := net.Pipe()
	t.Cleanup(func() { _ = clientConn2.Close(); _ = serverConn2.Close() })
	done2 := make(chan struct{})
	go func() {
		defer close(done2)
		server.handleControl(serverConn2, bufio.NewReader(serverConn2))
	}()
	decoder2 := json.NewDecoder(clientConn2)
	var hello, windowList controlResponse
	if err := decoder2.Decode(&hello); err != nil {
		t.Fatal(err)
	}
	if err := decoder2.Decode(&windowList); err != nil {
		t.Fatal(err)
	}
	if hello.Type != "hello" || windowList.Type != "window_list" ||
		len(windowList.Windows) != 1 ||
		windowList.Windows[0].NativeAcpBridgeID != frame.BridgeID ||
		windowList.Windows[0].NativeAcpProviderID != request.ProviderID {
		t.Fatalf("reconnected control state = %#v / %#v", hello, windowList)
	}

	server.close()
	_ = clientConn2.Close()
	select {
	case <-done2:
	case <-time.After(2 * time.Second):
		t.Fatal("second control handler did not stop")
	}
	if _, err := acpBridgeStatus(frame.BridgeID); err == nil {
		t.Fatal("bridge survived owning workspace shutdown")
	}
}

func TestStalledControlClientDoesNotBlockWindowOutput(t *testing.T) {
	server := newMuxServer("stalled-control")
	defer server.close()
	window := &muxWindow{id: "@1"}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn, peer := newDeadlineTestPipe(t)
	defer peer.Close()
	_ = peer.SetDeadline(time.Now().Add(socketTimeout + time.Second))
	handlerDone := make(chan struct{})
	go func() {
		defer close(handlerDone)
		server.handleControl(conn, bufio.NewReader(conn))
	}()
	decoder := json.NewDecoder(peer)
	for range 2 {
		assertTestDeadline(t, conn.writeDeadlines, false)
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
	}
	outputDone := make(chan struct{})
	go func() {
		defer close(outputDone)
		server.handleWindowOutput(window.id, []byte("first"))
		server.handleWindowOutput(window.id, []byte("second"))
	}()
	assertTestDeadline(t, conn.writeDeadlines, false)
	if err := conn.Conn.SetWriteDeadline(time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	for _, done := range []chan struct{}{outputDone, handlerDone} {
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("expired control writer blocked output or cleanup")
		}
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	if len(server.controls) != 0 {
		t.Fatal("stalled control client was not removed")
	}
	if got := string(window.history); got != "firstsecond" {
		t.Fatalf("history = %q, want firstsecond", got)
	}
}

func TestControlClientCloseCancelsRunCommand(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")
	client := newControlClient(nil)
	done := make(chan error, 1)

	startedAt := time.Now()
	go func() {
		_, _, err := client.runShellCommand(server, "slow-command", "sleep 30")
		done <- err
	}()
	waitForTrackedCommand(t, client)

	client.close()

	select {
	case err := <-done:
		if !errors.Is(err, errRunCommandCanceled) {
			t.Fatalf("runShellCommand error = %v, want canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runShellCommand did not stop after client close")
	}
	if elapsed := time.Since(startedAt); elapsed >= 2*time.Second {
		t.Fatalf("command ran for %s after client close", elapsed)
	}
}

func waitForTrackedCommand(t *testing.T, client *controlClient) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		client.commandsMu.Lock()
		count := len(client.commands)
		client.commandsMu.Unlock()
		if count > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("command was not tracked")
}

func TestPromptForServerUpdateDefaultsToKeepingExistingSession(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if promptForServerUpdate(strings.NewReader("\n"), &output, "main", status) {
		t.Fatal("empty prompt response updated server")
	}
	if got := output.String(); !strings.Contains(got, "update skipped") {
		t.Fatalf("prompt output = %q, want skipped message", got)
	}
}

func TestPromptForServerUpdateAcceptsYes(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if !promptForServerUpdate(strings.NewReader("yes\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
}

func TestPromptForServerUpdateWarnsWhenShutdownIsUnavailable(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if !promptForServerUpdate(strings.NewReader("y\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
	if got := output.String(); !strings.Contains(got, "may abandon") {
		t.Fatalf("prompt output = %q, want abandon warning", got)
	}
}

func TestPromptForServerUpdateDescribesWindowRestore(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{
		version:      "0.1.1",
		capabilities: []string{"shutdown"},
	}

	if !promptForServerUpdate(strings.NewReader("y\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
	if got := output.String(); !strings.Contains(got, "try to restore existing windows") {
		t.Fatalf("prompt output = %q, want restore message", got)
	}
}

func TestPromptForServerUpdateSkipsOnReadError(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if promptForServerUpdate(errReader{}, &output, "main", status) {
		t.Fatal("failed prompt read updated server")
	}
	if got := output.String(); !strings.Contains(got, "update skipped") {
		t.Fatalf("prompt output = %q, want skipped message", got)
	}
}

func TestCapabilitiesAdvertiseBracketedPasteControlInput(t *testing.T) {
	for _, capability := range capabilities {
		if capability == "inject-input-bracketed-paste" {
			return
		}
	}
	t.Fatal("bracketed-paste control input capability is not advertised")
}

func TestRunningServerStatusSupportsCapability(t *testing.T) {
	status := runningServerStatus{
		version:      "0.1.0",
		capabilities: []string{"attach", "shutdown"},
	}

	if !status.supportsCapability("shutdown") {
		t.Fatal("expected shutdown capability")
	}
	if status.supportsCapability("missing") {
		t.Fatal("unexpected missing capability")
	}
}

type errReader struct{}

type discardConn struct{}

type failingConn struct {
	discardConn
}

type closeOnSuccessfulWriteConn struct {
	discardConn
	client *attachClient
}

type gatedConn struct {
	*recordingConn
	gate    <-chan struct{}
	started chan struct{}
	once    sync.Once
}

type deadlineBudgetConn struct {
	*recordingConn
	mu                sync.Mutex
	maxWriteBytes     int
	writesPerDeadline int
	writesRemaining   int
	deadlineRefreshes int
}

type deadlineBudgetTimeoutError struct{}

type responseCheckConn struct {
	discardConn
	client               *attachClient
	responseClaimedFocus bool
}

func (errReader) Read([]byte) (int, error) {
	return 0, io.ErrUnexpectedEOF
}

func (discardConn) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (discardConn) Write(data []byte) (int, error) {
	return len(data), nil
}

func (failingConn) Write([]byte) (int, error) {
	return 0, io.ErrClosedPipe
}

func (c *closeOnSuccessfulWriteConn) Write(data []byte) (int, error) {
	c.client.close()
	return len(data), nil
}

func (c *gatedConn) Write(data []byte) (int, error) {
	if c.started != nil {
		c.once.Do(func() {
			close(c.started)
		})
	}
	<-c.gate
	return c.recordingConn.Write(data)
}

func (c *deadlineBudgetConn) Write(data []byte) (int, error) {
	c.mu.Lock()
	if c.writesRemaining == 0 {
		c.mu.Unlock()
		return 0, deadlineBudgetTimeoutError{}
	}
	c.writesRemaining--
	maxWriteBytes := c.maxWriteBytes
	c.mu.Unlock()
	if maxWriteBytes <= 0 || maxWriteBytes > len(data) {
		maxWriteBytes = len(data)
	}
	return c.recordingConn.Write(data[:maxWriteBytes])
}

func (c *deadlineBudgetConn) SetWriteDeadline(deadline time.Time) error {
	if deadline.IsZero() {
		return nil
	}
	c.mu.Lock()
	c.writesRemaining = c.writesPerDeadline
	c.deadlineRefreshes++
	c.mu.Unlock()
	return nil
}

func (c *deadlineBudgetConn) deadlineRefreshCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.deadlineRefreshes
}

func (deadlineBudgetTimeoutError) Error() string   { return "write deadline exceeded" }
func (deadlineBudgetTimeoutError) Timeout() bool   { return true }
func (deadlineBudgetTimeoutError) Temporary() bool { return true }

func (c *responseCheckConn) Write(data []byte) (int, error) {
	c.responseClaimedFocus = c.client.routeInput([]byte("\x1b[?62;4c")).claimsFocus
	return len(data), nil
}

func (discardConn) Close() error {
	return nil
}

func (discardConn) LocalAddr() net.Addr {
	return testAddr("local")
}

func (discardConn) RemoteAddr() net.Addr {
	return testAddr("remote")
}

func (discardConn) SetDeadline(time.Time) error {
	return nil
}

func (discardConn) SetReadDeadline(time.Time) error {
	return nil
}

func (discardConn) SetWriteDeadline(time.Time) error {
	return nil
}

func waitForPrimaryClient(
	t *testing.T,
	server *muxServer,
	want net.Conn,
	width int,
	height int,
) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		server.mu.Lock()
		primary := server.attachConn
		gotWidth, gotHeight := server.width, server.height
		server.mu.Unlock()
		if primary == want && gotWidth == width && gotHeight == height {
			return
		}
		time.Sleep(time.Millisecond)
	}
	server.mu.Lock()
	primary := server.attachConn
	gotWidth, gotHeight := server.width, server.height
	server.mu.Unlock()
	t.Fatalf(
		"primary client = %v at %dx%d, want %v at %dx%d",
		primary,
		gotWidth,
		gotHeight,
		want,
		width,
		height,
	)
}

func TestReplayOmitsTheAttachOscTailStillWithheldFromLiveOutput(t *testing.T) {
	// stripLocallyAnsweredThemeQueriesLocked withholds a partial OSC from the
	// live stream until its tail arrives, but appendHistoryLocked keeps the
	// whole chunk. A replay built straight from history would hand the client
	// bytes the live stream is about to send again; for the ESC that opens an
	// OSC 8 hyperlink that means the client receives "\x1b\x1b]8;id=..." and
	// prints the introducer as literal text.
	server := &muxServer{}
	window := &muxWindow{id: "@1"}

	chunkA := []byte("Seeded release: \x1b")
	window.appendHistoryLocked(chunkA)
	forwardedA := window.stripLocallyAnsweredThemeQueriesLocked(chunkA, nil)
	if string(forwardedA) != "Seeded release: " {
		t.Fatalf("forwarded first chunk = %q, want the ESC withheld", forwardedA)
	}
	if string(window.attachOscBuffer) != "\x1b" {
		t.Fatalf("attach OSC buffer = %q, want the withheld ESC", window.attachOscBuffer)
	}

	replay := server.replayBytesLocked(window)
	if !bytes.Contains(replay, []byte("Seeded release: ")) {
		t.Fatalf("replay = %q, want it to carry the delivered history", replay)
	}

	withheld := window.attachOscBuffer
	window.attachOscBuffer = nil
	untrimmed := server.replayBytesLocked(window)
	window.attachOscBuffer = withheld
	if len(untrimmed)-len(replay) != len(withheld) {
		t.Fatalf("replay = %q (%d bytes), untrimmed = %d bytes; want %d fewer",
			replay, len(replay), len(untrimmed), len(withheld))
	}
	// The buffer is window-global while replays are per client, so it must
	// survive: the live stream still owes those bytes to every attached client.
	if string(window.attachOscBuffer) != "\x1b" {
		t.Fatalf("attach OSC buffer = %q, want it kept for the live stream",
			window.attachOscBuffer)
	}

	chunkB := []byte("]8;id=md-7nao1v;https://example.com/x\x1b\\label\x1b]8;;\x1b\\")
	window.appendHistoryLocked(chunkB)
	forwardedB := window.stripLocallyAnsweredThemeQueriesLocked(chunkB, nil)
	if !bytes.HasPrefix(forwardedB, []byte("\x1b]8;")) {
		t.Fatalf("forwarded second chunk = %q, want it to lead with the ESC", forwardedB)
	}
	if got := string(replay) + string(forwardedB); strings.Contains(
		got,
		"\x1b\x1b]8;",
	) {
		t.Fatalf("replay+live stream = %q, want no duplicated ESC", got)
	}
}

func TestReplayKeepsWithheldTailWhenHistoryIsTrimmedAway(t *testing.T) {
	window := &muxWindow{attachOscBuffer: []byte("\x1b")}

	if got := window.withheldAttachOscSuffixTrimmedLocked(nil); len(got) != 0 {
		t.Fatalf("trimmed replay = %q, want it left empty", got)
	}
	if string(window.attachOscBuffer) != "\x1b" {
		t.Fatalf("attach OSC buffer = %q, want it kept when the replay omits it",
			window.attachOscBuffer)
	}
}

func TestWithheldAttachOscSuffixTrimmedRequiresSuffixMatch(t *testing.T) {
	window := &muxWindow{attachOscBuffer: []byte("\x1b]11;?")}

	// A snapshot taken before the partial arrived has nothing to trim.
	if got := window.withheldAttachOscSuffixTrimmedLocked(
		[]byte("earlier frame"),
	); string(got) != "earlier frame" {
		t.Fatalf("trimmed replay = %q, want it unchanged", got)
	}

	if got := window.withheldAttachOscSuffixTrimmedLocked(
		[]byte("earlier frame\x1b]11;?"),
	); string(got) != "earlier frame" {
		t.Fatalf("trimmed replay = %q, want the withheld tail removed", got)
	}
	if string(window.attachOscBuffer) != "\x1b]11;?" {
		t.Fatalf("attach OSC buffer = %q, want it left intact", window.attachOscBuffer)
	}
}

func TestCommandNameForProcessGroupUsesCachedProcessTable(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ps"), []byte("#!/bin/sh\nprintf '42 1 42 zsh zsh\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	cache := &commandProcessTableCache
	cache.mu.Lock()
	previous, loaded := cache.processes, cache.loadedAt
	now := time.Now()
	cache.processes = map[int]processInfo{42: {comm: "node", args: "node /tmp/copilot"}}
	cache.loadedAt = now
	cache.mu.Unlock()
	defer func() {
		cache.mu.Lock()
		cache.processes, cache.loadedAt = previous, loaded
		cache.mu.Unlock()
	}()
	if got := commandNameForProcessGroup(42); got != "copilot" {
		t.Fatalf("cached command = %q", got)
	}
	if got := commandNameForProcessGroup(-1); got != "" {
		t.Fatalf("invalid pid = %q", got)
	}
	if got := commandNameForProcessGroup(99999999); got != "" {
		t.Fatalf("missing pid = %q", got)
	}
	if got := cachedProcessTable(now.Add(499 * time.Millisecond))[42].comm; got != "node" {
		t.Fatalf("cache refreshed early: %q", got)
	}
	table := cachedProcessTable(now.Add(500 * time.Millisecond))
	if info, ok := table[42]; !ok || info.comm != "zsh" {
		t.Fatalf("cache did not refresh at 500 ms: %+v", info)
	}
	if got, want := commandNameForProcessGroup(42), commandNameFromProcessFields(table[42].comm, table[42].args); got != want {
		t.Fatalf("refreshed command = %q, want %q", got, want)
	}
}

func TestFailedProcessTableRefreshIsCached(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	cache := &commandProcessTableCache
	cache.mu.Lock()
	previous, loaded := cache.processes, cache.loadedAt
	cache.processes, cache.loadedAt = nil, time.Time{}
	cache.mu.Unlock()
	t.Cleanup(func() {
		cache.mu.Lock()
		cache.processes, cache.loadedAt = previous, loaded
		cache.mu.Unlock()
	})
	if got := cachedProcessTable(time.Now()); got != nil {
		t.Fatalf("missing ps returned process table: %v", got)
	}
	cache.mu.Lock()
	failedAt := cache.loadedAt
	cache.mu.Unlock()
	if err := os.WriteFile(filepath.Join(dir, "ps"), []byte("#!/bin/sh\nprintf '42 1 42 zsh zsh\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := cachedProcessTable(failedAt.Add(499 * time.Millisecond)); got != nil {
		t.Fatalf("failed cache refreshed early: %v", got)
	}
	if got := cachedProcessTable(failedAt.Add(500 * time.Millisecond))[42].comm; got != "zsh" {
		t.Fatalf("failed cache did not expire: %q", got)
	}
}

func TestMetadataDiscoveryReleasesServerLockAndRejectsChangedProcess(t *testing.T) {
	window := &muxWindow{id: "@1", foregroundPid: 42, foregroundCommand: "zsh"}
	_, server := newThemeQueryTestServer(t, window)
	foregroundProcessGroupForWindow = func(w *muxWindow) int { return w.foregroundPid }
	t.Setenv("HOME", t.TempDir())
	cache := &commandProcessTableCache
	cache.mu.Lock()
	previous, loaded := cache.processes, cache.loadedAt
	cache.processes = map[int]processInfo{42: {comm: "cursor-agent", args: "cursor-agent"}}
	cache.loadedAt = time.Now()
	cache.mu.Unlock()
	originalStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processStartedAtForMetadata = originalStart
		cache.mu.Lock()
		cache.processes, cache.loadedAt = previous, loaded
		cache.mu.Unlock()
	})
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	processStartedAtForMetadata = func(int) time.Time {
		close(entered)
		<-release
		return time.Now()
	}
	go func() {
		server.handleWindowOutput(window.id, []byte("output"))
		close(done)
	}()
	t.Cleanup(func() { close(release); <-done })
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("metadata discovery did not start")
	}
	changed := make(chan struct{})
	go func() {
		server.mu.Lock()
		window.foregroundPid = 43
		server.mu.Unlock()
		close(changed)
	}()
	select {
	case <-changed:
	case <-time.After(time.Second):
		t.Fatal("metadata discovery held server mutex")
	}
	release <- struct{}{}
	<-done
	if window.foregroundCommand != "zsh" || window.agentSessionID != "" {
		t.Fatalf("stale metadata committed: command=%q session=%q", window.foregroundCommand, window.agentSessionID)
	}
	if string(window.history) != "output" {
		t.Fatalf("output after discovery = %q", window.history)
	}
}

func TestUnansweredTerminalQueriesCloseDesynchronizedAttach(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(fmt.Sprintf("active=%v", active), func(t *testing.T) {
			conn := &recordingConn{}
			client := newAttachClient(conn, controlMessage{})
			t.Cleanup(client.close)
			query := []byte("\x1b[c")
			for i := 0; i < terminalResponseMaxOutstanding; i++ {
				completion, queued := client.enqueueTerminalQuery(query, true, "@1", 1)
				if !queued || !client.waitForWrite(completion) {
					t.Fatalf("query %d was rejected before the limit", i)
				}
				if active && i == 0 {
					enterStreamingTerminalResponseContinuation(t, client)
				}
			}
			completion, _ := client.enqueueTerminalQuery(query, true, "@2", 1)
			client.waitForWrite(completion)
			select {
			case <-client.done:
			case <-time.After(time.Second):
				t.Fatal("unanswered queries did not close the attach")
			}
			client.activityMu.Lock()
			outstanding := len(client.terminalResponseWindows)
			if client.terminalResponseActiveWindow != "" {
				outstanding++
			}
			client.activityMu.Unlock()
			if outstanding != terminalResponseMaxOutstanding {
				t.Fatalf("outstanding = %d, want %d", outstanding, terminalResponseMaxOutstanding)
			}
		})
	}
}

func TestRunShellCommandCancellationBoundsInheritedPipes(t *testing.T) {
	const helperEnv = "MONKEYMUX_TEST_ESCAPED_OUTPUT_PID"
	if pidPath := os.Getenv(helperEnv); pidPath != "" {
		child := exec.Command("sleep", "30")
		child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		child.Stdout = os.Stdout
		child.Stderr = os.Stderr
		if err := child.Start(); err != nil {
			os.Exit(2)
		}
		if err := os.WriteFile(pidPath+".pending", []byte(strconv.Itoa(child.Process.Pid)), 0o600); err != nil {
			_ = child.Process.Kill()
			os.Exit(3)
		}
		if err := os.Rename(pidPath+".pending", pidPath); err != nil {
			_ = child.Process.Kill()
			os.Exit(3)
		}
		_ = child.Wait()
		os.Exit(0)
	}
	pidPath := filepath.Join(t.TempDir(), "descendant.pid")
	t.Setenv(helperEnv, pidPath)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		_, _, err := newMuxServer("test").runShellCommandContext(ctx,
			shellQuote(executable)+" -test.run=^TestRunShellCommandCancellationBoundsInheritedPipes$")
		finished <- err
	}()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if data, err := os.ReadFile(pidPath); err == nil {
			pid, err := strconv.Atoi(string(data))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("escaped descendant did not start")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, errRunCommandCanceled) {
			t.Fatalf("cancel error = %v, want canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation waited for escaped descendant's output pipe")
	}
}

func TestThemeHintDeliversModeReportAndFocusPair(t *testing.T) {
	const mode = "\x1b[?997;2n"
	const background = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	for _, test := range []struct{ name, modes, want string }{
		{"DEC 2031", "\x1b[?2031h", mode},
		{"focus pair", "\x1b[?1004h", background + "\x1b[O\x1b[I"},
		{"DEC 2031 and focus pair", "\x1b[?2031h\x1b[?1004h", mode + background + "\x1b[O\x1b[I"},
	} {
		t.Run(test.name, func(t *testing.T) {
			pty := &recordingPty{}
			window := &muxWindow{id: "@1", foregroundCommand: "codex", pty: pty}
			window.observeTerminalModesLocked([]byte(test.modes))
			server := newMuxServer("test")
			server.windows = []*muxWindow{window}
			server.activeID = window.id
			t.Cleanup(server.close)
			if !server.sendThemeHint(mode + background) {
				t.Fatal("theme hint was not sent")
			}
			waitForRecordedOutput(t, &pty.recordingConn, test.want)
		})
	}
}

func TestRequestServerShutdownWaitsForMatchingAcknowledgement(t *testing.T) {
	for _, acknowledge := range []bool{true, false} {
		t.Run(fmt.Sprintf("acknowledge=%v", acknowledge), func(t *testing.T) {
			const session = "shutdown-ack"
			conn, peer := net.Pipe()
			defer conn.Close()
			defer peer.Close()
			done := make(chan struct{})
			started := time.Now()
			go func() {
				requestServerShutdownOnConnection(conn, session)
				close(done)
			}()
			_ = peer.SetDeadline(time.Now().Add(socketTimeout + time.Second))
			enc, dec := json.NewEncoder(peer), json.NewDecoder(peer)
			var request controlMessage
			if err := dec.Decode(&request); err != nil || request.Role != "control" {
				t.Fatalf("control handshake: %+v, %v", request, err)
			}
			if err := enc.Encode(controlResponse{Type: "hello"}); err != nil {
				t.Fatal(err)
			}
			if err := dec.Decode(&request); err != nil || request.Type != "shutdown" || request.ID == "" {
				t.Fatalf("shutdown request: %+v, %v", request, err)
			}
			for _, response := range []controlResponse{
				{Type: "window_list"},
				{Type: "shutdown", ID: "another-request"},
				{Type: "window_list", ID: request.ID},
			} {
				if err := enc.Encode(response); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case <-done:
				t.Fatal("returned before matching shutdown acknowledgement")
			case <-time.After(50 * time.Millisecond):
			}
			if acknowledge {
				if err := enc.Encode(controlResponse{Type: "shutdown", ID: request.ID, Status: "ok"}); err != nil {
					t.Fatal(err)
				}
			}
			wait := time.Second
			if !acknowledge {
				wait += socketTimeout
			}
			select {
			case <-done:
				if !acknowledge && time.Since(started) < socketTimeout {
					t.Fatal("returned before connection deadline without an acknowledgement")
				}
			case <-time.After(wait):
				t.Fatal("shutdown wait did not end")
			}
		})
	}
}
