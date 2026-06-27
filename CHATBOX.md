# CHATBOX.md — Reproducing the Claude CLI textual interface in Crysterm

This document collects the findings of an analysis of the **Claude Code CLI** (Anthropic's
official terminal client, version **2.1.195**, a 214 MB compiled Mach-O binary with an embedded
JavaScript/Ink+React+Yoga TUI), and lays out a concrete plan for implementing an equivalent
"chat box" interface in **Crysterm**.

> **Provenance / confidence.** Claude Code is closed-source. These findings were reconstructed by
> mining the embedded JS blob inside the binary (`strings` for ASCII, raw UTF-8 byte scans for
> glyphs) plus known runtime behavior. String/byte counts are *evidence of presence*, not exact
> UI specs. Items marked _(observed)_ come from runtime behavior; _(mined)_ come from the binary.
> Anything uncertain is flagged. Verify against a live `claude` session + `/help` before relying
> on a detail.

---

## Part 1 — Anatomy of the Claude CLI interface

The screen, top to bottom, is:

```
┌─ scrollback transcript (grows upward, scrollable) ─────────────────────┐
│ ⏺ assistant text / tool call                                           │
│   ⎿  tool result (indented, collapsible)                               │
│ ⏺ …                                                                    │
└────────────────────────────────────────────────────────────────────────┘
╭──────────────────────────────────────────────────────────────────────╮
│ ❯ user input (multiline editor, rounded border)                        │   ← input line
╰──────────────────────────────────────────────────────────────────────╯
  ⏵⏵ accept edits on · 2 tasks running · esc to interrupt   (hint/status)    ← status strip
  ⎿ Bash(npm test) running…                                                  ← tasks/agents list
```

### 1.1 The output / transcript widget (append model)  — _key focus_

**Append model:** the transcript is an **append-only, scrollable log**. New content is appended at
the bottom; older content scrolls up. It is *not* a fixed pane that redraws in place — entries are
emitted as blocks. Some recent blocks remain **mutable** (a running tool result updates in place
until it completes), then become frozen history.

**Content types interleaved in one stream** _(mined + observed)_:

| Content type            | How it renders                                                        |
|-------------------------|-----------------------------------------------------------------------|
| Assistant prose         | Markdown-rendered (headings, lists, bold/italic, **code blocks** with syntax highlight) |
| Tool invocation         | One line, leading bullet glyph + tool name + args summary             |
| Tool result             | Indented block under the call via an L-connector, **collapsible**     |
| Diffs                   | Dedicated diff renderer (added/removed lines, colorized)              |
| Todo / checklist        | Checklist with checkbox glyphs                                        |
| Status / error notices  | Decorated single lines (warning/info/error icons)                    |
| Thinking indicator      | Animated spinner + label while generating                            |

**Left-prefix / decoration glyphs** — confirmed present in the binary (exact UTF-8 byte counts):

| Glyph | U+    | Count | Role (inferred)                                            |
|-------|-------|-------|------------------------------------------------------------|
| `·`   | 00B7  | 142   | middot — separators in the status strip                    |
| `─`   | 2500  | 56    | horizontal rule / box top-bottom                           |
| `├`   | 251C  | 38    | tree branch (nested results)                               |
| `└`   | 2514  | 37    | tree last-child connector                                  |
| `→`   | 2192  | 21    | arrows in hints/labels                                     |
| `│`   | 2502  | 17    | vertical box edge / tree spine                             |
| `•`   | 2022  | 15    | bullet list marker                                         |
| `✓`   | 2713  | 9     | success / done                                             |
| `┗`   | 2517  | 8     | heavy connector                                            |
| `◉`   | 25C9  | 7     | selected radio / active marker                             |
| `›`   | 203A  | 6     | single chevron (breadcrumb / prompt)                       |
| `❯`   | 276F  | 5     | **input prompt chevron**                                   |
| `✗`   | 2717  | 5     | failure / cancelled                                        |
| `✔`   | 2714  | 4     | heavy check (alt success)                                  |
| `◯`   | 25EF  | 4     | empty / pending                                            |
| `╭╮╰╯`| 2570… | 1-4ea | **rounded box corners** (the input border)                |
| `…`   | 2026  | 4     | ellipsis (truncation marker)                               |
| `○`   | 25CB  | 2     | empty circle (pending todo)                                |
| `☒`   | 2612  | 1     | crossed checkbox (cancelled todo)                          |
| `☐`   | 2610  | 1     | empty checkbox (open todo)                                 |

> The output-line **prefix model is now confirmed from the binary — see §7.0**: a static colored
> dot (`⏺` on macOS / `●` elsewhere) marks a settled line, replaced by an **animated sparkle**
> (`· ✢ ✳ ✶ ✻ ✽`) for the currently-active step. The tree/box-drawing set above (`├ └ │ ─ ╭╮╰╯`)
> and status set (`✓ ✗ ✔ ○ ◯ ☐ ☒`) are confirmed. **Status semantics:** `✓`/`✔` = OK/done,
> `✗` = cancelled/failed/not-working, `○`/`◯`/`☐` = pending, `☒` = cancelled item.
> (Many glyphs are stored as `\uXXXX` escapes, so they appear in the ASCII strings dump but NOT in
> raw-UTF-8 byte scans — scan both ways when verifying.)

### 1.2 Expand / collapse of content  — _key focus_

_(mined: "expand" ×402, "collapsed/expanded" present, **"ctrl+o to expand"** ×2, "truncated" ×417)_

- Long tool results / outputs are **truncated** by default with a marker (e.g. `… +N lines`).
- **`Ctrl+O`** expands/collapses the most recent (or focused) truncated block in place.
- Content has explicit **collapsed/expanded state** per block; the renderer re-flows the
  transcript when toggled. This is conceptually identical to a tree node expand/collapse but
  applied to inline result blocks.

### 1.3 The agents / processes list (below the input line)  — _key focus_

_(mined: "background task" ×34, "task list"/"tasklist" ×67, **`Ctrl+B`** ×38, "press esc" ×29,
"running tasks"/"running agents"/"subagent" present, "fleet" ×254, **`Ctrl+K`** stops all)_

- Background work (background bash shells, spawned **sub-agents**, queued tasks) is shown as a
  **compact list strip beneath the input line** — one row per task: status glyph + label
  (`Bash(cmd)` / agent name) + state (`running…`, exit code, ✓/✗).
- These sub-agents are conceptually **separate windows/contexts** ("Fleet"): each runs its own
  context and reports back; the strip is the at-a-glance dashboard of them.
- **`Ctrl+B`** = background the current task / open the task list (toggle the tasks view).
- **`Ctrl+K`** = "stops all running agents and background work at once" _(mined verbatim)_.
- **`Esc`** interrupts the active task; **`Ctrl+C`** stops _(mined: "esc to stop", "ctrl+c to stop")_.
- A separate **task notification** mechanism re-surfaces a task when it completes.

### 1.4 The input line  — _key focus_

_(mined: "multiline" ×91, "placeholder" ×255, "paste" ×555, "history" ×1113, "vim mode" ×3,
"cursorOffset" present, "backslash"/"newline" present)_

- **Multiline editor** with a **rounded border** (`╭─╮ │ ╰─╯`) and a `❯` prompt chevron.
- **Placeholder** text when empty.
- **History**: `Up`/`Down` cycle previous inputs _(mined: "up to edit queued messages")_.
- **Paste**: bracketed paste; `Ctrl+V` pastes a screenshot, `Ctrl+Y` pastes deleted text _(mined)_.
- **Newline vs submit**: `Enter` submits, `Shift+Enter` (×52) / `\`+`Enter` inserts a newline.
- **Optional vim mode** (NORMAL/INSERT) for the editor.
- **Slash-command & @-file autocomplete** popup (mined: "autocomplete" ×75, "suggestion" ×1117,
  "@-mention"): typing `/` or `@` opens a filterable suggestion menu above/below the line.
- Special input prefixes: `/` = command, `@` = file mention, `!` = bash mode, `#` = memory.

### 1.5 Modes, status line, spinner

_(mined: "plan mode" ×173, "auto-accept edits" ×10, "accept edits on" ×2, "bypass permissions"
×21, "thinking" ×1382, "tokens" ×3847, "compact" ×1849, "interrupt" ×618)_

- **Permission modes**, cycled with **`Shift+Tab`** (×36, "shift+tab cycle by default"):
  normal → **auto-accept edits** (`⏵⏵ accept edits on`) → **plan mode** → (bypass permissions).
- **Status / hint line** under the input: shows current mode, token/context usage, running-task
  count, and a contextual hint ("esc to interrupt", "ctrl+o to expand", etc.), `·`-separated.
- **Thinking spinner**: animated indicator + label while the model generates; `Esc` interrupts.
- **Auto-compaction** of context when the window fills (mined: "autoCompactEnabled").

---

## Part 2 — Slash commands and shortcuts

### 2.1 Slash commands  _(mined; curated — filesystem/AWS-SDK path noise removed)_

```
/add-dir        /agents         /bashes          /bug            /clear
/compact        /config         /context         /cost           /diff
/doctor         /effort         /exit            /export         /fast
/feedback       /help           /hooks           /ide            /init
/install-github-app             /login           /logout         /loop
/mcp            /memory         /model           /output-style   /permissions
/plugin         /privacy        /release-notes   /resume         /review
/rewind         /sandbox        /status          /statusline     /terminal-setup
/todos          /usage          /vim
```
Plus **skill/plugin commands** that surface as slashes (e.g. `/code-review`, `/claude-api`,
`/security-review`, `/babysit-prs`). The authoritative live list is `/help`.

### 2.2 Keyboard shortcuts  _(mined; counts = references in binary)_

