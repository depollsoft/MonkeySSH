//go:build windows

package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

// conPtyMinimumBuild is the first Windows 10 build (1809) that ships the
// ConPTY (pseudo console) APIs used by MonkeyMux on Windows.
const conPtyMinimumBuild = 17763

// conPtyMaxDimension bounds pseudo console dimensions so the int->int16
// conversion for windows.Coord can never wrap into a negative or zero value
// (which ConPTY rejects). Real terminals are far smaller than this.
const conPtyMaxDimension = 0x7fff

const bundledConPtyVersion = "1.25.260710002-preview"

type conPtyBackend struct {
	name   string
	dll    *syscall.LazyDLL
	create func(
		size windows.Coord,
		input windows.Handle,
		output windows.Handle,
		flags uint32,
		hpcon *windows.Handle,
	) error
	resize func(windows.Handle, windows.Coord) error
	close  func(windows.Handle)
}

var (
	conPtyBackendOnce sync.Once
	preferredConPty   *conPtyBackend
	conPtyCacheRoot   string
)

func systemConPtyBackend() *conPtyBackend {
	return &conPtyBackend{
		name: "system",
		create: func(
			size windows.Coord,
			input windows.Handle,
			output windows.Handle,
			flags uint32,
			hpcon *windows.Handle,
		) error {
			return windows.CreatePseudoConsole(size, input, output, flags, hpcon)
		},
		resize: windows.ResizePseudoConsole,
		close:  windows.ClosePseudoConsole,
	}
}

func preferredConPtyBackend() *conPtyBackend {
	conPtyBackendOnce.Do(func() {
		backend, err := loadBundledConPtyBackend()
		if err != nil {
			log.Printf(
				"bundled ConPTY unavailable; falling back to the system backend: %v",
				err,
			)
			preferredConPty = systemConPtyBackend()
			return
		}
		preferredConPty = backend
	})
	return preferredConPty
}

func loadBundledConPtyBackend() (*conPtyBackend, error) {
	dllPath, err := ensureBundledConPtyFiles()
	if err != nil {
		return nil, err
	}
	dll := syscall.NewLazyDLL(dllPath)
	if err := dll.Load(); err != nil {
		return nil, fmt.Errorf("load bundled conpty.dll: %w", err)
	}
	createProc := dll.NewProc("ConptyCreatePseudoConsole")
	resizeProc := dll.NewProc("ConptyResizePseudoConsole")
	closeProc := dll.NewProc("ConptyClosePseudoConsole")
	for name, proc := range map[string]*syscall.LazyProc{
		"ConptyCreatePseudoConsole": procOrNil(createProc),
		"ConptyResizePseudoConsole": procOrNil(resizeProc),
		"ConptyClosePseudoConsole":  procOrNil(closeProc),
	} {
		if proc == nil {
			return nil, fmt.Errorf("bundled conpty.dll is missing %s", name)
		}
	}
	return &conPtyBackend{
		name: "bundled",
		dll:  dll,
		create: func(
			size windows.Coord,
			input windows.Handle,
			output windows.Handle,
			flags uint32,
			hpcon *windows.Handle,
		) error {
			hr, _, callErr := createProc.Call(
				packConPtyCoord(size),
				uintptr(input),
				uintptr(output),
				uintptr(flags),
				uintptr(unsafe.Pointer(hpcon)),
			)
			return conPtyHRESULT("create", hr, callErr)
		},
		resize: func(hpcon windows.Handle, size windows.Coord) error {
			hr, _, callErr := resizeProc.Call(
				uintptr(hpcon),
				packConPtyCoord(size),
			)
			return conPtyHRESULT("resize", hr, callErr)
		},
		close: func(hpcon windows.Handle) {
			_, _, _ = closeProc.Call(uintptr(hpcon))
		},
	}, nil
}

func procOrNil(proc *syscall.LazyProc) *syscall.LazyProc {
	if err := proc.Find(); err != nil {
		return nil
	}
	return proc
}

