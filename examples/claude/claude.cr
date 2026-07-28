# FEATURE: rich text — Markdown with GFM extensions.
#
# `TextDocument` imports and exports Markdown (via CommonMark + GFM), HTML and
# Crysterm's native tags; `TextEdit`/`TextBrowser` render it with headings,
# bold/italic/strikethrough, inline code and links, fenced code blocks,
# blockquotes, GFM tables (real box-drawing tables), GFM task lists and GFM
# alert admonitions — all themable via `TextTheme`, all editable with full
# undo, and round-trippable back to Markdown/HTML.
#
# The demo plays a Claude session: the "user" types a prompt into the input
# line, and the reply — task lists ticking off, a diff-style code block, a
# results table, an alert, emoji — streams into a read-only `TextBrowser`
# exactly as Markdown arrives from the model.

require "../../src/crysterm"

include Crysterm

PROMPT = "Add a --verbose flag and run the test suite"

REPLY = <<-MD
**Done.** Here's what changed: ✅

- [x] Added `--verbose` / `-v` to the option parser
- [x] Threaded `verbose?` into the runner
- [ ] Update the man page *(follow-up)*

```crystal
opts.on("-v", "--verbose", "Print each step") { config.verbose = true }
```

| Suite | Examples | Failures | Time |
| ----- | -------- | -------- | ---- |
| unit  | 214      | 0        | 1.9s |
| e2e   | 37       | 0        | 4.2s |

✅ All suites green — ⚠️ 2 deprecation warnings (non-blocking)

> [!NOTE]
> `spec/cli_spec.cr` now asserts the ~~old~~ **new** banner — see the
> [CLI guide](https://example.org/cli) for the `--verbose` conventions. 🎉
MD

s = Window.new title: "Claude"

# --- Chrome ------------------------------------------------------------------

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  parse_tags: true,
  content: " {#d77757-fg}✳{/} {bold}Claude{/bold}" \
           " {#8a94a6-fg}· TextBrowser rendering streamed GFM Markdown{/}"

view = Widget::TextBrowser.new parent: s, top: 1, left: 0, width: "100%", height: "100%-5"

input_frame = Widget::Box.new parent: s, bottom: 1, left: 0, width: "100%", height: 3,
  style: Style.new(border: true)
Widget::Box.new parent: input_frame, top: 0, left: 1, width: 2, height: 1,
  parse_tags: true, content: "{#d77757-fg}❯{/}"
input = Widget::LineEdit.new parent: input_frame, top: 0, left: 3, width: "100%-5", height: 1

Widget::Box.new parent: s, bottom: 0, left: 0, width: "100%", height: 1,
  parse_tags: true,
  content: " {#8a94a6-fg}GFM: tables · task lists · alerts · code · links — C-z undo · Ctrl-Q quit{/}"

# --- The session, replayed ---------------------------------------------------

# The transcript so far, as Markdown. The reply streams in chunk by chunk and
# the whole thing is re-imported each beat — `set_markdown` is cheap at this
# scale and exactly what a live LLM client does.
transcript = ""
reveal = 0

render_view = -> do
  streamed = REPLY[0, reveal]
  cursor = reveal < REPLY.size ? " ▌" : ""
  view.set_markdown "#{transcript}#{streamed}#{cursor}"
end

tick = 0
s.every(0.1.seconds) do
  case phase = tick % 64
  when 0
    transcript = ""
    reveal = 0
    input.value = ""
    view.set_markdown ""
  when 1..14 # the user types (two characters per beat)…
    input.value = PROMPT[0, Math.min(phase * 2, PROMPT.size)]
  when 15 # …and submits: the prompt joins the transcript
    input.value = ""
    transcript = "#### ❯ #{PROMPT}\n\n✳ *Thinking…*\n\n"
    render_view.call
  when 18..56 # the reply streams in
    transcript = "#### ❯ #{PROMPT}\n\n" if phase == 18
    reveal = Math.min(REPLY.size, (phase - 17) * (REPLY.size // 38 + 1))
    render_view.call
  end
  tick += 1
end

s.exec
