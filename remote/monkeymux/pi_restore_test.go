package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func resetPiMetadataForTest(t *testing.T) {
	t.Helper()
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }
}

func TestMonkeyMuxAgentLaunchCommandWrapsPiWithCurrentExecutable(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	invocation, ok := shellExecutableCommand(executable)
	if !ok {
		t.Fatalf("current executable is not shell-safe: %q", executable)
	}
	if got, want := monkeyMuxAgentLaunchCommand("pi --session-dir sessions"), invocation+" pi-agent --session-dir sessions"; got != want {
		t.Fatalf("Pi create command = %q, want %q", got, want)
	}
	if got := monkeyMuxAgentLaunchCommand("agy"); got != "agy" {
		t.Fatalf("unsupported command was rewritten: %q", got)
	}
}

func writePiTestSession(t *testing.T, path string, id string, cwd string, modified time.Time) {
	t.Helper()
	writePiTestSessionTimes(t, path, id, cwd, modified, modified)
}

func writePiTestSessionTimes(
	t *testing.T,
	path string,
	id string,
	cwd string,
	created time.Time,
	modified time.Time,
) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header := fmt.Sprintf(
		"{\"type\":\"session\",\"id\":%q,\"timestamp\":%q,\"cwd\":%q}\n",
		id,
		created.UTC().Format(time.RFC3339Nano),
		cwd,
	)
	if err := os.WriteFile(path, []byte(header), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func appendPiTestSessionName(t *testing.T, path string, name string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, writeErr := fmt.Fprintf(
		file,
		"{\"type\":\"session_info\",\"name\":%q}\n",
		name,
	)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		t.Fatal(errors.Join(writeErr, closeErr))
	}
}

func writePiTestRelocatedSession(
	t *testing.T,
	path string,
	id string,
	cwd string,
	parent string,
	created time.Time,
	modified time.Time,
) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header := fmt.Sprintf(
		"{\"type\":\"session\",\"id\":%q,\"timestamp\":%q,\"cwd\":%q,\"parentSession\":%q}\n",
		id,
		created.UTC().Format(time.RFC3339Nano),
		cwd,
		parent,
	)
	if err := os.WriteFile(path, []byte(header), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

// Pi's worktree flow relocates a running session into a bucket named for the
// new worktree cwd and deletes the original file, leaving only the header's
// parentSession pointing at the pane's working directory. The pane must still
// resume that session after a helper upgrade rather than launching a fresh Pi.
func TestDiscoverPiSessionsResumesSessionRelocatedToWorktree(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	started := time.Now().Add(-time.Hour).UTC()
	originCreated := started.Add(500 * time.Millisecond)
	// The deleted origin file only survives as the parentSession path.
	deletedOrigin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		originCreated.Format("2006-01-02T15-04-05-000Z")+"_origin-session.jsonl",
	)
	relocatedPath := filepath.Join(
		root,
		piEncodedSessionDirName(worktree),
		"relocated.jsonl",
	)
	writePiTestRelocatedSession(
		t,
		relocatedPath,
		"relocated-session",
		worktree,
		deletedOrigin,
		started.Add(30*time.Minute),
		started.Add(45*time.Minute),
	)
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "relocated-session" || got.sessionPath != relocatedPath {
		t.Fatalf("relocated Pi session = %#v, want exact path %q", got, relocatedPath)
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand:   "pi",
		AgentSessionID:   got.sessionID,
		AgentSessionDir:  got.sessionDir,
		AgentSessionPath: got.sessionPath,
	}, false)
	want := piResumeCommandWithFreshFallback(
		piResumeCommand(got.sessionID, got.sessionDir, got.sessionPath),
		piLaunchCommand(got.sessionDir),
	)
	if options.command != want {
		t.Fatalf("relocated restore command = %q, want %q", options.command, want)
	}
}

func TestDiscoverPiSessionsUsesPublishedTitleWhenSessionCreationIsDelayed(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-time.Hour).UTC()
	firstPath := filepath.Join(root, "project", "first.jsonl")
	secondPath := filepath.Join(root, "project", "second.jsonl")
	writePiTestSession(t, firstPath, "first-session", project, started.Add(20*time.Minute))
	appendPiTestSessionName(t, firstPath, "first restore")
	writePiTestSession(t, secondPath, "second-session", project, started.Add(30*time.Minute))
	appendPiTestSessionName(t, secondPath, "second restore")
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
		201: {pid: 201, ppid: 101, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{
		{
			PanePid: 100, CurrentCommand: "pi", AgentTool: "pi",
			PaneTitle: "π - first restore - project", Cwd: project,
		},
		{
			PanePid: 101, CurrentCommand: "pi", AgentTool: "pi",
			PaneTitle: "Pi - second restore - project", Cwd: project,
		},
	}}

	got := discoverPiSessions(
		restore,
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)
	if got[0].sessionID != "first-session" || got[0].sessionPath != firstPath ||
		got[1].sessionID != "second-session" || got[1].sessionPath != secondPath {
		t.Fatalf("title-correlated Pi sessions = %#v, want both exact paths", got)
	}
}

func TestDiscoverPiSessionsMatchesTitleWithMoreThan32Candidates(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-time.Hour).UTC()
	targetPath := ""
	for i := 0; i < 33; i++ {
		path := filepath.Join(root, "project", fmt.Sprintf("session-%02d.jsonl", i))
		writePiTestSession(t, path, fmt.Sprintf("session-%02d", i), project, started.Add(20*time.Minute))
		appendPiTestSessionName(t, path, fmt.Sprintf("restore %02d", i))
		if i == 32 {
			targetPath = path
		}
	}
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi",
		PaneTitle: "π - restore 32 - project", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "session-32" || got.sessionPath != targetPath {
		t.Fatalf("33-candidate title match = %#v, want exact path %q", got, targetPath)
	}
}