func packConPtyCoord(size windows.Coord) uintptr {
	return uintptr(uint32(uint16(size.X)) | uint32(uint16(size.Y))<<16)
}

func conPtyHRESULT(operation string, hr uintptr, callErr error) error {
	if int32(hr) >= 0 {
		return nil
	}
	return fmt.Errorf(
		"%s bundled pseudo console: HRESULT 0x%08x (%v)",
		operation,
		uint32(hr),
		callErr,
	)
}

func ensureBundledConPtyFiles() (string, error) {
	cacheDir := conPtyCacheRoot
	if cacheDir == "" {
		var err error
		cacheDir, err = os.UserCacheDir()
		if err != nil {
			return "", fmt.Errorf("resolve cache directory: %w", err)
		}
	}
	dir := filepath.Join(
		cacheDir,
		"MonkeySSH",
		"MonkeyMux",
		"conpty",
		bundledConPtyVersion,
		runtime.GOARCH,
	)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create bundled ConPTY directory: %w", err)
	}
	openConsolePath := filepath.Join(dir, "OpenConsole.exe")
	if err := writeBundledConPtyFile(openConsolePath, bundledOpenConsole); err != nil {
		return "", err
	}
	dllPath := filepath.Join(dir, "conpty.dll")
	if err := writeBundledConPtyFile(dllPath, bundledConPtyDLL); err != nil {
		return "", err
	}
	return dllPath, nil
}

func writeBundledConPtyFile(path string, data []byte) error {
	current, err := os.ReadFile(path)
	if err == nil && bytes.Equal(current, data) {
		return nil
	}
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read bundled ConPTY file %s: %w", path, err)
	}
	dir := filepath.Dir(path)
	temp, err := os.CreateTemp(dir, ".conpty-*")
	if err != nil {
		return fmt.Errorf("create temporary bundled ConPTY file: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return fmt.Errorf("write bundled ConPTY file %s: %w", path, err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("close bundled ConPTY file %s: %w", path, err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		// Another server may have won the same first-start extraction race.
		current, readErr := os.ReadFile(path)
		if readErr == nil && bytes.Equal(current, data) {
			return nil
		}
		_ = os.Remove(path)
		if retryErr := os.Rename(tempPath, path); retryErr != nil {
			return fmt.Errorf("install bundled ConPTY file %s: %w", path, retryErr)
		}
	}
	return nil
}

// conPtyCoord clamps cols/rows into the valid positive int16 range and returns
// the corresponding windows.Coord. Callers pass raw dimensions from control and
// attach messages, which are only validated as > 0 upstream.
func conPtyCoord(cols int, rows int) windows.Coord {
	return windows.Coord{X: clampConPtyDimension(cols), Y: clampConPtyDimension(rows)}
}

func clampConPtyDimension(value int) int16 {
	if value < 1 {
		return 1
	}
	if value > conPtyMaxDimension {
		return conPtyMaxDimension
	}
	return int16(value)
}

// winPty wraps a Windows pseudo console (ConPTY) and the two pipe endpoints the
// parent uses to talk to the attached child process.
type winPty struct {
	pid       uint32
	hpc       windows.Handle
	backend   *conPtyBackend
	writeFile *os.File // parent writes child's stdin (input pipe write end)
	readFile  *os.File // parent reads child's stdout (output pipe read end)

	mu        sync.Mutex
	closed    bool
	closeOnce sync.Once
}

func (p *winPty) Read(b []byte) (int, error)  { return p.readFile.Read(b) }
func (p *winPty) Write(b []byte) (int, error) { return p.writeFile.Write(b) }

