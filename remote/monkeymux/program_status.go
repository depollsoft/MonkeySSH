package main

import (
	"bytes"
	"encoding/base64"
	"runtime"
	"strings"
	"time"
	"unicode/utf8"
)

// MonkeyMux is the terminal for every window, so it implements the Program
// Status Protocol (OSC 7501, revision 0.3,
// https://superlogical.com/rex/docs/build/program-status) itself: it answers
// feature detection, keeps each window's records, and publishes the most
// urgent record in the window snapshot. Programs such as Claude Code report
// nothing until the terminal answers `OSC 7501 ; ?`.

const (
	programStatusOscCode = "7501"

	// Hard caps from the spec. A report that breaks one is discarded whole.
	programStatusMaxSequenceBytes     = 4096
	programStatusMaxKeyBytes          = 16
	programStatusMaxMsgEncodedBytes   = 2732
	programStatusMaxMsgDecodedBytes   = 2048
	programStatusMaxTitleEncodedBytes = 256
	programStatusMaxTitleDecodedBytes = 192
	programStatusMaxNameBytes         = 32
	programStatusMaxIDBytes           = 128
	programStatusMaxIDDepth           = 8
	// The spec requires at least 64 records per terminal. Over the cap the
	// least recently updated record is evicted.
	programStatusMaxRecords = 64
)

// programStatusQueryReply answers feature detection. The reply never echoes
// anything the program sent.
var programStatusQueryReply = []byte("\x1b]7501;?\x1b\\")

// programStatusOwnerExited reports whether the process group that sent a
// record has exited. Windows has no foreground process group to watch, so
// there records end only at a prompt, a reset, or with the window.
var programStatusOwnerExited = func(pgrp int) bool {
	return runtime.GOOS != "windows" && pgrp > 0 && !processGroupAlive(pgrp)
}

type programStatusRecord struct {
	state    string
	kind     string
	progress int // -1 when absent
	app      string
	title    string
	msg      string
	// owner is the window's foreground process group when the record was
	// reported. Idle, working and blocked records end when it exits.
	owner   int
	updated uint64
}

// programStatusSummary is the record a window publishes: its most urgent one,
// with app inherited from the nearest ancestor. It is comparable so a window
// broadcast can tell when it changed.
type programStatusSummary struct {
	state    string
	kind     string
	progress int
	app      string
	title    string
	msg      string
}

type programStatusSnapshot struct {
	State    string `json:"state"`
	Kind     string `json:"kind,omitempty"`
	Progress *int   `json:"progress,omitempty"`
	App      string `json:"app,omitempty"`
	Title    string `json:"title,omitempty"`
	Message  string `json:"msg,omitempty"`
}

// isProgramStatusQueryPayload reports whether an OSC payload is OSC 7501
// feature detection, which MonkeyMux answers itself.
func isProgramStatusQueryPayload(payload []byte) bool {
	return bytes.HasPrefix(payload, []byte(programStatusOscCode+";?"))
}

// parseProgramStatusBody parses the body of an `OSC 7501 ; body ST` sequence.
// query reports feature detection. ok is false when the report must be
// ignored: it breaks a limit, has a missing or unknown state or an invalid
// id, or carries text that is not base64 of control-free UTF-8.
func parseProgramStatusBody(
	body string,
) (id string, record programStatusRecord, query bool, ok bool) {
	if strings.HasPrefix(body, "?") {
		return "", programStatusRecord{}, true, true
	}
	if len(body) > programStatusMaxSequenceBytes {
		return "", programStatusRecord{}, false, false
	}
	fields := map[string]string{}
	for _, pair := range strings.Split(body, ":") {
		rawKey, rawValue, found := strings.Cut(pair, "=")
		key := strings.Trim(rawKey, " \t")
		value := strings.Trim(rawValue, " \t")
		if !isProgramStatusKey(key) {
			continue
		}
		if len(key) > programStatusMaxKeyBytes {
			return "", programStatusRecord{}, false, false
		}
		if !found || !isProgramStatusValue(value) {
			// An id the report tried to set but got wrong must not fall back
			// to the root record.
			if key == "id" {
				return "", programStatusRecord{}, false, false
			}
			continue
		}
		fields[key] = value
	}

	record = programStatusRecord{state: fields["state"], progress: -1}
	switch record.state {
	case "idle", "working", "done", "blocked", "error", "clear":
	default:
		return "", programStatusRecord{}, false, false
	}
	if value, present := fields["id"]; present {
		if !validProgramStatusID(value) {
			return "", programStatusRecord{}, false, false
		}
		id = value
	}
	if app, present := fields["app"]; present {
		if len(app) > programStatusMaxNameBytes {
			return "", programStatusRecord{}, false, false
		}
		if isProgramStatusName(app) {
			record.app = app
		}
	}
	var valid bool
	if record.title, valid = decodeProgramStatusText(
		fields["title"],
		programStatusMaxTitleEncodedBytes,
		programStatusMaxTitleDecodedBytes,
	); !valid {
		return "", programStatusRecord{}, false, false
	}
	if record.msg, valid = decodeProgramStatusText(
		fields["msg"],
		programStatusMaxMsgEncodedBytes,
		programStatusMaxMsgDecodedBytes,
	); !valid {
		return "", programStatusRecord{}, false, false
	}
	if record.state == "blocked" {
		switch kind := fields["kind"]; kind {
		case "permission", "question", "auth":
			record.kind = kind
		}
	}
	if record.state == "working" || record.state == "blocked" {
		record.progress = parseProgramStatusProgress(fields["progress"])
	}
	return id, record, false, true
}

