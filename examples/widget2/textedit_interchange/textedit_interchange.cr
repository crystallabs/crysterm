# Example: Crysterm::Widget::TextEdit interchange (TEXTEDIT.md Phase 3)
#
# Left pane: a `TextEdit` filled via `set_markdown` — headings, emphasis,
# code, lists and links arrive as TextDocument block/char formats. The script
# selects the formatted paragraph on the left and rich-copies it: the
# clipboard carries a `TextDocumentFragment` beside the plain text (which is
# all the OSC-52 system clipboard gets). Pasting into the right editor brings
# the formats along, and the bottom box live-exports the right document back
# out with `to_markdown` — the round trip in one screen.
# Run it:     crystal run examples/widget2/textedit_interchange/textedit_interchange.cr
require "../example"

SOURCE_MD = <<-MD
  # Interchange

  Phase 3 links **markdown**, *HTML* and
  `tags` to the document framework.

  - rich clipboard
  - [links](https://example.com) too

  > Copy left, paste right.
  MD

left : Crysterm::Widget::TextEdit? = nil
right : Crysterm::Widget::TextEdit? = nil
export : Crysterm::Widget::Box? = nil

refresh_export = -> do
  export.try { |e| right.try { |r| e.content = r.to_markdown } }
end

ctl = ->(k : Tput::Key) { Crysterm::Event::KeyPress.new '\0', k }

Crysterm::WidgetExample.run("TextEdit interchange",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.6
    # Select the formatted paragraph + list on the left.
    d.act(dwell: 0.8) do
      left.try do |l|
        text = l.document.to_plain_text
        l.selection_anchor = text.index!("Phase 3")
        l.cursor_pos = text.index!(" too") + 4
      end
    end
    # Rich-copy it: fragment + plain text land on the clipboard.
    d.act(dwell: 0.4) { left.try &._listener(ctl.call(Tput::Key::CtrlC)) }
    d.type "Pasted: ", dwell: 0.08
    # Paste into the right editor — the formats arrive with the text.
    d.act(dwell: 0.8) do
      right.try &._listener(ctl.call(Tput::Key::CtrlV))
      refresh_export.call
    end
    d.hold 2.5
  }) do |screen|
  # `#export`, not a bare `Box` rule: TextEdit derives from Box and the
  # border labels are Box children, so a type rule would restyle them all.
  screen.stylesheet = "TextEdit { border: solid; color: #c0caf5; background-color: #1f2335; } " \
                      "#export { border: solid; color: #9aa5ce; background-color: #16161e; }"

  l = Crysterm::Widget::TextEdit.new parent: screen, left: 1, top: 1, width: 38, height: 13
  l.label = " set_markdown "
  l.set_markdown SOURCE_MD
  left = l

  r = Crysterm::Widget::TextEdit.new parent: screen, left: 41, top: 1, width: 38, height: 13
  r.label = " paste target "
  right = r

  e = Crysterm::Widget::Box.new parent: screen, left: 1, top: 14, width: 78, height: 8
  e.css_id = "export"
  e.label = " right.to_markdown "
  export = e

  r.focus
  # Start editing right away (see the base textedit example): typed keys and
  # C-c/C-v route here; the export box refreshes after every keystroke.
  r.read_input
  r.on(Crysterm::Event::KeyPress) { refresh_export.call }
  refresh_export.call
end