func (p *winPty) Resize(cols int, rows int) error {
	if cols <= 0 || rows <= 0 {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	return p.backend.resize(p.hpc, conPtyCoord(cols, rows))
}

func (p *winPty) Fd() uintptr { return 0 }

func (p *winPty) Close() error {
	p.closeOnce.Do(func() {
		p.mu.Lock()
		p.closed = true
		p.mu.Unlock()
		// Closing the pseudo console terminates the attached process tree and
		// causes the output pipe to reach EOF (after any final frame is
		// flushed), so the reader goroutine unblocks and exits.
		p.backend.close(p.hpc)
		_ = p.readFile.Close()
		_ = p.writeFile.Close()
	})
	return nil
}

// winProcess wraps the child process launched into a ConPTY.
type winProcess struct {
	handle windows.Handle
	pid    int
	pty    *winPty

	waitOnce sync.Once
	waitErr  error
}

func (p *winProcess) Pid() int { return p.pid }

func (p *winProcess) Wait() error {
	p.waitOnce.Do(func() {
		event, err := windows.WaitForSingleObject(p.handle, windows.INFINITE)
		if event == windows.WAIT_FAILED {
			p.waitErr = err
		}
		windows.CloseHandle(p.handle)
	})
	return p.waitErr
}

func (p *winProcess) Hangup() {
	// There is no SIGHUP on Windows; closing the pseudo console terminates the
	// attached process tree, which is the closest equivalent.
	if p.pty != nil {
		_ = p.pty.Close()
	}
}

func (p *winProcess) Kill() {
	// The handle still belongs to this unwatched process, even if it exited
	// already. Do not use taskkill with a numeric PID that could be recycled.
	_ = windows.TerminateProcess(p.handle, 1)
	if p.pty != nil {
		// Rejected windows have no readWindow goroutine. ConPTY close can wait
		// for its final output to drain before terminating the attached tree.
		drained := make(chan struct{})
		go func() {
			_, _ = io.Copy(io.Discard, p.pty)
			close(drained)
		}()
		_ = p.pty.Close()
		<-drained
	}
}

// startWindow launches cmd attached to a new ConPTY sized to cols x rows.
func startWindow(cmd *exec.Cmd, cols int, rows int) (muxPty, muxProcess, error) {
	if cmd.Err != nil {
		return nil, nil, cmd.Err
	}
	if cols <= 0 {
		cols = defaultColumns
	}
	if rows <= 0 {
		rows = defaultRows
	}

	argv := commandLineArgs(cmd)
	commandLine := windows.ComposeCommandLine(argv)

	env := cmd.Env
	if env == nil {
		env = os.Environ()
	}
	env = ensureSystemRoot(env)

	writeHandle, readHandle, hpc, backend, procHandle, pid, err := startConPty(
		commandLine,
		env,
		cmd.Dir,
		cols,
		rows,
	)
	if err != nil {
		return nil, nil, err
	}

	windowPty := &winPty{
		pid:       pid,
		hpc:       hpc,
		backend:   backend,
		writeFile: os.NewFile(uintptr(writeHandle), "monkeymux-conpty-in"),
		readFile:  os.NewFile(uintptr(readHandle), "monkeymux-conpty-out"),
	}
	proc := &winProcess{handle: procHandle, pid: int(pid), pty: windowPty}
	return windowPty, proc, nil
}

// commandLineArgs returns argv for cmd, preferring the resolved executable path
// as argv[0] so CreateProcess launches the intended binary.
func commandLineArgs(cmd *exec.Cmd) []string {
	if len(cmd.Args) == 0 {
		if cmd.Path != "" {
			return []string{cmd.Path}
		}
		return []string{""}
	}
	if cmd.Path != "" {
		argv := make([]string, len(cmd.Args))
		argv[0] = cmd.Path
		copy(argv[1:], cmd.Args[1:])
		return argv
	}
	return cmd.Args
}

// startConPty creates a ConPTY of size cols x rows and launches commandLine
// attached to it. It returns the parent-side stdin write handle, stdout read
// handle, the pseudo console handle and backend, the process handle and pid.
func startConPty(
	commandLine string,
	env []string,
	workdir string,
	cols int,
	rows int,
) (
	writeHandle windows.Handle,
	readHandle windows.Handle,
	hpcon windows.Handle,
	backend *conPtyBackend,
	processHandle windows.Handle,
	pid uint32,
	err error,
) {
	return startConPtyWithFallback(
		preferredConPtyBackend(),
		systemConPtyBackend(),
		commandLine,
		env,
		workdir,
		cols,
		rows,
	)
}

func startConPtyWithFallback(
	preferred *conPtyBackend,
	fallback *conPtyBackend,
	commandLine string,
	env []string,
	workdir string,
	cols int,
	rows int,
) (
	writeHandle windows.Handle,
	readHandle windows.Handle,
	hpcon windows.Handle,
	backend *conPtyBackend,
	processHandle windows.Handle,
	pid uint32,
	err error,
) {
	backend = preferred
	writeHandle, readHandle, hpcon, processHandle, pid, err =
		startConPtyWithBackend(
			backend,
			commandLine,
			env,
			workdir,
			cols,
			rows,
		)
	if err == nil || fallback == nil || backend == fallback {
		return
	}
	log.Printf(
		"%s ConPTY failed; retrying with the %s backend: %v",
		preferred.name,
		fallback.name,
		err,
	)
	backend = fallback
	writeHandle, readHandle, hpcon, processHandle, pid, err =
		startConPtyWithBackend(
			backend,
			commandLine,
			env,
			workdir,
			cols,
			rows,
		)
	return
}

func startConPtyWithBackend(
	backend *conPtyBackend,
	commandLine string,
	env []string,
	workdir string,
	cols int,
	rows int,
) (writeHandle, readHandle, hpcon, processHandle windows.Handle, pid uint32, err error) {
	if info := windows.RtlGetVersion(); info != nil {
		if info.MajorVersion < 10 ||
			(info.MajorVersion == 10 && info.BuildNumber < conPtyMinimumBuild) {
			err = fmt.Errorf(
				"MonkeyMux requires Windows 10 1809 (build %d), found build %d",
				conPtyMinimumBuild,
				info.BuildNumber,
			)
			return
		}
	}

	commandLinePtr, cmdErr := windows.UTF16PtrFromString(commandLine)
	if cmdErr != nil {
		err = fmt.Errorf("encode command line: %w", cmdErr)
		return
	}

	var dirPtr *uint16
	if strings.TrimSpace(workdir) != "" {
		dirPtr, err = windows.UTF16PtrFromString(workdir)
		if err != nil {
			err = fmt.Errorf("encode working directory: %w", err)
			return
		}
	}

	creationFlags := uint32(windows.EXTENDED_STARTUPINFO_PRESENT)
	var envBlock *uint16
	if len(env) > 0 {
		creationFlags |= uint32(windows.CREATE_UNICODE_ENVIRONMENT)
		envBlock, err = buildEnvBlock(env)
		if err != nil {
			err = fmt.Errorf("encode environment: %w", err)
			return
		}
	}

	// input pipe:  ptyIn (read)  -> ConPTY,   cmdIn (write)  -> parent
	// output pipe: cmdOut (read) -> parent,   ptyOut (write) -> ConPTY
	var ptyIn, ptyOut, cmdIn, cmdOut windows.Handle
	defer func() {
		if err != nil {
			if hpcon != 0 {
				backend.close(hpcon)
				hpcon = 0
			}
			for _, handle := range []windows.Handle{ptyIn, ptyOut, cmdIn, cmdOut} {
				if handle != 0 {
					windows.CloseHandle(handle)
				}
			}
		}
	}()
	if err = windows.CreatePipe(&ptyIn, &cmdIn, nil, 0); err != nil {
		err = fmt.Errorf("create input pipe: %w", err)
		return
	}
	if err = windows.CreatePipe(&cmdOut, &ptyOut, nil, 0); err != nil {
		err = fmt.Errorf("create output pipe: %w", err)
		return
	}

	size := conPtyCoord(cols, rows)
	if err = backend.create(size, ptyIn, ptyOut, 0, &hpcon); err != nil {
		err = fmt.Errorf("create %s pseudo console: %w", backend.name, err)
		return
	}

	attrs, attrErr := windows.NewProcThreadAttributeList(1)
	if attrErr != nil {
		err = fmt.Errorf("allocate attribute list: %w", attrErr)
		return
	}
	defer attrs.Delete()

	// For PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE the attribute value is the HPCON
	// handle itself (passed by value in the pointer slot), per the Win32 ConPTY
	// sample. Reinterpret the handle's bits as an unsafe.Pointer via a pointer
	// cast rather than an int->pointer conversion so `go vet` does not flag it.
	pseudoConsoleValue := *(*unsafe.Pointer)(unsafe.Pointer(&hpcon))
	if err = attrs.Update(
		windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		pseudoConsoleValue,
		unsafe.Sizeof(hpcon),
	); err != nil {
		err = fmt.Errorf("set pseudo console attribute: %w", err)
		return
	}

	var startupInfo windows.StartupInfoEx
	startupInfo.ProcThreadAttributeList = attrs.List()
	startupInfo.Cb = uint32(unsafe.Sizeof(startupInfo))
	// STARTF_USESTDHANDLES stops the child from inheriting the parent's real
	// std handles. Without it, a server launched over an SSH exec channel (whose
	// stdin is an already-closed/EOF pipe, or NUL when detached) leaks those
	// handles to the shell, which then reads EOF at its first prompt and exits
	// immediately. With the flag set and the std handles left zero, the pseudo
	// console attribute connects the child's stdio to the ConPTY instead.
	startupInfo.Flags |= windows.STARTF_USESTDHANDLES

	var procInfo windows.ProcessInformation
	// Inheritable security attributes match the reference ConPTY launchers
	// (aymanbagabas/go-pty); the pseudo console attribute wires the child stdio.
	secAttr := &windows.SecurityAttributes{InheritHandle: 1}
	secAttr.Length = uint32(unsafe.Sizeof(*secAttr))
	if err = windows.CreateProcess(
		nil,
		commandLinePtr,
		secAttr,
		secAttr,
		false,
		creationFlags,
		envBlock,
		dirPtr,
		&startupInfo.StartupInfo,
		&procInfo,
	); err != nil {
		err = fmt.Errorf("create process: %w", err)
		return
	}

	// The pseudo console holds its own references to these ends; releasing our
	// copies lets I/O detect a broken channel when the session ends.
	windows.CloseHandle(ptyIn)
	windows.CloseHandle(ptyOut)
	windows.CloseHandle(procInfo.Thread)

	return cmdIn, cmdOut, hpcon, procInfo.Process, procInfo.ProcessId, nil
}

// buildEnvBlock encodes env as a double-NUL terminated UTF-16 environment block
// for CreateProcess.
func buildEnvBlock(env []string) (*uint16, error) {
	var block []uint16
	for _, entry := range env {
		if entry == "" {
			continue
		}
		encoded, err := windows.UTF16FromString(entry)
		if err != nil {
			return nil, fmt.Errorf("environment entry %q: %w", entry, err)
		}
		block = append(block, encoded...)
	}
	block = append(block, 0)
	return &block[0], nil
}

// ensureSystemRoot guarantees SystemRoot is present so system DLLs resolve.
func ensureSystemRoot(env []string) []string {
	for _, entry := range env {
		if strings.HasPrefix(strings.ToUpper(entry), "SYSTEMROOT=") {
			return env
		}
	}
	if root := os.Getenv("SystemRoot"); root != "" {
		return append(env, "SystemRoot="+root)
	}
	return env
}

// detachedDaemonSysProcAttrs returns the SysProcAttr strategies to try, in
// order, when starting the detached server daemon. The daemon must outlive the
// foreground `attach` shell so the session persists across reconnects. Windows
// OpenSSH runs the command inside a job object and may terminate that job when
// the channel closes, so the first strategy requests CREATE_BREAKAWAY_FROM_JOB.
// Some jobs disallow breakaway (CreateProcess then fails), so a second strategy
// without it is provided as a fallback; ensureServer starts a fresh command for
// each attempt.
func detachedDaemonSysProcAttrs() []*syscall.SysProcAttr {
	const base = windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP
	return []*syscall.SysProcAttr{
		{
			HideWindow:    true,
			CreationFlags: uint32(base | windows.CREATE_BREAKAWAY_FROM_JOB),
		},
		{
			HideWindow:    true,
			CreationFlags: uint32(base),
		},
	}
}

// newRunCommand builds the bounded metadata command using the platform shell.
func newRunCommand(command string) *exec.Cmd {
	shell := commandShellPath()
	var cmd *exec.Cmd
	if isCmdShell(shell) {
		// ComSpec is the platform shell selected by the signed-in user environment.
		cmd = exec.Command(shell, "/c", command) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	} else {
		// Non-cmd ComSpec values are invoked as the configured PowerShell host.
		cmd = exec.Command(shell, "-NoLogo", "-NonInteractive", "-Command", command) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
	}
	return cmd
}

func commandShellPath() string {
	if comspec := strings.TrimSpace(os.Getenv("ComSpec")); comspec != "" {
		return comspec
	}
	return "cmd.exe"
}

func killCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	if pid > 0 {
		// taskkill terminates the whole tree; fall back to Kill on failure.
		kill := exec.Command("taskkill", "/T", "/F", "/PID", fmt.Sprint(pid))
		kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if err := kill.Run(); err == nil {
			return
		}
	}
	_ = cmd.Process.Kill()
}

