//go:build linux

package main

import (
	"cmp"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// processCommandLine returns a process's argument vector as /proc records it,
// with every argument boundary, empty arguments included.
func processCommandLine(pid int) []string {
	if pid <= 0 {
		return nil
	}
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil || len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
}

// processEnvironment returns the environment a process was started with, as
// /proc records it, or nil when it cannot be read.
func processEnvironment(pid int) []string {
	if pid <= 0 {
		return nil
	}
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "environ"))
	if err != nil {
		return nil
	}
	return strings.FieldsFunc(string(data), func(r rune) bool { return r == 0 })
}

// processGroupMembers returns the live processes in a process group, oldest
// first.
func processGroupMembers(group int) []int {
	if group <= 0 {
		return nil
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	type member struct {
		pid     int
		started uint64
	}
	var members []member
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || !entry.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "stat"))
		if err != nil {
			continue
		}
		// The command name is parenthesized and may hold spaces, so the
		// fields are counted from its closing parenthesis: state, ppid,
		// pgrp, and starttime as the 20th.
		text := string(data)
		end := strings.LastIndex(text, ")")
		if end < 0 {
			continue
		}
		fields := strings.Fields(text[end+1:])
		if len(fields) < 20 || fields[0] == "Z" || fields[0] == "X" {
			continue
		}
		if memberGroup, err := strconv.Atoi(fields[2]); err != nil || memberGroup != group {
			continue
		}
		started, err := strconv.ParseUint(fields[19], 10, 64)
		if err != nil {
			continue
		}
		members = append(members, member{pid, started})
	}
	slices.SortStableFunc(members, func(a, b member) int {
		return cmp.Or(cmp.Compare(a.started, b.started), cmp.Compare(a.pid, b.pid))
	})
	pids := make([]int, 0, len(members))
	for _, member := range members {
		pids = append(pids, member.pid)
	}
	return pids
}
