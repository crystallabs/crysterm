# FEATURE: `{}` content tags.
#
# With `parse_tags: true`, widget content may carry inline `{tag}` markup:
# named and hex colors (`{red-fg}`, `{#57c7ff-fg}`, `{...-bg}`), text
# attributes (`{bold}`, `{underline}`, `{inverse}`, `{blink}`) that nest and
# restore the enclosing state on close, line alignment (`{center}`,
# `{right}`) plus the `{|}` left/right separator, and literals — `{open}` /
# `{close}` print real braces, `{escape}…{/escape}` passes a span through
# verbatim. Each panel shows the tag source (dimmed) next to its effect.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Content tags"

DIM = "#565f89"

# Dim "source" rendition of a tag: literal braces via {open}/{close}.
def tag(name)
  "{#{DIM}-fg}{open}#{name}{close}{/#{DIM}-fg}"
end

# Backdrop and caption strip.
Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: "#1a1b26")
Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Inline {open}tag{close} markup in widget content — parse_tags: true{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

# --- Colors ------------------------------------------------------------------

Widget::Box.new parent: s, top: 2, left: 1, width: 39, height: 10,
  label: " Colors ", parse_tags: true,
  content: "\n#{tag "red-fg"}      {red-fg}named color{/red-fg}\n" \
           "#{tag "#57c7ff-fg"}  {#57c7ff-fg}24-bit hex color{/#57c7ff-fg}\n" \
           "#{tag "#ff9e64-bg"}  {#ff9e64-bg}{#1a1b26-fg} hex background {/#1a1b26-fg}{/#ff9e64-bg}\n\n" \
           "{green-fg}nested: green {yellow-fg}yellow{/yellow-fg}\n" \
           "        … restored on close{/green-fg}",
  style: Style.new(fg: "#c0caf5", bg: "#24283b", border: Border.new(fg: "#3b4261"))

# --- Attributes --------------------------------------------------------------

Widget::Box.new parent: s, top: 2, left: 41, width: 38, height: 10,
  label: " Attributes ", parse_tags: true,
  content: "\n#{tag "bold"}       {bold}bold text{/bold}\n" \
           "#{tag "underline"}  {underline}underlined{/underline}\n" \
           "#{tag "inverse"}    {inverse} inverse video {/inverse}\n" \
           "#{tag "blink"}      {blink}blinking{/blink}\n\n" \
           "{bold}bold {underline}+ underline{/underline} nested{/bold}",
  style: Style.new(fg: "#c0caf5", bg: "#24283b", border: Border.new(fg: "#3b4261"))

# --- Alignment, the left/right separator, literals ---------------------------

Widget::Box.new parent: s, top: 12, left: 1, width: 78, height: 9,
  label: " Alignment, the left/right separator & literals ", parse_tags: true,
  content: "{center}#{tag "center"} this heading is centered{/center}\n" \
           "{right}pushed flush right #{tag "right"}{/right}\n" \
           "The left part{|}" \
           "the {#7dcfff-fg}pipe{/#7dcfff-fg} tag splits a line left/right\n\n" \
           "{#9ece6a-fg}Literals:{/#9ece6a-fg} {open}open{close} and {open}close{close} print real braces — {bold}{open}like this{close}{/bold}\n" \
           "{#9ece6a-fg}Escape:{/#9ece6a-fg}   #{tag "escape"}{escape}{bold}this span{/bold} passes through verbatim{/escape}#{tag "/escape"}",
  style: Style.new(fg: "#c0caf5", bg: "#24283b", border: Border.new(fg: "#3b4261"))

# Subtle animated accent: a hue-cycling gradient rule under the panels.
clock = Timer.new 0.1.seconds
Widget::Gradient.new parent: s, top: 22, left: 1, width: 78, height: 1,
  animate: clock, speed: 0.02

s.exec