| Key             | Action (inferred)                                              |
|-----------------|---------------------------------------------------------------|
| `Enter`         | Submit message                                                |
| `Shift+Enter`   | Insert newline (52)                                           |
| `\` + `Enter`   | Insert newline (backslash escape)                             |
| `Shift+Tab`     | Cycle permission mode (36)                                    |
| `Tab`           | Autocomplete / accept suggestion                              |
| `Esc`           | Interrupt / clear input / edit last message (47× "esc to …")  |
| `Esc Esc`       | Edit previous message / rewind                                |
| `Up` / `Down`   | History; edit queued messages                                 |
| `Ctrl+O`        | **Expand/collapse** truncated output (2)                      |
| `Ctrl+B`        | **Background task / task list** (38)                          |
| `Ctrl+K`        | **Stop all agents & background work** (verbatim)              |
| `Ctrl+C`        | Stop / cancel (twice to quit)                                 |
| `Ctrl+D`        | EOF / exit                                                    |
| `Ctrl+L`        | Clear screen                                                  |
| `Ctrl+R`        | Reverse-search / verbose toggle                               |
| `Ctrl+V`        | Paste screenshot                                              |
| `Ctrl+Y`        | Paste deleted text                                            |
| `Ctrl+_` / `Ctrl+Z` | Undo                                                      |
| `Ctrl+T`        | Todo / transcript toggle (2× "ctrl+t to")                     |
| `Ctrl+A`/`E`/`W`/`U`/`K` | Readline line-editing (home/end/del-word/del-line)   |

> Many of these are **rebindable** — the binary references a `keybindings.json` schema (cmd/meta
> variants like `cmd+v`, `meta+tab` appear), so the CLI supports user keybinding customization.

### 2.3 Mouse

_(mined: ink/Yoga; click-to-expand requested by user)_ — Click to focus/expand collapsible blocks,
wheel to scroll the transcript, click on suggestions in the autocomplete menu. (Terminal-dependent.)

### 2.4 Configuration options  _(mined `settings.json` keys)_

```
model                       theme                    verbose
permissions { allow, deny, ask, bypassPermissions,
              alwaysAllowRules, alwaysDenyRules, denyAllExcept }
hooks (+ hookEventName, hookSpecificOutput, disableAllHooks)
env / environment           apiKeyHelper             outputStyle
statusLine                  mcpServers (+ enableAllProjectMcpServers, mcpServerPolicy)
permissionPromptTool        preferredNotifChannel    messageIdleNotifThresholdMs
autoCompactEnabled / autoCompactWindow              cleanupPeriodDays
includeCoAuthoredBy         autoUpdates              forceLoginMethod
todoFeatureEnabled          spinnerTipsEnabled       effort
additionalContext           toolsNarrowing
```

---

## Part 3 — Mapping to Crysterm (gap analysis)

Crysterm already has a deep widget toolkit (70+ widgets, 10 layouts, CSS, damage-tracked
rendering, mouse/focus/scroll, dialogs, an embedded terminal emulator). The chat UI is mostly an
**assembly + a few new specialized widgets**, not new infrastructure.

| Claude CLI element            | Crysterm building block(s)                         | Status        |
|-------------------------------|----------------------------------------------------|---------------|
| Scrollback transcript         | `Log` / `ScrollableBox` + `Markdown`               | **new widget** atop existing |
| Markdown / code blocks        | `Markdown` widget (`src/widget/markdown.cr`)       | ✅ exists      |
| Tool-result tree connectors   | `Tree` glyphs + box-drawing in content parser      | ✅ primitives  |
| Expand/collapse blocks        | `Event::Expand`/`Event::Collapse` (Tree already)   | ✅ mechanism   |
| Diff rendering                | — (text styling exists; need a diff formatter)     | **new helper** |
| Todo / checklist              | `CheckBox` glyphs / `List` rows                     | ✅ primitives  |
| Multiline input + border      | `PlainTextEdit` + rounded `Style` border           | ✅ exists      |
| Single-line / history         | `LineEdit` (has placeholder, history, password)    | ✅ exists      |
| Slash/@ autocomplete popup    | `ComboBox` / `Menu` + `Mixin::Popup`               | ✅ adapt       |
| Tasks/agents strip            | `ListBar` / `List` + `StatusBar`                   | **new view**  |
| Status / hint line            | `StatusBar` (`src/widget/status_bar.cr`)           | ✅ exists      |
| Thinking spinner              | `Loading` widget (`src/widget/loading.cr`)         | ✅ exists      |
| Permission / confirm dialog   | `Message` / `Question` / `Dialog`                  | ✅ exists      |
| Mode cycling (Shift+Tab)      | Focus + key handling (`screen_focus.cr`)           | ✅ mechanism   |
| Sub-agents as "windows"       | Detached screens / child contexts                  | ✅ concept     |

**Genuinely new code needed:** (1) a `ChatTranscript` widget with the append/mutate/collapse model
and per-entry decoration; (2) a diff formatter; (3) a `TaskStrip` view bound to a task model;
(4) an autocomplete controller wired to a command/file registry; (5) glue (mode state machine,
status line content, key bindings).

---

## Part 4 — Implementation plan

### Phase 0 — Foundations & glyph set
- [ ] Add a `Crysterm::Chat::Glyphs` constants module: bullet `⏺`, result `⎿`, tree `├ └ │ ─`,
      rounded corners `╭ ╮ ╰ ╯`, prompt `❯ ›`, status `✓ ✔ ✗ ○ ◯ ☐ ☒`, ellipsis `…`, arrow `→`.
- [ ] Decide a color/style scheme (CSS classes: `.tool-call`, `.tool-result`, `.ok`, `.fail`,
      `.pending`, `.hint`, `.thinking`).

### Phase 1 — ChatTranscript widget (the output box) — _highest priority_
- [ ] New `src/widget/chat/transcript.cr` extending `ScrollableBox` (append-only, auto-scroll to
      bottom unless user scrolled up).
- [ ] **Entry model**: `Entry` with `kind` (`:prose | :tool_call | :tool_result | :diff | :todo |
      :notice | :thinking`), `state` (`:running | :ok | :fail | :cancelled | :pending`), `body`,
      `collapsed : Bool`, optional `parent` (for the call→result tree link).
- [ ] **append(entry)** appends and marks dirty; **update_last(entry)** mutates the live tail entry
      (for streaming tool output) without reflowing history.
- [ ] **Renderer per kind**: left prefix glyph by kind/state, indentation for nested results
      using `⎿`/`├`/`└`, Markdown body via the existing `Markdown` widget for `:prose`.
- [ ] **Collapse**: truncate bodies over N lines with a `… +N lines (Ctrl+O)` marker; store full
      body; toggle on `Ctrl+O` / click → emit `Event::Expand`/`Event::Collapse` and reflow.
- [ ] Reuse damage tracking so only the toggled subtree re-renders.

### Phase 2 — Input line
- [ ] `src/widget/chat/input.cr`: wrap `PlainTextEdit` with a rounded-border `Style`, `❯` prompt
      gutter, placeholder.
- [ ] `Enter` submits (emit `Event::SubmitData`); `Shift+Enter` / trailing `\` inserts newline.
- [ ] Up/Down history when caret at first/last line; otherwise move caret.
- [ ] Paste handling via existing `Event::Paste`; screenshot paste hook (`Ctrl+V`) optional.

### Phase 3 — Autocomplete popup
- [ ] Command/file registry (`name`, `description`, `kind`).
- [ ] On `/`, `@`, `!`, `#` open a `Menu`/`ComboBox`-style popup (via `Mixin::Popup`) anchored to
      the input, filtered as the user types; `Tab`/`Enter` accept, `Esc` dismiss, arrows navigate.

### Phase 4 — Tasks / agents strip
- [ ] `Task` model: `id, label, kind (:bash | :agent | :queued), state, exit_code`.
- [ ] `TaskRegistry` (observable list) the UI binds to.
- [ ] `src/widget/chat/task_strip.cr` (a `List`/`ListBar`): one row per task, status glyph + label
      + state; lives directly under the input.
- [ ] `Ctrl+B` toggle the strip / send current to background; `Ctrl+K` stop all; `Esc` interrupt
      active; surface completion via an `Event` (task notification analogue).

### Phase 5 — Status line & modes
- [ ] `StatusBar` content: mode badge, token/context gauge (reuse `ProgressBar`/`Gauge`),
      task count, `·`-separated contextual hints.
- [ ] Mode state machine (`normal → auto_accept → plan → bypass`), cycled by `Shift+Tab`; reflect
      in border color + status badge.
- [ ] `Loading` spinner shown during generation with an interrupt hint; `Esc` cancels.

### Phase 6 — Dialogs & diffs
- [ ] Permission/confirm prompts via `Question`/`Message` (`DialogButtonBox` Ok/Cancel).
- [ ] Diff formatter helper → emits styled `:diff` entries (green/red lines, hunk headers).

### Phase 7 — Sub-agents as windows (advanced)
- [ ] Model each sub-agent as a detached context; the `TaskStrip` row can open a focused view
      (a `StackedWidget` page or `TabWidget` tab) showing that agent's own transcript.

### Phase 8 — Assembly & keybindings
- [ ] `src/widget/chat/chatbox.cr` composing transcript (fill) + input + task_strip + status via a
      `VBox`/`Border` layout.
- [ ] Central keymap table (rebindable, mirroring §2.2) wired through `screen_interaction.cr`.
- [ ] Example app under `examples/chat/` with a mock backend (echo + fake tools/tasks) to exercise
      streaming append, collapse, and the task strip.

### Suggested order of attack
**Phase 1 (transcript) → Phase 2 (input) → Phase 5 (status/spinner) → Phase 4 (tasks) →
Phase 3 (autocomplete) → Phase 6/7/8.** Phases 1, 2, 5 give a usable chat box; the rest layer on.

