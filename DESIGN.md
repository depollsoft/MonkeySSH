---
name: MonkeySSH
description: The mobile SSH workspace for agentic coding — a quiet, dark terminal-native control surface.
colors:
  accent-teal: "#14756C"
  accent-teal-soft: "#58A38C"
  bg: "#0D0D12"
  surface: "#16161D"
  card: "#1C1C26"
  border: "#2A2A3A"
  ink: "#F0F0F5"
  ink-muted: "#8A8A9A"
  on-accent: "#FFFFFF"
  error: "#FF4757"
  warning: "#FFBE00"
  bg-light: "#F8F9FC"
  surface-light: "#FFFFFF"
  border-light: "#E8E8EF"
typography:
  display:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "22px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.5px"
  headline:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "32px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.5px"
  title:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "normal"
  body:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "normal"
  mono:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "normal"
rounded:
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "24px"
  xl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.accent-teal}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.md}"
    padding: "16px 24px"
    typography: "{typography.label}"
  button-outline:
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "16px 24px"
    typography: "{typography.label}"
  button-text:
    textColor: "{colors.accent-teal}"
    padding: "12px 16px"
    typography: "{typography.label}"
  card:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "16px"
  input:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "16px"
  chip:
    backgroundColor: "{colors.card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "6px 12px"
  chip-selected:
    backgroundColor: "{colors.accent-teal-soft}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "6px 12px"
  list-tile:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "8px 16px"
  fab:
    backgroundColor: "{colors.accent-teal}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.lg}"
  bottom-sheet:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.xl}"
  dialog:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.xl}"
---

# Design System: MonkeySSH

## 1. Overview

**Creative North Star: "The Quiet Terminal"**

MonkeySSH is a dark, low-chrome control surface that gets out of its own way. The
shell is near-black and almost silent; the loudest thing on any screen is the
user's work — the terminal, the agent session, the file they're editing. Every
surface, border, and label is tuned to recede so that content reads first.
Signal Teal is the lone voice in the room: it marks the one thing that matters
right now (the primary action, the active window, the focused field) and nothing
else. This is the visual translation of the product's promise — *precise, fast,
trustworthy* — for developers driving real remote work from a phone, often
one-handed.

The system is built from tonal layering, not decoration. Depth comes from three
near-black steps (Void → Slate Surface → Raised Slate) separated by hairline
borders, not from drop shadows or gradients. The single intentional glow — a
soft teal halo on the primary action — is the exception that proves the rule.
Typography is functional and confident: Inter for UI with tight, weighted
headings; JetBrains Mono wherever real terminal or code content lives, so the
monospace voice always signals "this is the machine talking."

This system explicitly rejects the tropes that make tools look unserious or
generic: no consumer-cutesy playfulness, no AI-SaaS cream/pastel with
gradient-text and glassmorphism, no enterprise navy-and-gold formality, and no
default stock-Material look with no point of view. It must read as a credible,
professional SSH client — never a toy terminal.

**The distinctive layer.** What keeps this from being just-another-dark-tool-
with-an-accent is a committed terminal identity. **JetBrains Mono is the display
voice** — screen titles, host names, numerals, and status badges are set in mono
on a strict hairline grid, so the interface looks like the machine it talks to.
A **cursor block ▮** is the recurring brand mark: it punctuates the wordmark,
marks active states, and animates loading and empty states. And because the
brand is *MonkeySSH*, the system carries a dry, terminal-native wit — but only
in the margins (empty states, first-run, the about screen, an optional
message-of-the-day), and only as voice or a crafted monospace mark. The wink is
the reward for looking closely; it never touches the surfaces you rely on under
pressure.

**Key Characteristics:**
- Dark-first, near-black canvas with a hint of blue (`#0D0D12`).
- One accent (Signal Teal) used sparingly as the single signal color.
- Depth by tonal layering + 1px hairline borders, not shadows.
- Functional type: Inter UI, JetBrains Mono for machine/code content.
- Terminal-driven theming: the whole app can re-skin to the active terminal theme.
- Built-in contrast awareness so text stays legible across every theme.
- Mono-display identity: JetBrains Mono sets titles, host names, numerals, and
  status — not just terminal content.
- The cursor block ▮ as the recurring brand mark (wordmark, active, loading,
  empty states).
- Restrained, terminal-native wit confined to the margins — voice and crafted
  mono marks, never a mascot.

## 2. Colors

A near-monochrome dark canvas in cool near-blacks, carrying exactly one
saturated signal (teal) plus two functional status hues (red, amber).

### Primary
- **Signal Teal** (`#14756C`): The single accent, sampled from the app icon.
  Primary buttons, FAB, active tab/indicator, focused input border, selected
  states, links. The one bright thing on a screen — use it where the eye should
  land, nowhere else.
