//go:build darwin

package main

import (
	"bytes"
	"encoding/binary"

	"golang.org/x/sys/unix"
)

// processCommandLine returns a process's argument vector from
// kern.procargs2, with every argument boundary, empty arguments included. The
// process table that ps prints joins the arguments with spaces, which cannot
// be split back into them.
func processCommandLine(pid int) []string {
	if pid <= 0 {
		return nil
	}
	data, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return nil
	}
	return parseProcArgs2(data)
}

// parseProcArgs2 reads the argument vector out of a kern.procargs2 buffer:
// argc, the executable path, the NULs that pad it, then argc NUL-terminated
// arguments, followed by the environment.
func parseProcArgs2(data []byte) []string {
	if len(data) < 4 {
		return nil
	}
	argc := int(binary.NativeEndian.Uint32(data))
	rest := data[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return nil
	}
	rest = bytes.TrimLeft(rest[end:], "\x00")
	argv := make([]string, 0, argc)
	for len(argv) < argc {
		end := bytes.IndexByte(rest, 0)
		if end < 0 {
			return nil
		}
		argv = append(argv, string(rest[:end]))
		rest = rest[end+1:]
	}
	return argv
}
