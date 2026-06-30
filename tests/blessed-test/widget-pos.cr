require "../../src/crysterm"

# Port of Blessed's test/widget-pos.js
#
# Demonstrates absolute vs. relative widget positioning: a `main` box with an
# `inner` box positioned at top:2,left:2 with width/height 50% of its parent.
#
# NOTE: blessed's version was primarily an assertion test harness (assert(...),
# screen.program.cols/rows pokes, screen.alloc(), and a reset() helper). That
# whole harness is dropped here; we keep the visual demo. Crysterm DOES expose
# the computed-position accessors (aleft/atop/aright/abottom/awidth/aheight,
# and relative rleft/rtop/...), so we display a few of them on `inner`.
module Crysterm
  s = Window.new always_propagate: [::Tput::Key::CtrlQ]

  main = Widget::Box.new \
    parent: s,
    width: 115,
    height: 14,
    top: 2,
    left: 2,
    content: "Welcome to my program",
    style: Style.new(bg: "yellow")

  inner = Widget::Box.new \
    parent: main,
    width: "50%",
    height: "50%",
    top: 2,
    left: 2,
    content: "Hello",
    style: Style.new(bg: "blue")

  # Append a second line showing the computed/relative positions of `inner`.
  inner.set_content \
    inner.content.to_s + "\n" + {
    "aleft"   => inner.aleft,
    "aright"  => inner.aright,
    "atop"    => inner.atop,
    "abottom" => inner.abottom,
    "awidth"  => inner.awidth,
    "aheight" => inner.aheight,
    "rleft"   => inner.rleft,
    "rtop"    => inner.rtop,
  }.to_s

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::Escape || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render
  s.exec
end
