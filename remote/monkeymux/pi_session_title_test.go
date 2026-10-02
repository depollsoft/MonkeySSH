package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const piTitleTestHeader = `{"type":"session","version":3,"id":"01a0f9cd-03d9-75cd-9ffa-8b89ede923c4","timestamp":"2026-10-01T23:29:17.785Z","cwd":"/work"}` + "\n"

func appendPiTitleTestRecords(t *testing.T, path string, records ...string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(strings.Join(records, "")); err != nil {
		t.Fatal(err)
	}
}

func TestPiSessionTitleScanPrefersNameOverFirstPrompt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path,
		piTitleTestHeader,
		`{"type":"model_change","provider":"openai"}`+"\n",
		`{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Give me a list\nof image files"},{"type":"image","data":"AAAA"},{"type":"text","text":"in this project"}]}}`+"\n",
		`{"type":"message","message":{"role":"user","content":"a later prompt"}}`+"\n",
	)
	var scan piSessionTitleScan
	if got := scan.title(path); got != "Give me a list of image files in this project" {
		t.Fatalf("first prompt title = %q", got)
	}

	// A record still being written is read once its newline lands.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"Image `)
	if got := scan.title(path); got != "Give me a list of image files in this project" {
		t.Fatalf("partial record changed the title to %q", got)
	}
	appendPiTitleTestRecords(t, path, `audit"}`+"\n")
	if got := scan.title(path); got != "Image audit" {
		t.Fatalf("named title = %q, want Image audit", got)
	}

	// An empty name clears it, as in Pi.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"  "}`+"\n")
	if got := scan.title(path); got != "Give me a list of image files in this project" {
		t.Fatalf("cleared name title = %q", got)
	}

	// A rewritten, shorter file is read again from the start.
	if err := os.WriteFile(path, []byte(piTitleTestHeader+
		`{"type":"message","message":{"role":"user","content":"Fresh start"}}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := scan.title(path); got != "Fresh start" {
		t.Fatalf("rewritten file title = %q, want Fresh start", got)
	}
}

func TestPiSessionTitleScanSummarizesLongPrompts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	prompt := strings.Repeat("é", 100)
	appendPiTitleTestRecords(t, path,
		piTitleTestHeader,
		`{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"not a prompt"}]}}`+"\n",
		`{"type":"message","message":{"role":"user","content":"`+prompt+`"}}`+"\n",
	)
	var scan piSessionTitleScan
	want := strings.Repeat("é", piSessionTitleMaxRunes-3) + "..."
	if got := scan.title(path); got != want {
		t.Fatalf("long prompt title = %q, want %q", got, want)
	}
}

func TestPiSessionTitleScanIgnoresFilesThatAreNotPiSessions(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "other.jsonl")
	appendPiTitleTestRecords(t, path,
		`{"type":"note"}`+"\n",
		`{"type":"session_info","name":"not a Pi session"}`+"\n",
	)
	var scan piSessionTitleScan
	if got := scan.title(path); got != "" {
		t.Fatalf("non-Pi file title = %q, want empty", got)
	}
	if got := scan.title(filepath.Join(directory, "missing.jsonl")); got != "" {
		t.Fatalf("missing file title = %q, want empty", got)
	}
}

func stubPiTitleBridgeStatus(t *testing.T, status func(string) (acpBridgeInfo, error)) {
	t.Helper()
	original := acpBridgeStatusForMetadata
	acpBridgeStatusForMetadata = status
	t.Cleanup(func() { acpBridgeStatusForMetadata = original })
}

func TestNativePiSessionPathFindsTheBridgeSessionFile(t *testing.T) {
	agentDir := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "")
	t.Setenv("PI_CODING_AGENT_DIR", agentDir)
	cwd := filepath.Join(t.TempDir(), "project")
	bucket := filepath.Join(agentDir, "sessions", piEncodedSessionDirName(cwd))
	if err := os.MkdirAll(bucket, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionID := "01a0f9cd-03d9-75cd-9ffa-8b89ede923c4"
	want := filepath.Join(bucket, "2026-10-01T23-29-17-785Z_"+sessionID+".jsonl")
	appendPiTitleTestRecords(t, want, piTitleTestHeader)
	appendPiTitleTestRecords(t, filepath.Join(bucket, "2026-10-01T22-00-00-000Z_other.jsonl"), piTitleTestHeader)
	bridgeID := "0123456789abcdef0123456789abcdef"
	reported := sessionID
	stubPiTitleBridgeStatus(t, func(id string) (acpBridgeInfo, error) {
		if id != bridgeID {
			return acpBridgeInfo{}, errors.New("unknown bridge")
		}
		return acpBridgeInfo{ID: id, SessionID: reported, Cwd: cwd}, nil
	})

	if got := nativePiSessionPath(bridgeID); got != want {
		t.Fatalf("native session path = %q, want %q", got, want)
	}
	if got := nativePiSessionPath("not-a-bridge"); got != "" {
		t.Fatalf("invalid bridge path = %q, want empty", got)
	}
	reported = "../escape"
	if got := nativePiSessionPath(bridgeID); got != "" {
		t.Fatalf("unsafe session id path = %q, want empty", got)
	}
}

func TestNativePiSessionPathSearchesAConfiguredSessionDir(t *testing.T) {
	sessionDir := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", sessionDir)
	cwd := filepath.Join(t.TempDir(), "project")
	sessionID := "01a0f9cd-03d9-75cd-9ffa-8b89ede923c4"
	bridgeID := "0123456789abcdef0123456789abcdef"
	stubPiTitleBridgeStatus(t, func(id string) (acpBridgeInfo, error) {
		return acpBridgeInfo{ID: id, SessionID: sessionID, Cwd: cwd}, nil
	})
	direct := filepath.Join(sessionDir, "2026-10-01T23-29-17-785Z_"+sessionID+".jsonl")
	appendPiTitleTestRecords(t, direct, piTitleTestHeader)
	if got := nativePiSessionPath(bridgeID); got != direct {
		t.Fatalf("configured session dir path = %q, want %q", got, direct)
	}

	// A second file for the same id in the cwd bucket makes the match ambiguous.
	bucket := filepath.Join(sessionDir, piEncodedSessionDirName(cwd))
	if err := os.MkdirAll(bucket, 0o700); err != nil {
		t.Fatal(err)
	}
	appendPiTitleTestRecords(t, filepath.Join(bucket, filepath.Base(direct)), piTitleTestHeader)
	if got := nativePiSessionPath(bridgeID); got != "" {
		t.Fatalf("ambiguous session path = %q, want empty", got)
	}
}

func newPiTitleTestServer(window *muxWindow) (*muxServer, *recordingConn) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	control := &recordingConn{}
	server.controls[newControlClient(control)] = struct{}{}
	return server, control
}

func TestQuietTitleRefreshBroadcastsARename(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path, piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Fix the window bar"}}`+"\n")
	window := &muxWindow{
		id: "@1", foregroundCommand: "pi", agentTool: "pi", agentToolConfirmed: true,
		agentSessionPath: path,
	}
	server, control := newPiTitleTestServer(window)
	if !server.refreshQuietAgentSessionTitles() {
		t.Fatal("quiet refresh reported a closed server")
	}
	if !strings.Contains(control.String(), `"agentSessionTitle":"Fix the window bar"`) {
		t.Fatalf("first title was not broadcast: %s", control.String())
	}

	// A rename right after the window's last output still reaches clients.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"Bar names"}`+"\n")
	server.refreshQuietAgentSessionTitles()
	if !strings.Contains(control.String(), `"agentSessionTitle":"Bar names"`) {
		t.Fatalf("rename was not broadcast: %s", control.String())
	}
	// Only titles are read; the process-scanning metadata refresh is skipped.
	if !window.lastProcessMetadataRefresh.IsZero() {
		t.Fatal("quiet refresh ran a full metadata refresh")
	}
	before := strings.Count(control.String(), `"window_updated"`)
	server.refreshQuietAgentSessionTitles()
	if got := strings.Count(control.String(), `"window_updated"`); got != before {
		t.Fatalf("unchanged title broadcast again: %d updates, want %d", got, before)
	}
}

