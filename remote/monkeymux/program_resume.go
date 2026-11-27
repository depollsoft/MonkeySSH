package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// MonkeyMux is the terminal for every window, so it implements the Program
// Resume Protocol (OSC 7577, revision 0.5,
// https://superlogical.com/rex/docs/build/program-resume) itself. Each window
// starts with its own OSC7577_TOKEN. A program that finds the token reports
// the command that brings it back, signed with the token, and an upgrade that
// restarts the window's processes runs that command again in the restored
// window. The protocol has no query and no reply, and reports are left in the
// output stream: they carry no secret and clients ignore them.

const (
	programResumeOscCode = "7577"
	// programResumeTokenEnv is how a program detects support and signs
	// reports. It is set for the first process of each window.
	programResumeTokenEnv = "OSC7577_TOKEN"
	// programResumeDisableEnv set to 0 in the server's environment turns the
	// protocol off: windows get no token, so nothing can report.
	programResumeDisableEnv = "MONKEYMUX_PROGRAM_RESUME"

	// The spec's minimums are 2048 bytes and 64 argv elements. The window's
	// OSC buffer holds 4096 bytes, so that is the most a split report can be.
	programResumeMaxBodyBytes    = 4096
	programResumeMaxArgvElements = 256
	// A window keeps this many owners. Over the cap the least recently
	// accepted one is evicted.
	programResumeMaxRecords = 16
	// A report whose time is further than this from the clock is ignored.
	programResumeTimeWindow = 60 * time.Second
	programResumeMacHexSize = sha256.Size * 2
)

// programResumeRecord is what one owning process last reported. argv is nil
// once the owner cleared its command or sent a report that was rejected; the
// entry stays so an older report cannot be replayed for the same pid.
type programResumeRecord struct {
	argv     []string
	cwd      string
	time     int64
	accepted uint64
}

// programResumeState is the command a restored window runs: the record chosen
// from a window's live owners.
type programResumeState struct {
	Argv []string `json:"argv"`
	Cwd  string   `json:"cwd,omitempty"`
	// ShellWindow marks a window whose own process was the interactive
	// shell, so the restored window returns to a shell when the program ends.
	ShellWindow bool `json:"shellWindow,omitempty"`
}

// programResumeCandidate is one live owner's record, kept until the restore
// snapshot can pick between a window's owners off the server lock.
type programResumeCandidate struct {
	pid      int
	accepted uint64
	state    programResumeState
}

type programResumeVerdict int

const (
	// programResumeIgnored reports have no effect at all.
	programResumeIgnored programResumeVerdict = iota
	// programResumeRejected reports passed the mac and time checks and were
	// refused; the owner's record is removed.
	programResumeRejected
	programResumeAccepted
)

// programResumeEnabled reports whether windows get a token; tests replace the
// environment lookup.
func programResumeEnabled() bool {
	return strings.TrimSpace(os.Getenv(programResumeDisableEnv)) != "0"
}

// newProgramResumeToken returns a window's token: 32 characters of
// [A-Za-z0-9_-] from the system's random source, or "" when that fails, which
// leaves the window without the protocol.
func newProgramResumeToken() string {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

// withProgramResumeToken replaces any inherited token with the window's own.
// A token from the terminal MonkeyMux itself runs in belongs to that terminal
// and is never passed on.
func withProgramResumeToken(env []string, token string) []string {
	prefix := programResumeTokenEnv + "="
	result := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if !strings.HasPrefix(entry, prefix) {
			result = append(result, entry)
		}
	}
	if token != "" {
		result = append(result, prefix+token)
	}
	return result
}

// programResumeMac is the mac of a report body: SHA-256 over the bytes before
// `:mac=`, a colon, and the token, as lowercase hex.
func programResumeMac(signed string, token string) string {
	sum := sha256.Sum256([]byte(signed + ":" + token))
	return hex.EncodeToString(sum[:])
}

