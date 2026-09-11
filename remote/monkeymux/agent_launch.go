package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unicode"
)

const openCodeIdentityPluginSource = `import { openSync, writeSync, closeSync, constants } from "node:fs";
export default {
  id: "monkeymux-identity",
  async tui(api) {
    const expectedPid = Number(process.env.MONKEYMUX_AGENT_PID || 0);
    if (expectedPid && expectedPid !== process.pid) return; // nested opencode inside an agent pane
    let last = "";
    const publish = (id) => {
      if (!id || id === last) return;
      const payload = Buffer.from(JSON.stringify({ tool: "opencode", id, source: "route" }), "utf8").toString("base64url");
      const marker = "\u001b]1337;MonkeyMuxAgent=" + payload + "\u0007";
      for (const path of [process.env.MONKEYMUX_PANE_TTY, "/dev/tty"]) {
        if (!path) continue;
        let fd;
        try { fd = openSync(path, constants.O_WRONLY | constants.O_NOCTTY); writeSync(fd, marker); last = id; return; }
        catch {} finally { if (fd !== undefined) { try { closeSync(fd); } catch {} } }
      }
    };
    const check = () => {
      let route; try { route = api.route.current; } catch { return; }
      if (!route || route.name !== "session") return;
      let info = api.state.session.get(route.params.sessionID);
      const seen = new Set();
      while (info && info.parentID && !seen.has(info.id)) { seen.add(info.id); info = api.state.session.get(info.parentID); }
      if (info && typeof info.id === "string") publish(info.id);
    };
    const timer = setInterval(check, 250);
    try { api.lifecycle.onDispose(() => clearInterval(timer)); } catch {}
    check();
  },
};
`

func runAgentLaunchWrapper(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: monkeymux agent-launch <tool> [--executable <command>] [args...]")
		os.Exit(2)
	}
	tool, original := args[0], args[1:]
	commandName := tool
	if len(original) > 0 && original[0] == "--executable" {
		if len(original) < 2 || original[1] == "" {
			fmt.Fprintln(os.Stderr, "monkeymux: --executable requires a command")
			os.Exit(2)
		}
		commandName, original = original[1], original[2:]
	}
	executable := commandName
	if !filepath.IsAbs(executable) && !strings.ContainsRune(filepath.ToSlash(executable), '/') {
		var err error
		executable, err = exec.LookPath(commandName)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(127)
		}
	}
	if runtime.GOOS == "windows" {
		command := exec.Command(executable, original...)
		command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
		command.Env = os.Environ()
		if err := command.Run(); err != nil {
			if exitError, ok := err.(*exec.ExitError); ok {
				os.Exit(exitError.ExitCode())
			}
			fatal(err)
		}
		return
	}
	self, err := os.Executable()
	if err != nil {
		fatal(err)
	}
	launch, err := prepareAgentLaunch(tool, original, os.Environ(), self)
	if err != nil {
		fatal(fmt.Errorf("prepare %s session integration: %w", tool, err))
	}
	launch.env = withAgentLaunchEnvironment(launch.env, "MONKEYMUX_AGENT_PID", strconv.Itoa(os.Getpid()))
	if tty := resolveAgentLaunchPaneTTY(); tty != "" {
		launch.env = withPaneTTYEnvironment(launch.env, tty)
	}
	if launch.replacedTUIConfig {
		fmt.Fprintln(os.Stderr, "monkeymux: the MonkeyMux identity plugin replaced OPENCODE_TUI_CONFIG for this launch")
	}
	if launch.assigned.ID != "" {
		fmt.Fprint(os.Stdout, encodeAgentIdentityMarker(launch.assigned))
	}
	if err := syscall.Exec(executable, append([]string{commandName}, launch.args...), launch.env); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(126)
	}
}

type preparedAgentLaunch struct {
	args              []string
	env               []string
	assigned          agentIdentity
	replacedTUIConfig bool
}