// processIDAlive reports whether a process with this pid exists. An access
// error means it exists but cannot be opened by this caller, which is still
// evidence that the pid is taken; only a missing process counts as gone.
func processIDAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	handle, err := windows.OpenProcess(
		windows.PROCESS_QUERY_LIMITED_INFORMATION,
		false,
		uint32(pid),
	)
	if err != nil {
		return errors.Is(err, windows.ERROR_ACCESS_DENIED)
	}
	defer windows.CloseHandle(handle)
	var code uint32
	if err := windows.GetExitCodeProcess(handle, &code); err != nil {
		return false
	}
	const stillActive = 259
	return code == stillActive
}

// inspectProcess reports what can be learned about pid. Windows has no zombie
// state: a terminated process reports a real exit code even while a handle to
// it is open.
func inspectProcess(pid int) processSnapshot {
	if pid <= 0 {
		return processSnapshot{known: true}
	}
	handle, err := windows.OpenProcess(
		windows.PROCESS_QUERY_LIMITED_INFORMATION,
		false,
		uint32(pid),
	)
	if err != nil {
		return processSnapshot{}
	}
	defer windows.CloseHandle(handle)
	var code uint32
	if err := windows.GetExitCodeProcess(handle, &code); err != nil {
		return processSnapshot{}
	}
	const stillActive = 259
	snapshot := processSnapshot{known: true, running: code == stillActive}
	var creation, exit, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(
		handle,
		&creation,
		&exit,
		&kernel,
		&user,
	); err == nil {
		snapshot.started = time.Unix(0, creation.Nanoseconds()).UTC()
	}
	// Toolhelp exposes the executable but not the argument list, so the image
	// cannot identify which session a helper serves. A pid missing from the
	// cached table may simply have started since it was taken, and reporting
	// no image at all would leave ownership unresolved, so the table is read
	// again before giving up.
	if info, ok := cachedProcessTable(time.Now())[pid]; ok {
		snapshot.image = info.comm
	} else if info, ok := readProcessTable()[pid]; ok {
		snapshot.image = info.comm
	}
	return snapshot
}

