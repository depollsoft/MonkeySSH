//go:build !windows

package main

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

// unixPty wraps a POSIX pseudo-terminal master file.
type unixPty struct {
	file   *os.File
	mu     sync.Mutex
	closed bool
}

func (p *unixPty) Read(b []byte) (int, error)  { return p.file.Read(b) }
func (p *unixPty) Write(b []byte) (int, error) { return p.file.Write(b) }

func (p *unixPty) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	p.closed = true
	return p.file.Close()
}

func (p *unixPty) Resize(cols int, rows int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return os.ErrClosed
	}
	return pty.Setsize(p.file, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(cols),
	})
}

func (p *unixPty) Fd() uintptr {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return ^uintptr(0)
	}
	return p.file.Fd()
}

func (p *unixPty) foregroundProcessGroup() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return 0
	}
	pgrp, err := unix.IoctlGetInt(int(p.file.Fd()), unix.TIOCGPGRP)
	if err != nil || pgrp <= 0 {
		return 0
	}
	return pgrp
}

// unixProcess wraps the child process attached to a pty master.
type unixProcess struct {
	cmd *exec.Cmd
}

func (p *unixProcess) Pid() int {
	if p.cmd == nil || p.cmd.Process == nil {
		return 0
	}
	return p.cmd.Process.Pid
}

func (p *unixProcess) Wait() error {
	if p.cmd == nil {
		return nil
	}
	return p.cmd.Wait()
}

func (p *unixProcess) Hangup() {
	signalCommandProcessGroup(p.cmd, syscall.SIGHUP)
}

func (p *unixProcess) Kill() {
	killCommandProcessGroup(p.cmd)
}

// startWindow launches cmd attached to a new pty sized to cols x rows.
func startWindow(cmd *exec.Cmd, cols int, rows int) (muxPty, muxProcess, error) {
	ptmx, tty, err := pty.Open()
	if err != nil {
		return nil, nil, err
	}
	defer tty.Close()
	if err := pty.Setsize(ptmx, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)}); err != nil {
		_ = ptmx.Close()
		return nil, nil, err
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = tty, tty, tty
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setsid, cmd.SysProcAttr.Setctty = true, true
	if cmd.Env == nil {
		cmd.Env = os.Environ()
	}
	cmd.Env = withPaneTTYEnvironment(cmd.Env, tty.Name())
	if err := cmd.Start(); err != nil {
		_ = ptmx.Close()
		return nil, nil, err
	}
	return &unixPty{file: ptmx}, &unixProcess{cmd: cmd}, nil
}

// detachedDaemonSysProcAttrs returns the SysProcAttr to use when starting the
// detached server daemon. On POSIX a new session (setsid) detaches it from the
// launching shell's controlling terminal and process group.
func detachedDaemonSysProcAttrs() []*syscall.SysProcAttr {
	return []*syscall.SysProcAttr{{Setsid: true}}
}

