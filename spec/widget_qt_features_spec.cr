require "./spec_helper"

include Crysterm

# Behavioral specs for the Qt-inspired widget options added to Crysterm:
# `ProgressBar` value range / percentage mapping, `CheckBox` tri-state,
# `Button` checkable toggling, and `TextArea`/`TextBox` `max_length` /
# `read_only` / placeholder.

private def qt_mem_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

private def keypress(ch : Char, key : Tput::Key? = nil)
  Crysterm::Event::KeyPress.new ch, key
end

describe Crysterm::Widget::ProgressBar do
  it "maps value within an arbitrary range onto a 0..100 fill" do
    s = qt_mem_screen
    pb = Crysterm::Widget::ProgressBar.new parent: s, minimum: 0, maximum: 200
    pb.value = 100
    pb.filled.should eq 50
    pb.value = 50
    pb.filled.should eq 25
  end

  it "clamps the value into [minimum, maximum]" do
    s = qt_mem_screen
    pb = Crysterm::Widget::ProgressBar.new parent: s, minimum: 10, maximum: 20
    pb.value = 5
    pb.value.should eq 10
    pb.value = 999
    pb.value.should eq 20
  end

  it "drives the bar by percentage via #filled=" do
    s = qt_mem_screen
    pb = Crysterm::Widget::ProgressBar.new parent: s, minimum: 0, maximum: 50
    pb.filled = 40
    pb.value.should eq 20
    pb.filled.should eq 40
  end

  it "emits ValueChange and Complete events" do
    s = qt_mem_screen
    pb = Crysterm::Widget::ProgressBar.new parent: s
    changes = [] of Int32
    completed = false
    pb.on(Crysterm::Event::ValueChange) { |e| changes << e.value }
    pb.on(Crysterm::Event::Complete) { completed = true }
    pb.value = 50
    pb.value = 100
    changes.should eq [50, 100]
    completed.should be_true
  end
end

describe Crysterm::Widget::CheckBox do
  it "toggles checked/unchecked by default" do
    s = qt_mem_screen
    cb = Crysterm::Widget::CheckBox.new parent: s
    cb.checked?.should be_false
    cb.toggle
    cb.checked?.should be_true
    cb.toggle
    cb.checked?.should be_false
  end

  it "cycles unchecked -> partial -> checked when tri-state" do
    s = qt_mem_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, tristate: true
    cb.checked?.should be_false
    cb.partial?.should be_false

    cb.toggle
    cb.partial?.should be_true
    cb.checked?.should be_false

    cb.toggle
    cb.checked?.should be_true
    cb.partial?.should be_false

    cb.toggle
    cb.checked?.should be_false
    cb.partial?.should be_false
  end

  it "does not enter the partial state when not tri-state" do
    s = qt_mem_screen
    cb = Crysterm::Widget::CheckBox.new parent: s
    cb.partial
    cb.partial?.should be_false
  end
end

describe Crysterm::Widget::Button do
  it "stays momentary by default" do
    s = qt_mem_screen
    b = Crysterm::Widget::Button.new parent: s
    presses = 0
    b.on(Crysterm::Event::Press) { presses += 1 }
    b.press
    presses.should eq 1
    b.checked?.should be_false
  end

  it "toggles a sticky state and emits Check/UnCheck when checkable" do
    s = qt_mem_screen
    b = Crysterm::Widget::Button.new parent: s, checkable: true
    states = [] of Bool
    b.on(Crysterm::Event::Check) { |e| states << e.value }
    b.on(Crysterm::Event::UnCheck) { |e| states << e.value }
    b.press
    b.checked?.should be_true
    b.press
    b.checked?.should be_false
    states.should eq [true, false]
  end
end

describe Crysterm::Widget::TextArea do
  it "enforces max_length on interactive input" do
    s = qt_mem_screen
    ta = Crysterm::Widget::TextArea.new parent: s, max_length: 3
    "abcdef".each_char { |c| ta._listener keypress(c) }
    ta.value.should eq "abc"
  end

  it "does not truncate programmatic value=" do
    s = qt_mem_screen
    ta = Crysterm::Widget::TextArea.new parent: s, max_length: 3
    ta.value = "abcdef"
    ta.value.should eq "abcdef"
  end

  it "ignores edits when read_only" do
    s = qt_mem_screen
    ta = Crysterm::Widget::TextArea.new parent: s, read_only: true
    ta.value = "hi"
    ta._listener keypress('x')
    ta._listener keypress('\u{8}', Tput::Key::Backspace)
    ta.value.should eq "hi"
  end
end

describe Crysterm::Widget::TextBox do
  it "exposes a placeholder while empty without affecting the value" do
    s = qt_mem_screen
    tb = Crysterm::Widget::TextBox.new parent: s, placeholder: "type here"
    tb.placeholder.should eq "type here"
    tb.value.should eq ""
  end
end

