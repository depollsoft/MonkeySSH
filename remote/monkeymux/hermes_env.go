package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"unicode/utf8"
)

// hermesTUIEnvironmentForGroup returns the environment the Hermes TUI in a
// process group runs with. Tests replace it.
//
// Hermes runs the TUI as a Node child of its Python CLI. Before starting it
// the CLI loads the profile's .env over the environment it inherited, and the
// administrator-managed .env over both, so the child, not the group leader,
// holds what the TUI reads. Linux exposes that environment directly: the
// oldest Node process in the group is the TUI, as anything Node it starts
// comes later. Elsewhere, and when that read fails, the files are read the
// way Hermes reads them, over the leader's initial environment, or over
// MonkeyMux's own, which every window inherits, where the leader's is hidden.
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
	base := processEnvironment(group)
	if base == nil {
		base = os.Environ()
	}
	return hermesLaunchEnvironment(base, processCommandLine(group))
}

func isNodeExecutable(path string) bool {
	name := strings.ToLower(filepath.Base(path))
	return strings.TrimSuffix(name, ".exe") == "node"
}

// hermesLaunchEnvironment returns base with what Hermes's CLI, run as argv,
// loads from its dotenv files in front, where a getenv finds it first.
// Hermes also reads a .env in its own source checkout, which only fills
// names the profile's .env leaves unset; that one is not read here.
func hermesLaunchEnvironment(base []string, argv []string) []string {
	lookup := environmentMap(base)
	layers := []string{filepath.Join(hermesHomeForLaunch(lookup, argv), ".env")}
	if managed := hermesManagedDir(lookup); managed != "" {
		layers = append(layers, filepath.Join(managed, ".env"))
	}
	var loaded []string
	for _, path := range layers {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		for _, assignment := range resolveHermesDotenv(parseDotenv(decodeHermesDotenv(data)), lookup) {
			lookup[assignment.name] = assignment.value
			loaded = append(loaded, assignment.name+"="+assignment.value)
		}
	}
	// A later layer and a later line override an earlier one, so the last
	// assignment of a name goes first.
	environment := make([]string, 0, len(loaded)+len(base))
	for i := len(loaded) - 1; i >= 0; i-- {
		environment = append(environment, loaded[i])
	}
	return append(environment, base...)
}

// environmentMap maps each name to its first value, the one getenv sees.
func environmentMap(environment []string) map[string]string {
	values := make(map[string]string, len(environment))
	for _, entry := range environment {
		name, value, found := strings.Cut(entry, "=")
		if !found || name == "" {
			continue
		}
		if _, seen := values[name]; !seen {
			values[name] = value
		}
	}
	return values
}

// hermesProfileNamePattern is Hermes's profile id grammar (PROFILE_ID_RE).
var hermesProfileNamePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)

// hermesHomeForLaunch follows Hermes's _apply_profile_override: a -p or
// --profile argument names the profile; without one, a HERMES_HOME that
// already names a profile directory stands; otherwise the root's sticky
// active_profile does. A profile that does not resolve stops Hermes before
// its TUI starts, so the home is then just HERMES_HOME or the default.
func hermesHomeForLaunch(environment map[string]string, argv []string) string {
	nativeHome := hermesPlatformDefaultHome(environment)
	envHome := ""
	if value := strings.TrimSpace(environment["HERMES_HOME"]); value != "" {
		envHome = expandHermesHomePath(value, environment)
	}
	home := nativeHome
	if envHome != "" {
		home = envHome
	}
	name, explicit := hermesProfileArgument(argv)
	if !explicit {
		if envHome != "" && filepath.Base(filepath.Dir(envHome)) == "profiles" {
			return envHome
		}
		name = hermesActiveProfile(hermesActiveProfileRoot(nativeHome, envHome))
	}
	if name == "" {
		return home
	}
	if name == "default" {
		return hermesProfileRoot(nativeHome, envHome)
	}
	if !hermesProfileNamePattern.MatchString(name) {
		return home
	}
	profile := filepath.Join(hermesProfileRoot(nativeHome, envHome), "profiles", name)
	if !hermesProfileIsLive(profile) {
		return home
	}
	return profile
}

