# Example: Crysterm::Widget::MarkdownViewer
#
# A markdown reading pane with a live table-of-contents sidebar: a TocView and
# a TextBrowser over the same document in a Splitter. Selecting a sidebar
# entry jumps the browser to that heading; `t` toggles the sidebar.
# Run it:     crystal run tests/widget/markdown_viewer/markdown_viewer.cr
require "../example"

include Crysterm
include Crysterm::Widgets

PAGE = <<-MD
  # MarkdownViewer

  One document, two views: the sidebar is the document's heading
  outline, the pane is a `TextBrowser` over the same `TextDocument`.

  The outline is `TextDocument#outline` — the same flat heading list
  the inline `TextToc` renders, here rebuilt live as a `Tree`, so it
  costs the document nothing: no reflow, no undo entries, no moved
  reading position.

  ## Navigation

  Arrows move the outline selection; Enter jumps the browser to the
  selected heading. The sidebar tracks the document live, so a page
  being streamed in grows its outline as headings arrive.

  Anchors identify entries across rebuilds: a heading inserted above
  shifts every row, but the selection and collapsed state stay with
  their headings. A skipped level (an `h1` straight to an `h3`)
  gets a filler node, so the tree keeps its shape.

  ## Links

  In the browser, Tab cycles link focus and Enter follows: a
  same-document anchor like [Sidebar](#sidebar) scrolls in place,
  and with a `loader` set, a cross-page link loads a new document —
  re-pointing the sidebar at its outline.

  History records each step with the reading position it was left
  at, so Backspace returns to the exact spot — following an anchor
  is itself a history step.

  ## Sidebar

  Hide it (`show_toc = false`) and the browser takes the full width;
  the detached outline keeps tracking the document and comes back
  current. The divider between the panes is draggable, and
  `toc_width` sets the extent a (re)shown sidebar gets.
  MD

Crysterm::WidgetExample.run("MarkdownViewer",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.6
    d.key :down, dwell: 0.5  # select "Navigation"
    d.key :enter, dwell: 0.8 # jump the browser to it
    d.key :down, times: 2, dwell: 0.4
    d.key :enter, dwell: 0.8 # jump to "Sidebar"
    d.char 't', dwell: 0.9   # hide the sidebar
    d.char 't', dwell: 0.8   # and bring it back
  }) do |window|
  window.stylesheet = <<-CSS
    MarkdownViewer { border: solid; }
    TocView { color: #7aa2f7; background-color: #1f2335; }
    TextBrowser { color: #c0caf5; background-color: #24283b; }
    .divider { background-color: #3b4261; }
    CSS

  mv = Widget::MarkdownViewer.new parent: window,
    top: 0, left: 0, width: "100%", height: "100%",
    document: TextDocument.from_markdown(PAGE)

  window.on(Crysterm::Event::KeyPress) do |e|
    mv.show_toc = !mv.show_toc? if e.char == 't'
  end

  mv.toc_view.focus
end
