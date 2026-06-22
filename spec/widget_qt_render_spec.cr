require "./spec_helper"

include Crysterm

# Render- and interaction-level specs for the Qt-inspired widgets. Unlike
# `widget_qt_features_spec.cr` (which checks state/logic), these drive a real
# synchronous render (`Screen#_render`) on an in-memory screen and inspect the
# resulting cell buffer, and feed real mouse events through `#dispatch_mouse` —
# so the layout-, focus- and pointer-dependent paths actually get exercised.

private def render_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

private def mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def press(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Down, x, y)
end

private def move(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

private def release(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
end

# Characters of a screen row, as a String, over the column range.
private def row_chars(s, y, x0, x1)
  line = s.lines[y]
  (x0...x1).map { |x| line[x].char }.join
end

describe "Slider rendering" do
  it "draws the track and places the handle at the value's position" do
    s = render_screen
    sl = Crysterm::Widget::Slider.new parent: s, top: 0, left: 0, width: 11, height: 1,
      minimum: 0, maximum: 10, value: 0, handle_char: '#', track_char: '-'
    s._render
    # value 0 -> handle at the far left.
    row_chars(s, 0, 0, 11).should eq "#----------"

    sl.value = 10
    s._render
    # value max -> handle at the far right (11 cells, 10 steps).
    row_chars(s, 0, 0, 11).should eq "----------#"

    sl.value = 5
    s._render
    # value mid -> handle in the middle.
    row_chars(s, 0, 0, 11).should eq "-----#-----"
  end
end

describe "SpinBox rendering" do
  it "renders prefix + value + suffix" do
    s = render_screen
    Crysterm::Widget::SpinBox.new parent: s, top: 0, left: 0, width: 6, height: 1,
      value: 7, prefix: "$", suffix: "%"
    s._render
    row_chars(s, 0, 0, 4).should eq "$7% "
  end
end

describe "Table alternating rows rendering" do
  it "paints every other body row with the alternate background" do
    s = render_screen
    Crysterm::Widget::Table.new parent: s, top: 0, left: 0, alternate_rows: true,
      style: Crysterm::Style.new(alternate: Crysterm::Style.new(bg: "blue")),
      rows: [["H"], ["a"], ["b"], ["c"]]
    s._render

    alt_bg = Crysterm::Colors.convert("blue")
    # Some cell on the screen must now carry the alternate background...
    found = s.lines.any? { |line| line.any? { |cell| Crysterm::Attr.bg(cell.attr) == alt_bg } }
    found.should be_true
  end

  it "uses no alternate background when the option is off" do
    s = render_screen
    Crysterm::Widget::Table.new parent: s, top: 0, left: 0, alternate_rows: false,
      style: Crysterm::Style.new(alternate: Crysterm::Style.new(bg: "blue")),
      rows: [["H"], ["a"], ["b"], ["c"]]
    s._render

    alt_bg = Crysterm::Colors.convert("blue")
    found = s.lines.any? { |line| line.any? { |cell| Crysterm::Attr.bg(cell.attr) == alt_bg } }
    found.should be_false
  end
end

describe "GroupBox rendering" do
  it "draws a border with the title in it" do
    s = render_screen
    Crysterm::Widget::GroupBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      title: "Opts"
    s._render
    top = row_chars(s, 0, 0, 20)
    # Box-drawing corners + the title text somewhere on the top edge.
    top.includes?("Opts").should be_true
    "┌╭".chars.any? { |c| top.includes? c }.should be_true
  end
end

describe "ComboBox interaction" do
  it "shows the value with a marker and opens a popup below itself" do
    s = render_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["Red", "Green", "Blue"]
    s._render
    row_chars(s, 0, 0, 6).should eq "Red ▾ "

    cb.open
    s._render
    cb.open?.should be_true
    # Popup sits directly under the combo (row 1+).
    cb.@popup.not_nil!.atop.should eq 1
  end

  it "commits a row on a single click" do
    s = render_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["Red", "Green", "Blue"]
    s._render
    cb.open
    s._render

    pop = cb.@popup.not_nil!
    # First item row: one row inside the popup's top border.
    row = pop.atop + 1
    col = pop.aleft + 1
    press s, col, row
    release s, col, row

    cb.value.should eq "Red"
    cb.open?.should be_false
  end

  it "closes when clicking outside the popup" do
    s = render_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["Red", "Green", "Blue"]
    s._render
    cb.open
    s._render
    cb.open?.should be_true

    press s, 70, 20 # far away
    release s, 70, 20
    cb.open?.should be_false
    cb.value.should eq "Red" # unchanged
  end
end

describe "TabWidget with layout" do
  it "keeps the tab bar selection in sync with the shown page" do
    s = render_screen
    tabs = Crysterm::Widget::TabWidget.new parent: s, top: 0, left: 0, width: 40, height: 10
    tabs.add_tab "A", Crysterm::Widget::Box.new(content: "one")
    tabs.add_tab "B", Crysterm::Widget::Box.new(content: "two")
    s._render

    tabs.show_tab 1
    s._render
    tabs.current_index.should eq 1
    tabs.bar.selected.should eq 1

    # Focusing the bar must not switch the page back (the Focus re-emit lands on
    # the already-current tab).
    tabs.bar.focus
    s._render
    tabs.current_index.should eq 1
  end
end

describe "Splitter mouse drag" do
  it "resizes the panes when the divider is dragged" do
    s = render_screen
    sp = Crysterm::Widget::Splitter.new parent: s, top: 0, left: 0, width: 40, height: 10,
      position: 20
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp.split a, b
    s._render

    sp.position.should eq 20
    # Grab the divider (a vertical bar at column 20) and drag it left to 12.
    press s, 20, 3
    move s, 12, 3
    sp.position.should eq 12
    a.width.should eq 12
    b.left.should eq 13
    release s, 12, 3
  end
end

describe "List multi-select rendering" do
  it "underlines checked (non-cursor) items" do
    s = render_screen
    list = Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 12, height: 6,
      multi_select: true, items: ["a", "b", "c"]
    list.selekt 0      # cursor on row 0
    list.select_item 2 # check row 2
    s._render

    cursor = list.render_style_for(list.items[0])
    marked = list.render_style_for(list.items[2])
    plain = list.render_style_for(list.items[1])

    marked.underline?.should be_true
    plain.underline?.should be_false
    # The cursor item is the fully-selected style, not the underline style.
    cursor.should_not eq marked
  end
end

describe "Question#ask_choices" do
  it "invokes the block with the chosen button index and restores OK/Cancel" do
    s = render_screen
    q = Crysterm::Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8
    chosen = nil.as(Int32?)
    q.ask_choices("Pick one", ["Yes", "No", "Maybe"]) { |i| chosen = i }
    s._render

    buttons = q.children.select { |c| c.is_a?(Crysterm::Widget::Button) && c.visible? }
    buttons.size.should eq 3
    buttons[1].as(Crysterm::Widget::Button).press

    chosen.should eq 1
    # Choice buttons gone; the standard OK/Cancel pair is shown again.
    q.children.count { |c| c.is_a?(Crysterm::Widget::Button) && c.visible? }.should eq 2
  end
end

describe "Prompt validation" do
  it "re-prompts on an invalid value and commits only a valid one" do
    s = render_screen
    pr = Crysterm::Widget::Prompt.new parent: s, top: 0, left: 0, width: 40, height: 8
    pr.validator = ->(v : String) { v == "good" }

    result = nil.as(String?)
    calls = 0
    pr.read_input("Enter:") { |_err, data| calls += 1; result = data }

    # Invalid submit -> stays open, outer callback not run.
    pr.textinput.value = "bad"
    pr.textinput.submit
    calls.should eq 0

    # Valid submit -> commits.
    pr.textinput.value = "good"
    pr.textinput.submit
    calls.should eq 1
    result.should eq "good"
  end
end
