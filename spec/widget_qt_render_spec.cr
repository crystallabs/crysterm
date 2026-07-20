require "./spec_helper"

include Crysterm

# Render- and interaction-level specs for the Qt-inspired widgets. Unlike
# `widget_qt_features_spec.cr` (which checks state/logic), these drive a real
# synchronous render (`Window#repaint`) on an in-memory screen, inspect the
# resulting cell buffer, and feed real mouse events through `#dispatch_mouse`.

private def render_screen
  Crysterm::Window.new(
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
    s.repaint
    # value 0 -> handle at the far left.
    row_chars(s, 0, 0, 11).should eq "#----------"

    sl.value = 10
    s.repaint
    # value max -> handle at the far right (11 cells, 10 steps).
    row_chars(s, 0, 0, 11).should eq "----------#"

    sl.value = 5
    s.repaint
    # value mid -> handle in the middle.
    row_chars(s, 0, 0, 11).should eq "-----#-----"
  end

  it "draws the value readout in a uniform attr, even where it overlaps the handle" do
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      s = render_screen
      st = Crysterm::Style.new(fg: "white", bg: "black")
      # Distinct handle style: if the readout inherited it at the overlapping
      # cell, that digit would differ from the rest.
      st.indicator = Crysterm::Style.new(fg: "red", bg: "blue")
      Crysterm::Widget::Slider.new parent: s, top: 0, left: 0, width: 11, height: 1,
        minimum: 0, maximum: 100, value: 50, text_visible: true, style: st
      s.repaint
      # "50" is centered at columns 4-5; the handle sits at column 5, so the '0'
      # digit lands directly on it.
      s.lines[0][4].char.should eq '5'
      s.lines[0][5].char.should eq '0'
      track = s.lines[0][0].attr # a plain track cell, drawn with the base style
      # Both digits carry the track attr, not the handle's indicator attr.
      s.lines[0][4].attr.should eq track
      s.lines[0][5].attr.should eq track
      s.lines[0][4].attr.should eq s.lines[0][5].attr
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end
end

describe "SpinBox rendering" do
  it "renders prefix + value + suffix" do
    s = render_screen
    Crysterm::Widget::SpinBox.new parent: s, top: 0, left: 0, width: 6, height: 1,
      value: 7, prefix: "$", suffix: "%"
    s.repaint
    row_chars(s, 0, 0, 4).should eq "$7% "
  end
end

describe "Table alternating rows rendering" do
  it "paints every other body row with the alternate background" do
    s = render_screen
    Crysterm::Widget::Table.new parent: s, top: 0, left: 0, alternate_rows: true,
      style: Crysterm::Style.new(alternate_row: Crysterm::Style.new(bg: "blue")),
      rows: [["H"], ["a"], ["b"], ["c"]]
    s.repaint

    alt_bg = Crysterm::Colors.convert("blue")
    found = s.lines.any? { |line| line.any? { |cell| Crysterm::Attr.bg(cell.attr) == alt_bg } }
    found.should be_true
  end

  it "uses no alternate background when the option is off" do
    s = render_screen
    Crysterm::Widget::Table.new parent: s, top: 0, left: 0, alternate_rows: false,
      style: Crysterm::Style.new(alternate_row: Crysterm::Style.new(bg: "blue")),
      rows: [["H"], ["a"], ["b"], ["c"]]
    s.repaint

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
    s.repaint
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
    s.repaint
    row_chars(s, 0, 0, 6).should eq "Red ▾ "

    cb.show_popup
    s.repaint
    cb.open?.should be_true
    # Popup sits directly under the combo (row 1+).
    cb.@popup.not_nil!.atop.should eq 1
  end

  it "commits a row on a single click" do
    s = render_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["Red", "Green", "Blue"]
    s.repaint
    cb.show_popup
    s.repaint

    pop = cb.@popup.not_nil!
    # First item row: one row inside the popup's top border.
    row = pop.atop + 1
    col = pop.aleft + 1
    press s, col, row
    release s, col, row

    cb.current_text.should eq "Red"
    cb.open?.should be_false
  end

  it "closes when clicking outside the popup" do
    s = render_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["Red", "Green", "Blue"]
    s.repaint
    cb.show_popup
    s.repaint
    cb.open?.should be_true

    press s, 70, 20 # far away
    release s, 70, 20
    cb.open?.should be_false
    cb.current_text.should eq "Red" # unchanged
  end
end

describe "TabWidget with layout" do
  it "keeps the tab bar selection in sync with the shown page" do
    s = render_screen
    tabs = Crysterm::Widget::TabWidget.new parent: s, top: 0, left: 0, width: 40, height: 10
    tabs.add_tab "A", Crysterm::Widget::Box.new(content: "one")
    tabs.add_tab "B", Crysterm::Widget::Box.new(content: "two")
    s.repaint

    tabs.current_index = 1
    s.repaint
    tabs.current_index.should eq 1
    tabs.tab_bar.current_index.should eq 1

    # Focusing the bar must not switch the page back (the Focus re-emit lands on
    # the already-current tab).
    tabs.tab_bar.focus
    s.repaint
    tabs.current_index.should eq 1
  end
end

describe "Splitter mouse drag" do
  it "resizes the panes when the divider is dragged" do
    s = render_screen
    sp = Crysterm::Widget::Splitter.new parent: s, top: 0, left: 0, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp.add_widget a
    sp.add_widget b
    sp.set_divider_position 0, 20
    s.repaint

    sp.divider_position(0).should eq 20
    # Grab the divider (a vertical bar at column 20) and drag it left to 12.
    press s, 20, 3
    move s, 12, 3
    sp.divider_position(0).should eq 12
    a.width.should eq 12
    b.left.should eq 13
    release s, 12, 3
  end
end

describe "List multi-select rendering" do
  it "underlines checked (non-cursor) items" do
    s = render_screen
    list = Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 12, height: 6,
      selection_mode: :multi_selection, items: ["a", "b", "c"]
    list.current_index = 0  # cursor on row 0
    list.add_to_selection 2 # check row 2
    s.repaint

    cursor = list.render_style_for(list.item_boxes[0])
    marked = list.render_style_for(list.item_boxes[2])
    plain = list.render_style_for(list.item_boxes[1])

    marked.underline?.should be_true
    plain.underline?.should be_false
    # The cursor item is the fully-selected style, not the underline style.
    cursor.should_not eq marked
  end
end

describe "List scroll-bar column reservation" do
  it "reserves the vertical bar's column for items even when they grow into overflow" do
    s = render_screen
    # Two items: fits in height 4, no vertical overflow, no bar yet.
    list = Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 12, height: 4,
      scrollbar: true, items: ["AAAAAAAAAA", "BBBBBBBBBB"]
    s.repaint
    list.show_scrollbar?.should be_false
    list.item_boxes.all? { |i| i.right == 0 }.should be_true

    # Grow past the viewport: bar now shows, #render must re-sync every item's
    # reservation to the real bar width, or the shown bar overpaints them.
    list.add_item "CCCCCCCCCC"
    list.add_item "DDDDDDDDDD"
    list.add_item "EEEEEEEEEE" # 5 items > height 4 -> overflow
    s.repaint
    list.show_scrollbar?.should be_true
    list.item_boxes.all? { |i| i.right == list.scrollbar_width }.should be_true
  end
end

describe "Question#ask_choices" do
  it "invokes the block with the chosen button index and restores OK/Cancel" do
    s = render_screen
    q = Crysterm::Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8
    chosen = nil.as(Int32?)
    q.ask_choices("Pick one", ["Yes", "No", "Maybe"]) { |i| chosen = i }
    s.repaint

    # The choice row is now a `DialogButtonBox` child (was inline direct-child
    # buttons); the standard OK/Cancel pair stays direct children (hidden here).
    bb = q.children.find(&.is_a?(Crysterm::Widget::DialogButtonBox)).as(Crysterm::Widget::DialogButtonBox)
    bb.buttons.size.should eq 3
    bb.buttons[1].click

    chosen.should eq 1
    # Choice buttons gone; the standard OK/Cancel pair is shown again.
    q.children.count { |c| c.is_a?(Crysterm::Widget::Button) && c.visible? }.should eq 2
  end

  it "survives an arrow key with an empty choice list (no division-by-zero)" do
    s = render_screen
    q = Crysterm::Widget::Question.new parent: s, top: 0, left: 0, width: 40, height: 8
    chosen = nil.as(Int32?)
    q.ask_choices("Pick one", [] of String) { |i| chosen = i }
    s.repaint

    # Left/Right used to do `(cur ± 1) % buttons.size` with size 0 → crash.
    s.emit Crysterm::Event::KeyPress, '\0', Tput::Key::Left
    s.emit Crysterm::Event::KeyPress, '\0', Tput::Key::Right
    chosen.should be_nil

    # Escape still dismisses, yielding nil.
    s.emit Crysterm::Event::KeyPress, '\0', Tput::Key::Escape
    chosen.should be_nil
  end
end

describe "Prompt validation" do
  it "re-prompts on an invalid value and commits only a valid one" do
    s = render_screen
    pr = Crysterm::Widget::Prompt.new parent: s, top: 0, left: 0, width: 40, height: 8
    pr.validator = ->(v : String) { v == "good" }

    result = nil.as(String?)
    calls = 0
    pr.read_input("Enter:") { |data| calls += 1; result = data }

    # Invalid submit -> stays open, outer callback not run.
    pr.line_edit.value = "bad"
    pr.line_edit.submit
    calls.should eq 0

    # Valid submit -> commits.
    pr.line_edit.value = "good"
    pr.line_edit.submit
    calls.should eq 1
    result.should eq "good"
  end
end

describe "Dial rendering" do
  it "draws a compass pointer reflecting the value" do
    s = render_screen
    d = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 7, height: 5,
      minimum: 0, maximum: 8, value: 0
    s.repaint
    # value 0 -> north pointer somewhere in the dial.
    s.lines.any? { |line| line.any? { |c| c.char == '↑' } }.should be_true

    d.value = 2 # quarter turn -> east
    s.repaint
    s.lines.any? { |line| line.any? { |c| c.char == '→' } }.should be_true
  end
end

describe "Menu submenus" do
  it "marks, opens on Right, and routes a leaf activation back to the parent" do
    s = render_screen
    m = Crysterm::Widget::Menu.new parent: s, top: 0, left: 0, width: 20, height: 8
    file = Crysterm::Action.new "File"
    new_a = Crysterm::Action.new "New"
    file.menu = [new_a, Crysterm::Action.new("Open")]
    triggered = false
    new_a.on(Crysterm::Event::Triggered) { triggered = true }
    m << file
    s.repaint

    m.item_texts[0].includes?("▶").should be_true

    m.current_index = 0
    m.on_keypress(Crysterm::Event::KeyPress.new('\0', Tput::Key::Right))
    s.repaint

    child = s.focused
    child.should_not eq m
    child.is_a?(Crysterm::Widget::Menu).should be_true

    # Activating a leaf in the submenu fires it and closes the chain (focus
    # returns to the parent menu).
    child.as(Crysterm::Widget::Menu).activate_selected
    triggered.should be_true
    s.focused.should eq m
  end
end

describe "wheel implicitly focuses" do
  it "focuses the widget under the wheel (like a click)" do
    s = render_screen
    btn = Crysterm::Widget::Button.new parent: s, top: 0, left: 0, width: 6, height: 1, content: "B"
    dial = Crysterm::Widget::Dial.new parent: s, top: 2, left: 0, width: 7, height: 3,
      minimum: 0, maximum: 100, value: 50
    list = Crysterm::Widget::List.new parent: s, top: 6, left: 0, width: 16, height: 5,
      items: ["a", "b", "c"]
    btn.focus
    s.repaint

    s.dispatch_mouse mouse(::Tput::Mouse::Action::WheelUp, dial.aleft + 3, dial.atop + 1, ::Tput::Mouse::Button::None)
    dial.focused?.should be_true

    # Wheeling an item focuses its scrollable list ancestor, not the item.
    btn.focus
    s.dispatch_mouse mouse(::Tput::Mouse::Action::WheelDown, list.aleft + 2, list.atop + 1, ::Tput::Mouse::Button::None)
    list.focused?.should be_true
  end
end

describe "CheckBox marker-only click" do
  it "toggles only when the [ ] marker is clicked, not the text" do
    s = render_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1,
      content: "Enable feature"
    s.repaint
    cb.checked?.should be_false
    # Click on the text label -> no toggle.
    press s, cb.aleft + 10, cb.atop
    release s, cb.aleft + 10, cb.atop
    cb.checked?.should be_false
    # Click on the marker -> toggles.
    press s, cb.aleft + 1, cb.atop
    release s, cb.aleft + 1, cb.atop
    cb.checked?.should be_true
  end
end

describe "Slider mouse wheel" do
  it "nudges the value by a step" do
    s = render_screen
    sl = Crysterm::Widget::Slider.new parent: s, top: 0, left: 0, width: 16, height: 1,
      minimum: 0, maximum: 100, value: 50
    s.repaint
    s.dispatch_mouse mouse(::Tput::Mouse::Action::WheelUp, sl.aleft + 5, sl.atop, ::Tput::Mouse::Button::None)
    sl.value.should eq 51
    s.dispatch_mouse mouse(::Tput::Mouse::Action::WheelDown, sl.aleft + 5, sl.atop, ::Tput::Mouse::Button::None)
    sl.value.should eq 50
  end
end

# Reads a vertical scroll bar's column (column 0) as a String.
private def col_chars(s, x, y0, y1)
  (y0...y1).map { |y| s.lines[y][x].char }.join
end

describe "ScrollBar rendering" do
  it "omits stepper buttons by default, splitting the trough around the thumb" do
    s = render_screen
    Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 7,
      minimum: 0, maximum: 10, value: 0
    s.repaint
    # thumb at the top (value 0), `::add-page` trough below it.
    col_chars(s, 0, 0, 7).should eq "█░░░░░░"
  end

  it "draws only the thumb when the trough is hidden (blessed-style)" do
    s = render_screen
    Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 7,
      minimum: 0, maximum: 10, value: 0, show_trough: false
    s.repaint
    # Thumb at the top, the rest of the track left blank (no `░` trough).
    col_chars(s, 0, 0, 7).should eq "█      "
  end

  it "draws stepper buttons at the trough ends when enabled" do
    s = render_screen
    Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 7,
      minimum: 0, maximum: 10, value: 0, stepper_buttons: true
    s.repaint
    # ▲ sub-line, █ thumb, ░ add-page trough, ▼ add-line.
    col_chars(s, 0, 0, 7).should eq "▲█░░░░▼"
  end

  it "draws left/right arrows for a horizontal bar with steppers" do
    s = render_screen
    Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 7, height: 1,
      orientation: Tput::Orientation::Horizontal,
      minimum: 0, maximum: 10, value: 0, stepper_buttons: true
    s.repaint
    row_chars(s, 0, 0, 7).should eq "◀█░░░░▶"
  end

  it "steps the value when a stepper button is clicked" do
    s = render_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 7,
      minimum: 0, maximum: 10, value: 5, step: 1, stepper_buttons: true
    s.repaint
    press(s, 0, 6) # the bottom (add-line) button -> increment
    sb.value.should eq 6
    press(s, 0, 0) # the top (sub-line) button -> decrement
    sb.value.should eq 5
  end

  it "paints the sub-control CSS slots into the rendered cells" do
    s = render_screen
    # A focusable sibling holds focus, so the bar renders unfocused — the
    # state the unprefixed rules target.
    Crysterm::Widget::LineEdit.new parent: s, top: 10, left: 0, width: 10, height: 1
    sb = Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 7,
      minimum: 0, maximum: 10, value: 0, stepper_buttons: true
    s.stylesheet = "ScrollBar::add-page { background-color: #00ff00; } " \
                   "ScrollBar::up-arrow { color: #0000ff; }"
    s.repaint
    # The slots route into the bar's sub-styles...
    sb.style.add_page.bg.should eq Crysterm::Colors.convert("#00ff00")
    sb.style.up_arrow.fg.should eq Crysterm::Colors.convert("#0000ff")
    # And actually paint: blue up-arrow at the top, green add-page trough below.
    s.lines[0][0].char.should eq '▲'
    Crysterm::Attr.unpack_color(Crysterm::Attr.fg(s.lines[0][0].attr)).should eq 0x0000ff
    s.lines[3][0].char.should eq '░'
    Crysterm::Attr.unpack_color(Crysterm::Attr.bg(s.lines[3][0].attr)).should eq 0x00ff00
  end
end

describe "Horizontal scrolling" do
  it "shifts non-wrapped content by column and tracks the bar" do
    s = render_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 10, height: 4,
      wrap_content: false,
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
      content: "ABCDEFGHIJKLMNOPQRST\n0123456789abcdefghij"
    s.repaint

    box.scroll_width.should eq 20 # widest unclipped line
    box.overflows_x?.should be_true
    box.show_horizontal_scrollbar?.should be_true
    row_chars(s, 0, 0, 10).should eq "ABCDEFGHIJ" # columns [0,10)

    box.scroll_by_x 5
    s.repaint
    box.child_base_x.should eq 5
    row_chars(s, 0, 0, 10).should eq "FGHIJKLMNO" # columns [5,15)
    row_chars(s, 1, 0, 10).should eq "56789abcde"

    # The bound horizontal bar mirrors and drives the column window.
    hb = box.horizontal_scrollbar_widget.not_nil!
    hb.orientation.horizontal?.should be_true
    hb.value.should eq 5
    hb.maximum.should eq 10 # width(20) - viewport(10)

    hb.value = 10 # drag the bar fully right
    s.repaint
    box.child_base_x.should eq 10
    row_chars(s, 0, 0, 10).should eq "KLMNOPQRST" # columns [10,20)
  end

  it "reserves a bottom row for the horizontal bar instead of overlaying content" do
    s = render_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 12, height: 5,
      wrap_content: false,
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
      content: (1..8).map { |i| "L#{i}-ABCDEFGHIJKLMNOP" }.join("\n") # wide + tall: both bars
    s.repaint

    box.hscrollbar_rows.should eq 1
    # Both bars show, so the horizontal one stops one column short of the right
    # edge: the last cell is the reserved bottom-right corner (Qt's
    # `QAbstractScrollArea` corner), left to the parent's background fill.
    bar_glyphs = ->(y : Int32) { row_chars(s, y, 0, 11).chars.all? { |c| c == '█' || c == '░' } }
    bar_glyphs.call(4).should be_true      # the bottom row is the bar, not content
    row_chars(s, 4, 11, 12).should eq " "  # …except the corner
    row_chars(s, 0, 0, 4).should eq "L1-A" # content sits in the rows above it

    # The last line stays reachable above the bar (not permanently hidden under it).
    box.scroll_to box.scroll_height
    s.repaint
    row_chars(s, 3, 0, 4).should eq "L8-A"
    bar_glyphs.call(4).should be_true
    row_chars(s, 4, 11, 12).should eq " "
  end

  it "draws the bottom border below a shown horizontal bar, not over it" do
    s = render_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 12, height: 6,
      wrap_content: false,
      style: Style.new(border: Crysterm::BorderType::Solid),
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
      content: (1..8).map { |i| "L#{i}-ABCDEFGHIJKLMNOP" }.join("\n") # wide + tall
    s.repaint

    box.show_horizontal_scrollbar?.should be_true
    # The bar reserves the last *interior* row (row 4); the bottom border stays at
    # the widget's true bottom edge (row 5) instead of being painted one row up.
    # Interior columns are [1,11); the bar runs to column 10, which is the
    # reserved corner cell under the vertical bar (see the sibling example).
    row_chars(s, 4, 1, 10).chars.all? { |c| c == '█' || c == '░' }.should be_true
    row_chars(s, 4, 10, 11).should eq " "
    row_chars(s, 5, 0, 12).should eq "└──────────┘"
  end

  it "leaves wrapped content unscrolled horizontally (no overflow)" do
    s = render_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 10, height: 6,
      content: "ABCDEFGHIJKLMNOPQRST" # wraps by default
    s.repaint
    box.overflows_x?.should be_false # wrapped → never horizontally scrollable
    box.scroll_by_x 5                # no-op
    box.child_base_x.should eq 0
    row_chars(s, 0, 0, 10).should eq "ABCDEFGHIJ"
    row_chars(s, 1, 0, 10).should eq "KLMNOPQRST" # wrapped onto the next row
  end

  it "scrolls horizontally on Shift + wheel" do
    s = render_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 10, height: 4,
      wrap_content: false,
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
      content: "ABCDEFGHIJKLMNOPQRST"
    s.repaint
    # Shift + wheel-down scrolls right; plain wheel would scroll vertically.
    down = mouse(::Tput::Mouse::Action::WheelDown, 2, 0, ::Tput::Mouse::Button::None)
    down.shift = true
    s.dispatch_mouse down
    box.child_base_x.should be > 0
    base = box.child_base_x

    up = mouse(::Tput::Mouse::Action::WheelUp, 2, 0, ::Tput::Mouse::Button::None)
    up.shift = true
    s.dispatch_mouse up
    box.child_base_x.should be < base
  end
end

describe "ListTable column-level horizontal scrolling" do
  it "scrolls a fixed-width table by whole columns" do
    s = render_screen
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 14, height: 8,
      rows: [["Name", "City", "Age"], ["Alice", "Paris", "30"], ["Bob", "Rome", "25"]]
    s.repaint
    lt.scroll_width.should eq 22
    lt.overflows_x?.should be_true
    lt.show_horizontal_scrollbar?.should be_true
    lt.column_start_offsets.should eq [0, 8, 16]
    row_chars(s, 0, 0, 14).should eq " Name    City " # header: col0 + col1 partial

    lt.scroll_by_x 1 # advance one whole column
    s.repaint
    lt.child_base_x.should eq 8 # snapped to column 1's offset
    row_chars(s, 0, 0, 14).should eq " City    Age  "

    lt.scroll_by_x 1 # already at the last column — clamps
    s.repaint
    lt.child_base_x.should eq 8

    lt.scroll_by_x -1
    s.repaint
    lt.child_base_x.should eq 0
    row_chars(s, 0, 0, 14).should eq " Name    City "
  end

  it "binds the horizontal bar to the column offset" do
    s = render_screen
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 14, height: 8,
      rows: [["Name", "City", "Age"], ["Alice", "Paris", "30"]]
    s.repaint
    hb = lt.horizontal_scrollbar_widget.not_nil!
    hb.orientation.horizontal?.should be_true
    hb.value.should eq 0
    hb.maximum.should eq 8 # scroll_width(22) - viewport(14)

    hb.value = hb.maximum # drag fully right
    s.repaint
    lt.child_base_x.should eq 8
    row_chars(s, 0, 0, 14).should eq " City    Age  "
  end

  it "keeps cell borders aligned with the scrolled columns" do
    s = render_screen
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 16, height: 8,
      style: Crysterm::Style.new(border: true),
      rows: [["Name", "City", "Age"], ["Alice", "Paris", "30"]]
    s.repaint
    # Header is row 1 (inside the top border); the `│` separator tracks the columns.
    row_chars(s, 1, 0, 16).should eq "│ Name  │ City │"
    lt.scroll_by_x 1
    s.repaint
    row_chars(s, 1, 0, 16).should eq "│ City  │ Age  │"
  end

  it "does not horizontally scroll a content-sized table" do
    s = render_screen
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, height: 6,
      rows: [["Name", "City"], ["Alice", "Paris"]] # no width: → content-sized
    s.repaint
    lt.overflows_x?.should be_false
    lt.show_horizontal_scrollbar?.should be_false
    lt.scroll_by_x 1 # no-op
    lt.child_base_x.should eq 0
  end

  it "reserves the vertical bar's column for the pinned header too" do
    s = render_screen
    # Content-sized table with enough rows to overflow height 5 -> vertical bar.
    rows = [["Name", "Status"]]
    8.times { |i| rows << ["item#{i}", "okay#{i}"] }
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, height: 5,
      scrollbar: true, rows: rows
    s.repaint

    lt.show_scrollbar?.should be_true
    # Header reserves the bar's column too, matching the body items (List#render).
    lt.header.right.should eq lt.scrollbar_width
    lt.item_boxes.all? { |i| i.right == lt.scrollbar_width }.should be_true
    # A content-sized table widens by that column so the bar gets its own cell.
    lt.awidth.should eq lt.row_width + lt.ihorizontal + lt.scrollbar_width
  end
end

describe "Horizontal scroll reaches the last column past the reserved margin" do
  it "scrolls a PlainTextEdit fully right despite its caret-column margin" do
    s = render_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 12, height: 3,
      wrap_content: false, content: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    ta.focus
    s.repaint
    # 12 cols − 1 reserved caret column (no vertical bar for one line) = 11 usable.
    ta.content_width.should eq 11

    hb = ta.horizontal_scrollbar_widget.not_nil!
    hb.maximum.should eq ta.scroll_width - ta.content_width # 26 − 11 = 15 (was 14)

    hb.value = hb.maximum # drag fully right
    s.repaint
    ta.child_base_x.should eq 15
    # The trailing 'Z' is now visible — previously the margin left it unreachable.
    row_chars(s, 0, 0, 11).should eq "PQRSTUVWXYZ"
  end
end