func terminateProcessID(pid int) {
	if pid <= 0 {
		return
	}
	kill := exec.Command("taskkill", "/T", "/F", "/PID", fmt.Sprint(pid))
	kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := kill.Run(); err == nil {
		return
	}
	handle, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(handle)
	_ = windows.TerminateProcess(handle, 1)
}

const supportsExplicitForegroundResizeSignal = false
const prefersVerticalForegroundRedrawResize = true

// signalForegroundResize is a no-op on Windows: ResizePseudoConsole already
// notifies the attached child of size changes.
var signalForegroundResize = func(processGroup int) {}

// attachOutputWriter wraps the attach process's stdout so win32-input-mode
// requests emitted by the window's child are hidden from the SSH server's own
// ConPTY (conhost) that hosts this attach process. Without this, that conhost
// switches its input delivery to win32-input-mode and corrupts relayed cursor
// keys (Up/Down stop recalling shell history). See
// win32InputModeRequestStripper.
func attachOutputWriter(w io.Writer) io.Writer {
	return newWin32InputModeRequestStripper(w)
}

// foregroundProcessGroupForWindow approximates the POSIX foreground process
// group with the window's own process id. Windows has no controlling-terminal
// foreground group, but pairing this with a parent-based process table lets
// MonkeyMux still surface agents launched inside the window's shell.
var foregroundProcessGroupForWindow = func(window *muxWindow) int {
	if window == nil || window.proc == nil {
		return 0
	}
	return window.proc.Pid()
}

