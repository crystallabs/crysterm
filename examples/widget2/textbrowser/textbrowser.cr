# Example: Crysterm::Widget::TextBrowser + TEXTEDIT.md Phase 4 structures
#
# A read-only rich-text browser over markdown pages: TextList bullets and
# numbering, blockquote bars, horizontal rules and a box-drawing GFM table
# all render as decorations; Tab cycles link focus, Enter follows a link
# through the `loader`, Backspace goes back through the history.
# Run it:     crystal run examples/widget2/textbrowser/textbrowser.cr
require "../example"

PAGES = {
  "home" => <<-MD,
    # Phase 4 tour

    Structures render as decorations — the document holds only text:

    - one `TextList` per markdown list
    - nesting via the list-format indent
      - like this
    - and **inline formats** still work

    1. numbered lists
    2. renumber live

    > Blockquotes are a block property now,
    > drawn as bars per level.

    | widget | role |
    | --- | --- |
    | TextEdit | editor |
    | TextBrowser | viewer |

    ---

    Follow the [details](details) link with Tab + Enter.
    MD
  "details" => <<-MD,
    # Details

    You arrived by activating an anchor: `AnchorClick` fired,
    the `loader` resolved the URL to a new `TextDocument`, and
    the history recorded the step.

    Press Backspace to go [home](home).
    MD
}

Crysterm::WidgetExample.run("TextBrowser",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.8
    d.key :tab, dwell: 0.5       # focus the link
    d.key :enter, dwell: 0.8     # follow it
    d.key :backspace, dwell: 0.8 # and back
    d.hold 1.0
  }) do |screen|
  screen.stylesheet = "TextBrowser { border: solid; color: #c0caf5; background-color: #1f2335; }"

  tb = Crysterm::Widget::TextBrowser.new parent: screen,
    top: "center", left: "center", width: 58, height: 24

  tb.loader = ->(url : String) {
    PAGES[url]?.try { |md| Crysterm::TextDocument.from_markdown(md) }
  }
  tb.source = "home"

  tb.focus
  tb.read_input
end
