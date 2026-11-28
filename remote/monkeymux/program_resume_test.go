package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const programResumeTestToken = "dummy-token-replace-me"

func programResumeText(text string) string {
	return base64.StdEncoding.EncodeToString([]byte(text))
}

func programResumeArgv(arguments ...string) string {
	encoded := make([]string, len(arguments))
	for index, argument := range arguments {
		encoded[index] = programResumeText(argument)
	}
	return "argv=" + strings.Join(encoded, ",")
}

// signedProgramResume appends the mac a program holding token would send.
func signedProgramResume(body string, token string) string {
	return body + ":mac=" + programResumeMac(body, token)
}

func programResumeOsc(body string) string {
	return "\x1b]7577;" + body + "\x1b\\"
}

func noProgramResumeHistory(int) (int64, bool) { return 0, false }

func TestProgramResumeMacMatchesSpecVector(t *testing.T) {
	got := programResumeMac("pid=74877:time=1795543200:clear=1", programResumeTestToken)
	want := "c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93"
	if got != want {
		t.Fatalf("mac = %s, want the spec's %s", got, want)
	}
}

func TestParseProgramResumeBody(t *testing.T) {
	now := time.Unix(1795543200, 0)
	directory := t.TempDir()
	program := filepath.Join(directory, "nvim")
	base := "pid=74877:time=1795543200"
	for _, test := range []struct {
		name    string
		body    string
		verdict programResumeVerdict
		argv    []string
		cwd     string
	}{
		{
			name:    "command with a directory",
			body:    signedProgramResume(base+":"+programResumeArgv("lazygit")+":cwd="+programResumeText(directory), programResumeTestToken),
			verdict: programResumeAccepted,
			argv:    []string{"lazygit"},
			cwd:     directory,
		},
		{
			name: "keys in any order, absolute program, empty and odd arguments",
			body: signedProgramResume(
				programResumeArgv(program, "-S", "", "a b", "$(x)")+":time=1795543200:pid=74877",
				programResumeTestToken,
			),
			verdict: programResumeAccepted,
			argv:    []string{program, "-S", "", "a b", "$(x)"},
		},
		{
			name: "base64 without padding",
			body: signedProgramResume(
				base+":argv="+base64.RawStdEncoding.EncodeToString([]byte("vi")),
				programResumeTestToken,
			),
			verdict: programResumeAccepted,
			argv:    []string{"vi"},
		},
		{
			name:    "clear",
			body:    signedProgramResume(base+":clear=1", programResumeTestToken),
			verdict: programResumeAccepted,
		},
		{
			name:    "unknown key is ignored",
			body:    signedProgramResume(base+":future=x:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeAccepted,
			argv:    []string{"vi"},
		},
		{
			name:    "value outside the protocol's characters",
			body:    signedProgramResume(base+":future=hello world:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "need naming known keys",
			body:    signedProgramResume(base+":need=argv,cwd:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeAccepted,
			argv:    []string{"vi"},
		},
		{
			name:    "time at the edge of the window",
			body:    signedProgramResume("pid=74877:time=1795543140:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeAccepted,
			argv:    []string{"vi"},
		},
		// The spec's table of invalid reports.
		{
			name:    "wrong mac",
			body:    signedProgramResume(base+":"+programResumeArgv("vi"), "another-token-0123456789"),
			verdict: programResumeIgnored,
		},
		{
			name:    "no mac",
			body:    base + ":" + programResumeArgv("vi"),
			verdict: programResumeIgnored,
		},
		{
			name: "mac not last",
			body: "pid=74877:mac=" + programResumeMac(base+":"+programResumeArgv("vi"), programResumeTestToken) +
				":time=1795543200:" + programResumeArgv("vi"),
			verdict: programResumeIgnored,
		},
		{
			name:    "time far from the clock",
			body:    signedProgramResume("pid=74877:time=1795543100:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeIgnored,
		},
		{
			name:    "time ahead of the clock",
			body:    signedProgramResume("pid=74877:time=1795543261:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeIgnored,
		},
		{
			name:    "no time",
			body:    signedProgramResume("pid=74877:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeIgnored,
		},
		{
			name:    "time too large to represent",
			body:    signedProgramResume("pid=74877:time=99999999999999999999:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeIgnored,
		},
		{
			name:    "relative program path",
			body:    signedProgramResume(base+":"+programResumeArgv("./run.sh"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "argv and clear together",
			body:    signedProgramResume(base+":"+programResumeArgv("vi")+":clear=1", programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "relative cwd",
			body:    signedProgramResume(base+":"+programResumeArgv("vi")+":cwd="+programResumeText("src/project"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "need names a key this terminal lacks",
			body:    signedProgramResume(base+":need=env:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		// Other strict-parsing rules.
		{
			name:    "program that is an option",
			body:    signedProgramResume(base+":"+programResumeArgv("-c", "id"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "program that env would read as an assignment",
			body:    signedProgramResume(base+":"+programResumeArgv("PATH=/tmp", "id"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "empty argv",
			body:    signedProgramResume(base+":argv=", programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "neither argv nor clear",
			body:    signedProgramResume(base, programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "clear with another value",
			body:    signedProgramResume(base+":clear=0", programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "repeated key",
			body:    signedProgramResume(base+":"+programResumeArgv("vi")+":"+programResumeArgv("id"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "pair without a value",
			body:    signedProgramResume(base+":stray:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "argument that is not base64",
			body:    signedProgramResume(base+":argv=dmk,!!!", programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "wrong base64 padding",
			body:    signedProgramResume(base+":argv=dmk==", programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "control character in an argument",
			body:    signedProgramResume(base+":"+programResumeArgv("vi", "a\x1bb"), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name:    "invalid UTF-8 in an argument",
			body:    signedProgramResume(base+":argv=dmk,"+base64.StdEncoding.EncodeToString([]byte{0xff, 0xfe}), programResumeTestToken),
			verdict: programResumeRejected,
		},
		{
			name: "too many arguments",
			body: signedProgramResume(
				base+":"+programResumeArgv(append([]string{"vi"}, make([]string, programResumeMaxArgvElements)...)...),
				programResumeTestToken,
			),
			verdict: programResumeRejected,
		},
		{
			name:    "pid that is not a positive integer",
			body:    signedProgramResume("pid=0:time=1795543200:"+programResumeArgv("vi"), programResumeTestToken),
			verdict: programResumeIgnored,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			pid, record, verdict := parseProgramResumeBody(test.body, programResumeTestToken, now, noProgramResumeHistory)
			if verdict != test.verdict {
				t.Fatalf("verdict = %d, want %d", verdict, test.verdict)
			}
			if verdict == programResumeIgnored {
				return
			}
			if pid != 74877 {
				t.Fatalf("pid = %d, want 74877", pid)
			}
			if !reflect.DeepEqual(record.argv, test.argv) || record.cwd != test.cwd {
				t.Fatalf("record = %q in %q, want %q in %q", record.argv, record.cwd, test.argv, test.cwd)
			}
		})
	}
}

func TestParseProgramResumeBodyNeedsAToken(t *testing.T) {
	body := signedProgramResume("pid=74877:time=1795543200:clear=1", "")
	if _, _, verdict := parseProgramResumeBody(body, "", time.Unix(1795543200, 0), noProgramResumeHistory); verdict != programResumeIgnored {
		t.Fatalf("a window without a token accepted a report: %d", verdict)
	}
}

func TestProgramResumeTokensAreUniqueAndWellFormed(t *testing.T) {
	seen := map[string]bool{}
	for range 64 {
		token := newProgramResumeToken()
		if len(token) < 22 || len(token) > 64 {
			t.Fatalf("token %q is not 22 to 64 characters", token)
		}
		for _, char := range token {
			if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-", char) {
				t.Fatalf("token %q has a character outside [A-Za-z0-9_-]", token)
			}
		}
		if seen[token] {
			t.Fatalf("token %q was issued twice", token)
		}
		seen[token] = true
	}
}

func TestProgramResumeTokenReplacesAnInheritedOne(t *testing.T) {
	env := withProgramResumeToken([]string{"A=1", "OSC7577_TOKEN=outer", "B=2"}, "inner")
	if want := []string{"A=1", "B=2", "OSC7577_TOKEN=inner"}; !reflect.DeepEqual(env, want) {
		t.Fatalf("environment = %q, want %q", env, want)
	}
	env = withProgramResumeToken([]string{"OSC7577_TOKEN=outer"}, "")
	if len(env) != 0 {
		t.Fatalf("the outer terminal's token was passed on: %q", env)
	}
	// Windows reads osc7577_token as the same variable.
	env = withProgramResumeTokenFor("windows", []string{"osc7577_token=outer", "A=1"}, "")
	if want := []string{"A=1"}; !reflect.DeepEqual(env, want) {
		t.Fatalf("environment = %q, want %q", env, want)
	}
	env = withProgramResumeTokenFor("linux", []string{"osc7577_token=other", "A=1"}, "inner")
	if want := []string{"osc7577_token=other", "A=1", "OSC7577_TOKEN=inner"}; !reflect.DeepEqual(env, want) {
		t.Fatalf("environment = %q, want %q", env, want)
	}
}

// reportProgramResume sends a report through the window's output scan in two
// reads, as a PTY may deliver it.
func reportProgramResume(window *muxWindow, body string) {
	sequence := programResumeOsc(signedProgramResume(body, window.programResumeToken))
	window.observeTerminalMetadataLocked([]byte(sequence[:len(sequence)/2]))
	window.observeTerminalMetadataLocked([]byte(sequence[len(sequence)/2:]))
}

func programResumeBodyNow(pid int, offset int, rest string) string {
	return fmt.Sprintf("pid=%d:time=%d:%s", pid, time.Now().Unix()+int64(offset), rest)
}

func TestWindowKeepsProgramResumeRecords(t *testing.T) {
	self := os.Getpid()
	window := &muxWindow{programResumeToken: programResumeTestToken}
	command := func() []string {
		candidates := window.programResumeCandidatesLocked()
		if len(candidates) == 0 {
			return nil
		}
		return candidates[0].state.Argv
	}

	reportProgramResume(window, programResumeBodyNow(self, 0, programResumeArgv("nvim", "-S", "one")))
	if got := command(); !reflect.DeepEqual(got, []string{"nvim", "-S", "one"}) {
		t.Fatalf("command = %q after the first report", got)
	}

	// A later report replaces the command; an older one cannot come back.
	reportProgramResume(window, programResumeBodyNow(self, 5, programResumeArgv("nvim", "-S", "two")))
	reportProgramResume(window, programResumeBodyNow(self, 1, programResumeArgv("nvim", "-S", "one")))
	if got := command(); !reflect.DeepEqual(got, []string{"nvim", "-S", "two"}) {
		t.Fatalf("command = %q, want the newer report's", got)
	}

	// Output that does not hold the token changes nothing.
	forged := programResumeBodyNow(self, 9, programResumeArgv("sh", "-c", "id"))
	window.observeTerminalMetadataLocked([]byte(programResumeOsc(signedProgramResume(forged, "guess"))))
	if got := command(); !reflect.DeepEqual(got, []string{"nvim", "-S", "two"}) {
		t.Fatalf("command = %q after a forged report", got)
	}

	// A rejected report removes the owner's command rather than keeping the
	// old one, and the old report still cannot be replayed.
	reportProgramResume(window, programResumeBodyNow(self, 6, programResumeArgv("./relative")))
	if got := command(); got != nil {
		t.Fatalf("command = %q after a rejected report", got)
	}
	reportProgramResume(window, programResumeBodyNow(self, 5, programResumeArgv("nvim", "-S", "two")))
	if got := command(); got != nil {
		t.Fatalf("command = %q: an older report was replayed", got)
	}

	reportProgramResume(window, programResumeBodyNow(self, 7, programResumeArgv("nvim")))
	reportProgramResume(window, programResumeBodyNow(self, 8, "clear=1"))
	if got := command(); got != nil {
		t.Fatalf("command = %q after clear", got)
	}
}

func TestProgramResumeRecordEndsWithItsOwner(t *testing.T) {
	window := &muxWindow{programResumeToken: programResumeTestToken}
	dead := exitedProcessID(t)

	reportProgramResume(window, programResumeBodyNow(dead, 0, programResumeArgv("nvim")))
	if got := window.programResumeCandidatesLocked(); len(got) != 0 {
		t.Fatalf("a process that is not running got a command: %+v", got)
	}

	reportProgramResume(window, programResumeBodyNow(os.Getpid(), 0, programResumeArgv("nvim")))
	window.programResume[dead] = programResumeRecord{argv: []string{"gone"}, time: 1, accepted: 99}
	window.dropExitedProgramResumeLocked()
	if _, kept := window.programResume[dead]; kept {
		t.Fatal("the exited owner's record was kept")
	}
	if got := window.programResumeCandidatesLocked(); len(got) != 1 {
		t.Fatalf("the running owner's record was dropped: %+v", got)
	}
}

func TestWindowKeepsABoundedNumberOfProgramResumeOwners(t *testing.T) {
	window := &muxWindow{programResumeToken: programResumeTestToken}
	for pid := 1; pid <= programResumeMaxRecords+4; pid++ {
		reportProgramResume(window, programResumeBodyNow(1000000+pid, 0, "clear=1"))
	}
	if len(window.programResume) != programResumeMaxRecords {
		t.Fatalf("window keeps %d owners, want %d", len(window.programResume), programResumeMaxRecords)
	}
	if _, kept := window.programResume[1000001]; kept {
		t.Fatal("the least recent owner was not the one evicted")
	}
}

func TestChooseProgramResumePrefersAnAncestor(t *testing.T) {
	previous, previousInspect := processTableForProgramResume, inspectProgramResumeOwner
	t.Cleanup(func() {
		processTableForProgramResume, inspectProgramResumeOwner = previous, previousInspect
	})
	started := time.Unix(1795543200, 0)
	inspectProgramResumeOwner = func(pid int) processSnapshot {
		switch pid {
		case 50: // a zombie
			return processSnapshot{known: true, started: started}
		case 60: // a later process with the owner's pid
			return processSnapshot{known: true, running: true, started: started.Add(time.Hour)}
		case 70: // nothing can be learned
			return processSnapshot{}
		}
		return processSnapshot{known: true, running: true, started: started}
	}
	processTableForProgramResume = func() map[int]processInfo {
		return map[int]processInfo{
			10: {pid: 10, ppid: 1},
			20: {pid: 20, ppid: 10},
			30: {pid: 30, ppid: 20},
			40: {pid: 40, ppid: 10},
		}
	}
	candidate := func(pid int, accepted uint64, name string) programResumeCandidate {
		return programResumeCandidate{pid: pid, accepted: accepted, state: programResumeState{Argv: []string{name}}}
	}

	if got := chooseProgramResume(nil); got != nil {
		t.Fatalf("chose %+v from nothing", got)
	}
	// An agent and the editor it started: the agent brings the editor back.
	got := chooseProgramResume([]programResumeCandidate{candidate(30, 9, "editor"), candidate(20, 1, "agent")})
	if got == nil || got.Argv[0] != "agent" {
		t.Fatalf("chose %+v, want the ancestor", got)
	}
	// Two jobs of one shell: the more recent report wins.
	got = chooseProgramResume([]programResumeCandidate{candidate(20, 3, "first"), candidate(40, 4, "second")})
	if got == nil || got.Argv[0] != "second" {
		t.Fatalf("chose %+v, want the most recent report", got)
	}
	// An owner that is a zombie, or whose pid now names another process, has
	// exited; one that cannot be inspected is taken at kill(2)'s word.
	identified := func(pid int, name string) programResumeCandidate {
		entry := candidate(pid, 9, name)
		entry.started, entry.identified = started, true
		return entry
	}
	got = chooseProgramResume([]programResumeCandidate{
		identified(50, "zombie"), identified(60, "reused"), candidate(20, 1, "running"),
	})
	if got == nil || got.Argv[0] != "running" {
		t.Fatalf("chose %+v, want the owner that still runs", got)
	}
	if got = chooseProgramResume([]programResumeCandidate{identified(60, "reused")}); got != nil {
		t.Fatalf("chose %+v for a pid that names another process", got)
	}
	if got = chooseProgramResume([]programResumeCandidate{identified(70, "unknown")}); got == nil {
		t.Fatal("dropped an owner that could not be inspected")
	}
}

func TestRestoreRunsTheReportedProgramResumeCommand(t *testing.T) {
	// The test binary is a program every platform can find.
	program, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if !programResumeRunnable(programResumeState{Argv: []string{program}}) {
		t.Skip("the default shell cannot run a reported command")
	}
	directory := t.TempDir()
	resume := &programResumeState{Argv: []string{program, "-S", "session file.vim"}, Cwd: directory}

	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand: "nvim",
		Cwd:            t.TempDir(),
		LaunchCommand:  "nvim",
		ProgramResume:  resume,
	}, false)
	if options.programResume != resume || options.command != "" || options.cwd != directory {
		t.Fatalf("options = %+v, want the reported command in its directory", options)
	}

	// An agent MonkeyMux has no session for comes back the way it reported.
	options = createWindowOptionsForRestore(restoreWindowState{
		AgentTool:     "claude",
		ProgramResume: &programResumeState{Argv: []string{program, "--resume", "abc"}},
	}, false)
	if options.programResume == nil || options.command != "" || options.agentTool != "claude" {
		t.Fatalf("options = %+v, want the agent's reported command", options)
	}

	// With a known session MonkeyMux's own resume keeps its flags and binding.
	options = createWindowOptionsForRestore(restoreWindowState{
		AgentTool:      "claude",
		AgentSessionID: "saved",
		ProgramResume:  &programResumeState{Argv: []string{"claude", "--resume", "abc"}},
	}, false)
	if options.programResume != nil || !strings.Contains(options.command, "saved") {
		t.Fatalf("options = %+v, want MonkeyMux's own agent resume", options)
	}

	for name, state := range map[string]*programResumeState{
		"directory that is gone": {Argv: []string{"nvim"}, Cwd: filepath.Join(directory, "missing")},
		"relative program":       {Argv: []string{"./nvim"}},
		"program that is a flag": {Argv: []string{"-c", "id"}},
		"no command":             {},
		"NUL in an argument":     {Argv: []string{"nvim", "a\x00b"}},
	} {
		options := createWindowOptionsForRestore(restoreWindowState{
			CurrentCommand: "nvim",
			LaunchCommand:  "nvim",
			ProgramResume:  state,
		}, false)
		if options.programResume != nil {
			t.Fatalf("%s: restored %+v", name, options.programResume)
		}
	}
}

// exitedProcessID returns the pid of a process that has already exited.
func exitedProcessID(t *testing.T) int {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(executable, "-test.run=^$")
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	return command.Process.Pid
}
