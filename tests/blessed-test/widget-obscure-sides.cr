require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-obscure-sides.js
# A small, centered scrollable box (blue bg, scrollbar, keyboard/vi_keys) holding two
# green child boxes positioned so they stick out past the parent's edges — one
# near the top, one (with a line border) running off the bottom/left.

# Blessed's `autoPadding: true` screen option has no Crysterm equivalent, so
# it's dropped.
s = CT::Window.new optimization: CT::OptimizationFlag::SmartCSR, always_propagated_keys: [::Tput::Key::CtrlQ]

box = CW::ScrollableBox.new(
  parent: s,
  scrollable: true,
  always_scroll: true,
  scrollbar_policy: :as_needed,
  height: 10,
  width: 30,
  top: "center",
  left: "center",
  keys: true,
  vi_keys: true,
  style: CT::Style.new(
    bg: "blue",
    # Blessed: border:{type:'bg', ch:' '} + style.border.inverse.
    border: CT::Border.new(type: CT::BorderType::Fill).tap { |b| b.reverse = true },
  ),
)

child = CW::Box.new(
  parent: box,
  content: "hello",
  style: CT::Style.new(bg: "green"),
  height: 5,
  width: 20,
  top: 2,
  left: 15,
)

child2 = CW::Box.new(
  parent: box,
  content: "hello",
  style: CT::Style.new(bg: "green", border: CT::BorderType::Solid),
  height: 5,
  width: 20,
  top: 25,
  left: -5,
)

box.focus

s.on(CT::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.update

s.exec