func TestPiSessionOriginResolvesChainAndFileNameTimestamp(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	created := time.Date(2026, 8, 15, 6, 56, 17, 353*int(time.Millisecond), time.UTC)
	origin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		"2026-08-15T06-56-17-353Z_origin-session.jsonl",
	)
	middle := filepath.Join(root, piEncodedSessionDirName(worktree), "middle.jsonl")
	newest := filepath.Join(root, piEncodedSessionDirName(worktree), "newest.jsonl")
	writePiTestRelocatedSession(t, middle, "middle-session", worktree, origin, created.Add(time.Minute), created.Add(2*time.Minute))
	writePiTestRelocatedSession(t, newest, "newest-session", worktree, middle, created.Add(3*time.Minute), created.Add(4*time.Minute))

	entries := readPiSessionEntries(root)
	if len(entries) != 2 {
		t.Fatalf("entries = %d, want 2", len(entries))
	}
	for _, entry := range entries {
		if entry.originDir != piEncodedSessionDirName(project) {
			t.Fatalf("%s origin dir = %q, want project bucket", entry.sessionID, entry.originDir)
		}
		if !entry.originCreatedAt.Equal(created) {
			t.Fatalf("%s origin createdAt = %s, want %s", entry.sessionID, entry.originCreatedAt, created)
		}
	}
}

// A relocated session that is later rotated (/new) leaves the intermediate
// file on disk, so the pane's chain has several links that all resolve to the
// same origin. The pane must resume the leaf it is actually on.
func TestDiscoverPiSessionsResumesLeafOfRelocatedThenRotatedChain(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	started := time.Now().Add(-time.Hour).UTC()
	deletedOrigin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		started.Add(500*time.Millisecond).Format("2006-01-02T15-04-05-000Z")+"_origin-session.jsonl",
	)
	middle := filepath.Join(root, piEncodedSessionDirName(worktree), "middle.jsonl")
	newest := filepath.Join(root, piEncodedSessionDirName(worktree), "newest.jsonl")
	writePiTestRelocatedSession(t, middle, "middle-session", worktree, deletedOrigin, started.Add(20*time.Minute), started.Add(25*time.Minute))
	writePiTestRelocatedSession(t, newest, "newest-session", worktree, middle, started.Add(30*time.Minute), started.Add(45*time.Minute))

	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "newest-session" {
		t.Fatalf("multi-hop Pi chain = %#v, want newest-session leaf", got)
	}
}

// Forks share a parent without superseding each other, so a branched history
// has no single leaf and must decline rather than guess a conversation.
func TestDiscoverPiSessionsDeclinesForkedChainBranches(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	started := time.Now().Add(-time.Hour).UTC()
	deletedOrigin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		started.Add(500*time.Millisecond).Format("2006-01-02T15-04-05-000Z")+"_origin-session.jsonl",
	)
	bucket := piEncodedSessionDirName(worktree)
	writePiTestRelocatedSession(t, filepath.Join(root, bucket, "branch-a.jsonl"), "branch-a", worktree, deletedOrigin, started.Add(20*time.Minute), started.Add(25*time.Minute))
	writePiTestRelocatedSession(t, filepath.Join(root, bucket, "branch-b.jsonl"), "branch-b", worktree, deletedOrigin, started.Add(30*time.Minute), started.Add(35*time.Minute))

	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("forked Pi chain = %#v, want fresh launch", got)
	}
}

func TestPiEncodedSessionDirNameMatchesPiLayout(t *testing.T) {
	if got, want := piEncodedSessionDirName("/Users/demo/Code/MonkeySSH"), "--Users-demo-Code-MonkeySSH--"; got != want {
		t.Fatalf("piEncodedSessionDirName = %q, want %q", got, want)
	}
	if got := piEncodedSessionDirName(""); got != "" {
		t.Fatalf("empty cwd encoding = %q, want empty", got)
	}
}

func TestPiAgentToolMappingAndResumeCommand(t *testing.T) {
	for _, name := range []string{"pi", "pi-agent", "/Users/demo/.local/bin/pi"} {
		if got := agentToolFromCommandName(name); got != "pi" {
			t.Fatalf("agentToolFromCommandName(%q) = %q, want pi", name, got)
		}
	}
	for _, title := range []string{"Pi", "Pi - restore work - project", "π", "π - restore work - project"} {
		if got := agentToolFromTerminalTitle(title); got != "pi" {
			t.Fatalf("agentToolFromTerminalTitle(%q) = %q, want pi", title, got)
		}
	}
	for _, title := range []string{"Pi notes", "Pi calculator", "Pi · restore work"} {
		if got := agentToolFromTerminalTitle(title); got != "" {
			t.Fatalf("agentToolFromTerminalTitle(%q) = %q, want no classification", title, got)
		}
	}
	shellState := restoreWindowState{
		CurrentCommand: "zsh",
		PaneTitle:      "Pi - notes",
		AgentTool:      "pi",
	}
	if got := agentToolForRestore(shellState); got != "" {
		t.Fatalf("shell window with Pi-like title classified as %q", got)
	}
	if got := createWindowOptionsForRestore(shellState, false).command; got != "" {
		t.Fatalf("shell window with Pi-like title restore command = %q", got)
	}
	if got := agentSessionIDFromArgs("pi", "pi --session 'session-id'"); got != "session-id" {
		t.Fatalf("agentSessionIDFromArgs = %q, want session-id", got)
	}

	options := createWindowOptionsForRestore(restoreWindowState{
		Name:           "Pi",
		CurrentCommand: "pi",
		AgentSessionID: "session-id",
	}, true)
	want := piResumeCommandWithFreshFallback(
		piResumeCommand("session-id", "", ""),
		piLaunchCommand(""),
	)
	if options.agentTool != "pi" || options.command != want {
		t.Fatalf("Pi restore options = tool:%q command:%q, want tool pi command %q", options.agentTool, options.command, want)
	}
}

