# Handoff: go-registry package (branch refactor/sa5-go-registry)

Two one-line edits in `remote/monkeymux/main.go` fall outside the regions this
package owns (lines 481-510 and the agent command/title helpers near 16100).
Both were unavoidable: removing the `agentCommands` and
`agentSessionIDArgumentPattern` tables leaves their only other callers
uncompilable. No logic changed; each is a single-expression swap.

| location | old | new |
|---|---|---|
| `agentToolRelaunchable` (~line 4943) | `_, ok := agentCommands[tool]; return ok` | `return agentRegistry[tool].launch.executable != ""` |
| `agentSessionIDFromArgs` (~line 6019) | `range agentSessionIDArgumentPattern[tool]` | `range agentRegistry[tool].resumeArgPatterns` |

If the owning package rewrites either function, keep the registry lookup.
`main.go:3491` (restore discovery `case "claude", "codex", "opencode", "muse"`)
was left untouched as instructed; it could become a registry flag later.
