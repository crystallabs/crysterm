require "../../src/crysterm"

# Port of Blessed's test/widget-shrink-padding.js
# An outer shrink (resizable) box with padding 1 and a green background,
# centered, containing an inner shrink box with content "foobar" and a
# magenta background.
module Crysterm
  s = Window.new always_propagate: [::Tput::Key::CtrlQ]

  outer = Widget::Box.new(
    parent: s,
    left: "center",
    top: "center",
    resizable: true,
    style: Style.new(
      bg: "green",
      padding: 1
    )
  )

  Widget::Box.new(
    parent: outer,
    left: 0,
    top: 0,
    resizable: true,
    content: "foobar",
    style: Style.new(
      bg: "magenta"
    )
  )

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render
  s.exec
end