func TestNewWindowAgentToolDoesNotConfirmNameOnlyMatch(t *testing.T) {
	if tool, confirmed := newWindowAgentTool(createWindowOptions{}, "Pi"); tool != "pi" || confirmed {
		t.Fatalf("name-only classification = %q, %v; want pi, false", tool, confirmed)
	}
	if tool, confirmed := newWindowAgentTool(
		createWindowOptions{agentTool: "pi"},
		"shell",
	); tool != "pi" || !confirmed {
		t.Fatalf("explicit classification = %q, %v; want pi, true", tool, confirmed)
	}
	if tool, confirmed := newWindowAgentTool(
		createWindowOptions{command: "pi"},
		"shell",
	); tool != "pi" || !confirmed {
		t.Fatalf("command classification = %q, %v; want pi, true", tool, confirmed)
	}
}

func TestPiResumeCommandRejectsShellMetacharacters(t *testing.T) {
	for _, id := range []string{"session's-id", "session&id", "$(touch-pwned)", "session id"} {
		if got := piResumeCommand(id, "", ""); got != "" {
			t.Fatalf("piResumeCommand(%q) = %q, want refusal", id, got)
		}
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand: "pi",
		AgentSessionID: "session&id",
	}, false)
	if options.command != piLaunchCommand("") {
		t.Fatalf("unsafe session command = %q, want managed fresh Pi", options.command)
	}
}

func TestEnrichRestoreWithAgentSessionIDsKeepsFreshPiWindowFresh(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	now := time.Now()
	primaryPath := filepath.Join(root, "project", "primary.jsonl")
	writePiTestSession(t, primaryPath, "primary-session", project, now)
	writePiTestSession(t, filepath.Join(root, "project", "primary", "child", "run-0", "session.jsonl"), "child-session", project, now.Add(time.Minute))
	writePiTestSession(t, filepath.Join(root, "other", "other.jsonl"), "other-session", filepath.Join(root, "other"), now.Add(2*time.Minute))

	restore := &serverRestore{Windows: []restoreWindowState{{
		Name: "Pi", Cwd: project, CurrentCommand: "pi", AgentTool: "pi",
	}}}
	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "" {
		t.Fatalf("fresh Pi window inherited session %q", got)
	}
	if restore.Windows[0].AgentSessionDir != "" || restore.Windows[0].AgentSessionPath != "" {
		t.Fatalf("fresh Pi window kept restore metadata: %#v", restore.Windows[0])
	}
}

func TestDiscoverPiSessionsUsesConfirmedWindowActivityWithoutProcessTable(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	activity := time.Now().UTC().Truncate(time.Second)
	path := filepath.Join(root, "project", "active.jsonl")
	writePiTestSession(t, path, "active-session", project, activity)
	restore := &serverRestore{Windows: []restoreWindowState{{
		Name:                     "Pi",
		Cwd:                      project,
		CurrentCommand:           "pi",
		AgentTool:                "pi",
		AgentToolConfirmed:       true,
		LastActivityEpochSeconds: activity.Unix(),
	}}}

	got := discoverPiSessions(restore, nil, nil)
	session, ok := got[0]
	if !ok {
		t.Fatal("confirmed Pi window activity did not restore a session")
	}
	if session.sessionID != "active-session" || session.sessionPath != path {
		t.Fatalf("activity-correlated Pi session = %#v", session)
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		AgentTool:        "pi",
		AgentSessionID:   session.sessionID,
		AgentSessionDir:  session.sessionDir,
		AgentSessionPath: session.sessionPath,
	}, false)
	want := piResumeCommandWithFreshFallback(
		piResumeCommand(session.sessionID, session.sessionDir, session.sessionPath),
		piLaunchCommand(session.sessionDir),
	)
	if options.command != want {
		t.Fatalf("restored Pi command = %q, want %q", options.command, want)
	}
}

func TestDiscoverPiSessionsUsesConfirmedPublishedTitleWithoutProcessTable(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	written := time.Now().Add(-time.Hour).UTC()
	path := filepath.Join(root, "project", "named.jsonl")
	writePiTestSession(t, path, "named-session", project, written)
	appendPiTestSessionName(t, path, "long restore")
	restore := &serverRestore{Windows: []restoreWindowState{{
		Name:                     "Pi",
		Cwd:                      project,
		CurrentCommand:           "pi",
		AgentTool:                "pi",
		AgentToolConfirmed:       true,
		PaneTitle:                "π - long restore - project",
		LastActivityEpochSeconds: time.Now().Unix(),
	}}}

	got := discoverPiSessions(restore, nil, nil)
	if got[0].sessionID != "named-session" || got[0].sessionPath != path {
		t.Fatalf("title-correlated processless Pi session = %#v", got)
	}
}

func TestDiscoverPiSessionsUsesLatestForSingleConfirmedWindowWithoutProcessTable(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	now := time.Now().UTC().Truncate(time.Second)
	writePiTestSession(
		t,
		filepath.Join(root, "project", "older.jsonl"),
		"older-session",
		project,
		now.Add(-2*time.Hour),
	)
	latestPath := filepath.Join(root, "project", "current.jsonl")
	writePiTestSession(t, latestPath, "current-session", project, now.Add(-time.Hour))
	restore := &serverRestore{Windows: []restoreWindowState{{
		Name:                     "Pi",
		Cwd:                      project,
		CurrentCommand:           "pi",
		AgentTool:                "pi",
		AgentToolConfirmed:       true,
		LastActivityEpochSeconds: now.Unix(),
	}}}

	got := discoverPiSessions(restore, nil, nil)
	if got[0].sessionID != "current-session" || got[0].sessionPath != latestPath {
		t.Fatalf("latest confirmed Pi session = %#v", got)
	}
}

