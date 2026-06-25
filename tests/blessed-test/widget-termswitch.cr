require "../../src/crysterm"

# Port of Blessed's test/widget-termswitch.js
# A centered 80%x80% green box with a line border, plus a centered 50%x50%
# draggable ScrollableText holding a long multi-line String that can be
# scrolled with the mouse, arrow keys or vi keys.
module Crysterm
  # NOTE: Blessed reads test/git.diff for the scrollable content. We don't have
  # that file, so a long multi-line String is substituted to make scrolling
  # visible.
  lorem = (1..40).map { |i| "Line #{i}: Lorem ipsum dolor sit amet, consectetur adipiscing elit." }.join("\n")

  s = Screen.new optimization: OptimizationFlag::SmartCSR, always_propagate: [::Tput::Key::CtrlQ]

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
    # NOTE: Blessed's `mouse: true` has no per-widget kwarg in Crysterm; mouse
    # wheel scrolling comes from being scrollable and mouse drag from
    # `draggable: true`, so it is dropped.
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

  # NOTE: Blessed switches the terminal to 'vt100' after 1s via setTimeout and
  # re-renders. Crysterm has no runtime terminal switch, so the timeout and the
  # terminal-switch are dropped.
end