func prepareAgentLaunch(tool string, args, env []string, executable string) (preparedAgentLaunch, error) {
	launch := preparedAgentLaunch{args: append([]string(nil), args...), env: append([]string(nil), env...)}
	if !agentLaunchToolSupported(tool) {
		return launch, nil
	}
	hookCommand := shellQuote(executable) + " agent-identity-hook --tool " + tool
	var prefix []string
	if tool == "codex" {
		prefix = []string{"-c", codexIdentityHookConfig(hookCommand), "-c", codexIdentityHookTrustConfig(hookCommand)}
	} else {
		directory, err := runtimeDirectory()
		if err != nil {
			return launch, err
		}
		directory, err = filepath.Abs(directory)
		if err != nil {
			return launch, err
		}
		writeJSON := func(relative string, value any) (string, error) {
			data, err := json.Marshal(value)
			if err != nil {
				return "", err
			}
			return writeAgentLaunchFile(directory, relative, string(data)+"\n")
		}
		switch tool {
		case "claude":
			path, err := writeJSON("monkeymux-claude-hooks.json", map[string]any{
				"hooks": map[string]any{"SessionStart": []any{map[string]any{
					"hooks": []any{map[string]any{"type": "command", "command": hookCommand, "timeout": 5}},
				}}},
			})
			if err != nil {
				return launch, err
			}
			prefix = []string{"--settings", path}
		case "copilot", "cursor-agent":
			plugin := "monkeymux-copilot-plugin"
			manifest := "plugin.json"
			hooks := map[string]any{"hooks": map[string]any{"sessionStart": []any{map[string]any{
				"type": "command", "bash": hookCommand, "powershell": "exit 0", "timeoutSec": 5,
			}}}}
			if tool == "cursor-agent" {
				plugin = "monkeymux-cursor-plugin"
				manifest = filepath.Join(".cursor-plugin", "plugin.json")
				hooks = map[string]any{"version": 1, "hooks": map[string]any{"sessionStart": []any{map[string]any{
					"command": hookCommand, "timeout": 5,
				}}}}
			}
			if _, err := writeJSON(filepath.Join(plugin, manifest), map[string]string{"name": "monkeymux-identity", "version": "1.0.0"}); err != nil {
				return launch, err
			}
			if _, err := writeJSON(filepath.Join(plugin, "hooks", "hooks.json"), hooks); err != nil {
				return launch, err
			}
			prefix = []string{"--plugin-dir", filepath.Join(directory, plugin)}
		case "opencode":
			plugin, err := writeAgentLaunchFile(directory, "monkeymux-opencode-identity.mjs", openCodeIdentityPluginSource)
			if err != nil {
				return launch, err
			}
			pluginURL := (&url.URL{Scheme: "file", Path: filepath.ToSlash(plugin)}).String()
			config := map[string]json.RawMessage{}
			merged := false
			for _, value := range env {
				if path, ok := strings.CutPrefix(value, "OPENCODE_TUI_CONFIG="); ok {
					data, err := os.ReadFile(path)
					var existing map[string]json.RawMessage
					if err == nil && json.Unmarshal(data, &existing) == nil && existing != nil {
						config = existing
						merged = true
					} else {
						launch.replacedTUIConfig = true
					}
					break
				}
			}
			var plugins []json.RawMessage
			_ = json.Unmarshal(config["plugin"], &plugins)
			found := false
			for _, plugin := range plugins {
				var value string
				if json.Unmarshal(plugin, &value) == nil && value == pluginURL {
					found = true
				}
			}
			if !found {
				plugin, _ := json.Marshal(pluginURL)
				plugins = append(plugins, plugin)
			}
			config["plugin"], _ = json.Marshal(plugins)
			data, err := json.Marshal(config)
			if err != nil {
				return launch, err
			}
			content := string(data) + "\n"
			name := "monkeymux-opencode-tui.json"
			if merged {
				digest := sha256.Sum256([]byte(content))
				name = fmt.Sprintf("monkeymux-opencode-tui-%x.json", digest[:8])
			}
			path, err := writeAgentLaunchFile(directory, name, content)
			if err != nil {
				return launch, err
			}
			launch.env = withAgentLaunchEnvironment(env, "OPENCODE_TUI_CONFIG", path)
		}
	}
	if flag := agentLaunchSessionIDFlag(tool, args); flag != "" {
		id, err := newAgentLaunchSessionID()
		if err != nil {
			return launch, err
		}
		prefix = append(prefix, flag, id)
		launch.assigned = agentIdentity{Tool: tool, ID: id, Source: "assigned"}
	}
	launch.args = append(prefix, args...)
	return launch, nil
}

