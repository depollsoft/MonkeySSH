//go:build windows

package main

import (
	"slices"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// hermesLaunchArguments finds the Hermes CLI among the descendants of a
// window's process, which stands in for the process group on Windows, and
// returns its command line: the hermes.exe launcher a pip install creates,
// or a Python interpreter running Hermes. The nearest one wins.
func hermesLaunchArguments(root int) []string {
	processes := readProcessTable()
	children := map[int][]int{}
	for pid, process := range processes {
		if pid != process.ppid {
			children[process.ppid] = append(children[process.ppid], pid)
		}
	}
	level := []int{root}
	for depth := 0; depth < 8 && len(level) > 0; depth++ {
		var next []int
		for _, pid := range level {
			descendants := children[pid]
			slices.Sort(descendants)
			for _, child := range descendants {
				name := hermesExecutableName(processes[child].comm)
				if name == "hermes" || name == "hermes-agent" || strings.HasPrefix(name, "python") {
					if argv := windowsProcessCommandLine(child); hermesCommandStart(argv) >= 0 {
						return argv
					}
				}
			}
			next = append(next, descendants...)
		}
		level = next
	}
	return nil
}

// windowsProcessCommandLine reads a process's command line, which needs only
// limited query access to it, and splits it the way the C runtime does.
func windowsProcessCommandLine(pid int) []string {
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(process)
	var size uint32
	_ = windows.NtQueryInformationProcess(process, windows.ProcessCommandLineInformation, nil, 0, &size)
	if size < uint32(unsafe.Sizeof(windows.NTUnicodeString{})) || size > 1<<20 {
		return nil
	}
	// Words, so the UNICODE_STRING at the start of the buffer is aligned.
	buffer := make([]uint64, (size+7)/8)
	if err := windows.NtQueryInformationProcess(
		process, windows.ProcessCommandLineInformation, unsafe.Pointer(&buffer[0]), size, &size,
	); err != nil {
		return nil
	}
	commandLine := (*windows.NTUnicodeString)(unsafe.Pointer(&buffer[0])).String()
	argv, err := windows.DecomposeCommandLine(commandLine)
	if err != nil {
		return nil
	}
	return argv
}
