# Example: Crysterm::Widget::TextEdit
#
# Rich-text editor over a `TextDocument` (TEXTEDIT.md Phase 2): character
# formats live on the document's fragments and survive editing anywhere,
# `C-z`/`M-z` drive undo/redo, and a full-width `ExtraSelection` paints the
# current-line highlight that follows the caret.
# Run it:     crystal run examples/widget2/textedit/textedit.cr
require "../example"

Crysterm::WidgetExample.run("TextEdit",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :up, times: 3, dwell: 0.25
    d.key :end, dwell: 0.25
    d.type " Edits keep formats.", dwell: 0.08
    d.key :down, times: 3, dwell: 0.3
    d.hold 1.0
  }) do |screen|
  screen.stylesheet = "TextEdit { border: solid; color: #c0caf5; background-color: #1f2335; }"

  te = Crysterm::Widget::TextEdit.new parent: screen,
    top: "center", left: "center", width: 54, height: 12,
    content: <<-TEXT
      Rich text editing
      Bold, italic and underline are fragment formats
      on a TextDocument; editing anywhere keeps them
      attached to their text.
      Undo with C-z, redo with M-z.
      TEXT

  doc = te.document
  text = doc.to_plain_text

  # First block is a heading; decorate a few runs by word.
  doc.apply_block_format(0, 0, Crysterm::TextBlockFormat.new(heading_level: 1, bg: "#292e42"))
  fmt = ->(word : String, f : Crysterm::TextCharFormat) do
    if i = text.index(word)
      doc.apply_char_format(i, i + word.size, f)
    end
  end
  fmt.call "Bold", Crysterm::TextCharFormat.new(bold: true)
  fmt.call "italic", Crysterm::TextCharFormat.new(italic: true)
  fmt.call "underline", Crysterm::TextCharFormat.new(underline: true)
  fmt.call "TextDocument", Crysterm::TextCharFormat.new(fg: "#7aa2f7")
  fmt.call "C-z", Crysterm::TextCharFormat.new(fg: "#9ece6a", bold: true)
  fmt.call "M-z", Crysterm::TextCharFormat.new(fg: "#e0af68", bold: true)
  # The decoration above shouldn't be what C-z undoes in the demo.
  doc.undo_stack.clear

  # Current-line highlight: a full-width ExtraSelection re-anchored to the
  # caret after every key/click (the handlers run after the editing mixin's,
  # so `cursor_pos` is already updated).
  highlight = Crysterm::TextCharFormat.new(bg: "#2a2f4a")
  update_line_highlight = -> do
    c = Crysterm::TextCursor.new(doc, te.cursor_pos)
    te.extra_selections = [Crysterm::Widget::TextEdit::ExtraSelection.new(c, highlight, full_width: true)]
  end

  te.focus
  # Start editing right away (the widget is the only focusable, so an
  # `input_on_focus` Focus event never fires — it is already focused).
  te.read_input
  te.on(Crysterm::Event::KeyPress) { update_line_highlight.call }
  te.on(Crysterm::Event::Click) { update_line_highlight.call }
  update_line_highlight.call
end
