//go:build windows

package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

const consoleInputModeCommand = "--internal-console-input-mode"

// Attaching a console is process-wide. Keep one isolated, hidden reader per
// PTY, rather than launching and attaching a process for every mobile input
// batch. Each request still reads the current mode; it is never cached.
func init() {
	if len(os.Args) != 3 || os.Args[1] != consoleInputModeCommand {
		return
	}
	pid, err := strconv.ParseUint(os.Args[2], 10, 32)
	if err != nil || pid == 0 {
		os.Exit(2)
	}
	kernel := windows.NewLazySystemDLL("kernel32.dll")
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
	requests := bufio.NewReader(os.Stdin)
	for {
		if _, err := requests.ReadByte(); err != nil {
			break
		}
		var mode uint32
		if err := windows.GetConsoleMode(input, &mode); err != nil {
			break
		}
		if _, err := fmt.Fprintln(os.Stdout, mode); err != nil {
			break
		}
	}
	_ = windows.CloseHandle(input)
	_, _, _ = kernel.NewProc("FreeConsole").Call()
	os.Exit(0)
}

type consoleInputModeReader struct {
	cmd    *exec.Cmd
	input  io.WriteCloser
	output io.ReadCloser
	reader *bufio.Reader
}

func startConsoleInputModeReader(pid uint32) (*consoleInputModeReader, error) {
	if pid == 0 {
		return nil, fmt.Errorf("console process unavailable")
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(executable, consoleInputModeCommand, strconv.FormatUint(uint64(pid), 10))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		_ = input.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		_ = input.Close()
		_ = output.Close()
		return nil, err
	}
	return &consoleInputModeReader{cmd: cmd, input: input, output: output, reader: bufio.NewReader(output)}, nil
}

func (r *consoleInputModeReader) close() {
	_ = r.input.Close()
	_ = r.output.Close()
	_ = r.cmd.Process.Kill()
	_ = r.cmd.Wait()
}

func (p *winPty) closeConsoleInputModeReader() {
	p.inputModeMu.Lock()
	defer p.inputModeMu.Unlock()
	if p.inputModeReader != nil {
		p.inputModeReader.close()
		p.inputModeReader = nil
	}
}

func (p *winPty) virtualTerminalInputEnabled() (bool, error) {
	p.inputModeMu.Lock()
	defer p.inputModeMu.Unlock()
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if closed {
		return false, os.ErrClosed
	}
	if p.inputModeReader == nil {
		reader, err := startConsoleInputModeReader(p.pid)
		if err != nil {
			return false, err
		}
		p.inputModeReader = reader
	}
	reader := p.inputModeReader
	type result struct {
		vt  bool
		err error
	}
	done := make(chan result, 1)
	go func() {
		if _, err := reader.input.Write([]byte{'?'}); err != nil {
			done <- result{err: err}
			return
		}
		line, err := reader.reader.ReadString('\n')
		if err != nil {
			done <- result{err: err}
			return
		}
		mode, err := strconv.ParseUint(strings.TrimSpace(line), 10, 32)
		done <- result{vt: mode&windows.ENABLE_VIRTUAL_TERMINAL_INPUT != 0, err: err}
	}()
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	var answer result
	select {
	case answer = <-done:
	case <-timer.C:
		answer.err = fmt.Errorf("console input mode query timed out")
	}
	if answer.err != nil {
		reader.close()
		p.inputModeReader = nil
	}
	return answer.vt, answer.err
}