> **Second-pass review (two independent deep passes) added Part 5 findings and Phases 9–16 —
> see Parts 5 & 6 below. Revised end-to-end build order is in §6.2.**
>
> **Third-pass review (two more passes — visual/theming/per-tool + lifecycle/flows/errors)
> added Part 7 findings and Phases 17–21 — see Parts 7 & 8 below.**
>
> **Fourth-pass review (layout/scroll/cursor + perf/streaming/terminal/teardown) added Part 9
> findings and Phases 22–28 — see Parts 9 & 10. Headline: Claude has TWO render backends
> (`/tui default|fullscreen`); the fullscreen one is a flicker-free alt-screen renderer with
> virtualized scrollback.**
>
> **Part 11 — General-capability GAP ANALYSIS, verified against crysterm's actual `src/` + `lib/`
> (shards). Lists which general/non-widget features are already supported vs genuinely missing.
> Read this before starting work — it supersedes earlier "gap" guesses in Parts 6/8/10.**
>
> **Fifth-pass review (deep crysterm src+lib audit × 2 + Claude residual × 2): §11.5 corrects the
> gap list with code-verified facts (crysterm has MORE than Part 11 first assumed — DEC 2031,
> theme roles, animation system, OSC 52 API, drag-drop, in-band resize), and Part 12 adds residual
> Claude findings (status-line contract, /config, $EDITOR) + exact reimplementation constants.**

---

## Part 5 — Second-pass deep-review findings

Two independent review passes over the binary (a *user-facing/content* lens and a
*terminal-interaction/system* lens) surfaced the following, beyond Parts 1–2. Counts are
binary reference counts (evidence of presence). Inferences flagged.

### 5.1 Terminal capability layer  _(NEW — the lowest layer of the TUI)_
- **Kitty keyboard protocol** (progressive enhancement): pushes `CSI > 1 u` / `CSI > 3 u`, pops
  `CSI < u`; also fixterms `CSI 27u` / `CSI 27;1u` for **ctrl+letter disambiguation**.
- **Focus events**: `CSI I` (focus-in) / `CSI O` (focus-out), enabled via `?1004h`.
- **Mouse**: SGR `?1006h` (primary) + normal `?1000h`, button-event `1002`, any-event `1003`,
  legacy `CSI M`; **extended buttons 4–8** (side/back); tracking scoped to alt-screen.
- **Bracketed paste** `?2004h`; **alt-screen** `?1049h` with a full-repaint state machine.
- **Cursor shape** DECSCUSR `0–6 q` + hide/show `?25l`/`?25h` (bar in vim-insert, block in
  normal — _inferred_).
- **Color** `COLORTERM`/`truecolor`/`256color` detection; `FORCE_COLOR`/`NO_COLOR` overrides.
- **OSC 8 hyperlinks** (incl. `file://` links), **OSC 7** cwd reporting, terminal title (OSC 0/2),
  **OSC 104** color reset.

### 5.2 Rendering engine  _(NEW — confirms the transcript design)_
- Built on **Ink (React reconciler) + Yoga flexbox**.
- **Two-region model confirmed**: Ink `<Static>` = committed scrollback (printed once, scrolls in
  the native terminal); a small **live region** re-renders each frame. ← This directly validates
  the Phase-1 append-only transcript + mutable-tail design.
- **Resize**: `SIGWINCH` → reflow + **rewrap**; `truncate-end` / `truncate-middle`; `wordWrap`;
  `overflowX/Y`.
- **Grapheme-correct width**: `Intl.Segmenter`, `eastAsianWidth`, combining marks, zero-width,
  surrogate handling (CJK = 2 cells).

### 5.3 Inline images  _(NEW)_
- **iTerm2** inline images (`OSC 1337;File=inline=1`), **Kitty graphics** (APC `_G`); **no Sixel**.
- Crysterm already ships `Media::Iterm`, `Media::Kitty`, `Media::Sixel` (+ more) — it **exceeds**
  Claude here.

### 5.4 Spinner / progress  _(NEW — exact values)_
- **Braille spinner**: frames `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` (`⠋…⠏`), **80 ms/frame**, 10 frames.
- **Rotating tip verbs**: thinking, working, pondering, percolating, noodling, forging, crafting,
  cooking, conjuring, brewing, vibing, synthesizing, spelunking, simmering, ruminating, mulling,
  deliberating, computing.
- **ReducedMotion** gate; **OSC 9;4** terminal taskbar progress during long ops.

### 5.5 FleetView — fullscreen multi-agent dashboard  _(NEW — largest undocumented subsystem)_
- A dedicated **alt-screen UI** tracking concurrent sub-agents: group mode, **peak-concurrency**
  counters ("N agents running").
- **Detach / reattach**: sessions persist over a **bridge socket**; reattach to **tmux** and
  **cloud** sessions; **`Ctrl+Z`** detach (`SIGTSTP`/`SIGCONT`), **`Ctrl+S`** switch views.
- `ParallelHelperPool` for parallel tool/agent execution.
- This is the heavyweight version of the §1.3 task strip — the strip is the inline summary; the
  FleetView is the full-screen dashboard.

### 5.6 Diff & todo rendering  _(NEW — exact)_
- **Diff**: themed `diffAdded`/`diffRemoved`, **word-level intra-line diff**, both **unified** and
  **side-by-side** modes, syntax highlighting (`hljs`).
- **Todo**: **four states** — `pending` / `in_progress` / `completed` / `cancelled`; checkbox
  glyphs; `toggleTodo`.

### 5.7 Full keymap & editing engine  _(NEW)_
- **`keybindings.json` schema**: `{ "bindings": [ { "key", "command", "when", "args", "chord" } ] }`
  — multi-key **chords** supported; typed validation warnings.
- **Kill-ring readline**: `yank`/`yankPop`, `transpose`, `deleteWord`, `deleteToLineStart/End`,
  history prev/next, pageUp/Down, scrollUp/Down, clearScreen, `cycleMode`.
- **Vim engine**: normal/insert/visual; operator+motion (`dd`, `de`, `db`, `cb`), `$`/`^` motions,
  count prefixes (_inferred_).

### 5.8 Accessibility & degraded modes  _(NEW)_
- `accessibilityMode`, **ScreenReader mode**, `ariaLabel`/`AccessibilityRole`; `ReducedMotion`;
  `NO_COLOR`/`FORCE_COLOR`; **quiet** mode; **non-interactive / CI / dumb-terminal** degraded
  render path.

### 5.9 Rewind, context display & notifications  _(NEW UX)_
- **Rewind/checkpoints**: backed by **git stash + file backup**; trigger **`Esc Esc`**; three
  restore axes — **code only / conversation only / both**.
- **`/context` display**: token-budget breakdown — System prompt · Messages · MCP tools ·
  Memory files · Free space.
- **Notifications**: `preferredNotifChannel` = `auto`/`iterm2`/`kitty`/`terminal_bell`/`disabled`;
  OSC 9 / OSC 777 / OSC 99 desktop notifications + bell + macOS `osascript`; idle threshold.
- **Output styles**: `default` / **Explanatory** / **Learning** (affect verbosity, inline
  insights, todo usage). **Thinking budget** tiers: `ultrathink` / `interleaved`.