func isProgramStatusKey(key string) bool {
	if key == "" {
		return false
	}
	for index := 0; index < len(key); index++ {
		if key[index] < 'a' || key[index] > 'z' {
			return false
		}
	}
	return true
}

func isProgramStatusValue(value string) bool {
	for index := 0; index < len(value); index++ {
		switch c := value[index]; {
		case isProgramStatusNameByte(c), c == ',', c == '/', c == '=':
		default:
			return false
		}
	}
	return true
}

// isProgramStatusName reports whether value is a non-empty run of
// [A-Za-z0-9_.+-], the alphabet of app names and id segments.
func isProgramStatusName(value string) bool {
	if value == "" {
		return false
	}
	for index := 0; index < len(value); index++ {
		if !isProgramStatusNameByte(value[index]) {
			return false
		}
	}
	return true
}

func isProgramStatusNameByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '+' || c == '-'
}

func validProgramStatusID(id string) bool {
	if len(id) > programStatusMaxIDBytes {
		return false
	}
	segments := strings.Split(id, "/")
	if len(segments) > programStatusMaxIDDepth {
		return false
	}
	for _, segment := range segments {
		if len(segment) > programStatusMaxNameBytes || !isProgramStatusName(segment) {
			return false
		}
	}
	return true
}

func parseProgramStatusProgress(value string) int {
	if value == "" || len(value) > 3 {
		return -1
	}
	progress := 0
	for index := 0; index < len(value); index++ {
		if value[index] < '0' || value[index] > '9' {
			return -1
		}
		progress = progress*10 + int(value[index]-'0')
	}
	if progress > 100 {
		return -1
	}
	return progress
}

// decodeProgramStatusText decodes a base64 msg or title. Padding is optional.
// Text with control characters invalidates the whole report; bidirectional
// formatting characters are removed so a message cannot reorder the text
// around it.
func decodeProgramStatusText(value string, maxEncoded int, maxDecoded int) (string, bool) {
	if value == "" {
		return "", true
	}
	if len(value) > maxEncoded {
		return "", false
	}
	unpadded := strings.TrimRight(value, "=")
	if padding := len(value) - len(unpadded); padding > 2 || (padding > 0 && len(value)%4 != 0) {
		return "", false
	}
	decoded, err := base64.RawStdEncoding.DecodeString(unpadded)
	if err != nil || len(decoded) > maxDecoded || !utf8.Valid(decoded) {
		return "", false
	}
	var text strings.Builder
	for _, r := range string(decoded) {
		switch {
		case r < 0x20, r >= 0x7f && r <= 0x9f:
			return "", false
		case r == 0x061c, r == 0x200e, r == 0x200f,
			r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069:
			continue
		}
		text.WriteRune(r)
	}
	return text.String(), true
}

// applyProgramStatusPayloadLocked applies the body of an OSC 7501 report.
// Feature-detection queries are answered where they are stripped from the
// forwarded stream (stripLocallyAnsweredThemeQueriesLocked).
func (w *muxWindow) applyProgramStatusPayloadLocked(body string) {
	id, record, query, ok := parseProgramStatusBody(body)
	if !ok || query {
		return
	}
	if record.state == "clear" {
		w.clearProgramStatusLocked(id)
		return
	}
	record.owner = w.foregroundProcessGroupLocked()
	w.programStatusClock++
	record.updated = w.programStatusClock
	if w.programStatus == nil {
		w.programStatus = map[string]*programStatusRecord{}
	}
	w.programStatus[id] = &record
	for len(w.programStatus) > programStatusMaxRecords {
		oldestID := id
		for candidateID, candidate := range w.programStatus {
			if candidate.updated < w.programStatus[oldestID].updated {
				oldestID = candidateID
			}
		}
		delete(w.programStatus, oldestID)
	}
}

// clearProgramStatusLocked removes the record id names and its descendants;
// the root id ("") removes every record.
func (w *muxWindow) clearProgramStatusLocked(id string) {
	if id == "" {
		w.programStatus = nil
		return
	}
	prefix := id + "/"
	for candidate := range w.programStatus {
		if candidate == id || strings.HasPrefix(candidate, prefix) {
			delete(w.programStatus, candidate)
		}
	}
}