// newRunCommand builds the bounded metadata command in its own process group so
// it can be signaled as a group on timeout/cancel.
func newRunCommand(command string) *exec.Cmd {
	cmd := exec.Command(commandShellPath(), "-c", command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

func commandShellPath() string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	switch filepath.Base(shell) {
	case "sh", "bash", "zsh", "ksh", "dash":
		return shell
	default:
		return "/bin/sh"
	}
}

func killCommandProcessGroup(cmd *exec.Cmd) {
	signalCommandProcessGroup(cmd, syscall.SIGKILL)
}

// processIDAlive reports whether a process with this pid exists. A permission
// error means it exists but belongs to another user, which is still evidence
// that the pid is taken; only a missing process counts as gone.
func processIDAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// processGroupAlive includes surviving members whose group leader has exited.
func processGroupAlive(pgid int) bool {
	if pgid <= 0 {
		return false
	}
	err := syscall.Kill(-pgid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// inspectProcess reports what can be learned about pid. Linux answers from
// procfs; elsewhere a single ps query is used, pinned to a fixed locale and
// timezone so the start time it prints does not depend on the environment the
// caller happened to inherit.
func inspectProcess(pid int) processSnapshot {
	if pid <= 0 {
		return processSnapshot{known: true}
	}
	if snapshot, ok := inspectProcFSProcess(pid); ok {
		return snapshot
	}
	return inspectPSProcess(pid)
}

func inspectProcFSProcess(pid int) (processSnapshot, bool) {
	if !procFSDescribesThisNamespace() {
		// A container that mounted the host's /proc would describe a different
		// process than the one kill(2) addresses, and its command line would be
		// bogus "proof" about an unrelated process.
		return processSnapshot{}, false
	}
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return processSnapshot{}, false
	}
	text := string(data)
	// The comm field is parenthesized and may itself contain spaces and
	// parentheses, so the numbered fields are counted from its closing brace.
	end := strings.LastIndex(text, ")")
	if end < 0 {
		return processSnapshot{}, false
	}
	fields := strings.Fields(text[end+1:])
	// These offsets are relative to field 3 (state), the first field after comm.
	const (
		stateOffset     = 0
		startTimeOffset = 19
	)
	if len(fields) <= startTimeOffset {
		return processSnapshot{}, false
	}
	snapshot := processSnapshot{
		known:     true,
		running:   fields[stateOffset] != "Z",
		arguments: true,
		image:     linuxProcessImage(pid, text[:end+1]),
	}
	if ticks, err := strconv.ParseInt(fields[startTimeOffset], 10, 64); err == nil {
		if boot, ok := linuxBootTime(); ok {
			snapshot.started = boot.Add(userHZTicksToDuration(ticks))
		}
	}
	return snapshot, true
}

// procFSDescribesThisNamespace reports whether /proc belongs to this process's
// pid namespace, by checking that it agrees about this process's own pid.
var procFSDescribesThisNamespace = sync.OnceValue(func() bool {
	data, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		return false
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return false
	}
	pid, err := strconv.Atoi(fields[0])
	return err == nil && pid == os.Getpid()
})

// userHZTicksToDuration converts a procfs tick count. The kernel always reports
// these in USER_HZ, which is 100 regardless of the configured timer frequency.
func userHZTicksToDuration(ticks int64) time.Duration {
	const userHZ = 100
	return time.Duration(ticks/userHZ)*time.Second +
		time.Duration(ticks%userHZ)*(time.Second/userHZ)
}

// linuxBootTime reads the boot wall-clock time, which anchors the boot-relative
// start times in /proc/<pid>/stat. Without it, a pid recycled after a reboot
// could report the same start tick as the process that first held it.
func linuxBootTime() (time.Time, bool) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return time.Time{}, false
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[0] != "btime" {
			continue
		}
		seconds, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			return time.Time{}, false
		}
		return time.Unix(seconds, 0), true
	}
	return time.Time{}, false
}

func linuxProcessImage(pid int, statPrefix string) string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err == nil {
		image := strings.TrimSpace(
			strings.ReplaceAll(string(data), "\x00", " "),
		)
		if image != "" {
			return image
		}
	}
	// Kernel threads have an empty cmdline; fall back to the comm field.
	if start := strings.Index(statPrefix, "("); start >= 0 {
		return strings.TrimSuffix(statPrefix[start+1:], ")")
	}
	return ""
}

func inspectPSProcess(pid int) processSnapshot {
	output, err := runProcessQuery(
		"ps",
		"-p",
		strconv.Itoa(pid),
		"-o",
		"state=",
		"-o",
		"lstart=",
		"-o",
		"args=",
	)
	if err != nil {
		return processSnapshot{}
	}
	fields := strings.Fields(output)
	if len(fields) == 0 {
		// ps ran and reported no such process.
		return processSnapshot{known: true}
	}
	snapshot := processSnapshot{
		known:     true,
		running:   !strings.HasPrefix(fields[0], "Z"),
		arguments: true,
	}
	// lstart always occupies exactly five fields ("Mon Jan  2 15:04:05 2006"),
	// so anything after it is the argument list, which may be absent.
	const lstartFields = 5
	if len(fields) >= 1+lstartFields {
		snapshot.started = parseProcessStartTime(
			strings.Join(fields[1:1+lstartFields], " "),
		)
		snapshot.image = strings.Join(fields[1+lstartFields:], " ")
	}
	return snapshot
}

