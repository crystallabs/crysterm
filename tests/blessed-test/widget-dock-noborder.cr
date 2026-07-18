require "../../src/crysterm"

# Port of Blessed's test/widget-dock-noborder.js
#
# Same as widget-dock, but quadrants use plain `line` borders at negative
# offsets (left:-1, top:-1) with "50%+1"/"50%+3" sizes so borders overlap and dock.
module Crysterm
  s = Window.new optimization: OptimizationFlag::SmartCSR, dock_borders: true, always_propagated_keys: [::Tput::Key::CtrlQ]

  Widget::Box.new(
    parent: s,
    left: -1,
    top: -1,
    width: "50%+1",
    height: "50%+1",
    style: Style.new(border: BorderType::Line),
    content: "Foo"
  )

  Widget::Box.new(
    parent: s,
    left: "50%-1",
    top: -1,
    width: "50%+3",
    height: "50%+1",
    style: Style.new(border: BorderType::Line),
    content: "Bar"
  )

  Widget::Box.new(
    parent: s,
    left: -1,
    top: "50%-1",
    width: "50%+1",
    height: "50%+3",
    style: Style.new(border: BorderType::Line),
    content: "Foo"
  )

  table = Widget::ListTable.new(
    parent: s,
    left: "50%-1",
    top: "50%-1",
    width: "50%+3",
    height: "50%+3",
    align: ::Tput::AlignFlag::Center,
    parse_tags: true,
    keys: true,
    vi: true,
    mouse: true,
    styles: Styles.new(
      normal: Style.new(
        border: Border.new(fg: nil),
        header: Style.new(fg: "blue", bold: true),
        cell: Style.new(fg: "magenta"),
      ),
      selected: Style.new(bg: "blue"),
    )
  )

  table.rows = [
    ["Animals", "Foods", "Times", "Numbers"],
    ["Elephant", "Apple", "1:00am", "One"],
    ["Bird", "Orange", "2:15pm", "Two"],
    ["T-Rex", "Taco", "8:45am", "Three"],
    ["Mouse", "Cheese", "9:05am", "Four"],
  ]

  table.focus

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render
  s.exec
end
