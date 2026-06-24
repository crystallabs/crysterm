# IMPRESSIVE DEMO: a Markdown viewer.
#
# `Widget::Markdown` parses CommonMark (markd shard) and renders it as styled,
# scrollable terminal text — modeled after Qt's QTextBrowser + setMarkdown.
# Scroll with the arrow keys / PgUp/PgDn. Press q / Ctrl+C to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Markdown"

doc = <<-MD
# Crysterm Markdown

A read-only viewer modeled after Qt's **QTextBrowser**.

## Features

- *Headings*, **bold**, *italic*, ~~strike~~
- `inline code` and fenced blocks
- ordered and nested lists:
  1. one
  2. two
- blockquotes and rules
- [links](https://crystal-lang.org) (collected, click wiring TBD)

> "Simplicity is the ultimate sophistication."

```
def hello
  puts "world"
end
```

---

That's it.
MD

md = Widget::Markdown.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  markdown: doc, style: Style.new(fg: "white", bg: "#10141c", border: true)
md.focus

# Print activated links (none fire without click wiring, but the API is here).
md.on(Event::AnchorClick) { |e| STDERR.puts "clicked: #{e.url}" }

s.exec
