package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
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
	// A window keeps this many owners' commands. Over the cap the least
	// recently accepted one is evicted.
	programResumeMaxRecords = 16
	// A window remembers the time of this many owners' last reports, apart
	// from the commands, so evicting a command never lets an older report
	// back in. Over the cap the oldest time becomes a floor for every owner.
	programResumeMaxTimes = 1024
	// A report whose time is further than this from the clock is ignored.
	programResumeTimeWindow = 60 * time.Second
	programResumeMacHexSize = sha256.Size * 2
)

// programResumeRecord is the command one owning process last reported.
type programResumeRecord struct {
	argv []string
	cwd  string
	// time is the report's own time, used while it is parsed.
	time     int64
	accepted uint64
	// started is when the owning process started and ownerCwd its working
	// directory, both read from the system after the report (identified). A
	// process with the same pid and another start time is a different
	// program, not the owner.
	started    time.Time
	ownerCwd   string
	identified bool
}

// programResumeTime is the time of an owner's last accepted report.
// exclusive marks a clear or a rejection: the same report sent again in the
// same second must not undo it, so the next report has to be later.
type programResumeTime struct {
	time      int64
	exclusive bool
}

// programResumeState is the command a restored window runs: the record chosen
// from a window's live owners.
type programResumeState struct {
	Argv []string `json:"argv"`
	Cwd  string   `json:"cwd,omitempty"`
	// ShellWindow marks a window whose own process was the interactive
	// shell: the restored window is a shell again, running the program as
	// its job.
	ShellWindow bool `json:"shellWindow,omitempty"`
}