func shellArgument(value string) (string, bool) {
	if !isCmdShell(defaultShellPath()) {
		return "'" + strings.ReplaceAll(value, "'", "''") + "'", true
	}
	if strings.ContainsAny(value, "\r\n\"%!") {
		return "", false
	}
	if !strings.ContainsAny(value, " \t&|<>()^") {
		return value, true
	}
	return "\"" + value + "\"", true
}

func shellExecutableCommand(value string) (string, bool) {
	argument, ok := shellArgument(value)
	if !ok {
		return "", false
	}
	if isCmdShell(defaultShellPath()) {
		return argument, true
	}
	// A quoted path is only a string expression in PowerShell. The call
	// operator makes it an executable invocation while preserving literal
	// quoting for spaces and apostrophes.
	return "& " + argument, true
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
	if isCmdShell(defaultShellPath()) {
		return resume + " || " + launch
	}
	return resume + "; if (-not $?) { " + launch + " }"
}

func defaultShellPath() string {
	if shell := strings.TrimSpace(os.Getenv("MONKEYMUX_SHELL")); shell != "" {
		return shell
	}
	if path, err := exec.LookPath("pwsh.exe"); err == nil {
		return path
	}
	if path, err := exec.LookPath("powershell.exe"); err == nil {
		return path
	}
	if comspec := strings.TrimSpace(os.Getenv("ComSpec")); comspec != "" {
		return comspec
	}
	return "cmd.exe"
}