describe Crysterm::Widget::List do
  it "toggles multiple selections and reports their values" do
    s = qt_mem_screen
    list = Crysterm::Widget::List.new parent: s, multi_select: true,
      items: ["a", "b", "c", "d"]
    list.toggle_selection 1
    list.toggle_selection 3
    list.selected_indices.to_a.sort.should eq [1, 3]
    list.selected_values.should eq ["b", "d"]
    list.toggle_selection 1
    list.selected_indices.to_a.sort.should eq [3]
  end

  it "marks the cursor item and the multi-selected items as selected" do
    s = qt_mem_screen
    list = Crysterm::Widget::List.new parent: s, multi_select: true,
      items: ["a", "b", "c"]
    list.selekt 0
    list.select_item 2
    list.item_selected?(list.items[0]).should be_true # cursor
    list.item_selected?(list.items[1]).should be_false
    list.item_selected?(list.items[2]).should be_true # multi-selected
  end

  it "keeps selected indices aligned when an earlier row is removed" do
    s = qt_mem_screen
    list = Crysterm::Widget::List.new parent: s, multi_select: true,
      items: ["a", "b", "c", "d"]
    list.select_item 2             # "c"
    list.select_item 3             # "d"
    list.remove_item list.items[0] # remove "a"; c,d shift to 1,2
    list.selected_indices.to_a.sort.should eq [1, 2]
    list.selected_values.should eq ["c", "d"]
  end

  it "does not multi-select when the option is off" do
    s = qt_mem_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "b"]
    list.toggle_selection 1
    list.selected_indices.empty?.should be_true
  end
end

describe Crysterm::Widget::ListTable do
  it "sorts body rows by a column numerically, keeping the header pinned" do
    s = qt_mem_screen
    lt = Crysterm::Widget::ListTable.new parent: s, sortable: true, rows: [
      ["Name", "Score"],
      ["Alice", "10"],
      ["Bob", "2"],
      ["Carol", "30"],
    ]
    lt.sort_by_column 1
    lt.rows.first.should eq ["Name", "Score"]
    lt.rows[1..].map(&.last).should eq ["2", "10", "30"]
    lt.sort_by_column 1, descending: true
    lt.rows[1..].map(&.last).should eq ["30", "10", "2"]
  end

  it "sorts textual columns lexicographically" do
    s = qt_mem_screen
    lt = Crysterm::Widget::ListTable.new parent: s, rows: [
      ["Name"],
      ["Carol"],
      ["Alice"],
      ["Bob"],
    ]
    lt.sort_by_column 0
    lt.rows[1..].map(&.first).should eq ["Alice", "Bob", "Carol"]
  end
end

describe Crysterm::Widget::Slider do
  it "clamps and steps the value, emitting ValueChange" do
    s = qt_mem_screen
    sl = Crysterm::Widget::Slider.new parent: s, minimum: 0, maximum: 10,
      value: 5, width: 20, height: 1
    changes = [] of Int32
    sl.on(Crysterm::Event::ValueChange) { |e| changes << e.value }
    sl.increment
    sl.value.should eq 6
    sl.decrement 100
    sl.value.should eq 0
    sl.value = 999
    sl.value.should eq 10
    changes.should eq [6, 0, 10]
  end
end

describe Crysterm::Widget::SpinBox do
  it "renders prefix/suffix and steps within range" do
    s = qt_mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 5,
      value: 4, prefix: "$", suffix: "%"
    sb.text.should eq "$4%"
    sb.increment
    sb.value.should eq 5
    sb.increment # clamps at maximum
    sb.value.should eq 5
  end

  it "wraps around the bounds when wrap is enabled" do
    s = qt_mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 3,
      value: 3, wrap: true
    sb.increment
    sb.value.should eq 0
    sb.decrement
    sb.value.should eq 3
  end
end

describe Crysterm::Widget::Message::Severity do
  it "provides a colored icon prefix per severity" do
    Crysterm::Widget::Message::Severity::None.prefix.should eq ""
    Crysterm::Widget::Message::Severity::Warning.prefix.includes?("⚠").should be_true
    Crysterm::Widget::Message::Severity::Critical.prefix.includes?("red-fg").should be_true
  end
end

describe Crysterm::Widget::Loading do
  it "selects a built-in spinner by name" do
    Crysterm::Widget::Loading.spinner_frames("braille").not_nil!.size.should be > 1
    Crysterm::Widget::Loading.spinner_frames("nope").should be_nil

    s = qt_mem_screen
    l = Crysterm::Widget::Loading.new parent: s, spinner: "dots"
    l.icons.should eq Crysterm::Widget::Loading::SPINNERS["dots"]
    l.spinner = "line"
    l.icons.should eq Crysterm::Widget::Loading::SPINNERS["line"]
  end
end

describe Crysterm::Widget::Log do
  it "filters by min_level and tags each line with its level" do
    s = qt_mem_screen
    log = Crysterm::Widget::Log.new parent: s, parse_tags: true, min_level: Crysterm::Widget::Log::Level::Warn
    log.debug "ignored"
    log.warn "shown"
    log.error "boom"
    text = log.content
    text.includes?("ignored").should be_false
    text.includes?("[WARN]").should be_true
    text.includes?("[ERROR]").should be_true
  end

  it "aliases max_lines to scrollback" do
    s = qt_mem_screen
    log = Crysterm::Widget::Log.new parent: s, max_lines: 5
    log.max_lines.should eq 5
    log.max_lines = 9
    log.max_lines.should eq 9
  end
