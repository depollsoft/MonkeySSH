package main

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

// Expected bindings are python-dotenv 1.2.4's, the version Hermes locks.
func TestParseDotenvMatchesPythonDotenv(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		text string
		want []dotenvAssignment
	}{
		{"A=1", []dotenvAssignment{{"A", "1", true}}},
		{"export A=2", []dotenvAssignment{{"A", "2", true}}},
		{"  A = 3  ", []dotenvAssignment{{"A", "3", true}}},
		{"A=4 # comment", []dotenvAssignment{{"A", "4", true}}},
		{"A=5#notcomment", []dotenvAssignment{{"A", "5#notcomment", true}}},
		{"A= # empty", []dotenvAssignment{{"A", "", true}}},
		{"A='six'", []dotenvAssignment{{"A", "six", true}}},
		{"A=\"seven\"", []dotenvAssignment{{"A", "seven", true}}},
		{"A='it\\'s'", []dotenvAssignment{{"A", "it's", true}}},
		{"A=\"tab\\tq\\\"x\\\\y\"", []dotenvAssignment{{"A", "tab\tq\"x\\y", true}}},
		{"A=\"multi\nline\"", []dotenvAssignment{{"A", "multi\nline", true}}},
		{"A", []dotenvAssignment{{"A", "", false}}},
		{"A=", []dotenvAssignment{{"A", "", true}}},
		{"#A=1\nB=2", []dotenvAssignment{{"B", "2", true}}},
		{"'A B'=quoted", []dotenvAssignment{{"A B", "quoted", true}}},
		{"A=1\nA=2", []dotenvAssignment{{"A", "1", true}, {"A", "2", true}}},
		{"A=x\r\nB=y\rC=z", []dotenvAssignment{{"A", "x", true}, {"B", "y", true}, {"C", "z", true}}},
		{"A='unterminated\nB=2", []dotenvAssignment{{"B", "2", true}}},
		{"=novalue\nB=3", []dotenvAssignment{{"B", "3", true}}},
		{"A=\"x\" trailing\nB=4", []dotenvAssignment{{"B", "4", true}}},
		{"A=  spaced value  ", []dotenvAssignment{{"A", "spaced value", true}}},
		{"\ufeffA=bom", []dotenvAssignment{{"A", "bom", true}}},
		{"export  B=5", []dotenvAssignment{{"B", "5", true}}},
		{"exportA=6", []dotenvAssignment{{"exportA", "6", true}}},
		{"A=${B}", []dotenvAssignment{{"A", "${B}", true}}},
		{"A=${B:-def}", []dotenvAssignment{{"A", "${B:-def}", true}}},
		{"A=\t", []dotenvAssignment{{"A", "", true}}},
		{"A=1 #c\n#x\n\nB=2", []dotenvAssignment{{"A", "1", true}, {"B", "2", true}}},
		{"A='x' # c", []dotenvAssignment{{"A", "x", true}}},
		{"A=a\\nb", []dotenvAssignment{{"A", "a\\nb", true}}},
		{"A=\"\\u0041\"", []dotenvAssignment{{"A", "\\u0041", true}}},
		{"KEY with space=1", nil},
		{"A=\"x\"\"y\"", nil},
	} {
		if got := parseDotenv(test.text); !reflect.DeepEqual(got, test.want) {
			t.Errorf("%q: got %+v, want %+v", test.text, got, test.want)
		}
	}
}

