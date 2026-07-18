require "../../src/crysterm"

# Port of Blessed's test/widget-csr.js
# A centered 80%x80% green box with a line border, plus a centered 50%x50%
# draggable ScrollableText whose long, multi-line content can be scrolled with
# the mouse, arrow keys or vi keys. Demonstrates that change-scroll-region
# (CSR) optimization still renders correctly with overlapping widgets.
module Crysterm
  # Blessed reads test/git.diff for scrollable content; substituted with a
  # generated multi-line String.
  lorem = (1..40).map { |i| "Line #{i}: Lorem ipsum dolor sit amet, consectetur adipiscing elit." }.join("\n")

  # Blessed's cleanSides/_oscroll overrides and CSR test-harness assertions
  # have no visual purpose; dropped. Only the two visible widgets remain.
  s = Window.new optimization: OptimizationFlag::SmartCSR, always_propagated_keys: [::Tput::Key::CtrlQ]

  btext = Widget::Box.new(
    parent: s,
    left: "center",
    top: "center",
    width: "80%",
    height: "80%",
    style: Style.new(bg: "green", border: BorderType::Line),
    content: "CSR should still work.",
  )

  text = Widget::ScrollableText.new(
    parent: s,
    content: lorem,
    style: Style.new(border: BorderType::Line),
    left: "center",
    top: "center",
    draggable: true,
    width: "50%",
    height: "50%",
    # Blessed's `mouse: true` has no per-widget kwarg here; wheel scrolling
    # comes from being scrollable, drag from `draggable: true`.
    keys: true,
    vi: true,
  )

  text.focus

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render

  s.exec
end