// hermesProfileArgument finds the profile Hermes's scan_profile_flag would
// take from the arguments after the hermes command. Hermes also steps over
// the values of its own options, which this does not.
func hermesProfileArgument(argv []string) (string, bool) {
	start := -1
	for i, arg := range argv {
		name := strings.ToLower(cleanProcessCommandName(arg))
		if name == "hermes" || name == "hermes-agent" || strings.HasPrefix(arg, "hermes_cli") {
			start = i + 1
			break
		}
	}
	if start < 0 {
		return "", false
	}
	arguments := argv[start:]
	for i, arg := range arguments {
		if arg == "--" {
			break
		}
		if (arg == "-p" || arg == "--profile") && i+1 < len(arguments) {
			value := strings.ToLower(strings.TrimSpace(arguments[i+1]))
			if hermesProfileNamePattern.MatchString(value) || value == "default" {
				return value, true
			}
			break
		}
		if value, found := strings.CutPrefix(arg, "--profile="); found {
			return strings.ToLower(strings.TrimSpace(value)), true
		}
	}
	return "", false
}

// hermesActiveProfile reads the sticky profile name, "" for the default.
func hermesActiveProfile(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "active_profile"))
	if err != nil || !utf8.Valid(data) {
		return ""
	}
	name := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(string(data), "\ufeff")))
	if name == "default" {
		return ""
	}
	return name
}

// hermesActiveProfileRoot mirrors get_default_hermes_root: a HERMES_HOME
// under the platform default belongs to it; any other is a custom root, or
// a profile directory inside one.
func hermesActiveProfileRoot(nativeHome, envHome string) string {
	if envHome == "" {
		return nativeHome
	}
	if relative, err := filepath.Rel(resolvedPath(nativeHome), resolvedPath(envHome)); err == nil &&
		relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return nativeHome
	}
	return hermesProfileRoot("", envHome)
}

// hermesProfileRoot mirrors profile_root_for_env_home: the root that holds
// the profiles a -p argument names.
func hermesProfileRoot(nativeHome, envHome string) string {
	if envHome == "" {
		return nativeHome
	}
	if filepath.Base(filepath.Dir(envHome)) == "profiles" {
		return filepath.Dir(filepath.Dir(envHome))
	}
	return envHome
}

func resolvedPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	if absolute, err := filepath.Abs(path); err == nil {
		return absolute
	}
	return filepath.Clean(path)
}

// hermesProfileIsLive mirrors named_profile_is_live: an existing directory
// holding one of the files that identify a profile, with no tombstone.
func hermesProfileIsLive(profile string) bool {
	if info, err := os.Stat(profile); err != nil || !info.IsDir() {
		return false
	}
	tombstone := filepath.Join(filepath.Dir(profile), ".deleted", filepath.Base(profile))
	if _, err := os.Lstat(tombstone); err == nil {
		return false
	}
	for _, marker := range []string{"config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db"} {
		if _, err := os.Lstat(filepath.Join(profile, marker)); err == nil {
			return true
		}
	}
	return false
}

// hermesPlatformDefaultHome is ~/.hermes, or %LOCALAPPDATA%\hermes on
// Windows, with HERMES_DATA_DIR_SUFFIX appended.
func hermesPlatformDefaultHome(environment map[string]string) string {
	suffix := environment["HERMES_DATA_DIR_SUFFIX"]
	if runtime.GOOS == "windows" {
		base := strings.TrimSpace(environment["LOCALAPPDATA"])
		if base == "" {
			base = filepath.Join(userHomeFromEnvironment(environment), "AppData", "Local")
		}
		return filepath.Join(base, "hermes"+suffix)
	}
	return filepath.Join(userHomeFromEnvironment(environment), ".hermes"+suffix)
}

// userHomeFromEnvironment is Python's Path.home(): HOME, or USERPROFILE on
// Windows, falling back to the account's home.
func userHomeFromEnvironment(environment map[string]string) string {
	name := "HOME"
	if runtime.GOOS == "windows" {
		name = "USERPROFILE"
	}
	if home := environment[name]; home != "" {
		return home
	}
	home, _ := os.UserHomeDir()
	return home
}

var pythonEnvironmentReference = regexp.MustCompile(`\$(\w+|\{[^}]*\})`)