func TestResolveHermesDotenv(t *testing.T) {
	t.Parallel()
	lookup := map[string]string{"SHELL_SPEED": "2", "EMPTY": ""}
	got := resolveHermesDotenv(parseDotenv(
		"A=${SHELL_SPEED}\n"+
			"B=${MISSING:-4}\n"+
			"C=${EMPTY:-4}\n"+
			"SHELL_SPEED=5\n"+
			"D=${SHELL_SPEED}x\n"+
			"UNSET\n"+
			"E=${UNSET:-6}\n"+
			"F='${A}'\n",
	), lookup)
	want := []dotenvAssignment{
		{"A", "2", true},
		{"B", "4", true},
		// Defined but empty: the default does not apply.
		{"C", "", true},
		{"SHELL_SPEED", "5", true},
		// An earlier line of the file wins over the environment.
		{"D", "5x", true},
		// A line naming a variable without assigning it shadows it as empty.
		{"E", "", true},
		// Hermes expands single-quoted values too.
		{"F", "2", true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestResolveHermesDotenvKeepsLastBinding(t *testing.T) {
	t.Parallel()
	got := resolveHermesDotenv(parseDotenv("A=1\nB=2\nA=3\nB\nC=${A}${B}\n"), map[string]string{"B": "9"})
	// B's bare last line drops it and shadows it as empty for later lines.
	want := []dotenvAssignment{{"A", "3", true}, {"C", "3", true}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func writeHermesTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// hermesTestAccount makes an empty account home, with the base environment
// a process started in it has and no managed scope.
func hermesTestAccount(t *testing.T) (string, string, map[string]string) {
	t.Helper()
	account := t.TempDir()
	defaultHome := filepath.Join(account, ".hermes")
	if runtime.GOOS == "windows" {
		defaultHome = filepath.Join(account, "AppData", "Local", "hermes")
	}
	environment := map[string]string{
		"HOME":               account,
		"USERPROFILE":        account,
		"LOCALAPPDATA":       filepath.Join(account, "AppData", "Local"),
		"HERMES_MANAGED_DIR": filepath.Join(account, "no-managed-scope"),
	}
	return account, defaultHome, environment
}

func environmentSlice(environment map[string]string) []string {
	var entries []string
	for name, value := range environment {
		entries = append(entries, name+"="+value)
	}
	return entries
}

func TestHermesLaunchEnvironmentLayers(t *testing.T) {
	t.Parallel()
	account, defaultHome, environment := hermesTestAccount(t)
	environment["HERMES_TUI_SCROLL_SPEED"] = "2"
	base := environmentSlice(environment)
	speed := func() float64 { return hermesScrollSpeedBase(hermesLaunchEnvironment(base, nil)) }

	if got := speed(); got != 2 {
		t.Fatalf("without a .env: base %v, want the shell's 2", got)
	}
	// A last line that assigns nothing drops the name's earlier lines, and
	// the inherited value stands.
	writeHermesTestFile(t, filepath.Join(defaultHome, ".env"), "HERMES_TUI_SCROLL_SPEED=3\nHERMES_TUI_SCROLL_SPEED\n")
	if got := speed(); got != 2 {
		t.Fatalf("with a bare last line: base %v, want the shell's 2", got)
	}
	// The profile's .env overrides a shell export, and its last line wins.
	writeHermesTestFile(t, filepath.Join(defaultHome, ".env"),
		"HERMES_TUI_SCROLL_SPEED=4\nexport HERMES_TUI_SCROLL_SPEED=3 # faster\n")
	if got := speed(); got != 3 {
		t.Fatalf("with a .env: base %v, want 3", got)
	}
	// The administrator-managed .env overrides both, and expands against
	// what the profile's .env set.
	managed := filepath.Join(account, "managed")
	writeHermesTestFile(t, filepath.Join(managed, ".env"), "HERMES_TUI_SCROLL_SPEED=${HERMES_TUI_SCROLL_SPEED}.5\n")
	environment["HERMES_MANAGED_DIR"] = managed
	base = environmentSlice(environment)
	if got := speed(); got != 3.5 {
		t.Fatalf("with a managed .env: base %v, want 3.5", got)
	}
}

func TestHermesLaunchEnvironmentEmptyValueShadowsFallback(t *testing.T) {
	t.Parallel()
	_, defaultHome, environment := hermesTestAccount(t)
	environment["CLAUDE_CODE_SCROLL_SPEED"] = "3"
	writeHermesTestFile(t, filepath.Join(defaultHome, ".env"), "HERMES_TUI_SCROLL_SPEED=\n")
	if got := hermesScrollSpeedBase(hermesLaunchEnvironment(environmentSlice(environment), nil)); got != 1 {
		t.Fatalf("base %v, want 1: an empty HERMES_TUI_SCROLL_SPEED still shadows CLAUDE_CODE_SCROLL_SPEED", got)
	}
}

func TestHermesHomeForLaunch(t *testing.T) {
	t.Parallel()
	account, defaultHome, environment := hermesTestAccount(t)
	work := filepath.Join(defaultHome, "profiles", "work")
	writeHermesTestFile(t, filepath.Join(work, "config.yaml"), "")
	gone := filepath.Join(defaultHome, "profiles", "gone")
	writeHermesTestFile(t, filepath.Join(gone, "config.yaml"), "")
	writeHermesTestFile(t, filepath.Join(defaultHome, "profiles", ".deleted", "gone"), "deleted\n")
	// A directory without a file that identifies a profile is not one.
	if err := os.MkdirAll(filepath.Join(defaultHome, "profiles", "ghost"), 0o755); err != nil {
		t.Fatal(err)
	}
	custom := filepath.Join(account, "custom")
	writeHermesTestFile(t, filepath.Join(custom, "profiles", "work", ".env"), "")
	hermes := []string{"/venv/bin/python3", "/venv/bin/hermes"}
	with := func(arguments ...string) []string { return append(append([]string(nil), hermes...), arguments...) }

	for _, test := range []struct {
		name       string
		hermesHome string
		active     string
		argv       []string
		want       string
	}{
		{name: "default", argv: with(), want: defaultHome},
		{name: "flag", argv: with("-p", "work"), want: work},
		{name: "long flag", argv: with("--tui", "--profile", "Work"), want: work},
		{name: "flag with equals", argv: with("--profile=work"), want: work},
		{name: "flag after subcommand", argv: with("chat", "-p", "work"), want: work},
		{name: "flag after --", argv: with("--", "-p", "work"), want: defaultHome},
		{name: "flag default", active: "work", argv: with("-p", "default"), want: defaultHome},
		{name: "deleted profile", argv: with("-p", "gone"), want: defaultHome},
		{name: "ghost profile", argv: with("-p", "ghost"), want: defaultHome},
		{name: "sticky", active: "work\n", argv: with(), want: work},
		{name: "sticky default", active: "default", argv: with(), want: defaultHome},
		{name: "sticky without argv", active: "work", want: work},
		{name: "module", argv: []string{"python3", "-m", "hermes_cli.main", "-p", "work"}, want: work},
		{name: "spaces in path", argv: []string{filepath.Join(account, "Jane Doe", "Scripts", "hermes.exe"), "-p", "work"}, want: work},
		{name: "profile HERMES_HOME", hermesHome: work, active: "ghost", argv: with(), want: work},
		{name: "custom root", hermesHome: custom, argv: with("-p", "work"), want: filepath.Join(custom, "profiles", "work")},
		{name: "custom root HERMES_HOME", hermesHome: custom, argv: with(), want: custom},
		{name: "tilde", hermesHome: "~/custom", argv: with(), want: custom},
		{name: "variable", hermesHome: "$HOME/custom", argv: with(), want: custom},
	} {
		t.Run(test.name, func(t *testing.T) {
			activePath := filepath.Join(defaultHome, "active_profile")
			_ = os.Remove(activePath)
			if test.active != "" {
				writeHermesTestFile(t, activePath, test.active)
			}
			lookup := map[string]string{}
			for name, value := range environment {
				lookup[name] = value
			}
			if test.hermesHome != "" {
				lookup["HERMES_HOME"] = test.hermesHome
			}
			if got := hermesHomeForLaunch(lookup, test.argv); filepath.Clean(got) != filepath.Clean(test.want) {
				t.Fatalf("home %q, want %q", got, test.want)
			}
		})
	}
}
