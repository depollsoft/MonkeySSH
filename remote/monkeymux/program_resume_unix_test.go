//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func waitForFile(t *testing.T, path string) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if raw, err := os.ReadFile(path); err == nil && len(raw) > 0 {
			return string(raw)
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s was never written", path)
	return ""
}

func programResumeTestShells() []string {
	var shells []string
	for _, shell := range []string{"/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash"} {
		if _, err := os.Stat(shell); err == nil {
			shells = append(shells, shell)
		}
	}
	return shells
}

// A program reports its command in one server, the restore snapshot carries
// it, and the restored window runs it again: each element as one argument, in
// the reported directory, under a new token.
func TestProgramResumeSurvivesARestore(t *testing.T) {
	for _, shell := range programResumeTestShells() {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			// A startup file that changes directory must not move the program.
			home := t.TempDir()
			for _, startup := range []string{".profile", ".bash_profile", ".zshrc"} {
				if err := os.WriteFile(filepath.Join(home, startup), []byte("cd /\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			setTestHomeDir(t, home)
			t.Setenv("SHELL", shell)
			t.Setenv("ENV", "")
			t.Setenv("BASH_ENV", "")
			t.Setenv(programResumeTokenEnv, "outer-terminal-token-000000")
			scratch, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			workspace := filepath.Join(scratch, "work space")
			if err := os.Mkdir(workspace, 0o700); err != nil {
				t.Fatal(err)
			}
			recorder := filepath.Join(scratch, "recorder")
			recorded := filepath.Join(scratch, "recorded")
			script := "#!/bin/sh\n" +
				"{ printf '%s\\n' \"$OSC7577_TOKEN\" \"$PWD\" \"$#\"; " +
				"for a in \"$@\"; do printf '[%s]\\n' \"$a\"; done; } > " + shellQuote(recorded+".tmp") + "\n" +
				"mv " + shellQuote(recorded+".tmp") + " " + shellQuote(recorded) + "\n"
			if err := os.WriteFile(recorder, []byte(script), 0o700); err != nil {
				t.Fatal(err)
			}

			first := newMuxServerWithSize("resume-first", 80, 24)
			t.Cleanup(first.close)
			identity := filepath.Join(scratch, "identity")
			report := filepath.Join(scratch, "report")
			_, err = first.createWindow(createWindowOptions{
				args: []string{"/bin/sh", "-c",
					`printf '%s %s' "$OSC7577_TOKEN" "$$" > "$0.tmp"; mv "$0.tmp" "$0"; ` +
						`while [ ! -f "$1" ]; do sleep 0.05; done; cat "$1"; sleep 30`,
					identity, report},
			})
			if err != nil {
				t.Fatal(err)
			}
			token, rawPid, _ := strings.Cut(waitForFile(t, identity), " ")
			pid, err := strconv.Atoi(rawPid)
			if err != nil || token == "" || token == "outer-terminal-token-000000" {
				t.Fatalf("window identity = %q %q, want its own token and a pid", token, rawPid)
			}
			arguments := []string{recorder, "a b", "$(touch " + filepath.Join(scratch, "pwned") + ")", `'q"`, "", ";x", "-flag"}
			body := fmt.Sprintf("pid=%d:time=%d:%s:cwd=%s",
				pid, time.Now().Unix(), programResumeArgv(arguments...), programResumeText(workspace))
			sequence := programResumeOsc(signedProgramResume(body, token))
			if err := os.WriteFile(report+".tmp", []byte(sequence), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Rename(report+".tmp", report); err != nil {
				t.Fatal(err)
			}

			var state restoreWindowState
			deadline := time.Now().Add(10 * time.Second)
			for {
				restore := first.restoreSnapshot()
				if len(restore.Windows) == 1 && restore.Windows[0].ProgramResume != nil {
					state = restore.Windows[0]
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("the restore snapshot never carried the reported command")
				}
				time.Sleep(20 * time.Millisecond)
			}
			if raw := fmt.Sprintf("%+v", state); strings.Contains(raw, token) {
				t.Fatalf("the restore snapshot leaks the token: %s", raw)
			}

			for _, shellWindow := range []bool{false, true} {
				_ = os.Remove(recorded)
				state.ProgramResume.ShellWindow = shellWindow
				second := newMuxServerWithSize("resume-second", 80, 24)
				window, err := second.createWindow(createWindowOptionsForRestore(state, false))
				if err != nil {
					second.close()
					t.Fatal(err)
				}
				lines := strings.Split(strings.TrimSuffix(waitForFile(t, recorded), "\n"), "\n")
				want := []string{"", workspace, "6", "[a b]", "[" + arguments[2] + "]", `['q"]`, "[]", "[;x]", "[-flag]"}
				if len(lines) != len(want) || lines[0] == "" || lines[0] == token ||
					strings.Join(lines[1:], "\n") != strings.Join(want[1:], "\n") {
					second.close()
					t.Fatalf("shell window %v: resumed program saw %q, want a new token then %q", shellWindow, lines, want[1:])
				}
				if _, err := os.Stat(filepath.Join(scratch, "pwned")); err == nil {
					second.close()
					t.Fatal("an argument was run as shell source")
				}
				// A shell window goes back to its shell once the program ends.
				time.Sleep(300 * time.Millisecond)
				second.mu.Lock()
				closed := window.closed
				second.mu.Unlock()
				if shellWindow && closed {
					second.close()
					t.Fatal("the shell window closed with its program")
				}
				second.close()
			}
		})
	}
}

// A reported program named like a shell builtin must not run the builtin.
func TestProgramResumeNeverRunsAShellBuiltin(t *testing.T) {
	for _, shell := range programResumeTestShells() {
		t.Run(filepath.Base(shell), func(t *testing.T) {
			setTestHomeDir(t, t.TempDir())
			t.Setenv("SHELL", shell)
			t.Setenv("ENV", "")
			t.Setenv("BASH_ENV", "")
			scratch := t.TempDir()
			pwned := filepath.Join(scratch, "pwned")
			done := filepath.Join(scratch, "done")
			server := newMuxServerWithSize("resume-builtin", 80, 24)
			t.Cleanup(server.close)

			_, err := server.createWindow(createWindowOptions{programResume: &programResumeState{
				Argv: []string{"eval", "touch " + shellQuote(pwned)},
			}})
			if err != nil {
				t.Fatal(err)
			}
			// A second window started afterwards marks a point by which the
			// first has run.
			_, err = server.createWindow(createWindowOptions{programResume: &programResumeState{
				Argv: []string{"/bin/sh", "-c", "sleep 0.5; echo ok > " + shellQuote(done)},
			}})
			if err != nil {
				t.Fatal(err)
			}
			// The resumed program owns its command until it reports, so a
			// second upgrade before then still brings it back.
			restore := server.restoreSnapshot()
			if len(restore.Windows) == 0 {
				t.Fatal("no window to restore")
			}
			last := restore.Windows[len(restore.Windows)-1].ProgramResume
			if last == nil || len(last.Argv) != 3 || last.Argv[0] != "/bin/sh" {
				t.Fatalf("the resumed program's command was not carried over: %+v", last)
			}
			waitForFile(t, done)
			if _, err := os.Stat(pwned); err == nil {
				t.Fatal("the shell's eval builtin ran in place of a program")
			}
		})
	}
}
