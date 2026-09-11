require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-dock.js
#
# Demonstrates `border_junctions`: four quadrant widgets whose adjacent borders
# dock together. Each quadrant uses per-side border widths (1 = draw, 0 =
# hide) so only inner edges are drawn. Bottom-right is a `Widget::ListTable`;
# a centered, draggable "Drag Me" box floats on top.

s = CT::Window.new optimization: CT::OptimizationFlag::SmartCSR, border_junctions: true, always_propagated_keys: [::Tput::Key::CtrlQ]

topleft = CW::Box.new(
  parent: s,
  left: 0,
  top: 0,
  width: "50%",
  height: "50%",
  # PER-SIDE: blessed {type:'line', left:false, top:false, right:true, bottom:false}
  # (border tuple is CSS shorthand order: {top, right, bottom, left})
  style: CT::Style.new(border: {0, 1, 0, 0}),
  content: "Foo"
)

topright = CW::Box.new(
  parent: s,
  left: "50%-1",
  top: 0,
  width: "50%+1",
  height: "50%",
  style: CT::Style.new(border: {0, 0, 0, 1}),
  content: "Bar"
)

bottomleft = CW::Box.new(
  parent: s,
  left: 0,
  top: "50%-1",
  width: "50%",
  height: "50%+1",
  style: CT::Style.new(border: {1, 0, 0, 0}),
  content: "Foo"
)

bottomright = CW::ListTable.new(
  parent: s,
  left: "50%-1",
  top: "50%-1",
  width: "50%+1",
  height: "50%+1",
  # PER-SIDE: blessed {type:'line', left:true, top:true, right:false, bottom:false}
  align: ::Tput::AlignFlag::Center,
  keys: true,
  vi_keys: true,
  mouse: true,
  styles: CT::Styles.new(
    normal: CT::Style.new(
      border: {1, 0, 0, 1},
      header: CT::Style.new(fg: "blue", bold: true),
      cell: CT::Style.new(fg: "magenta"),
    ),
    # blessed nests selected under cell; crysterm exposes it on Styles.
    selected: CT::Style.new(bg: "blue"),
  )
)

bottomright.rows = [
  ["Animals", "Foods", "Times", "Numbers"],
  ["Elephant", "Apple", "1:00am", "One"],
  ["Bird", "Orange", "2:15pm", "Two"],
  ["T-Rex", "Taco", "8:45am", "Three"],
  ["Mouse", "Cheese", "9:05am", "Four"],
]

bottomright.focus

over = CW::Box.new(
  parent: s,
  left: "center",
  top: "center",
  width: "50%",
  height: "50%",
  draggable: true,
  # PER-SIDE: blessed {type:'line', left:false, top:true, right:true, bottom:true}
  style: CT::Style.new(border: {1, 1, 1, 0}),
  content: "Drag Me"
)

s.on(CT::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.update
s.exec
