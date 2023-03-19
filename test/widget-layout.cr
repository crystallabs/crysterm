require "../src/crysterm"

# For reproducibility, the section near the end generating 10 widgets has been
# changed to always use fixed sizes instead of Random. The patch for Blessed's
# test file to get the same behavior is in file widget-layout.cr.blessed-patch.

module Crysterm
  s = Screen.new optimization: OptimizationFlag::SmartCSR, dock_borders: false

  l = layout = Widget::Layout.new(
    top: "center",
    left: "center",
    width: "50%",
    height: "50%",
    layout: ARGV[0]? == "grid" ? LayoutType::Grid : LayoutType::Inline,
    overflow: Overflow::Ignore, # Setting not existing in Blessed. Controls what to do when widget is overflowing available space. Value of 'ignore' ignores the issue and renders such widgets overflown.
    style: Style.new(
    bg: "red",
    border: Border.new(
      fg: "blue"
    )
  )
  )

  s.append l

  box1 = Widget::Box.new(
    parent: layout,
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    style: Style.new(border: BorderType::Line),
    content: "1"
  )

  box2 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "2"
  )

  box3 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "3"
  )

  box4 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "4"
  )

  box5 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "5"
  )

  box6 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "6"
  )

  box7 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "7"
  )

  box8 = Widget::Box.new(
    parent: layout,
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    style: Style.new(border: BorderType::Line),
    content: "8"
  )

  box9 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "9"
  )

  box10 = Widget::Box.new(
    parent: layout,
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    style: Style.new(border: BorderType::Line),
    content: "10"
  )

  box11 = Widget::Box.new(
    parent: layout,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    style: Style.new(border: BorderType::Line),
    content: "11"
  )

  box12 = Widget::Box.new(
    parent: layout,
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    style: Style.new(border: BorderType::Line),
    content: "12"
  )

  if ARGV[0]? != "grid"
    sizes = [0.2, 1, 0.3, 0.6, 0.3, 0.9, 0.2, 0.75, 0.1, 0.99]
    10.times do |i|
      Widget::Box.new(
        parent: layout,
        width: sizes[i] > 0.5 ? 10 : 20,
        height: sizes[i] > 0.5 ? 5 : 10,
        style: Style.new(border: BorderType::Line),
        content: (i + 1 + 12).to_s
      )
    end
  end

  s.on(Event::KeyPress) do |e|
    # STDERR.puts e.inspect
    if e.char == 'q'
      # e.accept!
      s.display.destroy
      exit
    end
  end

  s.render

  s.display.exec # We use exec to run the main loop. Similar to Qt.
end