// programResumeCandidate is one live owner's record, kept until the restore
// snapshot can pick between a window's owners off the server lock.
type programResumeCandidate struct {
	pid        int
	accepted   uint64
	started    time.Time
	identified bool
	state      programResumeState
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
// and is never passed on. Windows matches variable names without regard to
// case, so every spelling of the name is removed there.
func withProgramResumeToken(env []string, token string) []string {
	return withProgramResumeTokenFor(runtime.GOOS, env, token)
}

func withProgramResumeTokenFor(goos string, env []string, token string) []string {
	prefix := programResumeTokenEnv + "="
	result := make([]string, 0, len(env)+1)
	for _, entry := range env {
		name, _, _ := strings.Cut(entry, "=")
		inherited := name == programResumeTokenEnv ||
			goos == "windows" && strings.EqualFold(name, programResumeTokenEnv)
		if !inherited {
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
// against the window's token and the clock. earliestTime gives the earliest
// time a pid's next report may carry, or false when it has none on record: the
// last report accepted for a pid. A rejected report still returns its pid and
// time when those were readable, so the caller can remove that owner's record.
func parseProgramResumeBody(
	body string,
	token string,
	now time.Time,
	earliestTime func(pid int) (int64, bool),
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
		if _, repeated := fields[key]; repeated || key == "mac" || !isProgramResumeValue(value) {
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
		if earliest, known := earliestTime(pid); known && reportTime < earliest {
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

// isProgramResumeValue reports whether a value keeps to the characters the
// protocol sends: base64, digits, commas and key names.
func isProgramResumeValue(value string) bool {
	for index := 0; index < len(value); index++ {
		char := value[index]
		switch {
		case char >= 'a' && char <= 'z', char >= 'A' && char <= 'Z', char >= '0' && char <= '9':
		case strings.IndexByte("_.,+/=-", char) >= 0:
		default:
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
func isProgramResumeProgram(program string) bool {
	if program == "" || strings.HasPrefix(program, "-") {
		return false
	}
	if filepath.IsAbs(program) {
		return true
	}
	// A Windows drive-relative name such as C:nvim.exe has no separator but
	// is still a path, resolved against that drive's current directory.
	return filepath.VolumeName(program) == "" && !strings.ContainsAny(program, `/\`)
}

// applyProgramResumePayloadLocked applies the body of an OSC 7577 report.
func (w *muxWindow) applyProgramResumePayloadLocked(body string) {
	now := time.Now()
	pid, record, verdict := parseProgramResumeBody(
		body,
		w.programResumeToken,
		now,
		w.programResumeEarliestTimeLocked,
	)
	if verdict == programResumeIgnored {
		return
	}
	if verdict == programResumeAccepted && record.argv != nil &&
		(!processIDAlive(pid) || !programResumeOwnerInWindow(w.processID(), pid)) {
		// A command for a process that is not running would be dropped by the
		// next exit check, and a pid outside the window's session is not the
		// reporting program: one inside a pid namespace reports a number that
		// names some other, long-lived process here. Refuse both now.
		verdict = programResumeRejected
		record.argv = nil
	}
	w.noteProgramResumeTimeLocked(pid, programResumeTime{
		time:      record.time,
		exclusive: verdict == programResumeRejected || record.argv == nil,
	}, now)
	if verdict == programResumeRejected || record.argv == nil {
		delete(w.programResume, pid)
		return
	}
	if w.programResume == nil {
		w.programResume = map[int]programResumeRecord{}
	}
	w.programResumeClock++
	record.accepted = w.programResumeClock
	w.programResume[pid] = record
	if len(w.programResume) > programResumeMaxRecords {
		w.dropExitedProgramResumeLocked()
	}
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

// programResumeEarliestTimeLocked returns the earliest time the next report
// for pid may carry.
func (w *muxWindow) programResumeEarliestTimeLocked(pid int) (int64, bool) {
	earliest, known := w.programResumeTimeFloor, w.programResumeTimeFloor > 0
	if last, reported := w.programResumeTimes[pid]; reported {
		if last.exclusive {
			last.time++
		}
		if last.time > earliest {
			earliest = last.time
		}
		known = true
	}
	return earliest, known
}

// noteProgramResumeTimeLocked remembers the time of pid's last accepted
// report. Times too old for the clock check to let anything earlier through
// are forgotten.
func (w *muxWindow) noteProgramResumeTimeLocked(pid int, last programResumeTime, now time.Time) {
	if w.programResumeTimes == nil {
		w.programResumeTimes = map[int]programResumeTime{}
	}
	expired := now.Unix() - 2*int64(programResumeTimeWindow/time.Second)
	for owner, existing := range w.programResumeTimes {
		if existing.time < expired {
			delete(w.programResumeTimes, owner)
		}
	}
	w.programResumeTimes[pid] = last
	for len(w.programResumeTimes) > programResumeMaxTimes {
		oldest, oldestTime := 0, int64(0)
		for owner, existing := range w.programResumeTimes {
			if oldest == 0 || existing.time < oldestTime {
				oldest, oldestTime = owner, existing.time
			}
		}
		// Reports at or before a forgotten time are refused for every owner.
		if oldestTime+1 > w.programResumeTimeFloor {
			w.programResumeTimeFloor = oldestTime + 1
		}
		delete(w.programResumeTimes, oldest)
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
			pid:        pid,
			accepted:   record.accepted,
			started:    record.started,
			identified: record.identified,
			state: programResumeState{
				Argv:        append([]string(nil), record.argv...),
				Cwd:         firstNonEmptyString(record.cwd, record.ownerCwd),
				ShellWindow: w.interactiveShell,
			},
		})
	}
	return candidates
}

// processTableForProgramResume reads the process table and
// inspectProgramResumeOwner one process; tests replace them.
var (
	processTableForProgramResume       = readProcessTable
	inspectProgramResumeOwner          = inspectProcess
	inspectProgramResumeOwnerDirectory = defaultProcessWorkingDirectoryForMetadata
)

// identifyProgramResumeOwners reads the start time and the working directory
// of each owner whose report is new, off the server lock because that can run
// ps and lsof. kill(2) alone cannot tell an owner from a zombie or from a
// later process with the same pid; the start time lets the restore snapshot
// tell them apart. The directory is where a command that named none runs: the
// window's own directory follows OSC 7, which any output can send.
func (s *muxServer) identifyProgramResumeOwners() {
	type pending struct {
		window   *muxWindow
		pid      int
		accepted uint64
	}
	var owners []pending
	s.mu.Lock()
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		for pid, record := range window.programResume {
			if len(record.argv) > 0 && !record.identified {
				owners = append(owners, pending{window, pid, record.accepted})
			}
		}
	}
	s.mu.Unlock()
	for _, owner := range owners {
		snapshot := inspectProgramResumeOwner(owner.pid)
		if !snapshot.known {
			continue
		}
		directory := ""
		if snapshot.running {
			directory = programResumeOwnerDirectory(owner.pid)
		}
		s.mu.Lock()
		record, kept := owner.window.programResume[owner.pid]
		if kept && record.accepted == owner.accepted && !owner.window.closed {
			if snapshot.running {
				record.started, record.identified = snapshot.started, true
				record.ownerCwd = directory
				owner.window.programResume[owner.pid] = record
			} else {
				delete(owner.window.programResume, owner.pid)
			}
		}
		s.mu.Unlock()
	}
}

// programResumeOwnerDirectory returns the absolute working directory of a
// running owner, or "" when the system does not tell.
func programResumeOwnerDirectory(pid int) string {
	directory := inspectProgramResumeOwnerDirectory(pid)
	if !filepath.IsAbs(directory) {
		return ""
	}
	return directory
}

// programResumeOwnerRuns reports whether a candidate's owner is still the
// process that reported: running, not a zombie, and not a later process that
// was given its pid.
func programResumeOwnerRuns(candidate programResumeCandidate) bool {
	snapshot := inspectProgramResumeOwner(candidate.pid)
	if !snapshot.known {
		return true
	}
	return snapshot.running &&
		(!candidate.identified || snapshot.started.Equal(candidate.started))
}

// chooseProgramResume picks the one command a window resumes. A terminal has
// one foreground job, so only one owner can come back: an ancestor wins over
// its descendants, since resuming it brings back what it runs, and otherwise
// the most recent report wins.
func chooseProgramResume(candidates []programResumeCandidate) *programResumeState {
	running := candidates[:0:0]
	for _, candidate := range candidates {
		if programResumeOwnerRuns(candidate) {
			running = append(running, candidate)
		}
	}
	candidates = running
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
	if chosen.state.Cwd == "" && !chosen.identified {
		// The report arrived after the last identification pass.
		chosen.state.Cwd = programResumeOwnerDirectory(chosen.pid)
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
// resume then). A command without a directory runs in the home directory, as
// a new shell would, not in the window's: that one follows OSC 7. MonkeyMux's own agent resume wins when it knows the agent's
// session, because it also restores the launch flags and the session binding.
func programResumeForRestore(state restoreWindowState, agentTool string) *programResumeState {
	resume := state.ProgramResume
	if resume == nil || len(resume.Argv) == 0 || len(resume.Argv) > programResumeMaxArgvElements {
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
	if !programResumeRunnable(*resume) {
		return nil
	}
	return resume
}

// programResumeLaunch is what the server hands to `monkeymux
// program-resume-exec` in a private file: the command and where to run it.
type programResumeLaunch struct {
	Argv []string `json:"argv"`
	Cwd  string   `json:"cwd,omitempty"`
}

// writeProgramResumeLaunch saves a launch for the helper, readable by the
// user only. The helper removes the file when it reads it; one never read
// (the shell did not get as far as running the helper) is removed later.
func writeProgramResumeLaunch(launch programResumeLaunch) (string, error) {
	directory, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(launch)
	if err != nil {
		return "", err
	}
	name := make([]byte, 12)
	if _, err := rand.Read(name); err != nil {
		return "", err
	}
	path := filepath.Join(directory, "monkeymux-resume-"+hex.EncodeToString(name)+".json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	time.AfterFunc(programResumeLaunchLifetime, func() { _ = os.Remove(path) })
	return path, nil
}

// programResumeLaunchLifetime is how long an unread launch file is kept.
const programResumeLaunchLifetime = 5 * time.Minute

// programResumeExecCommand is `monkeymux program-resume-exec <file>`, which
// the restored window's shell runs once its startup files have been read. It
// becomes the reported program: it enters the directory after the shell has
// finished initialising (which may have moved elsewhere), finds the program
// on the shell's PATH itself, so no shell function, alias or builtin can
// stand in for it, and passes each element as one argument. Before that it
// reports the command under the window's new token, so the program owns it
// until it reports, clears or exits and a second upgrade still brings it
// back.
func programResumeExecCommand(args []string) {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: monkeymux program-resume-exec <file>")
		os.Exit(2)
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "monkeymux: this program was already resumed")
		os.Exit(1)
	}
	_ = os.Remove(args[0])
	var launch programResumeLaunch
	if err := json.Unmarshal(data, &launch); err != nil || len(launch.Argv) == 0 ||
		!isProgramResumeProgram(launch.Argv[0]) {
		fmt.Fprintln(os.Stderr, "monkeymux: the saved command cannot be resumed")
		os.Exit(1)
	}
	environment := os.Environ()
	if launch.Cwd != "" {
		if err := os.Chdir(launch.Cwd); err != nil {
			fmt.Fprintf(os.Stderr, "monkeymux: not resuming %s: %v\n", launch.Argv[0], err)
			os.Exit(1)
		}
		environment = append(environment, "PWD="+launch.Cwd)
	}
	program := launch.Argv[0]
	if !filepath.IsAbs(program) {
		if program, err = exec.LookPath(program); err != nil {
			fmt.Fprintf(os.Stderr, "monkeymux: not resuming %s: %v\n", launch.Argv[0], err)
			os.Exit(127)
		}
	}
	if report := programResumeReport(os.Getpid(), time.Now(), launch, os.Getenv(programResumeTokenEnv)); report != "" {
		_, _ = os.Stdout.WriteString(report)
	}
	if err := syscall.Exec(program, launch.Argv, environment); err != nil {
		fmt.Fprintf(os.Stderr, "monkeymux: not resuming %s: %v\n", launch.Argv[0], err)
		os.Exit(126)
	}
}

// programResumeReport is the OSC 7577 report of a command for pid, or "" when
// there is no token or the report would be longer than a window accepts.
func programResumeReport(pid int, now time.Time, launch programResumeLaunch, token string) string {
	if token == "" {
		return ""
	}
	elements := make([]string, len(launch.Argv))
	for index, argument := range launch.Argv {
		elements[index] = base64.StdEncoding.EncodeToString([]byte(argument))
	}
	body := fmt.Sprintf("pid=%d:time=%d:argv=%s", pid, now.Unix(), strings.Join(elements, ","))
	if launch.Cwd != "" {
		body += ":cwd=" + base64.StdEncoding.EncodeToString([]byte(launch.Cwd))
	}
	body += ":mac=" + programResumeMac(body, token)
	if len(body) > programResumeMaxBodyBytes {
		return ""
	}
	return "\x1b]" + programResumeOscCode + ";" + body + "\x1b\\"
}