// expandHermesHomePath is Python's os.path.expanduser(os.path.expandvars()):
// a $NAME or ${NAME} of a defined variable expands, any other stays as it is,
// and a leading ~ becomes the user's home.
func expandHermesHomePath(path string, environment map[string]string) string {
	path = pythonEnvironmentReference.ReplaceAllStringFunc(path, func(reference string) string {
		name := strings.Trim(reference[1:], "{}")
		if value, ok := environment[name]; ok {
			return value
		}
		return reference
	})
	if path == "~" || strings.HasPrefix(path, "~/") || (runtime.GOOS == "windows" && strings.HasPrefix(path, `~\`)) {
		return userHomeFromEnvironment(environment) + path[1:]
	}
	return path
}

// hermesManagedDir mirrors managed_scope.get_managed_dir: a non-empty
// HERMES_MANAGED_DIR, else /etc/hermes, when that is a directory.
func hermesManagedDir(environment map[string]string) string {
	dir := strings.TrimSpace(environment["HERMES_MANAGED_DIR"])
	if dir == "" {
		dir = "/etc/hermes"
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return ""
	}
	return dir
}

// decodeHermesDotenv decodes a .env file as Hermes does: UTF-8 with an
// optional byte order mark, or Latin-1 when that fails.
func decodeHermesDotenv(data []byte) string {
	data = []byte(strings.TrimPrefix(string(data), "\ufeff"))
	if utf8.Valid(data) {
		return string(data)
	}
	runes := make([]rune, len(data))
	for i, b := range data {
		runes[i] = rune(b)
	}
	return string(runes)
}

type dotenvAssignment struct {
	name  string
	value string
	// set is false for a line that names a variable without assigning it.
	set bool
}

var dotenvVariable = regexp.MustCompile(`\$\{([^}:]*)(?::-([^}]*))?\}`)

// resolveHermesDotenv expands ${NAME} and ${NAME:-default} the way Hermes's
// _resolve_dotenv_assignments does when a file overrides the environment:
// against lookup, with the file's earlier lines in front of it. A name
// defined but empty expands to empty, not to the default. It returns the
// assignments in file order, without the lines that assign nothing.
func resolveHermesDotenv(assignments []dotenvAssignment, lookup map[string]string) []dotenvAssignment {
	resolved := map[string]*string{}
	var output []dotenvAssignment
	for _, assignment := range assignments {
		if !assignment.set {
			resolved[assignment.name] = nil
			continue
		}
		value := dotenvVariable.ReplaceAllStringFunc(assignment.value, func(reference string) string {
			match := dotenvVariable.FindStringSubmatch(reference)
			if value, ok := resolved[match[1]]; ok {
				if value == nil {
					return ""
				}
				return *value
			}
			if value, ok := lookup[match[1]]; ok {
				return value
			}
			return match[2]
		})
		resolved[assignment.name] = &value
		output = append(output, dotenvAssignment{name: assignment.name, value: value, set: true})
	}
	return output
}

var (
	dotenvMultilineWhitespace = regexp.MustCompile(`^\s*`)
	dotenvWhitespace          = regexp.MustCompile(`^[^\S\r\n]*`)
	dotenvExport              = regexp.MustCompile(`^(?:export[^\S\r\n]+)?`)
	dotenvSingleQuotedKey     = regexp.MustCompile(`^'([^']+)'`)
	dotenvUnquotedKey         = regexp.MustCompile(`^([^=#\s]+)`)
	dotenvEqualSign           = regexp.MustCompile(`^(=[^\S\r\n]*)`)
	dotenvSingleQuotedValue   = regexp.MustCompile(`(?s)^'((?:\\.|[^'\\])*)'`)
	dotenvDoubleQuotedValue   = regexp.MustCompile(`(?s)^"((?:\\.|[^"\\])*)"`)
	dotenvUnquotedValue       = regexp.MustCompile(`^([^\r\n]*)`)
	dotenvInlineComment       = regexp.MustCompile(`\s+#.*`)
	dotenvComment             = regexp.MustCompile(`^(?:[^\S\r\n]*#[^\r\n]*)?`)
	dotenvEndOfLine           = regexp.MustCompile(`^[^\S\r\n]*(?:\r\n|\n|\r|$)`)
	dotenvRestOfLine          = regexp.MustCompile(`^[^\r\n]*(?:\r|\n|\r\n)?`)
	dotenvDoubleQuoteEscape   = regexp.MustCompile(`\\[\\'"abfnrtv]`)
	dotenvSingleQuoteEscape   = regexp.MustCompile(`\\[\\']`)
)