// codexIdentityHookTimeoutSec is the hook timeout written into the -c hooks
// override. The trust hash covers it, so both come from this one constant.
const codexIdentityHookTimeoutSec = 5

func codexIdentityHookConfig(command string) string {
	// TOML basic strings share these escapes with JSON, but not Go's \xNN.
	escaped := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\n", "\\n", "\r", "\\r", "\t", "\\t", "\b", "\\b", "\f", "\\f").Replace(command)
	return `hooks.SessionStart=[{hooks=[{type="command",command="` + escaped + `",timeout=` + strconv.Itoa(codexIdentityHookTimeoutSec) + `}]}]`
}

// codexIdentityHookTrustedHash reproduces Codex's hook trust identity
// (codex-rs/hooks/src/engine/discovery.rs hook_hash and
// config/src/fingerprint.rs version_for_toml): the sha256 of the compact,
// recursively key-sorted JSON of the normalised SessionStart handler. Unset
// fields (matcher, commandWindows, statusMessage, additionalContextLimit) are
// omitted, exactly as Codex omits them before hashing.
func codexIdentityHookTrustedHash(command string, timeoutSec int) string {
	var quoted strings.Builder
	encoder := json.NewEncoder(&quoted)
	encoder.SetEscapeHTML(false) // serde_json never escapes <, > or &.
	if err := encoder.Encode(command); err != nil {
		return ""
	}
	identity := `{"event_name":"session_start","hooks":[{"async":false,"command":` +
		strings.TrimSpace(quoted.String()) + `,"timeout":` + strconv.Itoa(timeoutSec) + `,"type":"command"}]}`
	return fmt.Sprintf("sha256:%x", sha256.Sum256([]byte(identity)))
}

// codexIdentityHookTrustConfig pre-trusts exactly the MonkeyMux identity hook
// for this launch, so Codex neither shows "Hooks need review" nor needs
// --dangerously-bypass-hook-trust (which would also bypass review for every
// other hook). Codex merges hooks.state from the session-flags layer. The
// value is an inline table because Codex's -c key parser splits on every dot
// and the state key itself contains "config.toml".
func codexIdentityHookTrustConfig(command string) string {
	return `hooks.state={"/<session-flags>/config.toml:session_start:0:0"={trusted_hash="` +
		codexIdentityHookTrustedHash(command, codexIdentityHookTimeoutSec) + `"}}`
}

func agentLaunchSessionIDFlag(tool string, args []string) string {
	var flag string
	var blockers []string
	switch tool {
	case "claude":
		flag = "--session-id"
		blockers = []string{"--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"}
	case "copilot":
		flag = "--session-id"
		blockers = []string{"--resume", "--continue", "--session-id"}
	case "cursor-agent":
		flag = "--new-session-id"
		blockers = []string{"--resume", "--continue", "--new-session-id"}
	default:
		return ""
	}
	for _, arg := range args {
		if arg == "--" {
			break
		}
		for _, blocker := range blockers {
			if arg == blocker || strings.HasPrefix(arg, blocker+"=") ||
				(len(blocker) == 2 && strings.HasPrefix(arg, blocker)) {
				return ""
			}
		}
	}
	return flag
}

func newAgentLaunchSessionID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[:4], value[4:6], value[6:8], value[8:10], value[10:]), nil
}

