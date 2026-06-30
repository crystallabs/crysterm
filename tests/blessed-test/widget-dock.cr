require "../../src/crysterm"

# Port of Blessed's test/widget-dock.js
#
# Demonstrates `dock_borders`: four quadrant widgets whose adjacent borders
# share/dock together. Each quadrant uses PER-SIDE border widths (1 = draw,
# 0 = hide) so only the inner edges are drawn. The bottom-right quadrant is a
# `Widget::ListTable`; a centered, draggable "Drag Me" box floats on top.
module Crysterm
  s = Window.new optimization: OptimizationFlag::SmartCSR, dock_borders: true, always_propagate: [::Tput::Key::CtrlQ]

  topleft = Widget::Box.new(
    parent: s,
    left: 0,
    top: 0,
    width: "50%",
    height: "50%",
    # PER-SIDE: blessed {type:'line', left:false, top:false, right:true, bottom:false}
    style: Style.new(border: Border.new(left: 0, top: 0, right: 1, bottom: 0)),
    content: "Foo"
  )

  topright = Widget::Box.new(
    parent: s,
    left: "50%-1",
    top: 0,
    width: "50%+1",
    height: "50%",
    style: Style.new(border: Border.new(left: 1, top: 0, right: 0, bottom: 0)),
    content: "Bar"
  )

  bottomleft = Widget::Box.new(
    parent: s,
    left: 0,
    top: "50%-1",
    width: "50%",
    height: "50%+1",
    style: Style.new(border: Border.new(left: 0, top: 1, right: 0, bottom: 0)),
    content: "Foo"
  )

  bottomright = Widget::ListTable.new(
    parent: s,
    left: "50%-1",
    top: "50%-1",
    width: "50%+1",
    height: "50%+1",
    # PER-SIDE: blessed {type:'line', left:true, top:true, right:false, bottom:false}
    align: ::Tput::AlignFlag::Center,
    parse_tags: true,
    keys: true,
    vi: true,
    mouse: true,
    styles: Styles.new(
      normal: Style.new(
        border: Border.new(left: 1, top: 1, right: 0, bottom: 0),
        header: Style.new(fg: "blue", bold: true),
        cell: Style.new(fg: "magenta"),
      ),
      # blessed nests selected under cell; crysterm exposes it on Styles.
      selected: Style.new(bg: "blue"),
    )
  )

  bottomright.set_data [
    ["Animals", "Foods", "Times", "Numbers"],
    ["Elephant", "Apple", "1:00am", "One"],
    ["Bird", "Orange", "2:15pm", "Two"],
    ["T-Rex", "Taco", "8:45am", "Three"],
    ["Mouse", "Cheese", "9:05am", "Four"],
  ]

  bottomright.focus

  over = Widget::Box.new(
    parent: s,
    left: "center",
    top: "center",
    width: "50%",
    height: "50%",
    draggable: true,
    # PER-SIDE: blessed {type:'line', left:false, top:true, right:true, bottom:true}
    style: Style.new(border: Border.new(left: 0, top: 1, right: 1, bottom: 1)),
    content: "Drag Me"
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