// parseDotenv is python-dotenv 1.2's parser (parse_stream), which Hermes
// loads its .env files with, returning each named binding in file order.
// Python's \s also matches Unicode white space; RE2's matches only ASCII.
func parseDotenv(text string) []dotenvAssignment {
	text = strings.TrimPrefix(text, "\ufeff")
	var assignments []dotenvAssignment
	for position := 0; position < len(text); {
		assignment, named, next := parseDotenvBinding(text, position)
		if named {
			assignments = append(assignments, assignment)
		}
		position = next
	}
	return assignments
}

func parseDotenvBinding(text string, position int) (dotenvAssignment, bool, int) {
	read := func(pattern *regexp.Regexp) ([]string, bool) {
		match := pattern.FindStringSubmatch(text[position:])
		if match == nil {
			return nil, false
		}
		position += len(match[0])
		return match, true
	}
	fail := func() (dotenvAssignment, bool, int) {
		read(dotenvRestOfLine)
		return dotenvAssignment{}, false, position
	}
	read(dotenvMultilineWhitespace)
	if position >= len(text) {
		return dotenvAssignment{}, false, position
	}
	read(dotenvExport)
	var assignment dotenvAssignment
	named := false
	switch {
	case strings.HasPrefix(text[position:], "#"):
	case strings.HasPrefix(text[position:], "'"):
		match, ok := read(dotenvSingleQuotedKey)
		if !ok {
			return fail()
		}
		assignment.name, named = match[1], true
	default:
		match, ok := read(dotenvUnquotedKey)
		if !ok {
			return fail()
		}
		assignment.name, named = match[1], true
	}
	read(dotenvWhitespace)
	if strings.HasPrefix(text[position:], "=") {
		equal, _ := read(dotenvEqualSign)
		assignment.set = true
		// Whitespace after = and then # leaves the value empty and makes the
		// rest of the line a comment.
		if !(len(equal[1]) > 1 && strings.HasPrefix(text[position:], "#")) {
			value, ok := parseDotenvValue(text, &position)
			if !ok {
				return fail()
			}
			assignment.value = value
		}
	}
	read(dotenvComment)
	if _, ok := read(dotenvEndOfLine); !ok {
		return fail()
	}
	return assignment, named, position
}

func parseDotenvValue(text string, position *int) (string, bool) {
	rest := text[*position:]
	switch {
	case strings.HasPrefix(rest, "'"):
		match := dotenvSingleQuotedValue.FindStringSubmatch(rest)
		if match == nil {
			return "", false
		}
		*position += len(match[0])
		return dotenvSingleQuoteEscape.ReplaceAllStringFunc(match[1], func(escape string) string {
			return escape[1:]
		}), true
	case strings.HasPrefix(rest, `"`):
		match := dotenvDoubleQuotedValue.FindStringSubmatch(rest)
		if match == nil {
			return "", false
		}
		*position += len(match[0])
		return dotenvDoubleQuoteEscape.ReplaceAllStringFunc(match[1], decodeDotenvEscape), true
	case rest == "" || rest[0] == '\n' || rest[0] == '\r':
		return "", true
	default:
		match := dotenvUnquotedValue.FindStringSubmatch(rest)
		*position += len(match[0])
		value := dotenvInlineComment.ReplaceAllString(match[1], "")
		return strings.TrimRightFunc(value, isPythonWhiteSpace), true
	}
}

func decodeDotenvEscape(escape string) string {
	switch escape[1] {
	case 'a':
		return "\a"
	case 'b':
		return "\b"
	case 'f':
		return "\f"
	case 'n':
		return "\n"
	case 'r':
		return "\r"
	case 't':
		return "\t"
	case 'v':
		return "\v"
	}
	return escape[1:]
}

// isPythonWhiteSpace is what str.rstrip() strips.
func isPythonWhiteSpace(r rune) bool {
	switch r {
	case ' ', '\t', '\n', '\v', '\f', '\r', 0x1c, 0x1d, 0x1e, 0x1f, 0x85:
		return true
	}
	return r > 0x7f && isJavaScriptWhiteSpace(r) && r != '\ufeff'
}