- **Soft Teal** (`#58A38C`): The lighter accent. Selected chips, accent
  gradients, and tints where full Signal Teal would be too loud.

### Neutral
- **Void** (`#0D0D12`): App background / scaffold. The deepest layer.
- **Slate Surface** (`#16161D`): Sheets, dialogs, bottom nav, app surfaces one
  step above the canvas.
- **Raised Slate** (`#1C1C26`): Cards, inputs, chips, popup menus — the raised
  content layer.
- **Hairline** (`#2A2A3A`): All 1px borders and dividers. The primary tool for
  separating layers.
- **Terminal White** (`#F0F0F5`): Primary text and active icons.
- **Muted Steel** (`#8A8A9A`): Secondary text, labels, resting icons. Verify it
  clears 4.5:1 on the surface it sits on; never push body text lighter than this.

> Light theme equivalents exist (`#F8F9FC` bg, `#FFFFFF` surfaces, `#E8E8EF`
> borders, `Colors.black87/54` text) and MonkeySSH also supports themes derived
> entirely from the active terminal palette.

### Tertiary (status)
- **Alert Red** (`#FF4757`): Errors, destructive actions, failure states.
- **Caution Amber** (`#FFBE00`): Warnings and at-risk states.

### Named Rules
**The One Signal Rule.** Signal Teal marks the single most important thing on a
screen and little else. If two elements are both teal, the eye has nowhere to
land — demote one. Its rarity is what makes it work.

**The Layer-Not-Shadow Rule.** Separation comes from the Void → Surface → Raised
Slate ramp plus Hairline borders. Reach for a tonal step or a 1px border before
you reach for elevation.

**The Status-Plus-Shape Rule.** Red and Amber never carry meaning alone. Pair
every status color with an icon, label, or shape so color-blind users and
glance-readers both get the message.

## 3. Typography

**Display Font:** JetBrains Mono (with `ui-monospace, monospace` fallback) — mono is the display voice.
**UI / Body Font:** Inter (with `system-ui, sans-serif` fallback)
**Content / Mono Font:** JetBrains Mono — terminal, code, paths, fingerprints, snippet bodies.

**Character:** The defining move is **monospace as the display voice.** JetBrains
Mono sets the things that identify a screen — titles, host names, numerals,
status badges — so the interface looks like the machine it talks to. Inter
carries the dense, readable middle: body copy, secondary labels, long-form
settings. The two pair on a hard contrast axis (true monospace vs. humanist
sans) and never blur together. The rule is about *role*: mono identifies and
quotes the machine; Inter explains.

### Hierarchy
- **Display** (JetBrains Mono 600, 20–24px, line-height ~1.15, letter-spacing
  -0.5px): The brand/identity voice — screen titles, host names, the wordmark,
  large numerals and status. Mono at title scale is the signature; use it where
  a screen announces what it is.
- **Headline** (Inter 700, 32px / 24px, line-height ~1.1, letter-spacing -0.5px):
  Screen titles and the largest headings. Tight tracking gives weight without
  shouting; the scale never climbs into hero/display territory.
- **Title** (Inter 600, 18–20px, line-height ~1.2): Section headers, app bar
  titles, dialog titles, list group headers.
- **Body** (Inter 400, 16px, line-height ~1.5): Primary reading text in
  Terminal White. Secondary body is 14px in Muted Steel. Cap measure at 65–75ch
  on wide screens.
- **Label** (Inter 600, 14px): Buttons, tabs, chips, emphasis. Weight carries
  emphasis — not size, not color.
- **Mono** (JetBrains Mono 400, 13px, line-height ~1.4): Terminal output, code,
  file paths, fingerprints, snippet bodies, any literal machine text.

### Named Rules
**The Mono-Display Rule.** Titles, host/identifier names, numerals, and status
are set in JetBrains Mono; body and dense explanatory text stay in Inter. Mono
at display scale is the brand — don't swap in Inter for a screen title to
"soften" it, and don't set paragraphs in mono.

**The Casing Register Rule.** Headers inside the app shell — the home panel
titles (`hosts`, `connections`, `keys`, `snippets`) and in-screen section
headers — are lowercase mono, the terminal-native section voice. Full-screen
route titles (AppBar) keep conventional Title Case in mono (`SSH Keys`,
`Settings`), and proper nouns keep their brand case (`MonkeySSH`). Two registers,
one font.

**The Machine-Voice Rule.** Real terminal / code / path / fingerprint content is
set in mono *regular* (13px) — never in Inter. (Display mono is a separate,
deliberate brand register; the prohibition is on setting literal machine output
in a proportional font, and on faking mono for decoration.)

**The Weight-Over-Size Rule.** Emphasize with weight (600/700) before size, and
never with the accent color. Headings stay below display scale; the interface
whispers.

