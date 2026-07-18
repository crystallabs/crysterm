require "../../src/crysterm"

# Port of Blessed's test/widget-shrink-padding.js
module Crysterm
  s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

  outer = Widget::Box.new(
    parent: s,
    left: "center",
    top: "center",
    shrink_to_fit: true,
    style: Style.new(
      bg: "green",
      padding: 1
    )
  )

  Widget::Box.new(
    parent: outer,
    left: 0,
    top: 0,
    shrink_to_fit: true,
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