func writeAgentLaunchFile(directory, relative, source string) (string, error) {
	path := filepath.Join(directory, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	if data, err := os.ReadFile(path); err == nil && string(data) == source {
		return path, os.Chmod(path, 0o600)
	}
	// Rename a complete file so simultaneous launches never read partial JSON.
	file, err := os.CreateTemp(filepath.Dir(path), ".monkeymux-identity-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.WriteString(source)
	closeErr := file.Close()
	if writeErr != nil {
		return "", writeErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	return path, os.Rename(file.Name(), path)
}

func withAgentLaunchEnvironment(env []string, key, value string) []string {
	result := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if !strings.HasPrefix(entry, key+"=") {
			result = append(result, entry)
		}
	}
	return append(result, key+"="+value)
}

func resolveAgentLaunchPaneTTY() string {
	if path := os.Getenv("MONKEYMUX_PANE_TTY"); path != "" {
		return path
	}
	info, err := os.Stdin.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return ""
	}
	switch runtime.GOOS {
	case "linux":
		path, err := os.Readlink("/proc/self/fd/0")
		if err == nil && strings.HasPrefix(path, "/dev/") && path != "/dev/null" {
			return path
		}
	case "darwin":
		paths, _ := filepath.Glob("/dev/ttys*")
		for _, path := range paths {
			candidate, err := os.Stat(path)
			if err == nil && sameAgentLaunchDevice(info, candidate) {
				return path
			}
		}
	}
	return ""
}

func sameAgentLaunchDevice(a, b os.FileInfo) bool {
	// Stat_t is unavailable on Windows. Reflection keeps the Darwin Rdev
	// comparison in this portable file without platform-specific declarations.
	rdev := func(info os.FileInfo) (uint64, bool) {
		value := reflect.ValueOf(info.Sys())
		if value.Kind() != reflect.Pointer || value.IsNil() || value.Elem().Kind() != reflect.Struct {
			return 0, false
		}
		field := value.Elem().FieldByName("Rdev")
		if field.CanUint() {
			return field.Uint(), true
		}
		if field.CanInt() {
			return uint64(field.Int()), true
		}
		return 0, false
	}
	left, leftOK := rdev(a)
	right, rightOK := rdev(b)
	return leftOK && rightOK && left == right
}

func agentLaunchToolSupported(tool string) bool {
	switch tool {
	case "claude", "codex", "opencode", "copilot", "cursor-agent":
		return true
	}
	return false
}

// Keep offsets into the original command so prefixes and arguments survive
// rewriting byte for byte, including shell quoting and trailing whitespace.
func agentLaunchExecutableOffset(command string) int {
	offset := 0
	for {
		rest := command[offset:]
		trimmed := strings.TrimLeftFunc(rest, unicode.IsSpace)
		offset += len(rest) - len(trimmed)
		if match := leadingCdCommandPattern.FindStringIndex(trimmed); match != nil {
			offset += match[1]
			continue
		}
		if match := leadingEnvPattern.FindStringIndex(trimmed); match != nil {
			offset += match[1]
			continue
		}
		return offset
	}
}

func agentLaunchShellWord(command string) (string, int) {
	var word strings.Builder
	var quote byte
	for i := 0; i < len(command); i++ {
		c := command[i]
		if c == '\\' && quote != '\'' && i+1 < len(command) {
			i++
			word.WriteByte(command[i])
		} else if quote != 0 {
			if c == quote {
				quote = 0
			} else {
				word.WriteByte(c)
			}
		} else if c == '\'' || c == '"' {
			quote = c
		} else if strings.ContainsRune(" \t\r\n;&|<>()", rune(c)) {
			return word.String(), i
		} else {
			word.WriteByte(c)
		}
	}
	if quote != 0 {
		return "", 0
	}
	return word.String(), len(command)
}

func agentLaunchToolFromCommand(command string) string {
	rest := command[agentLaunchExecutableOffset(command):]
	word, end := agentLaunchShellWord(rest)
	if cleanProcessCommandName(word) != "agent-launch" {
		rest = strings.TrimSpace(rest[end:])
		word, end = agentLaunchShellWord(rest)
		if word != "agent-launch" {
			return ""
		}
	}
	tool, _ := agentLaunchShellWord(strings.TrimSpace(rest[end:]))
	if agentLaunchToolSupported(tool) {
		return tool
	}
	return ""
}

func rewriteAgentLaunchCommand(command string) string {
	offset := agentLaunchExecutableOffset(command)
	word, end := agentLaunchShellWord(command[offset:])
	// This parser does not expand shell words. Keep expansion-bearing paths
	// in the shell rather than passing a literal path to --executable.
	if strings.ContainsAny(command[offset:offset+end], "~$`*?[]{}") {
		return command
	}
	tool := agentToolFromCommandName(filepath.Base(word))
	if !agentLaunchToolSupported(tool) {
		return command
	}
	executable, err := os.Executable()
	if err != nil {
		return command
	}
	invocation, ok := shellExecutableCommand(executable)
	if !ok {
		return command
	}
	invocation += " agent-launch " + tool
	if word != tool {
		invocation += " --executable " + shellQuote(word)
	}
	return command[:offset] + invocation + command[offset+end:]
}