func TestQuietTitleRefreshWaitsForAWatcherAndStopsAfterClose(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path, piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Unwatched"}}`+"\n")
	window := &muxWindow{id: "@1", agentTool: "pi", agentToolConfirmed: true, agentSessionPath: path}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	if !server.refreshQuietAgentSessionTitles() {
		t.Fatal("quiet refresh reported a closed server")
	}
	if window.agentSessionTitle != "" {
		t.Fatal("quiet refresh ran without a control client")
	}
	server.mu.Lock()
	server.closed = true
	server.mu.Unlock()
	if server.refreshQuietAgentSessionTitles() {
		t.Fatal("quiet refresh kept running after close")
	}
}

func TestQuietTitleRefreshTitlesNativePiWindows(t *testing.T) {
	agentDir := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "")
	t.Setenv("PI_CODING_AGENT_DIR", agentDir)
	cwd := filepath.Join(t.TempDir(), "project")
	bucket := filepath.Join(agentDir, "sessions", piEncodedSessionDirName(cwd))
	if err := os.MkdirAll(bucket, 0o700); err != nil {
		t.Fatal(err)
	}
	sessionID := "01a0f9cd-03d9-75cd-9ffa-8b89ede923c4"
	bridgeID := "0123456789abcdef0123456789abcdef"
	stubPiTitleBridgeStatus(t, func(id string) (acpBridgeInfo, error) {
		return acpBridgeInfo{ID: id, SessionID: sessionID, Cwd: cwd}, nil
	})
	window := &muxWindow{
		id:                  "@4",
		name:                "Pi",
		command:             "monkeymux acp wait " + bridgeID,
		agentTool:           "pi",
		agentToolConfirmed:  true,
		nativeAcpBridgeID:   bridgeID,
		nativeAcpProviderID: "builtin:pi-acp",
	}
	server, control := newPiTitleTestServer(window)

	// Pi writes a new session's file only after its first prompt.
	server.refreshQuietAgentSessionTitles()
	if window.agentSessionTitle != "" {
		t.Fatalf("title before the first prompt = %q", window.agentSessionTitle)
	}
	appendPiTitleTestRecords(t, filepath.Join(bucket, "2026-10-01T23-29-17-785Z_"+sessionID+".jsonl"),
		piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Native prompt"}}`+"\n",
	)
	// The window prints nothing; the next refresh after the bridge lookup is
	// due again finds the file.
	window.piTitleMu.Lock()
	window.piNativeSessionCheckedAt = time.Time{}
	window.piTitleMu.Unlock()
	server.refreshQuietAgentSessionTitles()
	if !strings.Contains(control.String(), `"agentSessionTitle":"Native prompt"`) {
		t.Fatalf("native label was not broadcast: %s", control.String())
	}
	if snapshots := server.snapshots(); snapshots[0].AgentSessionTitle != "Native prompt" {
		t.Fatalf("native snapshot title = %q", snapshots[0].AgentSessionTitle)
	}
}
