//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRefreshProcessMetadataPublishesPiSessionTitle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path,
		piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Fix the window bar"}}`+"\n",
	)
	window := &muxWindow{
		id:                 "@1",
		name:               "pi",
		command:            "pi",
		agentTool:          "pi",
		agentToolConfirmed: true,
		agentSessionID:     "01a0f9cd-03d9-75cd-9ffa-8b89ede923c4",
		agentSessionPath:   path,
		lastActivity:       time.Now(),
	}
	_, server := newThemeQueryTestServer(t, window)
	control := &recordingConn{}
	server.controls[newControlClient(control)] = struct{}{}
	server.activeID = window.id

	server.handleWindowOutput(window.id, []byte("x"))
	if got := server.snapshotLocked(window).AgentSessionTitle; got != "Fix the window bar" {
		t.Fatalf("snapshot title = %q, want first prompt", got)
	}
	if !strings.Contains(control.String(), `"agentSessionTitle":"Fix the window bar"`) {
		t.Fatalf("window update did not carry the title: %s", control.String())
	}

	// A rename right after the window's last output reaches clients through
	// the quiet-window refresh.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"Bar names"}`+"\n")
	expireMetadataRefresh(server, window)
	if !server.refreshQuietWindowMetadata() {
		t.Fatal("quiet refresh reported a closed server")
	}
	if !strings.Contains(control.String(), `"agentSessionTitle":"Bar names"`) {
		t.Fatalf("rename was not broadcast: %s", control.String())
	}
}

func expireMetadataRefresh(server *muxServer, window *muxWindow) {
	server.mu.Lock()
	window.lastProcessMetadataRefresh = time.Time{}
	server.mu.Unlock()
}

func TestRefreshQuietWindowMetadataWaitsForAWatcher(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	appendPiTitleTestRecords(t, path, piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Unwatched"}}`+"\n")
	window := &muxWindow{
		id: "@1", agentTool: "pi", agentToolConfirmed: true, agentSessionPath: path,
	}
	_, server := newThemeQueryTestServer(t, window)
	if !server.refreshQuietWindowMetadata() {
		t.Fatal("quiet refresh reported a closed server")
	}
	if !window.lastProcessMetadataRefresh.IsZero() || window.agentSessionTitle != "" {
		t.Fatal("quiet refresh ran without a control client")
	}
	server.mu.Lock()
	server.closed = true
	server.mu.Unlock()
	if server.refreshQuietWindowMetadata() {
		t.Fatal("quiet refresh kept running after close")
	}
}

func TestRefreshProcessMetadataTitlesNativePiWindows(t *testing.T) {
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
	_, server := newThemeQueryTestServer(t, window)
	control := &recordingConn{}
	server.controls[newControlClient(control)] = struct{}{}

	// Pi writes a new session's file only after its first prompt.
	snapshots := server.snapshots()
	if len(snapshots) != 1 || snapshots[0].AgentSessionTitle != "" {
		t.Fatalf("native snapshots before the first prompt = %+v", snapshots)
	}
	appendPiTitleTestRecords(t, filepath.Join(bucket, "2026-10-01T23-29-17-785Z_"+sessionID+".jsonl"),
		piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Native prompt"}}`+"\n",
	)
	// The window prints nothing, so the quiet-window refresh finds the file once
	// the bridge lookup is due again.
	expireMetadataRefresh(server, window)
	window.piTitleMu.Lock()
	window.piNativeSessionCheckedAt = time.Time{}
	window.piTitleMu.Unlock()
	if !server.refreshQuietWindowMetadata() {
		t.Fatal("quiet refresh reported a closed server")
	}
	if !strings.Contains(control.String(), `"agentSessionTitle":"Native prompt"`) {
		t.Fatalf("native label was not broadcast: %s", control.String())
	}
}
