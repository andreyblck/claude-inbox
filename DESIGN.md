# Design

The product is read at a glance, twenty times a day, out of the corner of an eye.
Every rule below exists to protect that one moment.

## What each surface can actually render

| Surface | Can | Cannot |
|---|---|---|
| Menu bar dropdown (`MenuBarExtra`) | native menu rows: icon, title, subtitle, shortcut, `alternate` on ⌥, sections, submenus | custom views, colour — **icons are template-rendered, monochrome, system-controlled** |
| Raycast window (`List` + detail) | two-pane layout, tinted icons, accessories, markdown, metadata panel, full keyboard map | live animation, arbitrary layout |
| `Form`, `Detail`, `Grid` | structured input and documents | — |

So "beautiful" does not live in the menu bar. The menu bar is **restraint**: monochrome,
narrow, glanceable. The visual design lives in the window that a hotkey opens.
Fighting this produces exactly the mush we are trying to avoid.

## State model

One vocabulary, shared by `bridge/` and the UI. Nothing renders a state not in this table.

| State | Means | Bar glyph | List tint |
|---|---|---|---|
| `blocked.permission` | waiting for allow / deny | lock | Yellow |
| `blocked.question` | waiting for a choice | question mark | Yellow |
| `blocked.plan` | waiting for plan approval | list | Yellow |
| `blocked.dialog` | needs the terminal (trust, MCP consent) — cannot be answered here | exclamation | Orange |
| `working` | busy, nothing needed | filled circle | Blue |
| `idle` | turn finished, nothing asked | hollow circle | Secondary |
| `done` | session finished | check | Green |
| `failed` | ended with an error | cross | Red |

Only the four `blocked.*` states are "you". Everything else is weather.

## Menu bar

The bar item answers one question in under 200 ms: **am I needed right now?**

```
needs you      ⬤2      glyph + count, nothing else
just working   ⬤       glyph, no number
nothing        ○       hollow glyph
```

Never put a project name or a message in the bar. The count is the whole message.
Colour is unavailable anyway (template rendering), so states differ by glyph shape —
which is also how the system's own menu extras behave.

Dropdown, at most three sections, each capped at five rows:

```
Waiting for you
  🔒  skyaccess-api · run rm -rf dist              ⌘1
  ❓  wt-5608 · pick one of 3                      ⌘2
Running
  ⬤  skyaccess-web · pull ▸ clean              4m
  ⬤  tarot · track                            12m
  ⋯  3 more                                        ▸
Recently finished
  ✓  morgan · clean                          just now
  ──────────────────────────────────────────────────
  Open Inbox                                      ⌘⇧C
  Preferences…
```

Rules that keep it from turning into mush:

1. **One line per row. Never wraps.** `<glyph> <project> · <what>` plus a right-hand
   `subtitle` for time or shortcut. If it does not fit, it gets truncated, not folded.
2. **Project** = basename of `cwd` (or the session name when set), 18 chars max.
   Never a path, never a UUID.
3. **What** = a lowercase verb phrase, 28 chars max: `run rm -rf dist`, `pick one of 3`,
   `approve plan`. For a running session it is the phase, not the tool.
4. **Five rows per section**, the rest collapse into a `⋯ N more` submenu.
5. **Empty sections vanish.** No "Nothing here" placeholders in a menu.
6. **⌘1…⌘9 belong to the *Waiting* section only.** They open the inbox on that
   row; holding ⌥ turns the row into **Approve**. Opening is the safe default —
   a tool call must never be allowed by a misclick in a menu.
7. `alternate` (⌥) on an approve row = "allow and stop asking for this tool here".
8. No emoji in production rows — Raycast `Icon.*` maps to SF Symbols and looks native;
   emoji do not.

## Inbox window

Two panes. Left: what. Right: enough context to decide without leaving.