### 5.10 Application-layer features  _(NOT TUI — out of scope for the widget; listed for a full client)_
These are agent-runtime concerns, surfaced through the chat box but not part of a TUI widget set:
- **Hooks**: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`,
  `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact`, `PostCompact`; `matcher` +
  structured JSON output (`permissionDecision`, `additionalContext`, `systemMessage`,
  `suppressOutput`).
- **MCP**: `stdio`/`http`/`sse` transports, `.mcp.json`, scopes `local`/`project`/`user`,
  `mcp__` tool namespacing, OAuth.
- **Plugins/Skills**: `SKILL.md` frontmatter (`allowed-tools`, `argument-hint`,
  `disable-model-invocation`), `plugin.json`, marketplaces, `enabledPlugins`.
- **Memory**: `CLAUDE.md` / `CLAUDE.local.md`, `@import`, user/project/local tiers.
- **Sandbox/permissions**: seatbelt (macOS) / bubblewrap (Linux), network gating via proxy, rule
  grammar `Bash(npm *)` / `Read(~/**)` / `WebFetch(domain:…)`, modes `acceptEdits`/`plan`/
  `bypassPermissions`.

---

## Part 6 — Plan additions (from the second-pass review)

### 6.1 New phases

#### Phase 9 — Terminal capability layer
- [ ] Audit crysterm's `Tput`/terminal layer against §5.1. Already present: SGR/GPM mouse, focus
      protocol, color-scheme detection, Unicode width.
- [ ] **Build the gaps**: **kitty keyboard progressive-enhancement protocol** (push/pop `>1u`/`<u`,
      ctrl+letter disambiguation), **DECSCUSR cursor-shape switching** (bar/block by vim mode),
      **OSC 8 hyperlinks** in the content parser, OSC 7/title emission.

#### Phase 10 — Two-region rendering hardening
- [ ] Map Ink `<Static>` → a **committed, non-redrawn scrollback region** in `ChatTranscript`
      (history printed once; only the live tail re-renders). Crysterm's damage tracking already
      supports partial redraw — formalize the "frozen history vs live tail" split.
- [ ] Verify `SIGWINCH` reflow + **rewrap** of wrapped history; confirm grapheme/CJK width via
      crysterm's Unicode-aware width.

#### Phase 11 — Rich keymap & editing engine
- [ ] Implement a **rebindable keymap** mirroring `keybindings.json` (`key`/`command`/`when`/
      `args`/`chord`, multi-key chords), wired through `screen_interaction.cr`.
- [ ] Add **kill-ring** to `Mixin::TextEditing` (yank/yankPop, transpose, delete-word,
      delete-to-line-start/end).
- [ ] Complete the **vim engine** (normal/insert/visual, operator+motion+count, cursor shape per
      mode).

#### Phase 12 — FleetView analogue (multi-agent dashboard)
- [ ] Full-screen multi-agent view using `StackedWidget`/`TabWidget` + **detached screens**
      (crysterm supports detached/remote screens): one page per agent, each its own transcript.
- [ ] Peak-concurrency + group counters; **`Ctrl+Z` suspend/detach** (`SIGTSTP`/`SIGCONT`),
      **`Ctrl+S`** switch views; optional reattach over a socket (advanced).

#### Phase 13 — Diff & todo widgets
- [ ] **Diff formatter**: line add/remove theming, **word-level intra-line** highlighting,
      **unified + side-by-side** layouts, syntax highlighting.
- [ ] **Four-state todo list** (pending / in_progress / completed / cancelled) with checkbox glyphs
      (`☐ ◯ ✓ ☒`) — reuse `CheckBox`/`List`.

#### Phase 14 — Spinner & progress
- [ ] `Loading` widget: **braille frame set** `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` @ 80 ms + **rotating tip verbs**.
- [ ] **ReducedMotion** gate; emit **OSC 9;4** terminal progress during long ops.

#### Phase 15 — Accessibility & degraded modes
- [ ] **Screen-reader mode** (linearized plain-text output, aria-label equivalents), **reduced
      motion**, honor `NO_COLOR`/`FORCE_COLOR`, and a **dumb/CI** fallback render path.

#### Phase 16 — Client-layer adapters _(only if building a full agent client, not the widget set)_
- [ ] **Rewind/checkpoint** UX (git-stash-backed; code-only / conversation-only / both), **`Esc Esc`**.
- [ ] **`/context`** token-budget view (System prompt · Messages · MCP tools · Memory · Free).
- [ ] **Notification channels** (bell / iTerm2 / kitty / osascript; idle threshold), **output styles**.
- [ ] Hooks / MCP / skills / sandbox are agent-runtime concerns — surface them **through the
      existing `Event` system**, do **not** bake them into widgets (keep the widget layer pure TUI).

### 6.2 Revised end-to-end build order
**1–8** (working chat box) → **9 (terminal layer) + 10 (rendering)** harden the foundation →
**11 (keymap) + 13 (diff/todo) + 14 (spinner)** add fidelity → **12 (FleetView) + 15 (a11y) +
16 (client adapters)** are advanced/optional.

### 6.3 Crysterm gap summary (what's already there vs. what to build)
- **Already covered well** — mouse SGR/GPM, focus events, color-scheme detection, Unicode/CJK
  width, damage-tracked partial redraw, **image backends (iTerm/Kitty/Sixel — exceeds Claude)**,
  detached/remote screens, dialogs, scrollable areas, **tree expand/collapse**, CSS theming,
  `Markdown`/`Log`/`StatusBar`/`Loading` widgets.
- **Genuine gaps to build** — kitty keyboard progressive-enhancement protocol; cursor-shape-by-mode;
  OSC 8 hyperlinks; kill-ring + full vim operator engine; `keybindings.json` schema + chords;
  word-level + side-by-side diff; four-state todo; braille spinner + rotating tips; FleetView
  multi-agent dashboard + detach/reattach; screen-reader / degraded modes; OSC 9;4 progress.

---

## Part 7 — Third-pass deep-review findings

Two more passes (visual/theming/per-tool, and lifecycle/flows/errors). Counts are binary
references; many glyphs appear as `\uXXXX` escapes (see note below).

### 7.0 ⭐ Output-line prefix model — CONFIRMED (supersedes a second-pass note)
The exact prefix logic, recovered verbatim from the binary:
- **Static dot** (settled line): `hc = isMacOS ? "⏺" : "●"` → **`⏺` on macOS, `●`
  elsewhere** — a *colored* filled dot; color is theme/status-driven (seen: `color:"ansi:cyan"`,
  `color:"text"`). This is the prefix on every committed output line.
- **Animated sparkle** (currently active/working step): a 6-frame cycle that **replaces** the dot —
  `["\xB7","✢","✳","✶","✻","✽"]` = **`· ✢ ✳ ✶ ✻ ✽`** — the star "grows"
  from a middot to a full pinwheel, then loops (ghostty variant ends `…✻ ✻`). Plus a secondary
  micro-spinner `·|· ·/· ·-· ·\·`.
- **Why the earlier "sparkle unused" note was wrong**: these glyphs are stored as `\uXXXX` *escape
  sequences* (ASCII), so the raw-UTF-8 byte scan returned 0. `✻` (✻) actually occurs 13×,
  `✶` (✶) 5×, `✳` (✳) 5×, `⏺` (⏺) 3×, `●` (●) 7×. Status icons likewise as
  escapes: `✓` ✓ (46×), `✗` ✗ (31×), plus emoji `✅` ✅ (96×), `❌` ❌ (74×).

So the per-line lifecycle is: **pending → active (animated sparkle) → done (static colored
dot, `✓`/`✗` for tool status)**.

### 7.1 Borders, boxes & tables
- **8 standard box styles**: `round` (default, 23×), `single` (11×), `double`, `bold`/heavy,
  `singleDouble`, `doubleSingle`, `classic` (`+`), `arrow` (↖↑↗→↘↓↙←).
- **2 custom styles**: **`quote`** = markdown blockquote (dimmed **left bar only**, paddingLeft 1);
  **`dashed`** = inline code / workflow-snippet boxes.
- **GFM table box**: `single` + tees `├ ┤ ─ │` for row separators; per-column widths.
- Boxes carry `title:` + **`titleAlign`**; **border colors are semantic slots** (`subtle` /
  `announce` / `tier`), not raw ANSI — a token-based theming layer.

### 7.2 Theme system (6 themes + picker)
- Internal ids: `dark`, `light`, `dark-ansi`, `light-ansi`, `dark-daltonized`, `light-daltonized`.
- UI labels: **Dark/Light mode**, **… (ANSI colors only)**, **… (colorblind-friendly)**.
- `ThemePicker` component; selectable at onboarding + via `/config`. Syntax highlight = highlight.js
  with colors mapped from the active theme (no standalone scheme). ANSI-only tier ≠ `NO_COLOR`
  (uses the 16 ANSI colors only).

### 7.3 Per-tool result rendering
- Tool-call label format **`ToolName(arg-summary)`** — `Bash(…)` `Read(…)` `Write(…)` `Edit(…)`
  `Glob(…)` `Task(…)` `WebFetch(…)` `WebSearch(…)`.
- **Read** → numbered lines ("with line numbers", `cat -n`).
- **Bash** → exit code, "timed out after", "running in background"; title "Bash command
  (unsandboxed)" variant.
- **Grep/Glob** → "Found N …" summary.

### 7.4 Markdown fidelity
- GFM: **tables** (tHead/tBody/TableRow/TableCell, per-column widths), **blockquotes** (quote
  border), headings `#`–`######`, **`hr`** node, **fenced code with language + filetype label**
  (drives hljs grammar), nested lists.

### 7.5 Input adjuncts — paste, images, queue
- Paste placeholder **`[Pasted text #N]`**; image placeholders **`[Image #N]`** / `[Image]` plus
  states `[Image data detected…]`, `[Image could not be processed]`, `[Image source: …]`,
  `[IMAGE_DATA]`.
- **Queued messages** (type while generating): "queued message" / "Message queued",
  hint "↑ to edit queued messages", "will be sent".

### 7.6 Help & shortcuts
- `/help` groups: **Available commands** / **Custom commands** / **Keyboard shortcuts**.
- Inline affordance **"? for shortcuts"** → opens the keyboard-shortcuts overlay.

### 7.7 Status readouts — context / usage / update
- **Context**: "N% context used" and inverse "N% until auto-compact"; "Context low (N% remaining)
  · Run /compact to compact & continue"; "Compacting conversation"; auto-compact window picker.
- **Usage limits**: windows labelled "session limit" (5-hour), "weekly limit" (7-day),
  "Opus limit" / "Sonnet limit", monthly; "· resets in <dur>" / "Resets <date>"; credit-limit +
  upgrade CTAs (`/upgrade`, `/usage-credits`).
- **Update**: "New version available: <ver>", "Update installed · Restart to apply",
  auto-update enable/disable/failed.

### 7.8 Thinking block
- Header label "Thinking…"; internal term **Reasoning** (686×); interleaved thinking; budget tiers
  `ultrathink`/`interleaved`. Active reasoning uses the §7.0 sparkle (not a static glyph).

### 7.9 Onboarding / first-run
- Welcome box "Welcome to Claude Code" (+ org/IDE variant), "Welcome back!", "Let's get started.",
  "Tips for getting started" (incl. "Run /init…", "Press up to…"), "Did you know" tips,
  changelog / release-notes. No ASCII-art logo.
- Theme picker (6, §7.2).
- **Trust-folder dialog**: "Yes, I trust this folder" / "No, exit"; body "Claude Code will be able
  to read files… make edits when auto-accept edits is on"; reason "Due to prompt injection
  risks, only use it with code you trust".
- **Security-notes** screen ("Security notes:", "Claude can make mistakes.").
- **terminal-setup**: per-terminal Shift+Enter (Option+Enter on Apple Terminal) installers
  (Alacritty, Zed, …); native-support detection.

### 7.10 Login / auth
- Method picker: "Claude account with subscription" (Pro/Max/Team/Enterprise) vs "Anthropic
  Console account" (API).
- OAuth: placeholder "Paste code here if prompted >", browser-open fallbacks, invalid/missing-code
  errors. Logout ("Successfully logged out…"); device enrollment ("Remote Control"); separate
  `/design-login` path.

### 7.11 Permission-prompt UI (exact tiered options)
- **Edit**: "Yes, allow all edits during this session" / "…in <dir>/" / "Yes, manually approve
  edits" / "Yes, auto-accept edits".
- **Read**: "Yes, allow reading from <dir>" / "…from this project".
- **Bash**: "Any Bash command" / "Any Bash command starting with <prefix>" / "Yes, and don't ask
  again for <X> in <dir>".
- **Decline**: "No, and tell Claude what to do differently" / "No, don't ask again".
- Per-tool titles: "Claude needs your permission", "Claude wants to fetch content from <host>",
  "… wants to open a URL", external-imports, macOS app control, mobile notifications.

### 7.12 Plan mode & approval
- Banners: "Claude wants to enter/exit plan mode"; "Here is Claude's plan:".
- **ExitPlanMode dialog**: "…has written up a plan and is ready to execute. Would you like to
  proceed?" → "Yes, auto-accept edits" / "Yes, manually approve edits" / "No, keep planning".
- Records: "User approved/rejected Claude's plan".

### 7.13 Error / retry & interrupt
- 429: "Request rejected (429) · this may be a temporary capacity issue"; inline " · will retry in
  <t> · check your network"; overloaded; **fallback-model rotation** triggered by literal strings
  ("overloaded","529","credit balance too low","usage limit reached"); "Restart to retry".
- **Interrupt marker inserted in transcript: `[Request interrupted by user]`**; "Press Esc to
  cancel/go back", "Press Esc twice or type /rewind".
- Refusal render path: "Claude Code can't respond to this request with <X>."

### 7.14 /mcp status screen
- Server states: connected / connecting / failed / **needs-auth** ("needs authentication") /
  **needs-approval** ("pending approval — approve with /mcp") / disabled / init / unknown;
  empty state "No MCP servers are configured…"; status refresh after reload.

### 7.15 Resume / continue
- "Continue the conversation from where it left off"; sessions tracked by lastModified / sessionId,
  userModified flag, optional gitDiff. (Picker row layout didn't surface as distinct labels.)

> Areas that yielded little/nothing new: `/doctor` & `/status` live-screen contents (only referral
> strings + embedded help docs); destructive-file-overwrite confirmation TUI wording; ASCII-art
> logo; standalone syntax-highlight color scheme.

---

## Part 8 — Plan additions (from the third-pass review)

### 8.1 Enrichments to existing phases
- **Phase 0 (glyphs)** — add the **prefix-state model** (§7.0): static colored dot `⏺`(macOS)/`●`
  for settled lines + animated sparkle `· ✢ ✳ ✶ ✻ ✽` for the active step; per-status colors;
  status icons `✓`/`✗`/`✔` (optional emoji `✅`/`❌`).
- **Phase 1 (transcript)** — add **per-tool renderers** (`ToolName(arg)` label, Read line-numbers,
  Bash exit/timeout/background panel, Grep/Glob "Found N"); implement the **per-line state machine**
  pending → active(sparkle) → done(dot/✓)/failed(✗); insert `[Request interrupted by user]` on
  cancel; render collapsible Reasoning/thinking blocks.
- **Phase 2 (input)** — add paste/image placeholders (`[Pasted text #N]`, `[Image #N]` + states) and
  the **queued-messages** model (type-while-generating, ↑ to edit queue).
- **Phase 5 (status)** — add context readouts ("N% context used" / "N% until auto-compact" /
  "Context low …"), usage-limit/reset display, update notice.
- **Phase 14 (spinner)** — besides the braille spinner, add the **sparkle frame set** for
  active-step prefixes; reduced-motion → fall back to a static dot.

### 8.2 New phases

#### Phase 17 — Markdown fidelity
- [ ] Extend crysterm's `Markdown` widget: **GFM tables** (per-column widths + tee box `├ ┤ ─ │`),
      **blockquote** (quote = dimmed left-bar border), **fenced code** with language/filetype label
      + syntax highlight, `hr`, nested lists.

#### Phase 18 — Theme system
- [ ] Named theme presets: dark/light × {default, **ANSI-colors-only**, **colorblind-friendly**}.
- [ ] A **semantic color-slot layer** (subtle / announce / tier / text) over crysterm's CSS so
      widgets reference slots, not raw ANSI; map slots per theme.
- [ ] `ThemePicker` widget; switch via config. (Crysterm already has CSS theming + file watching —
      this is presets + the slot indirection + the ANSI/colorblind tiers.)

#### Phase 19 — Border / box system
- [ ] Add the 8 standard styles + custom **`quote`** (left-bar) and **`dashed`**; titled boxes with
      **`titleAlign`**; the table tee set; **semantic border colors**. (Crysterm `Style` already
      supports border styles — extend the enum + color binding.)

#### Phase 20 — Dialogs & flows
- [ ] Onboarding: welcome, **trust-folder** dialog, theme picker, security-notes.
- [ ] Login pickers (subscription vs console; OAuth paste-code).
- [ ] **Permission-prompt dialog** with the exact tiered option sets (§7.11) — numbered-option
      list selection over `Question`/`Dialog`.
- [ ] **Plan-mode approval** dialog (§7.12); generic confirmations.

#### Phase 21 — Help & notices
- [ ] `/help` grouped command list; **"? for shortcuts"** overlay.
- [ ] Notice/status rendering: context-low, usage-limit, update, **/mcp status** (server-state
      enum), error/retry inline, refusal. (Mostly client-layer — wire via the `Event` system.)

### 8.3 Updated end-to-end build order
**1–8** (working chatbox) → **9–10** (terminal + rendering foundation) →
**0/1/2/5/14 enrichments + 17 (markdown) + 18 (themes) + 19 (borders)** for visual fidelity →
**11 (keymap) + 13 (diff/todo)** → **20 (dialogs/flows)** → **12 (FleetView) + 15 (a11y) +
16 (client) + 21 (help/notices)**.

### 8.4 Crysterm gap update (third pass)
- **Newly confirmed crysterm already has**: border-style system, CSS theming + file watching,
  `Markdown` widget, `Dialog`/`Question`/`Message`, `Tree` expand/collapse — so Phases 17–20 are
  mostly *extensions*, not new infrastructure.
- **Net-new to build from this pass**: the active-step **sparkle frame set** + per-line state
  machine; **semantic color-slot** layer + colorblind/ANSI-only theme tiers; **quote/dashed**
  borders + table tees; **per-tool result renderers**; **GFM table** rendering; **trust-folder /
  permission-prompt / plan-approval** dialogs with exact option tiers; **queued-messages** input
  model; **"? for shortcuts"** overlay; the context/usage/update notice readouts.

---

## Part 9 — Fourth-pass deep-review findings

Two passes: layout/scroll/cursor mechanics, and performance/streaming/terminal/teardown.

### 9.0 ⭐ Two render backends + `/tui` command (major architectural finding)
- **`/tui <default|fullscreen>`**: **default** = classic main-scrollback renderer (prints into the
  terminal's native scrollback); **fullscreen** = *"flicker-free alt-screen renderer with
  virtualized scrollback"* (≡ `CLAUDE_CODE_NO_FLICKER=1`), with mouse support + auto-copy on select.
- Switching **restarts and resumes** the session; persisted to `userSettings.tui`; **cannot switch
  while tasks run** ("stop it via /tasks, then run /tui again").
- **Implication for crysterm**: it already has *both* alt-screen mode and damage-tracked partial
  redraw — this is a runtime mode toggle over existing infra, not new machinery.

### 9.1 Synchronized output & flicker control
- **DEC 2026 synchronized output** (`?2026h`/`?2026l`) gated by a **terminal allowlist** (iTerm,
  WezTerm, Warp, ghostty, contour, vscode, alacritty, mintty, rio, Tabby, JetBrains, Konsole
  ≥211200, kitty); **disabled under tmux**; override `CLAUDE_CODE_FORCE_SYNC_OUTPUT`.
- `CLAUDE_CODE_NO_FLICKER` tri-state. **RAF render loop** (`useAnimationFrame`); spinner ticks at
  `setInterval(…,200)` (200 ms). No hard FPS cap — RAF + sync-output batching *is* the throttle.
- Full **DEC private-mode catalog**: 25 (cursor) / 47 / 1049 (alt-screen) / 1000·1002·1003·1006
  (mouse) / 1004 (focus) / 2004 (paste) / **2031 (theme notify)** / **2026 (sync)**.

### 9.2 Virtualized scrollback & output caps
- **`virtualScroll`** (kill-switch `CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL`); **scrollback cap**
  (`reachedScrollbackCap`).
- Output caps: `BASH_MAX_OUTPUT_LENGTH`, `TASK_MAX_OUTPUT_LENGTH`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`.
  Truncation wording: `... [N lines truncated] ...`, `N lines hidden`, byte-limit truncation.
- **Diff caps**: 500 files / 8000 lines (`maxFiles:500, maxLines:8000`).

### 9.3 Transcript scroll mechanics
- **Sticky follow-tail** (`isSticky()`, `stickyScroll`, re-enabled on new output).
- **Jump-to-bottom "pill" with unseen count** (`newMessageCount`, `onPillClick`); **"unseen"
  divider line** (`unseenDivider`/`dividerYRef`) marking where unread output begins.
- **In-transcript search** (`onSearchMatchesChange`, `jumpRef`, "No matches found").
- Scroll telemetry: `reached_scrollback_cap`, `scrolls`, `page_jumps`, `jumpToBottomClicks`,
  `scrolledUpMs`. Pill hidden on the main pane; sticky adjusted for teammate panes (FleetView).

### 9.4 Scroll-wheel acceleration
- `wheelFlood` handling (terminals that flood wheel events); **decay-curve vs native-window**
  acceleration; `CLAUDE_CODE_SCROLL_SPEED` multiplier; arrow-key-for-wheel detection; JetBrains
  `jediTerm`/`jbBypass`, Windows-Terminal `wtSession` special-cases.

### 9.5 Layout geometry & spacing constants
- Viewport: content width = `columns − sidebar`; transcript height = `rows − 3` reserved;
  degenerate-width guard (`maxColumns = 1`). **No minimum-size splash** for the chat (negative).
- **Spacing house style**: **2-space gutter** (`paddingLeft:2` dominant; deeper nesting 3–6);
  **`paddingX:1`/`paddingY:1`** box padding; **`gap:1`** standard inter-element gap.

### 9.6 Input box & cursor
- Input **collapses its render when `maxHeight < 8`** with content; some fixed **60-col** sub-inputs.
- **Cursor = an inverse-rendered space cell** (`cursorChar = showCursor ? " " : ""`); visibility
  **gated on focus + idle** (suppressed when unfocused or busy).
- **`argumentHint` ghost text** rendered at the cursor for slash-command arguments.

### 9.7 Emphasis & color conventions
- **`dimColor` is THE secondary/subtle tier (1681×)**; **bold** is the primary attention mechanism
  (482×); italic occasional (77×); **underline/inverse rare** (inverse reserved for cursor/selection).
- **DEC 2031 color-scheme auto-detect** (`THEME_NOTIFY:2031`, reply `?997;[12]n`) → adds a **7th
  theme option "Auto (match terminal)"** on top of the six in §7.2.

### 9.8 Text wrapping & truncation
- Custom **word-wrap (hard/soft)**; **`break-all`** fallback for long URLs/tokens; **`trimEnd`** of
  trailing whitespace.
- **`truncate-end` is the default** for wide single-row UI (status/lists/tool headers); markers
  **`…`** (ellipsis) and **`→`** (overflow/affordance); `truncate-start`/`truncate-middle` available.
- Fold/preview renderer (`minWidth/maxWidth/maxLines`); empty state **"No preview available"**.

### 9.9 Width measurement (i18n)
- **`Bun.stringWidth(…, {ambiguousIsNarrow:true})`** (ambiguous East-Asian width = 1 col); grapheme
  segmentation via `Intl.Segmenter({granularity:"grapheme"})`.
- Handles **ZWJ (200D), VS-16 (FE0F), skin-tone modifiers, regional-indicator flags, combining
  marks**; control-char stripping (`stripVTControlCharacters`).
- **No RTL/bidi** text shaping (negative).

### 9.10 Clipboard
- **OSC 52** write (`ESC]52;c;<base64>`) with **multiplexer-aware wrapping**: tmux → `raw+dcs`
  passthrough, screen → `dcs`, else `raw`.
- **Native fallbacks**: `pbcopy` / `xclip` / `xsel` / `wl-copy` / `powershell Set-Clipboard`.
- `copyOnSelect` (default true), `copyFullResponse`; **`ctrl+s` to copy**; three toasts
  (native / "to tmux buffer · paste with prefix + ]" / "via OSC 52"); unit `char(s)`/`line(s)`.

### 9.11 Terminal detection & probe
- **Probe**: XTVERSION reply, `term_program_version`, `is_ssh`, **multiplexer** (tmux / `STY`→screen
  / `ZELLIJ`→zellij), rows/cols, `dec2026_allowlist`.
- Per-terminal version gates (ghostty ≥1.2.0, iTerm ≥3.6.6, Konsole ≥211200); mintty/cygwin/msys;
  **Apple_Terminal custom `cursorTo`**; win32-input-mode toggle (`?9001l`).
- `CLAUDE_CODE_TMUX_TRUECOLOR`; mouse toggles (`CLAUDE_CODE_DISABLE_MOUSE`/`_MOUSE_CLICKS`); title
  toggle (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`).

