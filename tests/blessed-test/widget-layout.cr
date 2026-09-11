require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# The section generating 10 widgets near the end uses fixed sizes instead of
# Random for reproducibility. Patch for Blessed's test file to match: widget-layout.cr.blessed-patch.

s = CT::Window.new optimization: CT::OptimizationFlag::SmartCSR, border_junctions: false

l = layout = CW::Box.new(
  top: "center",
  left: "center",
  width: "100%-2",
  height: "100%-2",
  layout: ARGV[0]? == "grid" ? CT::Layout::UniformGrid.new : CT::Layout::Masonry.new,
  overflow: CT::Overflow::Ignore, # Not in Blessed. Controls overflow handling; `ignore` lets overflowing widgets render overflown.
  style: CT::Style.new(
  bg: "red",
  border: CT::Border.new(
    fg: "blue"
  )
)
)

s.append l

box1 = CW::Box.new(
  parent: layout,
  top: "center",
  left: "center",
  width: 20,
  height: 10,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "1"
)

box2 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "2"
)

box3 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "3"
)

box4 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "4"
)

box5 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "5"
)

box6 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "6"
)

box7 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "7"
)

box8 = CW::Box.new(
  parent: layout,
  top: "center",
  left: "center",
  width: 20,
  height: 10,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "8"
)

box9 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "9"
)

box10 = CW::Box.new(
  parent: layout,
  top: "center",
  left: "center",
  width: 20,
  height: 10,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "10"
)

box11 = CW::Box.new(
  parent: layout,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "11"
)

box12 = CW::Box.new(
  parent: layout,
  top: "center",
  left: "center",
  width: 20,
  height: 10,
  style: CT::Style.new(border: CT::BorderType::Solid),
  content: "12"
)

if ARGV[0]? != "grid"
  sizes = [0.2, 1, 0.3, 0.6, 0.3, 0.9, 0.2, 0.75, 0.1, 0.99]
  10.times do |i|
    CW::Box.new(
      parent: layout,
      width: sizes[i] > 0.5 ? 10 : 20,
      height: sizes[i] > 0.5 ? 5 : 10,
      style: CT::Style.new(border: CT::BorderType::Solid),
      content: (i + 1 + 12).to_s
    )
  end
end

s.on(CT::Event::KeyPress) do |e|
  # STDERR.puts e.inspect
  if e.char == 'q'
    # e.accept
    s.destroy
    exit
  end
end

s.update

s.exec # runs the main loop, similar to Qt