func TestDiscoverPiSessionsDeclinesAmbiguousCwdFallback(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	now := time.Now()
	writePiTestSession(t, filepath.Join(root, "project", "one.jsonl"), "session-one", project, now)
	writePiTestSession(t, filepath.Join(root, "project", "two.jsonl"), "session-two", project, now.Add(time.Second))

	for _, windows := range [][]restoreWindowState{
		{{CurrentCommand: "pi", AgentTool: "pi", Cwd: project}},
		{
			{CurrentCommand: "pi", AgentTool: "pi", Cwd: project},
			{CurrentCommand: "pi", AgentTool: "pi", Cwd: project},
		},
	} {
		restore := &serverRestore{Windows: windows}
		if got := discoverPiSessions(restore, nil, nil); len(got) != 0 {
			t.Fatalf("ambiguous Pi fallback = %#v, want none", got)
		}
	}
}

func TestDiscoverPiSessionsUsesProcessStartWhenPiClosesSessionFile(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	processStarted := time.Now().Add(-time.Minute).UTC()
	writePiTestSession(
		t,
		filepath.Join(root, "project", "old.jsonl"),
		"old-session",
		project,
		processStarted.Add(-time.Hour),
	)
	writePiTestSession(
		t,
		filepath.Join(root, "project", "current.jsonl"),
		"current-session",
		project,
		processStarted.Add(500*time.Millisecond),
	)
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return processStarted
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {
			pid:  200,
			ppid: 100,
			comm: "node",
			args: "node /usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
		},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "node", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "current-session" || got.sessionDir != filepath.Join(root, "project") {
		t.Fatalf("process-correlated Pi session = %#v, want current-session", got)
	}
}

func TestPiSessionsCreatedForProcessStartDeclinesAmbiguousMatches(t *testing.T) {
	started := time.Now().UTC()
	entries := []piSessionEntry{
		{sessionID: "one", createdAt: started, modTime: started},
		{sessionID: "two", createdAt: started.Add(time.Second), modTime: started.Add(time.Second)},
	}
	if got := piSessionsCreatedForProcessStart(entries, started); len(got) != 2 {
		t.Fatalf("created-at matches = %#v, want both ambiguous sessions", got)
	}
}

func TestDiscoverPiSessionsDeclinesInitialSessionAfterChange(t *testing.T) {
	for _, test := range []struct {
		name            string
		initialModified time.Duration
		otherFilename   string
		otherID         string
		otherCreated    time.Duration
		otherModified   time.Duration
		failure         string
	}{
		{"Rotation", 10 * time.Minute, "rotated.jsonl", "rotated-session", 20 * time.Minute, 30 * time.Minute, "rotated Pi session match = %#v, want fresh fallback"},
		{"Resume", 5 * time.Minute, "resumed.jsonl", "resumed-session", -time.Hour, 30 * time.Minute, "resumed Pi session match = %#v, want fresh fallback rather than initial session"},
	} {
		t.Run(test.name, func(t *testing.T) {
			resetPiMetadataForTest(t)
			root := t.TempDir()
			t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
			project := filepath.Join(root, "project")
			started := time.Now().Add(-time.Hour).UTC()
			writePiTestSessionTimes(t, filepath.Join(root, "project", "initial.jsonl"),
				"initial-session", project, started.Add(500*time.Millisecond), started.Add(test.initialModified))
			writePiTestSessionTimes(t, filepath.Join(root, "project", test.otherFilename),
				test.otherID, project, started.Add(test.otherCreated), started.Add(test.otherModified))
			processStartedAtForMetadata = func(int) time.Time { return started }
			processes := map[int]processInfo{
				100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
				200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
			}
			restore := &serverRestore{Windows: []restoreWindowState{{
				PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
			}}}
			if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
				t.Fatalf(test.failure, got)
			}
		})
	}
}

func TestDiscoverPiSessionsPrefersExactExtensionIdentity(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	t.Cleanup(func() { processOpenFilePathsForMetadata = originalOpenFiles })
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	launchDirectory := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktrees", "feature")
	path := filepath.Join(root, "sessions", "resumed.jsonl")
	writePiTestSessionTimes(
		t,
		path,
		"resumed-session",
		worktree,
		time.Now().Add(-3*time.Hour),
		time.Now().Add(-2*time.Hour),
	)
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid:                   100,
		CurrentCommand:            "pi",
		AgentTool:                 "pi",
		AgentToolConfirmed:        true,
		Cwd:                       launchDirectory,
		PaneTitle:                 "π - unrelated-title",
		AgentSessionID:            "resumed-session",
		AgentSessionDir:           filepath.Dir(path),
		AgentSessionPath:          path,
		AgentSessionIdentityExact: true,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "resumed-session" || got.sessionPath != path {
		t.Fatalf("exact Pi extension identity = %#v, want exact resumed path", got)
	}
}