// parseProcessStartTime parses the C-locale, UTC output forced by
// runProcessQuery. A value it cannot parse yields the zero time, which callers
// treat as "unknown" rather than as evidence about the process.
func parseProcessStartTime(value string) time.Time {
	for _, layout := range []string{
		"Mon Jan _2 15:04:05 2006",
		"Mon Jan _2 15:04:05 MST 2006",
	} {
		if started, err := time.Parse(layout, value); err == nil {
			return started.UTC()
		}
	}
	return time.Time{}
}

func runProcessQuery(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	// Pin the timezone and locale so timestamps are comparable no matter what
	// the SSH session exported. os/exec keeps the last value for a duplicated
	// name, so these override anything inherited.
	cmd.Env = append(os.Environ(), "TZ=UTC", "LC_ALL=C")
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	return string(output), nil

}

func terminateProcessID(pid int) {
	if pid <= 0 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if !processIDAlive(pid) {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
}

func signalCommandProcessGroup(cmd *exec.Cmd, signal syscall.Signal) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, signal)
	}
	_ = cmd.Process.Signal(signal)
}

const supportsExplicitForegroundResizeSignal = true
const prefersVerticalForegroundRedrawResize = false

var signalForegroundResize = func(processGroup int) {
	if processGroup <= 0 {
		return
	}
	_ = syscall.Kill(-processGroup, syscall.SIGWINCH)
}

// killProcessGroup force-terminates every process in processGroup. Shutdown
// uses it for a pane's foreground group, which an interactive pane shell keeps
// separate from its own group under job control.
func killProcessGroup(processGroup int) {
	if processGroup <= 0 {
		return
	}
	_ = syscall.Kill(-processGroup, syscall.SIGKILL)
}

// attachOutputWriter returns w unchanged: POSIX pseudo-terminals do not
// interpret win32-input-mode (DEC private mode 9001) requests, so the outer
// conhost corruption the Windows implementation guards against cannot occur.
func attachOutputWriter(w io.Writer) io.Writer {
	return w
}

var foregroundProcessGroupForWindow = func(window *muxWindow) int {
	if window == nil || window.pty == nil {
		return 0
	}
	pty, ok := window.pty.(interface{ foregroundProcessGroup() int })
	if !ok {
		return 0
	}
	return pty.foregroundProcessGroup()
}

func shellArgument(value string) (string, bool) {
	return shellQuote(value), true
}

func shellExecutableCommand(value string) (string, bool) {
	return shellArgument(value)
}

func piResumeCommandWithFreshFallback(resume string, launch string) string {
	resume = strings.TrimSpace(resume)
	launch = strings.TrimSpace(launch)
	if resume == "" {
		return launch
	}
	if launch == "" || launch == resume {
		return resume
	}
	return resume + " || " + launch
}

func defaultShellPath() string {
	shell := os.Getenv("SHELL")
	if strings.TrimSpace(shell) == "" {
		return "/bin/sh"
	}
	return shell
}

func shellCommand(shell string) *exec.Cmd {
	cmd := exec.Command(shell)
	if base := filepath.Base(shell); base != "" {
		cmd.Args[0] = "-" + base
	}
	return cmd
}

func shellCommandForScript(shell string, command string) *exec.Cmd {
	cmd := exec.Command(shell, "-i", "-c", command)
	if base := filepath.Base(shell); base != "" {
		cmd.Args[0] = "-" + base
	}
	return cmd
}

// agentWindowHoldThresholdSeconds bounds how soon after launch an abnormal agent
// exit still holds the window open. Startup failures surface within a couple of
// seconds; a later exit is treated as the user ending the session normally, so
// the window closes as usual.
const agentWindowHoldThresholdSeconds = 12

// holdAgentWindowCommand wraps an agent launch command so the window survives a
// fast, abnormal exit. If the agent exits non-zero within
// agentWindowHoldThresholdSeconds, the terminal is restored to a sane state and
// an interactive shell replaces it, keeping the failure output on screen and
// letting the user recover (for example, `security unlock-keychain` on a locked
// macOS login keychain) and relaunch. A clean exit, or one after the session has
// been running for a while, lets the window close normally. An intentional
// window close signals SIGHUP to the whole process group, terminating this
// wrapping shell before the fallback runs, so closing a window never lingers.
func holdAgentWindowCommand(shell string, command string) string {
	command = strings.TrimSpace(command)
	if command == "" {
		return command
	}
	notice := "[MonkeySSH] Agent exited (status %s) right after launch. " +
		"Keeping this window open so you can read the error above; " +
		"fix it and relaunch, or close the window."
	return "__mm_t0=$(date +%s 2>/dev/null || echo 0); " +
		command + "; __mm_rc=$?; " +
		"__mm_t1=$(date +%s 2>/dev/null || echo 0); " +
		"if [ \"$__mm_rc\" -ne 0 ] && " +
		"[ \"$((__mm_t1 - __mm_t0))\" -lt " +
		strconv.Itoa(agentWindowHoldThresholdSeconds) + " ]; then " +
		"stty sane 2>/dev/null; " +
		"printf '\\r\\n" + notice + "\\r\\n' \"$__mm_rc\"; " +
		"exec " + shellQuote(shell) + " -i; fi"
}