// parseProgramResumeBody checks the body of an `OSC 7577 ; body ST` report
// against the window's token and the clock. lastTime gives the time of the
// last report accepted for a pid. A rejected report still returns its pid and
// time when those were readable, so the caller can remove that owner's record.
func parseProgramResumeBody(
	body string,
	token string,
	now time.Time,
	lastTime func(pid int) (int64, bool),
) (pid int, record programResumeRecord, verdict programResumeVerdict) {
	if token == "" || len(body) > programResumeMaxBodyBytes {
		return 0, programResumeRecord{}, programResumeIgnored
	}
	macStart := strings.LastIndex(body, ":mac=")
	if macStart < 0 {
		return 0, programResumeRecord{}, programResumeIgnored
	}
	signed, mac := body[:macStart], body[macStart+len(":mac="):]
	if len(mac) != programResumeMacHexSize || !isLowerHex(mac) {
		return 0, programResumeRecord{}, programResumeIgnored
	}
	if subtle.ConstantTimeCompare([]byte(programResumeMac(signed, token)), []byte(mac)) != 1 {
		return 0, programResumeRecord{}, programResumeIgnored
	}

	// The time check comes before every other rule: a report outside the
	// window is ignored however malformed the rest of it is.
	fields := map[string]string{}
	malformed := false
	for _, pair := range strings.Split(signed, ":") {
		key, value, found := strings.Cut(pair, "=")
		if !found || !isProgramResumeKey(key) {
			malformed = true
			continue
		}
		if _, repeated := fields[key]; repeated || key == "mac" {
			malformed = true
			continue
		}
		fields[key] = value
	}
	reportTime, ok := parsePositiveDecimal(fields["time"])
	if !ok {
		return 0, programResumeRecord{}, programResumeIgnored
	}
	if skew := now.Unix() - reportTime; skew > int64(programResumeTimeWindow/time.Second) ||
		-skew > int64(programResumeTimeWindow/time.Second) {
		return 0, programResumeRecord{}, programResumeIgnored
	}
	owner, ownerOK := parsePositiveDecimal(fields["pid"])
	if ownerOK && owner <= int64(^uint32(0)>>1) {
		pid = int(owner)
		if last, known := lastTime(pid); known && reportTime < last {
			return 0, programResumeRecord{}, programResumeIgnored
		}
	} else {
		// Without an owner there is no record to remove.
		return 0, programResumeRecord{}, programResumeIgnored
	}
	record = programResumeRecord{time: reportTime}
	rejected := func() (int, programResumeRecord, programResumeVerdict) {
		return pid, programResumeRecord{time: reportTime}, programResumeRejected
	}
	if malformed {
		return rejected()
	}
	if need, present := fields["need"]; present {
		for _, key := range strings.Split(need, ",") {
			switch key {
			case "pid", "time", "mac", "argv", "cwd", "clear", "need":
			default:
				return rejected()
			}
		}
	}
	rawArgv, hasArgv := fields["argv"]
	rawClear, hasClear := fields["clear"]
	if hasArgv == hasClear || hasClear && rawClear != "1" {
		return rejected()
	}
	if rawCwd, present := fields["cwd"]; present {
		cwd, ok := decodeProgramResumeText(rawCwd)
		if !ok || !filepath.IsAbs(cwd) {
			return rejected()
		}
		record.cwd = cwd
	}
	if hasClear {
		record.cwd = ""
		return pid, record, programResumeAccepted
	}
	elements := strings.Split(rawArgv, ",")
	if len(elements) > programResumeMaxArgvElements {
		return rejected()
	}
	record.argv = make([]string, 0, len(elements))
	for _, element := range elements {
		text, ok := decodeProgramResumeText(element)
		if !ok {
			return rejected()
		}
		record.argv = append(record.argv, text)
	}
	if !isProgramResumeProgram(record.argv[0]) {
		return rejected()
	}
	return pid, record, programResumeAccepted
}

