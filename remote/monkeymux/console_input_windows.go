//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

const consoleInputModeCommand = "--internal-console-input-mode"

// Attaching a console is process-wide. Run the query in an isolated, hidden
// helper so it cannot detach the server from its own console or interfere with
// other windows. This also works when the executable is a Go test binary.
func init() {
	if len(os.Args) != 3 || os.Args[1] != consoleInputModeCommand {
		return
	}
	pid, err := strconv.ParseUint(os.Args[2], 10, 32)
	if err != nil || pid == 0 {
		os.Exit(2)
	}
	kernel := windows.NewLazySystemDLL("kernel32.dll")
	// The helper starts detached, but FreeConsole also covers manual invocation.
	_, _, _ = kernel.NewProc("FreeConsole").Call()
	attached, _, _ := kernel.NewProc("AttachConsole").Call(uintptr(pid))
	if attached == 0 {
		os.Exit(1)
	}
	input, err := windows.CreateFile(windows.StringToUTF16Ptr("CONIN$"), windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		os.Exit(1)
	}
	var mode uint32
	err = windows.GetConsoleMode(input, &mode)
	_ = windows.CloseHandle(input)
	_, _, _ = kernel.NewProc("FreeConsole").Call()
	if err != nil {
		os.Exit(1)
	}
	fmt.Fprintln(os.Stdout, mode)
	os.Exit(0)
}

func (p *winPty) virtualTerminalInputEnabled() (bool, error) {
	if p.pid == 0 {
		return false, fmt.Errorf("console process unavailable")
	}
	executable, err := os.Executable()
	if err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, consoleInputModeCommand, strconv.FormatUint(uint64(p.pid), 10))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
	output, err := cmd.Output()
	if err != nil {
		return false, err
	}
	mode, err := strconv.ParseUint(strings.TrimSpace(string(output)), 10, 32)
	return mode&windows.ENABLE_VIRTUAL_TERMINAL_INPUT != 0, err
}
