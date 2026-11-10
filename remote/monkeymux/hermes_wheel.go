package main

import (
	"math"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// The Hermes Ink TUI accelerates wheel input itself (ui-tui/src/lib/
// wheelAccel.ts, nativeStep). Its multiplier starts at a base speed and grows
// by 0.3 for each report at most 40 ms after the last, up to the larger of 6
// and twice the base, and each report moves the multiplier's floor. Nothing
// turns this off. The base is the one setting, read from the environment.

const (
	hermesWheelAccelerationStep = 0.3
	hermesWheelAccelerationMax  = 6
	hermesScrollSpeedMax        = 20
)

// hermesWheelSpeedForProcessGroup reads the base speed of the Hermes TUI in a
// window's foreground process group and returns the rows each report of a
// quick run moves.
func hermesWheelSpeedForProcessGroup(group int) func(count int) int {
	return hermesWheelSpeed(hermesScrollSpeedBase(hermesTUIEnvironmentForGroup(group)))
}

// hermesWheelSpeed returns nil for a base below 1, where Hermes moves no row
// at all for the first report and the client cannot calibrate.
func hermesWheelSpeed(base float64) func(count int) int {
	if base < 1 {
		return nil
	}
	steps := hermesWheelSteps(base)
	return func(count int) int {
		return steps[min(count, len(steps)-1)]
	}
}

// hermesWheelSteps holds the rows Hermes moves for each report of a quick run
// until its multiplier reaches the maximum. It sums the multiplier in float64
// the way Hermes sums it, so rounding matches: from a base of 1 the eleventh
// report moves 3 rows, because ten additions of 0.3 fall just short of 4.
func hermesWheelSteps(base float64) []int {
	limit := math.Max(hermesWheelAccelerationMax, base*2)
	var steps []int
	for multiplier := base; ; multiplier = math.Min(limit, multiplier+hermesWheelAccelerationStep) {
		steps = append(steps, int(math.Floor(multiplier)))
		if multiplier == limit {
			return steps
		}
	}
}

// hermesTUIEnvironmentForGroup returns the environment of the TUI process in a
// process group. Hermes runs the TUI as a Node child of its Python CLI, which
// first loads ~/.hermes/.env into its own environment, so the child, not the
// group leader, holds the value the TUI reads. The oldest Node process is the
// TUI; anything Node it starts comes later. Without one the leader's
// environment is the best guess. Only Linux exposes another process's
// environment, so elsewhere this is nil and the base is Hermes's default.
// Tests replace it.
var hermesTUIEnvironmentForGroup = func(group int) []string {
	for _, pid := range processGroupMembers(group) {
		argv := processCommandLine(pid)
		if len(argv) == 0 || !isNodeExecutable(argv[0]) {
			continue
		}
		if environment := processEnvironment(pid); environment != nil {
			return environment
		}
	}
	return processEnvironment(group)
}

func isNodeExecutable(path string) bool {
	name := strings.ToLower(filepath.Base(path))
	return strings.TrimSuffix(name, ".exe") == "node"
}

// hermesScrollSpeedBase mirrors Hermes's readScrollSpeedBase, which applies
// parseFloat to HERMES_TUI_SCROLL_SPEED, or to CLAUDE_CODE_SCROLL_SPEED when
// that is unset, and uses the result when finite and positive, capped at 20,
// and 1 otherwise. A variable that is set but empty still shadows the next
// one, as JavaScript's ?? does.
func hermesScrollSpeedBase(environment []string) float64 {
	value, ok := firstEnvironmentValue(environment, "HERMES_TUI_SCROLL_SPEED")
	if !ok {
		value, _ = firstEnvironmentValue(environment, "CLAUDE_CODE_SCROLL_SPEED")
	}
	speed := javaScriptParseFloat(value)
	if math.IsNaN(speed) || math.IsInf(speed, 0) || speed <= 0 {
		return 1
	}
	return math.Min(speed, hermesScrollSpeedMax)
}

// firstEnvironmentValue returns the first value of key, the one getenv sees.
func firstEnvironmentValue(environment []string, key string) (string, bool) {
	for _, entry := range environment {
		if value, found := strings.CutPrefix(entry, key+"="); found {
			return value, true
		}
	}
	return "", false
}

var javaScriptFloatPrefix = regexp.MustCompile(`^[+-]?(?:Infinity|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)`)

// javaScriptParseFloat follows JavaScript's parseFloat: leading white space
// is skipped, the longest decimal prefix is read, and NaN results when there
// is none.
func javaScriptParseFloat(value string) float64 {
	value = strings.TrimLeftFunc(value, isJavaScriptWhiteSpace)
	prefix := javaScriptFloatPrefix.FindString(value)
	if prefix == "" {
		return math.NaN()
	}
	if strings.HasSuffix(prefix, "Infinity") {
		if prefix[0] == '-' {
			return math.Inf(-1)
		}
		return math.Inf(1)
	}
	// An out-of-range prefix still parses, to an infinity or zero, as it
	// does in JavaScript.
	speed, _ := strconv.ParseFloat(prefix, 64)
	return speed
}

func isJavaScriptWhiteSpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', '\u00a0', '\u2028', '\u2029', '\ufeff':
		return true
	}
	return unicode.Is(unicode.Zs, r)
}
