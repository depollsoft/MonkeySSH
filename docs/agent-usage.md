# Agent account usage

Agent Management starts account usage checks as soon as installed agents are
discovered, alongside upstream version checks. Windows version probes and
upstream metadata lookups run with up to four workers per batch. POSIX version
probes and usage readers also run concurrently. Usage
checks do not block installation or update controls. Refreshing the screen or
re-checking a runtime requests usage again. CLI and ACP rows share the matching
agent's account snapshot. These are account allowances, not usage attributed to
an individual conversation.
Overlapping usage requests share one in-flight check, including retryable
failures. Standalone Claude, Pi, and Antigravity ACP adapters can read account
usage without a separate CLI installation.

Every supported agent has a reader:

| Agent | Source and reported information |
| --- | --- |
| Claude Code | Existing host OAuth credentials and the account usage endpoint. Reports five-hour, weekly, and model-specific windows. |
| Codex | Installed CLI's `account/rateLimits/read` app-server method. Reports every returned bucket and earned resets available. Never redeems a reset. |
| Copilot CLI | Installed CLI's `account.getQuota` stdio method. Reports allowances, unlimited categories, resets, and paid overage availability. |
| OpenCode | Its saved provider accounts. Reads the applicable provider quota endpoint for each account. |
| Antigravity | An already-running CLI's local `RetrieveUserQuotaSummary` endpoint. Reports all enabled quota groups and reset times. Shows a start-agent hint when no running CLI is found. |
| Cursor Agent | Its existing access token and `DashboardService/GetUsageLimitPolicyStatus`. Reports access restrictions and the supplied reset time. Does not infer a percentage or remaining allowance from that status. |
| Pi | Its saved provider accounts. Reads the applicable provider quota endpoint for each account. |
| Hermes | Its saved provider accounts and credential pool, deduplicated by credential. Includes Nous subscription, purchased-credit balances, and member spending caps when reported. |
| OpenClaw | Installed CLI's `status --usage --json`. Preserves provider quotas, supported USD billing figures, resets, and individual provider failures. |
| Grok Build | Its signed-in account and the credits billing endpoint. Prefers current credit percentage and reset period; keeps on-demand spending and prepaid balances separate. |

The OpenCode, Pi, and Hermes readers support Anthropic OAuth, OpenAI/Codex OAuth,
GitHub Copilot OAuth, Google Antigravity/Gemini CLI OAuth, OpenRouter keys, and
Nous OAuth where those credentials are present in the tool's store. Other saved
providers explicitly report that their quota is not available through this
reader. A failed provider does not hide successful providers. Multiple saved
accounts for a provider receive anonymous account numbers; no emails or account
identifiers return to the app.

The credential stores are OpenCode's `$XDG_DATA_HOME/opencode/auth.json`
(default `~/.local/share/opencode/auth.json`), Pi's
`$PI_CODING_AGENT_DIR/auth.json` (default `~/.pi/agent/auth.json`), and Hermes's
`$HERMES_HOME/auth.json` (default `~/.hermes/auth.json`). These readers inspect
saved accounts, including inactive accounts. OpenCode also honors its
`OPENCODE_AUTH_CONTENT` override before reading the file. They do not resolve project-specific
configuration, run key-generating shell commands, or discover keys supplied only
through other environment variables or an external credential plugin. An empty saved
store is reported as such, not as zero usage. Unreadable or malformed stores
report an unavailable check; UTF-8 byte-order marks are accepted.

Claude also supports `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR`, and the default
macOS Claude Code keychain entry. Cursor supports `CURSOR_AUTH_TOKEN`, its default
macOS keychain entry, and its platform-specific auth file. Grok uses `GROK_HOME`
or `~/.grok`. Expired tokens require signing in through the agent itself; the
direct credential reader never refreshes tokens or changes authentication configuration.
Claude and Cursor environment-token overrides bypass credential files and
keychain reads, including when those stores cannot be read.
The installed CLIs may maintain their own authentication sessions when queried.

Successful and throttled checks stay in memory for two minutes per SSH connection.
Sign-in failures, transient failures, and partial snapshots with failed accounts
can retry immediately unless a provider has throttled the check. Throttling holds
the agent snapshot for two minutes, including partial results. A passed reset
bypasses other cached snapshots. The screen
shows when usage was checked and labels past reset times without claiming the
allowance has replenished. Missing reset times remain explicit. Rows with many
quotas show a count of additional details that are available by expanding the row.
Failed provider notices also stay compact until expanded. A single screen-level
live region announces when account usage checks finish.

Percentage quotas include a bar filled to the percentage remaining. Exhausted
allowances show an empty bar; unlimited and unknown allowances have no bar.

The remote reader requires Node.js and uses built-in libraries. No package is
installed or updated. Codex, Copilot, and OpenClaw start temporary read-only CLI
processes without sending prompts. Antigravity reuses a running process; it does
not start an agent session. Requests and subprocesses have time limits. Windows
receives the reader through SSH standard input to stay within command-line limits.
The Windows launcher loads the same user profile PATH as version detection,
including fnm, and falls back to Node beside a detected agent launcher. If Node
cannot be found, the row reports that requirement explicitly. npm `.ps1`, `.cmd`,
and `.bat` launchers run through PowerShell with a process-local execution-policy
bypass, matching version detection.
POSIX hosts likewise report missing Node.js separately from provider failures.

Abandoned agent probes explicitly close their SSH channels, including commands
that ignore end-of-input and channels that finish opening after a timeout.
This prevents those probes from retaining session slots on the SSH connection.
If every agent reports `SSHChannelOpenError`, the failure precedes agent
execution. Reconnect the host to test with a fresh SSH connection; signing in to
an agent does not resolve a channel-open failure.

Credentials, raw responses, and provider error text stay on the SSH host. Only
normalized quota figures and status records return to MonkeySSH. Usage is not
persisted or sent to telemetry. Diagnostics record built-in agent IDs, statuses, window/notice counts, aggregate
status counts, platform, connection ID, and exit status, never quota figures or
credentials. Provider endpoints that are not
public API contracts can change independently of MonkeySSH; failures remain
visible and can be retried.

## Implementation references

- [Codex app-server rate limits](https://developers.openai.com/codex/app-server)
- [Copilot SDK RPC schema](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/rpc.ts)
- [OpenCode provider authentication](https://opencode.ai/docs/providers/)
- [Pi authentication storage](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/auth-storage.ts)
- [Hermes account usage readers](https://github.com/NousResearch/hermes-agent/blob/main/agent/account_usage.py)
- [Hermes Nous account schema](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/nous_account.py)
- [OpenClaw status command](https://docs.openclaw.ai/cli/status)
- [OpenClaw usage tracking](https://docs.openclaw.ai/concepts/usage-tracking)
- [Antigravity usage command](https://www.antigravity.google/docs/cli/commands/usage)
- [Grok Build billing schema](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs)

Cursor's reader follows the credential storage and generated Connect RPC schema
in the installed 2026.09.08 CLI. Antigravity's local protocol is also cross-checked
against its CLI and the [CodexBar reader](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift).
Contract fixtures cover every agent. Live account checks have succeeded locally
for Claude, Codex, Copilot, OpenCode, and Pi. Authenticated live checks for the
remaining providers and Windows hosts still need suitable accounts/hosts.