func shellCommand(shell string) *exec.Cmd {
	// The shell path is explicit user-owned MONKEYMUX_SHELL/ComSpec configuration.
	return exec.Command(shell) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
}

func shellCommandForScript(shell string, command string) *exec.Cmd {
	if isCmdShell(shell) {
		return exec.Command(shell, "/c", command) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	}
	return exec.Command(shell, "-NoLogo", "-Command", command) // nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
}

func isCmdShell(shell string) bool {
	base := strings.ToLower(filepath.Base(shell))
	return base == "cmd" || base == "cmd.exe"
}

// holdAgentWindowCommand mirrors the POSIX helper's signature. The reported
// fast-exit failure (a locked macOS login keychain that makes cursor-agent print
// an error and exit immediately) is macOS-specific, and the Windows shell exit
// semantics differ, so the command is returned unchanged here for now.
func holdAgentWindowCommand(shell string, command string) string {
	_ = shell
	return command
}

// readProcessTable enumerates running processes via the Toolhelp snapshot API.
// Windows has no process groups, so pgid is approximated with the parent pid so
// that direct children of a window's shell can be correlated. Full argument
// lists are unavailable through Toolhelp, so args mirrors the executable name.
func readProcessTable() map[int]processInfo {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(snapshot)

	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := windows.Process32First(snapshot, &entry); err != nil {
		return nil
	}

	processes := map[int]processInfo{}
	for {
		pid := int(entry.ProcessID)
		ppid := int(entry.ParentProcessID)
		comm := windows.UTF16ToString(entry.ExeFile[:])
		processes[pid] = processInfo{
			pid:  pid,
			ppid: ppid,
			pgid: ppid,
			comm: comm,
			args: comm,
		}
		if err := windows.Process32Next(snapshot, &entry); err != nil {
			break
		}
	}
	return processes
}