```
┌ Search ─────────────────────────────┐┌ Detail ──────────────────────────┐
│ WAITING FOR YOU                     ││  Run a shell command             │
│ 🔒 skyaccess-api      permission 2m ││                                  │
│ ❓ wt-5608            question   6m ││  ```                             │
│ 📋 tarot              plan      11m ││  rm -rf dist && npm run build    │
│                                     ││  ```                             │
│ RUNNING                             ││  Recently: read 4 files, ran     │
│ ⬤ skyaccess-web  pull ▸ clean    4m ││  tsc, edited deploy.sh           │
│ ⬤ morgan         track          12m ││  ──────────────────────────────  │
│                                     ││  Project      skyaccess-api      │
│ FINISHED                            ││  Worktree     wt-5608            │
│ ✓ english-blck   done      just now ││  Model        opus-5             │
│                                     ││  Mode         default            │
└─────────────────────────────────────┘└──────────────────────────────────┘
  ↵ Approve   ⌘⇧D Deny   ⌘R Refresh   ⌘K Actions
```

- Accessories carry time and phase as tags, never inside the title.
- Detail is markdown: the ask first, the command in a fenced block, then a two-line
  "what this session just did" reconstructed from the transcript, then metadata.
  The question a person actually has is *"what has it been doing?"* — answer it there.
- `List.EmptyView`: "Nothing needs you" with a calm icon. This is the most-seen state;
  it must feel like a finished screen, not an error.

### Keyboard

Raycast reserves `⌘↵` and `⌘⌫` and strips them from an `Action` **silently** — the
action still renders, it just never fires. Approve is therefore the primary action
(Raycast binds `↵` to the first one by itself) and destructive actions carry an
explicit `⌘⇧` shortcut.

## Copy

- No jargon from the machine: never `PreToolUse`, `tool_input`, `hook`, `session_id`
  in primary text. They belong in metadata, if anywhere.
- Times are relative and compact: `2m`, `1h`, `just now`.
- Questions are shown as the model wrote them, trimmed to one line in the list and
  in full in the detail pane.

## Latency

- No 10-second wait for a state change: the bridge kicks
  `raycast://…?launchType=background` after each event, so the menu bar redraws in
  under a second. The `interval` poll is only a safety net.
- Optimistic UI: the verdict file is written and the row disappears immediately.
  No spinner on a local file write.

## Where this design stops

A native panel in the menu bar — rounded card, live progress, avatars — is not
possible in Raycast at all. That needs `NSStatusItem` + a SwiftUI popover in a real
app. The directory protocol is deliberately UI-agnostic so such an app could read the
same state later without touching `bridge/`.

## Usage and accounts

Usage is weather, not a task, so it never competes with the sessions that need you.

- **Menu bar**: usage earns **no space** in the bar itself until it matters. Below
  the threshold it is one row at the bottom of the dropdown, above the separator:
  `5h 38% · 7d 71% · resets in 2h`. At or above the threshold the bar glyph itself
  changes — that is the single case where a number outranks the waiting count.
- **Rings, not bars**: `getProgressIcon(fraction, tint)` from `@raycast/utils` gives
  a native-looking circular indicator for a list accessory. Tint follows the same
  scale everywhere: under 70 secondary, 70–90 yellow, above 90 red.
- **Always show the age of the number.** It only advances while a session is
  talking, so a stale reading is normal, not a bug: `7d 71% · 12m ago`. A display
  that hides its own staleness is worse than no display.
- **Account chip**: the short handle before the `@`, plus the config-directory label
  when more than one account is configured. Never the full email, never a UUID.
- **Switching is an action on the next task, not on the running ones.** The copy
  says so: "Next task uses <account>", never "switched".

Auto-rotation at a threshold is off by default and stays a deliberate choice.
Owning several accounts and picking the right one per task is ordinary; wiring a
rotation whose purpose is to carry on past one plan's limit is the part that reads
as working around the limit, and that is a terms question rather than a technical
one. The switcher is built so either policy works; the product does not pick the
aggressive one on the user's behalf.