func readProcessTable() map[int]processInfo {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"ps",
		"-eo",
		"pid=,ppid=,pgid=,comm=,args=",
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	processes := map[int]processInfo{}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		pgid, err := strconv.Atoi(fields[2])
		if err != nil {
			continue
		}
		args := ""
		if len(fields) > 4 {
			args = strings.Join(fields[4:], " ")
		}
		processes[pid] = processInfo{
			pid:  pid,
			ppid: ppid,
			pgid: pgid,
			comm: fields[3],
			args: args,
		}
	}
	return processes
}

// detectSystemMemoryBytes returns total physical memory in bytes, or 0 when it
// cannot be determined on this platform.
func detectSystemMemoryBytes() uint64 {
	if bytes := readLinuxMemTotalBytes(); bytes > 0 {
		return bytes
	}
	return readDarwinMemTotalBytes()
}

func readLinuxMemTotalBytes() uint64 {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			if kb, err := strconv.ParseUint(fields[1], 10, 64); err == nil {
				return kb * 1024
			}
		}
		break
	}
	return 0
}

func readDarwinMemTotalBytes() uint64 {
	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 0
	}
	bytes, err := strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 0
	}
	return bytes
}

func terminalSize() (int, int) {
	if size, err := pty.GetsizeFull(os.Stdin); err == nil && size.Cols > 0 && size.Rows > 0 {
		return int(size.Cols), int(size.Rows)
	}
	columns, rows, err := term.GetSize(int(os.Stdin.Fd()))
	if err == nil && columns > 0 && rows > 0 {
		return columns, rows
	}
	return defaultColumns, defaultRows
}

func forwardResizeSignals(
	session string,
	clientID string,
	initialWidth int,
	initialHeight int,
	explicitSize bool,
) func() {
	if explicitSize && initialWidth > 0 && initialHeight > 0 {
		return func() {}
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGWINCH)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-signals:
				width, height := terminalSize()
				sendResize(session, clientID, width, height)
			case <-done:
				return
			}
		}
	}()
	width, height := terminalSize()
	sendResize(session, clientID, width, height)
	return func() {
		close(done)
		signal.Stop(signals)
	}
}

func (id socketIdentity) valid() bool {
	return id.device != 0 || id.inode != 0
}

func socketInfoIdentity(info os.FileInfo) (socketIdentity, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return socketIdentity{}, errors.New("unix socket identity unavailable")
	}
	return socketIdentity{device: uint64(stat.Dev), inode: uint64(stat.Ino)}, nil
}

func isStaleUnixSocketError(err error) bool {
	return errors.Is(err, syscall.ECONNREFUSED)
}

// Hooks may run without a controlling terminal. The pane slave is inherited
// through the environment and must still be a real terminal when opened.
func writeAgentIdentityMarker(marker string) {
	path, set := os.LookupEnv("MONKEYMUX_PANE_TTY")
	if !set {
		path = "/dev/tty"
	} else if !strings.HasPrefix(path, "/dev/") || path == "/dev/tty" || filepath.Clean(path) != path {
		return
	}
	fd, err := unix.Open(path, unix.O_WRONLY|unix.O_NOCTTY|unix.O_NONBLOCK, 0)
	if err != nil {
		return
	}
	defer unix.Close(fd)
	var stat unix.Stat_t
	if unix.Fstat(fd, &stat) != nil || stat.Mode&unix.S_IFMT != unix.S_IFCHR || !term.IsTerminal(fd) {
		return
	}
	_, _ = unix.Write(fd, []byte(marker))
}