type memoryStatusEx struct {
	length               uint32
	memoryLoad           uint32
	totalPhys            uint64
	availPhys            uint64
	totalPageFile        uint64
	availPageFile        uint64
	totalVirtual         uint64
	availVirtual         uint64
	availExtendedVirtual uint64
}

var procGlobalMemoryStatusEx = windows.NewLazySystemDLL("kernel32.dll").
	NewProc("GlobalMemoryStatusEx")

// detectSystemMemoryBytes returns total physical memory in bytes, or 0 when it
// cannot be determined.
func detectSystemMemoryBytes() uint64 {
	var status memoryStatusEx
	status.length = uint32(unsafe.Sizeof(status))
	ret, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&status)))
	if ret == 0 {
		return 0
	}
	return status.totalPhys
}

func terminalSize() (int, int) {
	if columns, rows, err := term.GetSize(int(os.Stdout.Fd())); err == nil &&
		columns > 0 && rows > 0 {
		return columns, rows
	}
	if columns, rows, err := term.GetSize(int(os.Stdin.Fd())); err == nil &&
		columns > 0 && rows > 0 {
		return columns, rows
	}
	return defaultColumns, defaultRows
}

// forwardResizeSignals sends the initial terminal size and then polls for
// changes. Windows has no SIGWINCH; interactive resizes primarily arrive over
// the MonkeyMux control channel, and this poller covers local console resizes.
//
// A raw SSH exec attach has no local console to poll. Its caller supplies an
// explicit size and all later resizes arrive over the app control channel; a
// terminalSize() poll there would return the 80x24 fallback and overwrite the
// correct attach hello immediately.
func forwardResizeSignals(
	session string,
	clientID string,
	initialWidth int,
	initialHeight int,
	explicitSize bool,
) func() {
	if explicitSize {
		return func() {}
	}
	done := make(chan struct{})
	go func() {
		lastWidth, lastHeight := initialWidth, initialHeight
		sendResize(session, clientID, lastWidth, lastHeight)
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				width, height := terminalSize()
				if width != lastWidth || height != lastHeight {
					lastWidth, lastHeight = width, height
					sendResize(session, clientID, width, height)
				}
			case <-done:
				return
			}
		}
	}()
	return func() { close(done) }
}

func (id socketIdentity) valid() bool {
	return id.device != 0 || id.inode != 0
}

func socketInfoIdentity(info os.FileInfo) (socketIdentity, error) {
	// Windows AF_UNIX still uses a filesystem path, but inodes are not a
	// reliable identity there. Callers treat an invalid identity as "path
	// only", which is still enough to avoid deleting a rebound replacement
	// after SetUnlinkOnClose(false) stops Close() from unlinking by name.
	_ = info
	return socketIdentity{}, errors.New("windows socket identity unavailable")
}

func isStaleUnixSocketError(err error) bool {
	return errors.Is(err, windows.WSAECONNREFUSED) ||
		errors.Is(err, windows.ERROR_CONNECTION_REFUSED)
}