### 9.12 OSC catalog, progress bar, tab status
- **Full OSC catalog**: SET_TITLE/ICON (0/1/2), SET_COLOR (4), SET_CWD (7), HYPERLINK (8),
  iTerm2 (9 / 1337), FG/BG/CURSOR color (10/11/12), **CLIPBOARD (52)**, kitty (99), ghostty
  notify (777), **TAB_STATUS (21337)**. OSC-9 sub-enum: notify (0) / badge (2) / **progress (4)**.
- **OSC 9;4 progress bar** ("orange progress bar at bottom", default on, toggleable).
- **Terminal tab status** (OSC 21337): `showStatusInTerminalTab`; **`/rename` updates the tab title**.

### 9.13 Signals, teardown, persistence, headless
- Signals: SIGTERM/INT/KILL/HUP/QUIT/CONT/USR1/USR2/TSTP/PIPE/WINCH.
- **Teardown**: `exitAlternateScreen()`, `setRawMode(false)` (defensive try/catch), cursor show
  (`?25h`), mouse disable; `crash_handler`. Subprocess env scrubbed of render flags.
- **Persistence**: `~/.claude/` tree (`skills/`, `worktrees/`, `keybindings.json`,
  `settings.local.json`, `statusline-command.sh`); input-history ring persisted; tui-mode + theme
  persisted.