end

describe Crysterm::Widget::Menu do
  it "skips separators during navigation" do
    s = qt_mem_screen
    m = Crysterm::Widget::Menu.new parent: s
    m << Crysterm::Action.new "One"
    m.add_separator
    m << Crysterm::Action.new "Two"
    m.ritems.size.should eq 3
    m.selekt 0
    m.down # would land on the separator at 1; should skip to 2
    m.selected.should eq 2
  end

  it "toggles checkable actions when activated" do
    s = qt_mem_screen
    m = Crysterm::Widget::Menu.new parent: s
    wrap = Crysterm::Action.new "Word Wrap"
    wrap.checkable = true
    triggered = 0
    wrap.on(Crysterm::Event::Triggered) { triggered += 1 }
    m << wrap
    m.selekt 0
    m.activate_selected
    wrap.checked?.should be_true
    triggered.should eq 1
    m.activate_selected
    wrap.checked?.should be_false
  end
end

describe Crysterm::Widget::ListBar do
  it "creates separators and skips them when moving" do
    s = qt_mem_screen
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true,
      top: 0, left: 0, width: 40, height: 1
    bar.add "a"
    bar.add_separator
    bar.add "b"
    bar.commands[1].separator?.should be_true

    # Moving right from item 0 must land on item 2, stepping over the
    # separator at index 1. `selekt` flips each item's state regardless of
    # layout, so the selected glyph follows even on a headless screen.
    bar.move 1
    bar.items[2].state.selected?.should be_true
    bar.items[1].state.selected?.should be_false
  end
end

describe Crysterm::Widget::TabWidget do
  it "stacks pages and switches the visible one" do
    s = qt_mem_screen
    tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
    p1 = Crysterm::Widget::Box.new content: "one"
    p2 = Crysterm::Widget::Box.new content: "two"
    tabs.add_tab "A", p1
    tabs.add_tab "B", p2

    tabs.current_index.should eq 0
    p1.visible?.should be_true
    p2.visible?.should be_false

    tabs.next_tab
    tabs.current_index.should eq 1
    p1.visible?.should be_false
    p2.visible?.should be_true

    tabs.previous_tab
    tabs.current_index.should eq 0
    p1.visible?.should be_true
  end
end

describe Crysterm::Widget::ComboBox do
  it "exposes the selected value and cycles in place" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["red", "green", "blue"], selected: 0
    cb.value.should eq "red"
    actions = [] of String
    cb.on(Crysterm::Event::Action) { |e| actions << e.value }
    cb.cycle 1
    cb.value.should eq "green"
    cb.cycle -1
    cb.value.should eq "red"
    cb.cycle -1 # wraps to last
    cb.value.should eq "blue"
    actions.should eq ["green", "red", "blue"]
  end

  it "commits a chosen index and emits Action" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b", "c"]
    chosen = nil.as(String?)
    cb.on(Crysterm::Event::Action) { |e| chosen = e.value }
    cb.commit 2
    cb.value.should eq "c"
    cb.selected.should eq 2
    chosen.should eq "c"
    cb.open?.should be_false
  end

  it "keeps the selection in range when options are replaced" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b", "c"], selected: 2
    cb.options = ["x"]
    cb.selected.should eq 0
    cb.value.should eq "x"
  end
end

describe Crysterm::Widget::GroupBox do
  it "carries a title and toggles its checked state" do
    s = qt_mem_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Options", checkable: true, width: 30, height: 8
    child = Crysterm::Widget::CheckBox.new parent: gb, top: 0, content: "Wrap"

    gb.title.should eq "Options"
    gb.checked?.should be_true
    child.state.normal?.should be_true

    gb.toggle
    gb.checked?.should be_false
    child.state.disabled?.should be_true

    gb.toggle
    gb.checked?.should be_true
    child.state.normal?.should be_true
  end
end

describe Crysterm::Widget::Splitter do
  it "lays out two panes around the divider (horizontal)" do
    s = qt_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10, position: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp.split a, b

    sp.pane1.should be(a)
    sp.pane2.should be(b)
    a.width.should eq 10
    sp.divider.left.should eq 10
    b.left.should eq 11
  end

  it "clamps the divider position into range" do
    s = qt_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10, position: 10
    sp.split Crysterm::Widget::Box.new, Crysterm::Widget::Box.new
    sp.position = 9999
    sp.position.should eq 38 # width - 2
    sp.position = -5
    sp.position.should eq 1
  end

  it "splits vertically by height" do
    s = qt_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, orientation: Tput::Orientation::Vertical,
      width: 40, height: 20, position: 8
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    sp.split a, b
    a.height.should eq 8
    sp.divider.top.should eq 8
    b.top.should eq 9
  end
end