func TestDiscoverPiSessionsRestoresInteractiveResumeIntoWorktree(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	launchDirectory := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktrees", "feature")
	otherWorktree := filepath.Join(root, "archive", "feature")
	started := time.Now().Add(-time.Hour).UTC()
	activity := started.Add(30 * time.Minute)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "archive", "old.jsonl"),
		"old-session",
		otherWorktree,
		started.Add(-2*time.Hour),
		started.Add(10*time.Minute),
	)
	resumedPath := filepath.Join(root, "worktree", "resumed.jsonl")
	writePiTestSessionTimes(
		t,
		resumedPath,
		"resumed-session",
		worktree,
		started.Add(-2*time.Hour),
		activity,
	)
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	// Pi was launched in launchDirectory and changed sessions through its
	// interactive picker, so neither argv nor the pane cwd names the worktree.
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid:                  100,
		CurrentCommand:           "pi",
		AgentTool:                "pi",
		Cwd:                      launchDirectory,
		PaneTitle:                "π - feature",
		LastActivityEpochSeconds: activity.Unix(),
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "resumed-session" || got.sessionPath != resumedPath {
		t.Fatalf("cross-worktree interactive resume = %#v, want exact resumed path", got)
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		AgentTool:        "pi",
		AgentSessionID:   got.sessionID,
		AgentSessionDir:  got.sessionDir,
		AgentSessionPath: got.sessionPath,
	}, false)
	want := piResumeCommandWithFreshFallback(
		piResumeCommand(got.sessionID, got.sessionDir, got.sessionPath),
		piLaunchCommand(got.sessionDir),
	)
	if options.command != want {
		t.Fatalf("cross-worktree restore command = %q, want %q", options.command, want)
	}
}

func TestDiscoverPiSessionsAssignsTwoKnownNodeProcessesMutually(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	firstStart := time.Now().Add(-time.Hour).UTC()
	secondStart := firstStart.Add(time.Minute)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "first.jsonl"),
		"first-session",
		project,
		firstStart.Add(500*time.Millisecond),
		firstStart.Add(10*time.Minute),
	)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "second.jsonl"),
		"second-session",
		project,
		secondStart.Add(500*time.Millisecond),
		secondStart.Add(10*time.Minute),
	)
	processStartedAtForMetadata = func(pid int) time.Time {
		switch pid {
		case 200:
			return firstStart
		case 201:
			return secondStart
		default:
			return time.Time{}
		}
	}
	// Windows Toolhelp exposes node.exe but not its package-path argv. The
	// known Pi pane classification still lets the closest runtime participate.
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "node.exe", args: "node.exe"},
		201: {pid: 201, ppid: 101, comm: "node.exe", args: "node.exe"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{
		{PanePid: 100, CurrentCommand: "cmd.exe", AgentTool: "pi", Cwd: project},
		{PanePid: 101, CurrentCommand: "powershell.exe", AgentTool: "pi", Cwd: project},
	}}

	got := discoverPiSessions(
		restore,
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)
	if got[0].sessionID != "first-session" || got[1].sessionID != "second-session" {
		t.Fatalf("mutual Pi assignments = %#v, want first and second sessions", got)
	}
	for i := range restore.Windows {
		if !restore.Windows[i].AgentToolConfirmed || agentToolForRestore(restore.Windows[i]) != "pi" {
			t.Fatalf("Windows-like Pi pane %d was not process-confirmed: %#v", i, restore.Windows[i])
		}
	}
}

func TestDiscoverPiSessionsDeclinesOverlappingProcessStarts(t *testing.T) {
	started := time.Now().UTC()
	entries := []piSessionEntry{
		{sessionID: "one", createdAt: started.Add(time.Second)},
		{sessionID: "two", createdAt: started.Add(2 * time.Second)},
	}
	if got := piSessionsCreatedForProcessStart(entries, started); len(got) != 2 {
		t.Fatalf("first overlapping process matches = %#v, want ambiguity", got)
	}
	if got := piSessionsCreatedForProcessStart(entries, started.Add(time.Second)); len(got) != 2 {
		t.Fatalf("second overlapping process matches = %#v, want ambiguity", got)
	}
}

func TestPiProcessesByPaneRejectsMinimumDepthTie(t *testing.T) {
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi --session first"},
		201: {pid: 201, ppid: 100, comm: "pi", args: "pi --session second"},
	}
	if got := piProcessesByPane(processes, map[int]struct{}{100: {}}, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("same-depth Pi process tie = %#v, want fail closed", got)
	}
	delete(processes, 201)
	processes[300] = processInfo{pid: 300, ppid: 200, comm: "pi", args: "pi --session nested"}
	if got := piProcessesByPane(processes, map[int]struct{}{100: {}}, map[int]struct{}{100: {}}); got[100].pid != 200 {
		t.Fatalf("Pi process selection = %#v, want shallow pid 200", got)
	}
}

func TestDiscoverPiSessionsUsesLiveOpenFileAndSkipsNestedPiProcess(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	t.Cleanup(func() { processOpenFilePathsForMetadata = originalOpenFiles })
	root := t.TempDir()
	project := filepath.Join(root, "project")
	current := filepath.Join(root, "sessions", "current.jsonl")
	other := filepath.Join(root, "sessions", "other.jsonl")
	child := filepath.Join(root, "sessions", "children", "child.jsonl")
	writePiTestSession(t, current, "current-session", project, time.Now())
	writePiTestSession(t, other, "other-session", project, time.Now().Add(time.Second))
	writePiTestSession(t, child, "child-session", project, time.Now().Add(2*time.Second))
	processOpenFilePathsForMetadata = func(pid int) []string {
		switch pid {
		case 200:
			return []string{current}
		case 300:
			return []string{child}
		default:
			return nil
		}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
		300: {pid: 300, ppid: 200, comm: "pi", args: "pi --session child-session"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "current-session" || got.sessionDir != filepath.Dir(current) || got.sessionPath != current {
		t.Fatalf("live Pi session = %#v, want current open file", got)
	}
}

func TestDiscoverPiSessionsHonorsProcessSessionDir(t *testing.T) {
	resetPiMetadataForTest(t)
	project := t.TempDir()
	custom := filepath.Join(project, ".sessions")
	now := time.Now()
	writePiTestSession(t, filepath.Join(custom, "current.jsonl"), "custom-session", project, now)
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi --session-dir .sessions"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if want := filepath.Join(normalizedWorkingDirectory(project), ".sessions"); got.sessionID != "custom-session" || got.sessionDir != want {
		t.Fatalf("custom-dir Pi session = %#v, want custom session in %q", got, want)
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand:   "pi",
		AgentSessionID:   got.sessionID,
		AgentSessionDir:  got.sessionDir,
		AgentSessionPath: got.sessionPath,
	}, false)
	want := piResumeCommandWithFreshFallback(
		piResumeCommand(got.sessionID, got.sessionDir, got.sessionPath),
		piLaunchCommand(got.sessionDir),
	)
	if options.command != want {
		t.Fatalf("custom-dir restore command = %q, want %q", options.command, want)
	}
}

