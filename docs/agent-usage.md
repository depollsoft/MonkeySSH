# Agent account usage

Agent Management starts account usage checks as soon as installed agents are
discovered, alongside upstream version checks. Windows version probes and
upstream metadata lookups run with up to four workers per batch. POSIX version
probes and usage readers also run concurrently. Usage
checks do not block installation or update controls. Refreshing the screen or
re-checking a runtime requests usage again. In Agent Management, usage is shown only for
agent CLI rows; ACP adapters show installation and version information. These
are account allowances, not usage attributed to an individual conversation.
Overlapping usage requests for the same installed rows and executable paths
share one in-flight check, including retryable failures. Changed selections wait
for the active check and then request their own results. Cached usage is reused
only for the same SSH session and agent executable path. ACP adapters do not request usage.

Every supported agent has a reader:

| Agent | Source and reported information |
| --- | --- |
| Claude Code | Existing host OAuth credentials and the account usage endpoint. Reports five-hour, weekly, and model-specific windows, including Fable weekly allowances when returned. |
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

Successful snapshots are reused for five minutes for Claude and two minutes for
other agents, within the same SSH session and executable path. Reading one
agent preserves the other agents' cached snapshots and reset markers. Sign-in
and transient failures remain retryable unless throttling is active.

HTTP `Retry-After` is retained as a sanitized relative duration, accepting seconds
or an HTTP date and bounding malformed/extreme input to at most seven days.
Rate-limit cooldowns start at five minutes, then grow to 10, 20, and 30 minutes
on repeated throttling; a longer server deadline wins. Cooldown metadata is
bounded and shared per saved host and agent, so switching windows, opening Agent
Management, changing an executable path, or reconnecting cannot immediately
repeat the blocked check. Quota values themselves remain session-scoped. Manual
refresh and elapsed quota resets do not bypass an active cooldown, including
partial multi-provider responses. A fully successful response clears backoff;
unrelated or partially failed responses cannot shorten it.

The manager shows the next allowed usage-check time. This is a usage-endpoint
throttle, not an indication that the account's model allowance is exhausted.
No extra live request is needed to display the retry time. Cooldowns and caches
stay in memory only; no credentials or raw response headers are persisted.
A passed quota reset can bypass an otherwise fresh success snapshot once, but
never a throttle. The screen
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

## MonkeyMux usage rings · Pro

Claude Code, Codex, Antigravity, and Grok Build can show remaining account
allowances around the current agent icon in MonkeyMux's existing bottom bar or
tablet sidebar. **Zero used means a full meter.** As usage grows, the colored arc
shrinks: 23% used leaves 77% filled, and 100% used leaves an empty track.

Only actual reported quotas occupy the circle:

- One quota uses the whole circle. This includes Codex accounts that report a
  weekly limit but no account-wide five-hour limit, and Grok's included credits.
- Two quotas use the top and bottom halves. For Claude Code and Codex, the
  five-hour allowance stays above the account-wide weekly allowance.
- Antigravity exposes its numerical quota groups as separate, equal segments.
  Group positions use stable label order rather than guessing an active model.
  More than two reported groups divide the circle into additional segments.

There are no dashed placeholders or empty halves for unreported quotas. A
reported zero remains a real empty meter; no reported numerical allowance means
no ring. Provider labels and percentages are available to accessibility services.
Rings add no tap action, percentage label, or bar row. Native-chat badges and
window-switcher gestures are preserved.

**Options > Show usage rings** controls the feature. It defaults on for Pro and
is saved app-wide. Free accounts see the Pro badge and upgrade flow rather than
rings; no usage-ring requests run without Pro. The saved preference loads before
any read, so a stored opt-out cannot briefly start a probe. Losing Pro hides the
rings and stops polling without overwriting the preference.

A visible, connected, foreground icon requests only its agent's quotas. The
initial path/version probe targets that CLI and never fetches upstream version
metadata or installs anything. Claude refreshes normally every five minutes;
other agents use two minutes. Refreshes honor the shared cache and longer provider
cooldowns, with a bounded refresh at a reported reset only when not throttled.
Hiding the bar, covering the terminal route, disabling rings, disconnecting, or
backgrounding the app stops scheduled checks. Already-started requests remain
bounded; late results cannot update a different agent or disposed subscription.
Session identity separates cached quotas after reconnects.

Claude/Codex model-specific caps are not substituted for account-wide quotas.
Grok uses the reported included-credit percentage; on-demand spending caps and
prepaid balances are not mixed into that meter. Antigravity uses the numerical
groups returned by the same reader as Agent Management. Duplicate labels,
unlimited allowances, balances without a total, unreported percentages, and
elapsed resets do not produce a guessed percentage. An elapsed quota is removed
until fresh data arrives, never refilled speculatively.

These are host-account allowances, not consumption attributed to the current
conversation. Pane-local credential overrides are not resolved. Multi-provider
tools such as Pi and OpenCode still need an explicit active-account selection
rather than a guess from all saved credentials. Usage values are not added to
telemetry or diagnostics; only the existing allowlisted paywall feature token is
registered.

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

Fable weekly usage comes from the OAuth usage response's `limits` entries with
`kind: weekly_scoped` and `scope.model.display_name: Fable` (also accepts versioned
Fable names). Its `percent` and `resets_at` are displayed directly; no allowance
is inferred from the overall weekly percentage or plan name. This projection
matches the installed Claude Code 2.1.268 `/usage` reader. Accounts without a
reported Fable allowance show no Fable bar. Anthropic describes plan eligibility
in [Claude Fable models on your plan](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).
Authenticated Fable-specific reads still need verification; the parser and native
preview have fixture coverage.