- **Raw/TTY/headless**: `isTTY` + `getColorDepth` gating; `TERM != "dumb"` degraded path;
  `--print`/`-p` + `stream-json` headless; `CLAUDE_CODE_EXIT_AFTER_FIRST_RENDER`;
  `--debug` / `--debug-file`; `CLAUDE_CODE_TERMINAL_RECORDING`.

### 9.14 Formatting conventions
- Counts: `toLocaleString` thousands separators ("1,234 tokens"); compact **"k"** for some metrics
  (`1.5k`); context labels written literally (20k / 100K / 200K).
- Durations: "Xs ago" / "Xms ago", **"just now"** (<60 s), "yesterday". (No composite `2m3s`.)
- Bytes: "0 KB" / "1 MB" / "1.5GB" (space-separated unit).

> Negative findings: no chat minimum-size splash; no artificial typewriter/smoothing (chunked
> deltas + sync-output instead); no hard numeric FPS cap; no RTL/bidi; sixel still absent.

---

## Part 10 — Plan additions (from the fourth-pass review)

### 10.1 New phases

#### Phase 22 — Dual render backends (classic vs fullscreen)
- [ ] Runtime toggle analogous to `/tui`: **classic** = print into native scrollback; **fullscreen**
      = alt-screen + virtualized scrollback. Crysterm has both alt-screen and damage tracking —
      wire the switch + persist the preference; block switching while tasks run.

#### Phase 23 — Synchronized output (flicker-free)
- [ ] Wrap frame writes in **DEC 2026** (`?2026h`/`l`) with a **terminal allowlist** + tmux-disable
      + force override. (Extends `screen_drawing.cr`.)

#### Phase 24 — Virtualized scrollback + output caps
- [ ] Windowed transcript rendering for very long histories; scrollback cap; per-tool output
      **byte/line caps** with `[N lines truncated]` / `N lines hidden` markers + `ctrl+o` expand;
      diff caps (≈500 files / 8000 lines).

#### Phase 25 — Advanced transcript scroll
- [ ] **Sticky follow-tail**; **jump-to-bottom pill** with unseen count; **unseen-divider** line;
      **in-transcript search** ("No matches found"). (Extends `ScrollableBox`.)

#### Phase 26 — Clipboard (OSC 52 + native)
- [ ] **OSC 52** with multiplexer-aware wrapping (tmux `raw+dcs`, screen `dcs`); native fallbacks
      (pbcopy/xclip/xsel/wl-copy/powershell); `copyOnSelect`; `ctrl+s`; copy toasts.

#### Phase 27 — Terminal integration polish
- [ ] Terminal **probe** (XTVERSION, multiplexer, dims) + per-terminal gates; **scroll-wheel
      acceleration** (decay/native, flood handling, speed multiplier, arrow-for-wheel); **OSC 9;4
      progress bar**; **OSC 21337 tab status** + title; **DEC 2031 theme auto-detect** → "Auto" theme.

#### Phase 28 — Robustness: signals, teardown, headless
- [ ] Full signal handling; **clean teardown** (restore alt-screen / raw-mode / cursor / mouse) on
      exit *and* crash; **non-TTY/headless** (`--print`/`stream-json`) render path; state persistence
      (history ring, mode/theme prefs).

### 10.2 Enrichments to existing phases
- **Phase 0/1** — spacing constants (2-gutter, `paddingX:1`, `gap:1`); `truncate-end` default; `…`/`→`
  markers; "No preview available" / "No matches found" empty states; formatting helpers
  (`toLocaleString`, `k`, durations, bytes).
- **Phase 2 (input)** — cursor = inverse-space gated on focus+idle; collapse render `<8` rows;
  `argumentHint` ghost text.
- **Phase 9 (terminal layer)** — DEC private-mode catalog; DEC 2031 auto-theme; width edge cases
  (`ambiguousIsNarrow`, ZWJ/VS-16/skin-tones/flags); control-char stripping; win32-input-mode.
- **Phase 14 (spinner)** — 200 ms tick, RAF-paced.
- **Phase 18 (themes)** — add 7th **"Auto (match terminal)"** via DEC 2031.

### 10.3 Updated end-to-end build order
**1–8** (working chatbox) → **9–10 + 22 (backends) + 23 (sync output)** (foundation) →
**17–19 + 24 (virtualized scrollback) + 25 (scroll) + 14** (visual fidelity) →
**11 + 13 + 26 (clipboard) + 27 (terminal polish)** (interaction) →
**20 + 12 + 15 + 16 + 21 + 28 (robustness)** (flows/advanced).

### 10.4 Crysterm gap update (fourth pass)
- **Already has**: alt-screen, damage-tracked partial redraw, SGR mouse, Unicode width, scrollable
  areas, image backends, CSS theming.