## 4. Elevation

Flat by default. On the dark theme, surfaces sit at elevation 0 and depth is
expressed entirely through the tonal ramp (Void → Slate Surface → Raised Slate)
and 1px Hairline borders. There is no ambient drop-shadow vocabulary. The single
sanctioned shadow is a **teal glow** — a soft halo used only to make the primary
action and FAB feel alive, never to lift a card off the page. The light theme is
allowed restrained, literal elevation (1–4) since shadows read naturally on a
pale ground.

### Shadow Vocabulary
- **Teal Glow** (`color: accent-teal @ alpha 40 (~16%); blur 20; spread 0`):
  Primary buttons, FAB, and special accent elements on the dark theme only. The
  brand's one expressive light effect — used sparingly.
- **Light Elevation** (Material elevation 1–4, neutral shadow): Cards (1), FAB
  (4), elevated buttons (2) on the light theme only.

### Named Rules
**The Flat-By-Default Rule.** Dark surfaces are flat at rest. The only glow is
the teal halo on the primary action. If you're adding a shadow to separate two
dark surfaces, use a tonal step or a Hairline border instead.

## 5. Components

### Buttons
- **Shape:** Rounded 12px (`rounded.md`); padding 24×16px.
- **Primary (FilledButton):** Signal Teal background, white label, Inter 600
  15px, flat (elevation 0) with the teal glow on dark.
- **Secondary (OutlinedButton):** Transparent fill, 1.5px Hairline border,
  Terminal White label.
- **Tertiary (TextButton):** Signal Teal label, no fill, 16×12px padding.
- **Hover / Focus / Pressed:** Keep transitions quick and quiet (≤150ms). Focus
  must be visible for keyboard/switch users — a teal border or ring, not color
  alone.

### Chips
- **Style:** Raised Slate background, Hairline border, 8px radius, Inter 500 13px
  label in Terminal White.
- **State:** Selected chips fill with Soft Teal. Used for filters and quick
  toggles (e.g. host tags, agent pickers).

### Cards / Containers
- **Corner Style:** 16px (`rounded.lg`).
- **Background:** Raised Slate (`#1C1C26`) on dark; white on light.
- **Shadow Strategy:** Flat on dark (elevation 0) — see Elevation. Subtle teal
  glow shadow color only; light theme may use elevation 1.
- **Border:** 1px Hairline, always.
- **Internal Padding:** 16px (`spacing.md`). **Never nest a card inside a card.**

### Inputs / Fields
- **Style:** Filled with Raised Slate, 12px radius, 1px Hairline border, 16px
  padding.
- **Focus:** Border shifts to Signal Teal at 2px. No glow.
- **Error:** Border shifts to Alert Red; pair with a message, never color alone.
- **Placeholder/label:** Muted Steel — verify 4.5:1; don't let hint text fade
  below the contrast floor.

### Navigation
- **Bottom Navigation:** Slate Surface background, Signal Teal active icon on
  a teal-tinted indicator pill, active label in Terminal White, Muted Steel for
  inactive. Labels Inter 12px (600 active / 500 inactive). Every foreground is
  lifted to WCAG AA against what is behind it, which some terminal-derived
  themes need. On wide screens, the remote-window switcher promotes to a side
  sidebar.
- **Vertical bar (iPhone Duo):** where iOS 27.1 runs its vertical bar, the
  same destinations sit in one Raised Slate capsule with a hairline border, and
  screen actions become 44px round keys beside the status cluster.
- **App Bar:** Background matches the scaffold (Void), flat (elevation 0, no
  scrolled-under tint), left-aligned title in **display mono** (JetBrains Mono
  600, ~20px).
- **Tabs:** Signal Teal label + indicator (sized to the label), Muted Steel
  inactive.

### Surfaces (sheets, dialogs, menus)
- **Bottom Sheet / Dialog:** Slate Surface, 20px (`rounded.xl`) — top-only on
  sheets. The window switcher and most quick actions live in bottom sheets for
  one-handed reach.
- **Popup Menu / Tooltip:** Raised Slate, Hairline border, 12px / 8px radius.
- **Snackbar:** Floating, 12px radius, auto-contrasting text.

### Signature System: Terminal-Driven Theming
MonkeySSH's defining trait is that the **entire app theme can be re-derived from
the active terminal theme**. Background, surfaces, text, and borders are computed
by blending the terminal's own colors, and the accent is chosen by a
contrast-aware scorer (preferring a saturated cursor color, otherwise the most
vivid, sufficiently contrasty ANSI color). A built-in readable-text helper picks
black or white per surface so labels never fall below contrast. When building new
surfaces, **consume the resolved `ColorScheme`/`ThemeData` — never hardcode the
hex values above** — so every screen automatically follows both the app default
and any terminal-driven theme.