func TestDiscoverPiSessionsReservesExplicitProcessSession(t *testing.T) {
	project := t.TempDir()
	sessionPath := filepath.Join(project, "sessions", "exact.jsonl")
	writePiTestSession(t, sessionPath, "exact-session", project, time.Now())
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi --session exact-session --session-dir sessions"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}
	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if want := filepath.Join(normalizedWorkingDirectory(project), "sessions"); got.sessionID != "exact-session" || got.sessionDir != want || got.sessionPath != filepath.Join(want, "exact.jsonl") {
		t.Fatalf("explicit Pi session = %#v, want exact-session in %q", got, want)
	}

	entry, ok := piSessionFromProcessArgs("pi --session "+shellQuote(sessionPath), project)
	if !ok || entry.sessionID != "exact-session" || entry.path != sessionPath {
		t.Fatalf("path-based Pi process session = %#v, %v, want exact path", entry, ok)
	}
}

func TestPiSessionRootUsesProjectThenGlobalSettings(t *testing.T) {
	project := t.TempDir()
	agentDir := filepath.Join(t.TempDir(), "agent")
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "")
	t.Setenv("PI_CODING_AGENT_DIR", agentDir)
	if err := os.MkdirAll(filepath.Join(project, ".pi"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	globalDir := filepath.Join(t.TempDir(), "global-sessions")
	if err := os.WriteFile(filepath.Join(agentDir, "settings.json"), []byte(fmt.Sprintf(`{"sessionDir":%q}`, globalDir)), 0o600); err != nil {
		t.Fatal(err)
	}
	projectSettings := filepath.Join(project, ".pi", "settings.json")
	if err := os.WriteFile(projectSettings, []byte(`{"sessionDir":".project-sessions"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := piSessionRootForWorkingDirectory(project), filepath.Join(normalizedWorkingDirectory(project), ".project-sessions"); got != want {
		t.Fatalf("project sessionDir = %q, want %q", got, want)
	}
	if err := os.Remove(projectSettings); err != nil {
		t.Fatal(err)
	}
	if got := piSessionRootForWorkingDirectory(project); got != globalDir {
		t.Fatalf("global sessionDir = %q, want %q", got, globalDir)
	}
}

func TestReadPiSessionEntrySkipsLeadingNonHeaderLines(t *testing.T) {
	project := t.TempDir()
	path := filepath.Join(t.TempDir(), "session.jsonl")
	content := "\nnot-json\n" + fmt.Sprintf("{\"type\":\"session\",\"id\":%q,\"cwd\":%q}\n", "session-id", project)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	entry, ok := readPiSessionEntry(path)
	if !ok || entry.sessionID != "session-id" || entry.cwd != normalizedWorkingDirectory(project) {
		t.Fatalf("Pi session entry = %#v, %v", entry, ok)
	}
}

func TestPiLatestSessionNameUsesLateMetadataAndSkipsOversizedRecords(t *testing.T) {
	project := t.TempDir()
	path := filepath.Join(t.TempDir(), "session.jsonl")
	writePiTestSession(t, path, "session-id", project, time.Now())
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 600; i++ {
		if _, err := fmt.Fprintf(file, "{\"type\":\"message\",\"id\":%q}\n", fmt.Sprintf("%08d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := file.Write([]byte("{\"type\":\"message\",\"image\":\"")); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write(bytes.Repeat([]byte("A"), 2*piSessionMetadataRecordLimitBytes)); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write([]byte("\"}\n{\"type\":\"session_info\",\"name\":\"renamed late\"}\n")); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	entry, ok := readPiSessionEntry(path)
	if !ok || entry.sessionID != "session-id" {
		t.Fatalf("entry after oversized message = %#v, %v", entry, ok)
	}
	if name, found := piLatestSessionName(path); !found || name != "renamed late" {
		t.Fatalf("latest session name = %q, %v, want renamed late", name, found)
	}

	appendPiTestSessionName(t, path, "")
	if name, found := piLatestSessionName(path); !found || name != "" {
		t.Fatalf("cleared session name = %q, %v, want authoritative empty", name, found)
	}
}

func TestPiSessionIdentitySurvivesSecondUpgradeAndRejectsRotation(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	project := filepath.Join(root, "project")
	started := time.Now().UTC()
	firstPath := filepath.Join(root, "first.jsonl")
	secondPath := filepath.Join(root, "second.jsonl")
	writePiTestSessionTimes(t, firstPath, "first-session", project, started.Add(-2*time.Hour), started.Add(-time.Hour))
	writePiTestSessionTimes(t, secondPath, "second-session", project, started.Add(-90*time.Minute), started.Add(-45*time.Minute))

	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id: "@1", index: 0, name: "Pi", cwd: project,
			command: "pi", foregroundCommand: "pi", agentTool: "pi", agentToolConfirmed: true,
			agentSessionID: "first-session", agentSessionDir: root, agentSessionPath: firstPath,
			lastActivity: time.Now(),
		},
		{
			id: "@2", index: 1, name: "Pi", cwd: project,
			command: "pi", foregroundCommand: "pi", agentTool: "pi", agentToolConfirmed: true,
			agentSessionID: "second-session", agentSessionDir: root, agentSessionPath: secondPath,
			lastActivity: time.Now(),
		},
	}
	server.activeID = "@1"
	restore := server.restoreSnapshot()
	if got := restore.Windows[0].AgentSessionPath; got != firstPath {
		t.Fatalf("snapshotted first path = %q, want %q", got, firstPath)
	}
	if options := createWindowOptionsForRestore(restore.Windows[0], false); options.agentSessionPath != firstPath {
		t.Fatalf("restored options path = %q, want %q", options.agentSessionPath, firstPath)
	}
	legacyRestore := restoreFromWindowSnapshots([]windowSnapshot{{
		AgentTool:        "pi",
		AgentSessionID:   "first-session",
		AgentSessionDir:  root,
		AgentSessionPath: firstPath,
	}})
	if got := legacyRestore.Windows[0].AgentSessionPath; got != firstPath {
		t.Fatalf("legacy snapshot path = %q, want %q", got, firstPath)
	}

	restore.Windows[0].PanePid = 100
	restore.Windows[1].PanePid = 101
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "pi.exe", args: "pi.exe"},
		101: {pid: 101, ppid: 1, comm: "pi.exe", args: "pi.exe"},
	}
	processStartedAtForMetadata = func(int) time.Time { return started.Add(-3 * time.Hour) }
	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}, 101: {}})
	if got[0].sessionPath != firstPath || got[1].sessionPath != secondPath {
		t.Fatalf("second-upgrade sessions = %#v, want persisted exact paths", got)
	}

	rotatedPath := filepath.Join(root, "rotated.jsonl")
	writePiTestSessionTimes(t, rotatedPath, "rotated-session", project, started.Add(time.Minute), started.Add(2*time.Minute))
	got = discoverPiSessions(restore, processes, map[int]struct{}{100: {}, 101: {}})
	if len(got) != 0 {
		t.Fatalf("sessions after unowned rotation = %#v, want fresh launch", got)
	}
}

func TestDiscoverPiSessionsRejectsPersistedPathWithoutCurrentProcessWrite(t *testing.T) {
	resetPiMetadataForTest(t)
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().UTC().Truncate(time.Second)
	path := filepath.Join(root, "project", "stale.jsonl")
	writePiTestSessionTimes(t, path, "stale-session", project, started.Add(-2*time.Hour), started.Add(-time.Hour))
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return started
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
		AgentSessionID: "stale-session", AgentSessionDir: filepath.Dir(path), AgentSessionPath: path,
	}}}

	if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("persisted path without current-process write restored: %#v", got)
	}
}

func TestDiscoverPiSessionsUsesWindowActivityForUnnamedSameCwdSessions(t *testing.T) {
	resetPiMetadataForTest(t)

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-2 * time.Hour).UTC().Truncate(time.Second)
	activities := []time.Time{
		started.Add(25 * time.Minute),
		started.Add(50 * time.Minute),
		started.Add(75 * time.Minute),
	}
	paths := make([]string, len(activities))
	for i, activity := range activities {
		paths[i] = filepath.Join(root, "project", fmt.Sprintf("session-%d.jsonl", i))
		// These sessions were selected with /resume after Pi started, so process
		// creation time cannot identify them. Their final writes still coincide
		// with output activity in the owning MonkeyMux window.
		writePiTestSessionTimes(
			t,
			paths[i],
			fmt.Sprintf("session-%d", i),
			project,
			started.Add(-time.Duration(i+1)*time.Hour),
			activity,
		)
	}
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{}
	restore := &serverRestore{Windows: make([]restoreWindowState, len(activities))}
	panePids := map[int]struct{}{}
	for i, activity := range activities {
		panePID := 100 + i
		processPID := 200 + i
		processes[panePID] = processInfo{pid: panePID, ppid: 1, comm: "zsh", args: "zsh"}
		processes[processPID] = processInfo{pid: processPID, ppid: panePID, comm: "pi", args: "pi"}
		panePids[panePID] = struct{}{}
		restore.Windows[i] = restoreWindowState{
			PanePid:                  panePID,
			CurrentCommand:           "pi",
			AgentTool:                "pi",
			Cwd:                      project,
			LastActivityEpochSeconds: activity.Unix(),
		}
	}

	got := discoverPiSessions(restore, processes, panePids)
	if len(got) != len(activities) {
		t.Fatalf("activity-correlated Pi sessions = %#v, want all %d sessions", got, len(activities))
	}
	for i, path := range paths {
		if got[i].sessionPath != path {
			t.Fatalf("window %d session = %#v, want exact path %q", i, got[i], path)
		}
		options := createWindowOptionsForRestore(restoreWindowState{
			CurrentCommand:   "pi",
			AgentSessionID:   got[i].sessionID,
			AgentSessionDir:  got[i].sessionDir,
			AgentSessionPath: got[i].sessionPath,
		}, false)
		want := piResumeCommandWithFreshFallback(
			piResumeCommand(got[i].sessionID, got[i].sessionDir, path),
			piLaunchCommand(got[i].sessionDir),
		)
		if options.command != want {
			t.Fatalf("window %d restore command = %q, want exact-path command %q", i, options.command, want)
		}
	}
}

func TestPiWindowActivityCorrelationRejectsAmbiguity(t *testing.T) {
	activity := time.Now().UTC().Truncate(time.Second)
	restore := &serverRestore{Windows: []restoreWindowState{
		{LastActivityEpochSeconds: activity.Unix()},
		{LastActivityEpochSeconds: activity.Add(time.Second).Unix()},
	}}
	candidates := []piSessionEntry{
		{sessionID: "one", path: "one.jsonl", modTime: activity},
		{sessionID: "two", path: "two.jsonl", modTime: activity.Add(2 * time.Second)},
	}
	got := uniquePiSessionsByWindowActivity(
		restore,
		[]int{0, 1},
		candidates,
		map[int]bool{0: true, 1: true},
	)
	if len(got) != 0 {
		t.Fatalf("overlapping activity matches = %#v, want no assignments", got)
	}
}

func TestDiscoverPiSessionsUsesSingleCurrentCwdFallback(t *testing.T) {
	resetPiMetadataForTest(t)
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-time.Hour).UTC().Truncate(time.Second)
	path := filepath.Join(root, "project", "resumed.jsonl")
	writePiTestSessionTimes(t, path, "resumed-session", project, started.Add(-time.Hour), started.Add(30*time.Minute))
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})
	if got[0].sessionPath != path {
		t.Fatalf("current-process cwd fallback = %#v, want %q", got, path)
	}
}

func TestDiscoverPiSessionsActivityDeclinesLaterUnownedSession(t *testing.T) {
	resetPiMetadataForTest(t)
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-2 * time.Hour).UTC().Truncate(time.Second)
	activity := started.Add(30 * time.Minute)
	writePiTestSessionTimes(t, filepath.Join(root, "project", "abandoned.jsonl"), "abandoned", project, started.Add(-time.Hour), activity)
	writePiTestSessionTimes(t, filepath.Join(root, "project", "later.jsonl"), "later", project, started.Add(-30*time.Minute), activity.Add(time.Minute))
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
		LastActivityEpochSeconds: activity.Unix(),
	}}}

	if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("activity restored superseded session: %#v", got)
	}
}

func TestPiActivityAssignmentsRejectPartialOverlap(t *testing.T) {
	activity := time.Now().UTC().Truncate(time.Second)
	restore := &serverRestore{Windows: []restoreWindowState{
		{LastActivityEpochSeconds: activity.Unix()},
		{LastActivityEpochSeconds: activity.Add(10 * time.Second).Unix()},
	}}
	candidates := []piSessionEntry{
		{sessionID: "a", modTime: activity},
		{sessionID: "b", modTime: activity.Add(20 * time.Second)},
	}
	got := uniquePiSessionsByWindowActivity(restore, []int{0, 1}, candidates, map[int]bool{0: true, 1: true})
	if len(got) != 0 {
		t.Fatalf("partial-overlap activity assignments = %#v, want none", got)
	}
}

func TestDiscoverPiSessionsDoesNotCollapseMultiPaneCwdFallback(t *testing.T) {
	resetPiMetadataForTest(t)
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-2 * time.Hour).UTC().Truncate(time.Second)
	activity := started.Add(time.Hour)
	firstPath := filepath.Join(root, "project", "first.jsonl")
	writePiTestSessionTimes(t, firstPath, "first", project, started.Add(-2*time.Hour), activity)
	writePiTestSessionTimes(t, filepath.Join(root, "project", "second.jsonl"), "second", project, started.Add(-time.Hour), activity.Add(-time.Minute))
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
		201: {pid: 201, ppid: 101, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{
		{PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project, LastActivityEpochSeconds: activity.Unix()},
		{PanePid: 101, CurrentCommand: "pi", AgentTool: "pi", Cwd: project},
	}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}, 101: {}})
	if len(got) != 1 || got[0].sessionPath != firstPath {
		t.Fatalf("collapsed multi-pane fallback = %#v, want only pane 0", got)
	}
}

func TestDiscoverPiSessionsIgnoresUnconfirmedShellPane(t *testing.T) {
	resetPiMetadataForTest(t)
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	path := filepath.Join(root, "project", "named.jsonl")
	now := time.Now()
	writePiTestSession(t, path, "named-session", project, now)
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 201 {
			return now.Add(-time.Minute)
		}
		return time.Time{}
	}
	appendPiTestSessionName(t, path, "work")
	title := "Pi - work - " + filepath.Base(project)
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		201: {pid: 201, ppid: 101, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{
		{PanePid: 100, CurrentCommand: "zsh", AgentTool: "pi", PaneTitle: title, Cwd: project},
		{PanePid: 101, CurrentCommand: "pi", AgentTool: "pi", PaneTitle: title, Cwd: project},
	}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}, 101: {}})
	if _, ok := got[0]; ok || got[1].sessionPath != path {
		t.Fatalf("Pi-like shell consumed session: %#v", got)
	}
}

func TestEnrichRestoreWithWindowActivityUsesStableWindowIdentity(t *testing.T) {
	restore := &serverRestore{Windows: []restoreWindowState{
		{ID: "@2", Index: 0, AgentTool: "pi"},
		{Index: 0, AgentTool: "pi"},
	}}
	if !restoreNeedsWindowActivity(restore) {
		t.Fatal("legacy Pi restore did not request window activity")
	}
	enrichRestoreWithWindowActivity(restore, []windowSnapshot{
		{ID: "@1", Index: 0, LastActivityEpochSeconds: 10},
		{ID: "@2", Index: 1, LastActivityEpochSeconds: 20},
	})
	if got := restore.Windows[0].LastActivityEpochSeconds; got != 20 {
		t.Fatalf("ID-matched activity = %d, want 20", got)
	}
	if got := restore.Windows[1].LastActivityEpochSeconds; got != 10 {
		t.Fatalf("legacy index-matched activity = %d, want 10", got)
	}
	if restoreNeedsWindowActivity(restore) {
		t.Fatal("enriched Pi restore still requests window activity")
	}
}
