# Product

## Register

product

## Users

Remote developers who run modern coding agents (Claude Code, Copilot CLI, Codex,
OpenCode, Antigravity, Cursor Agent, and others) and need to keep that work
moving from a phone, away from a laptop. They are comfortable in a terminal and
expect power: they connect to a box, attach to a persistent MonkeyMux/tmux
workspace, open an agent as a native chat or a terminal, resume the right agent
session, switch remote windows, browse and edit files over SFTP, forward ports,
and paste commands safely. Their context is mobile and often one-handed, on the
move, between meetings, or away from their desk, so speed, reach, and trust
matter more than decoration.

## Product Purpose

MonkeySSH is the mobile SSH workspace for agentic coding. It exists to make
serious remote development practical from a phone: native chat windows for
coding agents, a real xterm-256color terminal, an SFTP workspace, MonkeyMux/tmux
remote windows, and launch, resume, and update flows for the agents themselves,
without requiring a laptop or cloud sync. Success is a developer reconnecting and
being back in the right agent conversation, in the right window, in seconds, then
staying productive with gestures, modifier keys, snippets, and clickable paths.
It is local-first and private by default (PIN/biometrics, on-device storage,
host-key verification, encrypted transfers, opt-in telemetry that starts off).
One connected native chat is free; the Pro tier covers parallel chats, launch
presets, Agent Management, and multi-device workflows.

## Brand Personality

Precise, fast, trustworthy. Terminal-native and unmistakably a serious pro tool
— the voice of a sharp command-line utility, not a consumer app. Modern hacker
aesthetic in the lineage of Termius: confident, dense, and quiet, letting the
work (terminal, files, agents) be the loudest thing on screen.

The "Monkey" brand earns one extra note that a generic SSH client can't: a
**restrained, terminal-native wit** — the dry humor of a well-crafted CLI's
`--help`, an easter egg, or a message-of-the-day. The wink lives only in the
margins (empty states, first-run, the about screen, the wordmark, loading
lines) and only as voice or a crafted monospace mark — never a cartoon mascot,
never bouncy motion. Anything a user touches under pressure (terminal, host
rows, SFTP, blocking errors) stays dead serious and fast. Personality is the
reward for looking closely; it never gets in the way of the work.

## Anti-references

- Generic stock Material — default components with no point of view.
- Consumer-cutesy — cartoon mascots, bouncy/elastic motion, rounded toy energy.
  (Dry, terminal-native wit in the margins is welcome; cartoon-cute is not.)
- AI-SaaS cream/pastel with gradient text and glassmorphism — the 2026 slop look.
- Enterprise-corporate navy-and-gold — stiff, "B2B dashboard" formality.
- A toy terminal — it must read as a credible, professional SSH client.

## Design Principles

- **One-handed by default.** Primary actions are reachable and operable with a
  thumb on a phone in the field. Reach, target size, and bottom-anchored
  affordances are first-class, not afterthoughts.
- **The work is the loudest thing.** Chrome serves the content. The terminal,
  SFTP browser, and editor get the space and contrast; navigation and decoration
  recede so the user's session is always the focal point.
- **Expert confidence, not hand-holding.** Respect that users are power users:
  dense, fast, keyboard- and gesture-friendly, with shortcuts and presets over
  wizards. Guidance appears where it prevents mistakes, then gets out of the way.
- **Trust is visible.** Security and privacy state — host-key verification,
  lock/auth, encryption, telemetry-off — is legible and reassuring at a glance,
  never buried or implied.
- **Cohesion over novelty.** One system, applied consistently across every
  screen. Shared spacing, type, color roles, states, and component patterns beat
  per-screen invention; consistency is the feature.

## Accessibility & Inclusion

Target WCAG AA contrast on all text, including terminal chrome and muted
secondary labels (the common failure is light-gray body text on tinted dark
surfaces). Respect `prefers-reduced-motion` with a calm fallback for every
animation. Never rely on color alone to convey status — badges and alerts carry
shape, icon, or text as well — so the UI works for color-blind users. Maintain
comfortable one-handed reach and ≥44px touch targets on mobile. Support light,
dark, and terminal-driven themes, keeping contrast and legibility intact across
all of them.