- **Net-new to build**: dual-backend toggle; **DEC 2026 sync output** + allowlist; **virtualized
  scrollback** + output caps; **sticky/pill/unseen-divider/search**; **OSC 52 mux-aware clipboard**
  + native fallbacks; **scroll-wheel acceleration**; **OSC 9;4 progress** + **OSC 21337 tab
  status**; **DEC 2031 auto-theme**; cursor-as-inverse-space focus/idle gating; spacing constants;
  width edge cases (ZWJ/flags/skin-tones); signal/teardown/headless robustness.

---

## Part 11 — General-capability gap analysis (verified against crysterm `src/` + `lib/`)

Scope: **general, framework-wide features** (not widget-specific). Verified by grepping crysterm's
own `src/` **and its shards in `lib/`** — crysterm's terminal layer mostly lives in the **`tput`
shard**, so the gap list is much narrower than Parts 6/8/10 assumed. Evidence = file paths.

### 11.1 Already supported — NOT gaps (don't rebuild these)

**Terminal escape/mode layer (via the `tput` shard + screen core):**
- Alt-screen — the app enters/exits it: `src/crysterm.cr`, `src/screen_connection.cr` (`enter` =
  "alternate buffer + modes"); `lib/tput/src/tput/output/screen.cr`.
- Bracketed paste, focus events, **all mouse modes incl. SGR 1006**:
  `lib/tput/src/tput/{input,keys,mouse,output/mouse}.cr` + `src/screen_mouse.cr` (`Event::Paste`,
  `Event::Focus`, `Event::Mouse`).
- **Kitty keyboard protocol** (progressive-enhancement flags): `lib/tput/src/tput/keyboard.cr`,
  `output/cursor.cr` (CSI u). *(Corrects the earlier inference that this was missing.)*
- **DECSCUSR cursor shapes**: `Tput::CursorShape`, `src/widget_cursor.cr`, `lib/tput/.../output/cursor.cr`.
- Truecolor (24-bit) + 256-color: `src/screen_attributes.cr`, `src/colors.cr`, `lib/tput/.../output/colors.cr`.
- **OSC 8 hyperlinks** (`lib/tput/.../output/emulator.cr`, used in `src/widget/markdown.cr`),
  **OSC 52 clipboard** (`src/drag.cr`, `lib/tput/.../output/{emulator,text}.cr`), **OSC 9;4
  progress** primitive (`lib/tput/src/tput/output/text.cr`), terminal title (OSC 0/2).
- **DEC 2026 synchronized output** — crysterm *emits* it, **default-on**: `src/screen_drawing.cr`
  (`io << "\e[?2026h" … "\e[?2026l"`, `synchronized_output? = true`).
- Light/dark **color-scheme detection** (`Event::ColorScheme`, `src/screen_connection.cr`); bell.

**Rendering / i18n / system:**
- Damage-tracked partial redraw (`src/widget_rendering.cr`, `src/screen_damage.cr`).
- Grapheme / wide-char + **emoji ZWJ / flags / skin-tone width** (`src/misc/util/unicode.cr`,
  `src/screen_rows.cr`, `src/widget_content.cr`).
- Signals, teardown/restore on exit (`src/crysterm.cr`), headless/non-TTY, CSS theming
  (covers the "semantic color slot" idea).
- In-memory input history (Up/Down, `src/widget/lineedit.cr`); list/tree incremental search
  (`src/mixin/item_view.cr`).

### 11.2 Genuine general gaps (currently unsupported)

**A. Color / motion / accessibility policy** *(all confirmed absent in src + lib)*
| # | Gap | Evidence | Where it belongs |
|---|-----|----------|------------------|
| 1 | **`NO_COLOR`/`FORCE_COLOR`/`CLICOLOR`** env honoring | zero matches anywhere | global color policy in `colors.cr`/`screen_attributes.cr` |
| 2 | **Reduced-motion** global flag | absent; crysterm has many effects/animations | global flag gating `Event::Tick` animations |
| 3 | **Screen-reader / accessibility mode** | no linearized/ARIA-equivalent path | a degraded render mode on `Screen` |
| 4 | **Colorblind & ANSI-only theme tiers** | presets exist, these tiers don't | theme presets |

**B. Global input layer**
| # | Gap | Evidence | Where it belongs |
|---|-----|----------|------------------|
| 5 | **Rebindable keymap + multi-key chords** (`keybindings.json`-style) | no `keybinding`/`keymap`/`chord` in src or terminal shards; keys handled per-widget via `on(KeyPress)` | a global keymap layer in `screen_interaction.cr` |
| 6 | **Kill-ring register** (yank/transpose/delete-word, shared) | `Mixin::TextEditing` has basic caret ops only | `src/mixin/text_editing.cr` |

**C. Rendering at scale**
| # | Gap | Evidence | Where it belongs |
|---|-----|----------|------------------|
| 7 | **Virtualized / windowed scrollback** | absent | scroll/render core |
| 8 | **Scroll-wheel acceleration / flood handling / speed multiplier** | only hit was a fire effect | `src/screen_mouse.cr` + scroll mixin |

**D. High-level terminal-integration APIs** *(tput primitives exist; the framework feature/API does not)*
| # | Gap | Evidence | Note |
|---|-----|----------|------|
| 9  | **OSC 9;4 progress** Screen-level API | primitive in `tput/output/text.cr`, no high-level API | thin wrapper |
| 10 | **OSC 21337 terminal tab status** | fully absent | new |
| 11 | **OSC 7 cwd reporting** | absent | minor |
| 12 | ~~DEC 2031 live theme-change subscription~~ → **SUPPORTED** (see §11.5) | `lib/tput/.../response.cr:185`, `keys.cr` → `Event::ColorScheme` | not a gap |
| 13 | **Sync-output allowlist gating** | crysterm emits DEC 2026 unconditionally; Claude gates by allowlist + disables under tmux | refine `screen_drawing.cr` |
| 14 | **Multiplexer-aware OSC 52 wrapping** (tmux `raw+dcs`, screen `dcs`) + native clipboard fallbacks | OSC 52 exists, mux wrapping doesn't; `tput/probe.cr` gives partial terminal probing | extend clipboard path |

**E. Persistence**
| # | Gap | Evidence | Where it belongs |
|---|-----|----------|------------------|
| 15 | **State to disk** (input history, UI prefs across restart) | history is in-memory only (`lineedit.cr`); `focus.history_size` is unrelated focus history | a small persistence layer |

### 11.3 Borderline (excluded — these are scroll-area / input *widget* features, not framework-wide)
Sticky follow-tail, jump-to-bottom pill + unseen-count, unseen divider, in-*transcript* search, and
the dual classic-vs-fullscreen render backends (crysterm is fundamentally a fullscreen alt-screen
TUI). These map to Phases 22/24/25 if wanted, but are not "general" in the sense of this section.

### 11.4 Recommended quick wins
**#1 (`NO_COLOR`/`FORCE_COLOR`)**, **#2 (reduced-motion)**, **#5 (rebindable keymap + chords)** —
all genuinely global, currently absent, and low-effort relative to impact.

---

### 11.5 Round-5 code audit — verified corrections to the gap list

Deep read of `src/` + `lib/` (two audits) corrected several Part 11 entries. **crysterm supports more
than first assumed.**

