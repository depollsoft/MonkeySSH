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

	// Pi records a new name, then retitles its terminal. The retitle refreshes
	// the label at once, inside the metadata interval, so an idle window does
	// not keep the old one.
	appendPiTitleTestRecords(t, path, `{"type":"session_info","name":"Bar names"}`+"\n")
	server.handleWindowOutput(window.id, []byte("\x1b]0;π - Bar names - project\x07"))
	if !strings.Contains(control.String(), `"agentSessionTitle":"Bar names"`) {
		t.Fatalf("rename was not broadcast: %s", control.String())
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
	appendPiTitleTestRecords(t, filepath.Join(bucket, "2026-10-01T23-29-17-785Z_"+sessionID+".jsonl"),
		piTitleTestHeader,
		`{"type":"message","message":{"role":"user","content":"Native prompt"}}`+"\n",
	)
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

	snapshots := server.snapshots()
	if len(snapshots) != 1 || snapshots[0].AgentSessionTitle != "Native prompt" {
		t.Fatalf("native snapshots = %+v, want the Pi session title", snapshots)
	}
}
