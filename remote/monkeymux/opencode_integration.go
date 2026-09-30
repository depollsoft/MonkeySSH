package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// V2 replaces arrays when merging the inline config. Copy the global plugin
// declarations before appending ours so the user's plugins remain enabled.
func openCodeGlobalCLIPlugins(env []string) (json.RawMessage, error) {
	value := func(key string) string {
		for _, entry := range env {
			if v, ok := strings.CutPrefix(entry, key+"="); ok {
				return v
			}
		}
		return ""
	}
	directory := value("OPENCODE_CONFIG_DIR")
	if directory == "" {
		root := value("XDG_CONFIG_HOME")
		if root == "" {
			home := value("HOME")
			if home == "" {
				home, _ = os.UserHomeDir()
			}
			root = filepath.Join(home, ".config")
		}
		directory = filepath.Join(root, "opencode")
	}
	data, err := os.ReadFile(filepath.Join(directory, "cli.json"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var config map[string]json.RawMessage
	if err := json.Unmarshal(normalizeOpenCodeJSONC(data), &config); err != nil {
		return nil, fmt.Errorf("read OpenCode cli.json: %w", err)
	}
	return config["plugins"], nil
}

// cli.json accepts comments and trailing commas. Preserve strings while
// removing only those extensions before passing the document to encoding/json.
func normalizeOpenCodeJSONC(data []byte) []byte {
	result := append([]byte(nil), data...)
	quoted, escaped := false, false
	for i := 0; i < len(result); i++ {
		c := result[i]
		if quoted {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				quoted = false
			}
			continue
		}
		if c == '"' {
			quoted = true
			continue
		}
		if c != '/' || i+1 >= len(result) {
			continue
		}
		switch result[i+1] {
		case '/':
			for i < len(result) && result[i] != '\n' && result[i] != '\r' {
				result[i] = ' '
				i++
			}
		case '*':
			end := i + 2
			for end+1 < len(result) && !(result[end] == '*' && result[end+1] == '/') {
				end++
			}
			if end+1 >= len(result) {
				return data // Leave invalid input for the JSON decoder to reject.
			}
			for ; i <= end+1; i++ {
				result[i] = ' '
			}
			i--
		}
	}
	quoted, escaped = false, false
	for i, c := range result {
		if quoted {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				quoted = false
			}
		} else if c == '"' {
			quoted = true
		} else if c == ',' {
			j := i + 1
			for j < len(result) && strings.ContainsRune(" \t\r\n", rune(result[j])) {
				j++
			}
			if j < len(result) && (result[j] == ']' || result[j] == '}') {
				result[i] = ' '
			}
		}
	}
	return result
}
