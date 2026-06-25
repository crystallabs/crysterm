require "../../src/crysterm"

# Port of Blessed's test/widget-nested-attr.js
# A single tags-enabled box with nested fg/bg color tags inside a line
# border, centered, sized 80%x80%.
module Crysterm
  s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

  Widget::Box.new(
    parent: s,
    left: "center",
    top: "center",
    width: "80%",
    height: "80%",
    parse_tags: true,
    style: Style.new(
      bg: "black",
      fg: "yellow",
      border: true
    ),
    content: "{red-fg}hello {blue-fg}how{/blue-fg}" \
             " {yellow-bg}are{/yellow-bg} you?{/red-fg}"
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