### Signature Motif: The Cursor Block ▮
A solid block glyph (▮, U+25AE) is MonkeySSH's brand mark — the blinking cursor
of a live terminal, abstracted into identity. Use it:
- **Wordmark:** `monkeyssh ▮` — the block trails the name and blinks slowly
  (≈1.06s; reduced motion → static block).
- **Active state:** a small static block marks the active host / window / tab
  where a dot or check would otherwise sit.
- **Loading:** a blinking block (or a short `▮▯▯`→`▯▮▯` cycle) instead of a
  generic spinner, on terminal-flavored surfaces.
- **Empty states:** the block anchors a crafted mono mark (below).

Keep it Signal Teal or Terminal White, never multicolor. One block per context —
it's punctuation, not wallpaper.

### Empty & First-Run States (where the wit lives)
Empty states are the one place the brand gets to talk. Pattern:
- A **crafted monospace mark** — a prompt, a tiny ASCII monkey, or a block
  cursor — in Muted Steel or Soft Teal.
- A **mono title** stating the fact plainly (`no hosts yet`).
- One line of **dry, terminal-native wit** as the subtitle — the voice of a good
  CLI, not a punchline (e.g. `Nothing to connect to — let's fix that.`).
- A **single, unmistakable primary action** (Signal Teal), plus at most one
  secondary.

The wit never appears in blocking error states, in the terminal, or in host
rows. Serious where it counts; a wink where it doesn't.

### Status & Badges
- Set status text in **mono**, paired with a shape or icon — never color alone
  (The Status-Plus-Shape Rule).
- Connection states read as a small block/dot + a mono label (`connected`,
  `idle`, `offline`): Signal Teal = active, Muted Steel = idle, Alert Red =
  failed (always with an icon).
- Window and agent status pills follow one rule on every screen (Connections,
  the window navigator, the session switcher): Alert Red when the user must
  act (an agent blocked on them, a bell or notification, an error), Caution
  Amber for a warning or a finished turn, Signal Teal while it works. A pill
  is never louder than a row sorted above it, and its small label clears
  4.5:1 (`legiblePillColors` shades a theme fill that does not).

## 6. Do's and Don'ts

### Do:
- **Do** drive every color from the resolved `Theme.of(context).colorScheme`
  (primary, surface, outline, onSurface) so screens track the app theme and
  terminal-driven themes. The hex values here are the default, not literals to
  paste.
- **Do** keep Signal Teal rare — one signal per screen (The One Signal Rule).
- **Do** convey depth with the Void → Slate Surface → Raised Slate ramp and 1px
  Hairline borders before any shadow (The Layer-Not-Shadow Rule).
- **Do** set all real terminal / code / path / fingerprint content in JetBrains
  Mono; set all chrome in Inter.
- **Do** pair every status color with an icon, label, or shape (The
  Status-Plus-Shape Rule), and verify body and label text clears WCAG AA (4.5:1).
- **Do** keep primary actions within one-handed thumb reach (bottom sheets, FAB,
  bottom nav) with ≥44px touch targets.
- **Do** give every animation a `prefers-reduced-motion` fallback and keep
  transitions quick and quiet (≤150ms, ease-out).
- **Do** set screen titles, host names, numerals, and status in display mono;
  keep body and dense explanatory text in Inter (The Mono-Display Rule).
- **Do** use the cursor block ▮ as the one brand mark — Signal Teal or white,
  one per context.
- **Do** let empty states, first-run, the about screen, and an optional MOTD
  carry dry, terminal-native wit; keep everything load-bearing dead serious.

### Don't:
- **Don't** ship generic stock Material with no point of view.
- **Don't** go consumer-cutesy or playful — no bouncy/elastic motion, no toy
  rounded energy.
- **Don't** use AI-SaaS cream/pastel, gradient text (`background-clip: text`), or
  glassmorphism. The one sanctioned gradient is the teal accent gradient on
  genuinely special elements; the one sanctioned glow is the teal halo.
- **Don't** drift enterprise-corporate navy-and-gold, or let the UI read as a
  toy terminal — it must feel like a serious pro tool.
- **Don't** use colored side-stripe borders (`border-left`/`right` > 1px) on
  cards, list items, or callouts. Use full Hairline borders or tonal tints.
- **Don't** nest cards, add a second teal element "for balance," or push muted
  text below 4.5:1 contrast for elegance.
- **Don't** hardcode the hex values above in widgets when a theme token exists.
- **Don't** put jokes, mascots, or wit in error states, the terminal, host rows,
  or anything used under pressure.
- **Don't** render a cartoon monkey or animate the brand bouncily — the monkey is
  voice and a crafted mono mark, not a character.
- **Don't** set body paragraphs in mono or screen titles in Inter — that inverts
  the type system.
