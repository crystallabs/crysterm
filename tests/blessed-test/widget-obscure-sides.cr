require "../../src/crysterm"

# Port of Blessed's test/widget-obscure-sides.js
# A small, centered scrollable box (blue bg, scrollbar, keyboard/vi) holding two
# green child boxes positioned so they stick out past the parent's edges — one
# near the top, one (with a line border) running off the bottom/left.
module Crysterm
  # NOTE: Blessed's `autoPadding: true` screen option has no Crysterm equivalent
  # (grep of src/ finds no auto-padding screen setting), so it is dropped.
  s = Screen.new optimization: OptimizationFlag::SmartCSR, always_propagate: [::Tput::Key::CtrlQ]

  box = Widget::ScrollableBox.new(
    parent: s,
    scrollable: true,
    always_scroll: true,
    scrollbar: true,
    height: 10,
    width: 30,
    top: "center",
    left: "center",
    keys: true,
    vi: true,
    style: Style.new(
      bg: "blue",
      # Blessed: border:{type:'bg', ch:' '} + style.border.inverse → an
      # inverse-video space frame that reads as a light outline around the box.
      border: Border.new(type: BorderType::Bg).tap { |b| b.reverse = true },
    ),
  )

  child = Widget::Box.new(
    parent: box,
    content: "hello",
    style: Style.new(bg: "green"),
    height: 5,
    width: 20,
    top: 2,
    left: 15,
  )

  child2 = Widget::Box.new(
    parent: box,
    content: "hello",
    style: Style.new(bg: "green", border: BorderType::Line),
    height: 5,
    width: 20,
    top: 25,
    left: -5,
  )

  box.focus

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render

  s.exec
end