// dropRunningProgramStatusLocked drops the records that describe a running
// program (idle, working and blocked); done and error outlive it. With
// exited set, only records whose sender has exited are dropped. It reports
// whether any record was dropped.
func (w *muxWindow) dropRunningProgramStatusLocked(exited func(owner int) bool) bool {
	dropped := false
	for id, record := range w.programStatus {
		switch record.state {
		case "idle", "working", "blocked":
		default:
			continue
		}
		if exited != nil && !exited(record.owner) {
			continue
		}
		delete(w.programStatus, id)
		dropped = true
	}
	return dropped
}

// dropExitedProgramStatusLocked applies the spec's process-exit rule per
// sender, which also covers shells that never mark a prompt with OSC 133.
func (w *muxWindow) dropExitedProgramStatusLocked() bool {
	if len(w.programStatus) == 0 {
		return false
	}
	exitedOwners := map[int]bool{}
	return w.dropRunningProgramStatusLocked(func(owner int) bool {
		exited, checked := exitedOwners[owner]
		if !checked {
			exited = programStatusOwnerExited(owner)
			exitedOwners[owner] = exited
		}
		return exited
	})
}

// programStatusSummaryLocked returns the window's most urgent record: blocked,
// then error, working, done and idle, preferring the shallowest and then the
// most recently updated record.
func (w *muxWindow) programStatusSummaryLocked() programStatusSummary {
	var best *programStatusRecord
	bestID := ""
	for id, record := range w.programStatus {
		if best == nil || programStatusRecordOutranks(id, record, bestID, best) {
			best, bestID = record, id
		}
	}
	if best == nil {
		return programStatusSummary{}
	}
	return programStatusSummary{
		state:    best.state,
		kind:     best.kind,
		progress: best.progress,
		app:      w.programStatusAppLocked(bestID),
		title:    best.title,
		msg:      best.msg,
	}
}

func programStatusRecordOutranks(
	id string,
	record *programStatusRecord,
	otherID string,
	other *programStatusRecord,
) bool {
	if urgency, otherUrgency := programStatusUrgency(record.state),
		programStatusUrgency(other.state); urgency != otherUrgency {
		return urgency > otherUrgency
	}
	if depth, otherDepth := programStatusIDDepth(id),
		programStatusIDDepth(otherID); depth != otherDepth {
		return depth < otherDepth
	}
	return record.updated > other.updated
}

func programStatusUrgency(state string) int {
	switch state {
	case "blocked":
		return 4
	case "error":
		return 3
	case "working":
		return 2
	case "done":
		return 1
	default:
		return 0
	}
}

func programStatusIDDepth(id string) int {
	if id == "" {
		return 0
	}
	return strings.Count(id, "/") + 1
}

// programStatusAppLocked returns the app of the record id names, inherited
// from its nearest ancestor that has one.
func (w *muxWindow) programStatusAppLocked(id string) string {
	for {
		if record := w.programStatus[id]; record != nil && record.app != "" {
			return record.app
		}
		if id == "" {
			return ""
		}
		if slash := strings.LastIndexByte(id, '/'); slash >= 0 {
			id = id[:slash]
		} else {
			id = ""
		}
	}
}

func (summary programStatusSummary) snapshot() *programStatusSnapshot {
	if summary.state == "" {
		return nil
	}
	snapshot := &programStatusSnapshot{
		State:   summary.state,
		Kind:    summary.kind,
		App:     summary.app,
		Title:   summary.title,
		Message: summary.msg,
	}
	if summary.progress >= 0 {
		progress := summary.progress
		snapshot.Progress = &progress
	}
	return snapshot
}

// takeProgramStatusRepliesLocked returns the replies owed for the feature
// detection queries stripped from the output since the last call.
func (w *muxWindow) takeProgramStatusRepliesLocked() []byte {
	if w.programStatusQueries == 0 {
		return nil
	}
	replies := bytes.Repeat(programStatusQueryReply, w.programStatusQueries)
	w.programStatusQueries = 0
	return replies
}

// dropExitedProgramStatus drops the records of senders that have exited and
// broadcasts the windows that changed. Output may stop for good once a
// program dies, so this runs on a timer rather than on output.
func (s *muxServer) dropExitedProgramStatus() {
	s.mu.Lock()
	var snapshots []windowSnapshot
	for _, window := range s.windows {
		if window.closed || !window.dropExitedProgramStatusLocked() {
			continue
		}
		snapshots = append(snapshots, s.snapshotLocked(window))
		window.lastBroadcast = time.Now()
	}
	s.mu.Unlock()
	for index := range snapshots {
		s.broadcast(controlResponse{
			Type:    "window_updated",
			Session: s.session,
			Window:  &snapshots[index],
		})
	}
}