**Move to "supported" (were listed as gaps/partial):**
- **DEC 2031 live color-scheme notify** — `supports_color_scheme_notifications?` + `request_color_scheme`
  → `Event::ColorScheme` (`lib/tput/src/tput/response.cr:185`, `keys.cr`). *(was gap #12)*
- **Semantic color tokens / theme system** — `Theme.dark/.light/.from_terminal`, **8 roles**
  (surface/text/accent/muted/success/warning/danger/info) **× 5 shades**, CSS custom properties
  (`src/style/css/theme.cr`). Equals/exceeds Claude's "semantic slots."
- **Frame-rate throttle / FPS cap** — `interval` + phase-locked trailing throttle
  (`src/screen_rendering.cr:62,203`). Not a gap.
- **Animation system** — `Event::Tick`, `Animation` (8 easings), CSS transitions, CSS `@keyframes`,
  fade (`src/animation.cr`, `widget_transition.cr`, `widget_animation.cr`, `widget_fade.cr`).
- **In-band resize (DEC 2048)** + SIGWINCH debounce (`src/screen_resize.cr`, `tput/features.cr:142`).
- **OSC 52 clipboard at framework level** — `set_clipboard`/`request_clipboard`
  (`src/screen_interaction.cr:169-188`) + `Event::Paste`.
- **Drag-and-drop** — full MIME-typed model + 6 events (`src/drag.cr`).
- **Focus management** — history stack, Tab nav, save/restore (`src/screen_focus.cr`).
- **Global key routing** — `grab_keys`/`propagate_keys`/`always_propagate` + kitty/modifyOtherKeys
  protocol toggle (`src/screen_interaction.cr`). *(routing yes — rebinding still no, see below)*
- **Config + YAML persistence** — Superconf, `~/.config/crysterm/config.yml`, `CRYSTERM_*` env,
  41 options (`src/config/builtins.cr`, `src/config.cr`).
- **Caret text editing** — grapheme-aware movement + insert/delete + viewport autoscroll
  (`src/mixin/text_editing.cr`).

**Refined / newly-found gaps:**
- **Readline editing depth** (broader than the earlier "kill-ring"): `text_editing.cr` has only
  char/grapheme moves + Home/End/PageUp/Down + insert/delete. **Missing: word ops (Ctrl-W,
  word-move), line ops (Ctrl-U/K/A/E), undo/redo, kill-ring/yank.**
- **External editor** (`$EDITOR`/`$VISUAL`, `ctrl+g`) — **absent** (Claude has it). NEW.
- **Desktop notifications** (OSC 9 / 777 / 99) — **absent**; bell is present. NEW.
- **Follow-tail / stay-at-bottom auto-scroll** — **absent** (approximable via `ensure_visible`);
  promoted from "borderline" to a real general scroll-area gap.
- **`modifyOtherKeys`** — probed but **not wired** into event translation (partial).

### 11.6 Consolidated FINAL general-capability gap list (code-verified)

- **A. Color / motion / a11y**: `NO_COLOR`/`FORCE_COLOR`/`CLICOLOR`; **reduced-motion** (high value —
  crysterm has a rich animation system to gate); screen-reader / a11y mode; colorblind & ANSI-only
  theme tiers.
- **B. Input**: rebindable keymap + **multi-key chords**; **readline editing depth** (word/line ops,
  undo/redo, kill-ring); wire `modifyOtherKeys` to events; **external `$EDITOR`** integration.
- **C. Scroll / scale**: content **virtualization/windowing**; **follow-tail** auto-scroll mode;
  **scroll-wheel acceleration**.
- **D. Terminal-integration APIs**: OSC 9;4 progress **high-level API** (tput primitive exists);
  **OSC 21337 tab status**; **OSC 7 cwd**; **sync-output allowlist + tmux gating** (currently emits
  unconditionally); **mux-aware OSC 52 wrapping** (tmux `raw+dcs`, screen `dcs`) + native clipboard
  fallbacks; **desktop notifications** (OSC 9/777/99).
- **E. Persistence**: **input history + UI prefs/session to disk** (config file exists; *state* doesn't).

### 11.7 Plan delta (slots the verified gaps into existing phases)
> **Status — branch `quick-wins-general` (implemented, with specs; full suite green):**
> ✅ `NO_COLOR`/`FORCE_COLOR`/`CLICOLOR[_FORCE]` honoring + a `colors.depth` config option
> (`Screen.resolve_color_depth` + `Colors.sgr_color_to` monochrome guard, `spec/color_depth_spec.cr`);
> ✅ reduced-motion (`render.reduced_motion`, collapses tweens in `Animation#start`);
> ✅ OSC 7 cwd + ✅ OSC 9;4 progress (`Screen#report_cwd` / `Screen#progress`, added to the `tput`
> shard and mirrored to `../tput.cr`); ✅ sync-output made configurable
> (`render.synchronized_output`). OSC 52 was found **already** tmux-DCS-wrapped (via `_tprint`);
> only GNU `screen` is unwrapped.

- **Phase 9 (terminal layer)**: ✅ `NO_COLOR`/`FORCE_COLOR`; ✅ OSC 7; ☐ OSC 21337 tab status;
  ◐ sync-output now configurable (☐ auto allowlist/tmux *gating* still open); ◐ OSC 52 already
  tmux-wrapped (☐ GNU `screen` wrapping); ☐ wire `modifyOtherKeys`.
- **Phase 11 (keymap/editing)**: ☐ rebindable keymap + chords; ☐ readline depth + kill-ring + undo;
  ☐ `$EDITOR` integration.
- **Phase 14 / animation**: ✅ global **reduced-motion** flag gating tweens (`Animation#start`).
- **Phase 15 (a11y)**: ☐ screen-reader mode; ☐ colorblind / ANSI-only theme tiers (extend `Theme`).
- **Phases 24/25 (scroll)**: ☐ content virtualization; ☐ **follow-tail** mode; ☐ scroll-wheel accel.
- **Phase 27**: ✅ OSC 9;4 progress high-level API; ☐ desktop notifications (OSC 9/777/99).
- **Phase 28**: ☐ persist input history + UI prefs.

---

## Part 12 — Residual Claude findings + exact constants (rounds 7–8)

### 12.1 Composed / dynamic UI (residual pass A)
- **Status-line custom-command contract**: command receives **JSON on stdin** —
  `session_id`, `model:{id,display_name}`, `workspace:{current_dir,project_dir,…}`,
  `cost:{total_input_tokens,total_output_tokens,total_cost_usd,total_duration_ms,total_lines_added,
  total_lines_removed,model_usage}`, `context_window:{…,context_window_size}`, `exceeds_200k_tokens`,
  `rate_limits:{five_hour,seven_day}:{used_percentage,resets_at}`, `output_style`, `effort`,
  `fast_mode`, `agent`, `pr`, `worktree`. **stdout rendered in dimmed colors**; use `printf` for ANSI.
  Separate **`subagentStatusLine`** key; `settings.json` `statusLine:{type:"command",command}`.
- **Interrupt hint**: no literal "esc to interrupt" — composed from the `interrupt` keybinding action
  (Ctrl-C/escape). All hint bars are composed via conditional `push()` (the FleetView pattern).
- **@-mention picker**: file index (`generateFileSuggestions`/`createFileIndexCache`),
  longest-common-prefix tab-complete, `respectGitignore`; **prefix/substring match (not fuzzy)**;
  shares its renderer with the slash-command menu.
- **Slash arg hints**: frontmatter `argument-hint`; dynamic `getArgumentCompletions` (e.g. `/config
  [key=value]`, `/plugin`); empty message `No commands match "…"`.
- **External editor**: **`ctrl+g`** (rebindable to `ctrl+e`); resolves `$EDITOR`/`$VISUAL` else
  `open --goto --line`; `input_stash` stashes the draft.
- **Model picker** (`/model`): Default (recommended) / Opus Plan Mode / Sonnet + "(1M context)"
  variants + capability blurbs.
- **`/config` items** (typed list): booleans (`verbose`, `autoScroll`, `externalEditorContext`,
  `prStatus`, `chrome`, `autoConnectIde`…); enums (`model`, `editorMode:[normal,vim]`,
  `diffTool:[terminal,auto]`, `notifChannel:[iterm2,iterm2_with_bell,terminal_bell,kitty,ghostty,
  notifications_disabled]`, `defaultView:[transcript,chat,default]`, `teammateMode:[auto,tmux,
  iterm2,in-process]`, `worktreeBaseRef:[fresh,head]`).
- **Bash output**: collapsible `(ctrl+o to expand)`, `(No output)`; background "Running in the
  background"; **ANSI preserved** (not stripped); MCP output **>100K tokens auto-truncated**.
- **Multiline/paste**: terminal-setup Option+Enter / Shift+Enter; placeholders
  `[Pasted text #N +M lines]` / `[Image #N]` / `[…Truncated text #N +M lines]`; `snapToGraphemeBoundary`.

### 12.2 Exact constants for reimplementation (residual pass B)
*(reference values — crysterm needn't match them, but they're good defaults for a chat client.)*
- **Theme palette — dark/default (RGB)**: `claude (215,119,87)`, `text (255,255,255)`,
  `success (78,186,101)`, `error (255,107,128)`, `warning (255,193,7)`, `permission (177,185,249)`,
  `planMode (72,150,140)`, `autoAccept (175,135,255)`, `bashBorder (253,93,177)`,
  `diffAdded (34,92,43)` / `diffRemoved (122,41,54)`, `diffAddedWord (56,166,96)` /
  `diffRemovedWord (179,89,107)`. (light / daltonized = RGB variants; `*-ansi` themes use
  `ansi:<name>`.)
- **Auto-compact math**: window min 100000 / max 1000000, **default 200000**; arms at **~80%**
  (buffer 0.2); reserves **13000** (hard ceiling `window−13000`); **disabled if window<200000**;
  "blocked" at `window−3000`. Context-string parser: bare int 100–1000 ⇒ ×1000.
- **Output / timeout caps**: `BASH_DEFAULT_TIMEOUT 120000`, `BASH_MAX_TIMEOUT 600000`;
  `BASH_MAX_OUTPUT_LENGTH 30000` (cap 150000); `TASK_MAX_OUTPUT_LENGTH 32000` (cap 160000);
  `messageIdleNotifThresholdMs 60000`; `cleanupPeriodDays 30`; API timeout 600000; query maxRetries 2.
- **Spinner**: braille frames @ **200 ms**; **187** rotating gerund tips (Accomplishing … Zesting).
- **Per-terminal version gates**: ghostty ≥1.2.0 & iTerm ≥3.6.6 (progress/scroll caps); Konsole
  ≥211200 (kitty keyboard); WezTerm ≥20200620, vscode ≥1.72, VTE ≥0.50 (hyperlinks);
  Apple_Terminal color-depth 2.
- **Model ids**: opus→`claude-opus-4-8`, sonnet→`claude-sonnet-4-6`, haiku→`claude-haiku-4-5`;
  output tokens opus-4-8 64000/128000, sonnet-4-6 32000/128000.

---

## Appendix — How to refresh these findings

```sh
BIN=~/.local/share/claude/versions/<version>          # native Mach-O binary
strings -n 5 "$BIN" > claude.strings.txt              # ASCII strings (drops UTF-8!)
grep -oiE '(ctrl|shift|meta|alt|cmd)\+[a-z0-9]+' claude.strings.txt | sort | uniq -c | sort -rn
grep -oE '"/[a-z][a-z0-9_-]+"' claude.strings.txt | sort -u    # slash commands (has path noise)
# Glyphs — SCAN BOTH WAYS (this is the gotcha that produced a wrong "sparkle unused" note):
#  (a) raw UTF-8 byte sequences in the binary:
python3 -c 'import sys;d=open(sys.argv[1],"rb").read();
print({g:d.count(g.encode()) for g in "⏺⎿❯✓✗○◯├└│─╭╮╰╯"})' "$BIN"
#  (b) \uXXXX ESCAPE form in the strings file — many glyphs (spinner frames, sparkles, dots) are
#      stored as ASCII escapes and are INVISIBLE to (a):
grep -oiE '\\u(23fa|25cf|2722|2733|2736|273b|273d|2713|2717)' claude.strings.txt | sort | uniq -c
grep -oE 'frames:\[[^]]*\]' claude.strings.txt        # spinner/animation frame arrays
```
Then cross-check the live UI with `claude`, `/help`, and the keybindings screen — the binary shows
*what exists*; the running app shows *how it behaves*.
