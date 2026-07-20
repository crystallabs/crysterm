require "../../src/crysterm"

# Port of Blessed's test/widget-pos.js
#
# Demonstrates absolute vs. relative widget positioning: a `main` box with an
# `inner` box positioned at top:2,left:2 with width/height 50% of its parent.
#
# Blessed's assertion harness (assert(...), screen.alloc(), reset(), etc.) is
# dropped; we keep the visual demo and show Crysterm's computed-position
# accessors (aleft/atop/aright/abottom/awidth/aheight, rleft/rtop/...) on `inner`.
include Crysterm

s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

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

# Show `inner`'s computed/relative positions on a second line.
inner.content = \
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