func isProgramResumeKey(key string) bool {
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

func isLowerHex(value string) bool {
	for index := 0; index < len(value); index++ {
		char := value[index]
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

// parsePositiveDecimal reads a positive integer written with digits only. A
// value too large to represent fails.
func parsePositiveDecimal(value string) (int64, bool) {
	if value == "" {
		return 0, false
	}
	for index := 0; index < len(value); index++ {
		if value[index] < '0' || value[index] > '9' {
			return 0, false
		}
	}
	number, err := strconv.ParseInt(value, 10, 64)
	return number, err == nil && number > 0
}

// decodeProgramResumeText decodes standard base64 of UTF-8 text without
// control characters. Padding may be left out but must be right when present.
func decodeProgramResumeText(encoded string) (string, bool) {
	var decoded []byte
	var err error
	if strings.HasSuffix(encoded, "=") {
		decoded, err = base64.StdEncoding.Strict().DecodeString(encoded)
	} else {
		decoded, err = base64.RawStdEncoding.Strict().DecodeString(encoded)
	}
	if err != nil || !utf8.Valid(decoded) {
		return "", false
	}
	for _, char := range string(decoded) {
		if char < 0x20 || char >= 0x7f && char <= 0x9f {
			return "", false
		}
	}
	return string(decoded), true
}

// isProgramResumeProgram reports whether the first argv element names a
// program the spec allows: a bare command name that is not an option, or an
// absolute path. A relative path would depend on the directory it runs in.
// MonkeyMux also refuses a name with `=` in it, which the env that starts the
// program would read as a variable assignment.
func isProgramResumeProgram(program string) bool {
	if program == "" || strings.HasPrefix(program, "-") || strings.Contains(program, "=") {
		return false
	}
	if filepath.IsAbs(program) {
		return true
	}
	return !strings.ContainsAny(program, `/\`)
}

// applyProgramResumePayloadLocked applies the body of an OSC 7577 report.
func (w *muxWindow) applyProgramResumePayloadLocked(body string) {
	pid, record, verdict := parseProgramResumeBody(
		body,
		w.programResumeToken,
		time.Now(),
		func(pid int) (int64, bool) {
			existing, known := w.programResume[pid]
			return existing.time, known
		},
	)
	if verdict == programResumeIgnored {
		return
	}
	if verdict == programResumeAccepted && record.argv != nil && !processIDAlive(pid) {
		// A command for a process that is not running would be dropped by the
		// next exit check; refuse it now so it is never restored.
		verdict = programResumeRejected
		record = programResumeRecord{time: record.time}
	}
	if w.programResume == nil {
		w.programResume = map[int]programResumeRecord{}
	}
	w.programResumeClock++
	record.accepted = w.programResumeClock
	w.programResume[pid] = record
	for len(w.programResume) > programResumeMaxRecords {
		oldest, oldestAccepted := 0, uint64(0)
		for candidate, existing := range w.programResume {
			if oldest == 0 || existing.accepted < oldestAccepted {
				oldest, oldestAccepted = candidate, existing.accepted
			}
		}
		delete(w.programResume, oldest)
	}
}

// dropExitedProgramResumeLocked removes the records of owners that have
// exited: a program that ended has nothing to resume.
func (w *muxWindow) dropExitedProgramResumeLocked() {
	for pid := range w.programResume {
		if !processIDAlive(pid) {
			delete(w.programResume, pid)
		}
	}
}

// programResumeCandidatesLocked lists the commands of the window's live
// owners.
func (w *muxWindow) programResumeCandidatesLocked() []programResumeCandidate {
	var candidates []programResumeCandidate
	for pid, record := range w.programResume {
		if len(record.argv) == 0 || !processIDAlive(pid) {
			continue
		}
		candidates = append(candidates, programResumeCandidate{
			pid:      pid,
			accepted: record.accepted,
			state: programResumeState{
				Argv:        append([]string(nil), record.argv...),
				Cwd:         record.cwd,
				ShellWindow: w.interactiveShell || w.programResumeShellWindow,
			},
		})
	}
	return candidates
}

// processTableForProgramResume reads the process table; tests replace it.
var processTableForProgramResume = readProcessTable

// chooseProgramResume picks the one command a window resumes. A terminal has
// one foreground job, so only one owner can come back: an ancestor wins over
// its descendants, since resuming it brings back what it runs, and otherwise
// the most recent report wins.
func chooseProgramResume(candidates []programResumeCandidate) *programResumeState {
	if len(candidates) == 0 {
		return nil
	}
	if len(candidates) > 1 {
		owners := map[int]bool{}
		for _, candidate := range candidates {
			owners[candidate.pid] = true
		}
		processes := processTableForProgramResume()
		roots := candidates[:0:0]
		for _, candidate := range candidates {
			if !processHasAncestorIn(processes, candidate.pid, owners) {
				roots = append(roots, candidate)
			}
		}
		if len(roots) > 0 {
			candidates = roots
		}
	}
	chosen := candidates[0]
	for _, candidate := range candidates[1:] {
		if candidate.accepted > chosen.accepted {
			chosen = candidate
		}
	}
	return &chosen.state
}

func processHasAncestorIn(processes map[int]processInfo, pid int, owners map[int]bool) bool {
	seen := map[int]bool{pid: true}
	for parent := processes[pid].ppid; parent > 0 && !seen[parent]; parent = processes[parent].ppid {
		if owners[parent] {
			return true
		}
		seen[parent] = true
	}
	return false
}

// programResumeForRestore returns the reported command a restored window
// runs, or nil when the window restores the usual way: it has no report, the
// report is not valid any more, or its directory is gone (the spec does not
// resume then). MonkeyMux's own agent resume wins when it knows the agent's
// session, because it also restores the launch flags and the session binding.
func programResumeForRestore(state restoreWindowState, agentTool string) *programResumeState {
	resume := state.ProgramResume
	if resume == nil || len(resume.Argv) == 0 || len(resume.Argv) > programResumeMaxArgvElements ||
		!programResumeSupported() {
		return nil
	}
	if agentTool != "" && strings.TrimSpace(state.AgentSessionID) != "" {
		return nil
	}
	if !isProgramResumeProgram(resume.Argv[0]) {
		return nil
	}
	for _, argument := range resume.Argv {
		if !utf8.ValidString(argument) || strings.ContainsRune(argument, 0) {
			return nil
		}
	}
	if resume.Cwd != "" && (!filepath.IsAbs(resume.Cwd) || !directoryExists(resume.Cwd)) {
		return nil
	}
	return resume
}
