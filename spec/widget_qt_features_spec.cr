require "./spec_helper"

include Crysterm

# Behavioral specs for the Qt-inspired widget options added to Crysterm:
# `ProgressBar` value range / percentage mapping, `CheckBox` tri-state,
# `Button` checkable toggling, and `PlainTextEdit`/`LineEdit` `max_length` /
# `read_only` / placeholder.

private def qt_mem_screen
  # `default_quit_keys: false`: the default handler calls `exit` on a `q`/Ctrl-Q
  # keypress (the interactive "press q to quit" behavior). These specs synthesize
  # key events — e.g. the ListBar tests `emit KeyPress, 'q'` to exercise a `q`
  # *hotkey* — so leaving it on would terminate the whole spec process mid-run
  # (no summary, exit 0). Headless test screens want no interactive quit.
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
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

describe Crysterm::Widget::PlainTextEdit do
  it "enforces max_length on interactive input" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, max_length: 3
    "abcdef".each_char { |c| ta._listener keypress(c) }
    ta.value.should eq "abc"
  end

  it "does not truncate programmatic value=" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, max_length: 3
    ta.value = "abcdef"
    ta.value.should eq "abcdef"
  end

  it "ignores edits when read_only" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, read_only: true
    ta.value = "hi"
    ta._listener keypress('x')
    ta._listener keypress('\u{8}', Tput::Key::Backspace)
    ta.value.should eq "hi"
  end

  # Workstream C-tail: one scroll model (`@child_base`), caret tracked via
  # `@cursor_pos`, `@child_offset` ≡ 0, so the attached bar drives the viewport.
  it "defaults to AsNeeded and shows a working bar on overflow" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..30).map { |i| "line#{i}" }.join("\n")
    ta.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AsNeeded
    s._render
    ta.show_scrollbar?.should be_true
    sb = ta.scrollbar_widget.should_not be_nil
    sb.maximum.should be > 0
    # `get_scroll == child_base` (the caret is tracked separately, not as offset).
    ta.child_offset.should eq 0
    sb.value.should eq ta.child_base
  end

  it "drags the bar to scroll the viewport, leaving the caret put" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..30).map { |i| "line#{i}" }.join("\n")
    ta.cursor_pos = 0 # caret at the top
    s._render
    sb = ta.scrollbar_widget.not_nil!

    sb.value = 3              # a small drag the old model lost into @child_offset
    ta.child_base.should eq 3 # the view actually moved...
    ta.child_offset.should eq 0
    ta.cursor_pos.should eq 0 # ...and the caret stayed (scrolled off the top)
    sb.sync_from_target
    sb.value.should eq 3 # no jump-back (single model, no feedback)
  end

  it "follows the caret with the viewport, and the bar follows the view" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..30).map { |i| "line#{i}" }.join("\n")
    ta.cursor_pos = 0
    s._render
    sb = ta.scrollbar_widget.not_nil!

    # Walk the caret down past the bottom visible row; the view follows.
    8.times { ta._listener keypress(' ', Tput::Key::Down) }
    ta.child_offset.should eq 0
    ta.child_base.should be > 0
    sb.value.should eq ta.child_base
  end

  it "shows the vertical bar only on real overflow, not for content that fits" do
    s = qt_mem_screen
    short = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 12, height: 4,
      content: "hi"
    s._render
    short.really_scrollable?.should be_false # `@resizable` no longer forces this
    short.show_scrollbar?.should be_false    # …so no vertical bar for a fitting field

    tall = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 20, width: 12, height: 4,
      content: (1..10).map { |i| "L#{i}" }.join("\n")
    s._render
    tall.show_scrollbar?.should be_true
  end

  it "hides the vertical bar again after content shrinks (chrome is not content)" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 12, height: 6,
      content: "hi"
    s._render
    ta.value = (1..20).map { |i| "line#{i}" }.join("\n") # overflow → bar appears
    s._render
    ta.show_scrollbar?.should be_true

    ta.value = "hi" # shrink back: the (now-hidden) bar child must not keep the
    s._render       # scroll height inflated and re-trigger AsNeeded
    ta.get_scroll_height.should eq 1
    ta.show_scrollbar?.should be_false
  end

  it "scrolls horizontally for non-wrapped long lines, following the caret" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 12, height: 3,
      wrap_content: false, content: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    ta.focus
    s._render
    ta.really_scrollable_x?.should be_true
    ta.show_horizontal_scrollbar?.should be_true
    ta.child_base_x.should be > 0 # caret created at the line end → view followed it

    ta._listener keypress(' ', Tput::Key::Home) # caret to line start → view snaps left
    ta.child_base_x.should eq 0
    ta.cursor_pos.should eq 0
  end

  it "drags the horizontal bar without moving the caret" do
    s = qt_mem_screen
    ta = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 12, height: 3,
      wrap_content: false, content: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    ta.focus
    ta._listener keypress(' ', Tput::Key::Home)
    s._render
    ta.child_base_x.should eq 0

    hb = ta.horizontal_scrollbar_widget.not_nil!
    hb.value = hb.maximum # drag right
    ta.child_base_x.should be > 0
    ta.cursor_pos.should eq 0 # the caret stayed put (it may scroll off-screen)
  end
end

describe Crysterm::Widget::LineEdit do
  it "exposes a placeholder while empty without affecting the value" do
    s = qt_mem_screen
    tb = Crysterm::Widget::LineEdit.new parent: s, placeholder: "type here"
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

describe "GroupBox child enabling" do
  it "disables a child added after construction when unchecked" do
    s = qt_mem_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "G", checkable: true,
      checked: false, width: 20, height: 6
    child = Crysterm::Widget::CheckBox.new parent: gb, top: 0, content: "x"
    # Adopted into an unchecked group -> comes up disabled.
    child.state.disabled?.should be_true
    gb.toggle
    child.state.normal?.should be_true
  end
end

describe "ComboBox cleanup" do
  it "removes its popup from the screen when destroyed" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b"]
    cb.open
    pop = cb.@popup.not_nil!
    s.children.includes?(pop).should be_true
    cb.destroy
    s.children.includes?(pop).should be_false
  end
end

describe "ListBar auto_command_keys" do
  it "selects a tab by number through the focused bar's key handler" do
    s = qt_mem_screen
    fired = [] of Int32
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true, auto_command_keys: true
    bar.add("one") { fired << 0 }
    bar.add("two") { fired << 1 }
    bar.add("three") { fired << 2 }
    bar.on_keypress(keypress('2'))
    fired.should eq [1]
    bar.on_keypress(keypress('3'))
    fired.should eq [1, 2]
  end
end

describe "ListBar hotkey cleanup" do
  it "stops a removed command's global hotkey from firing" do
    s = qt_mem_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true
    bar.add("keep") { }
    item = bar.add("quit", keys: ["q"]) { fired += 1 }

    s.emit Crysterm::Event::KeyPress, 'q'
    fired.should eq 1

    bar.remove_item item
    s.emit Crysterm::Event::KeyPress, 'q'
    fired.should eq 1 # handler was detached, so no further firing
  end

  it "detaches all hotkeys when the bar is destroyed" do
    s = qt_mem_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true
    bar.add("quit", keys: ["q"]) { fired += 1 }
    bar.destroy
    s.emit Crysterm::Event::KeyPress, 'q'
    fired.should eq 0
  end
end

describe Crysterm::Widget::StackedWidget do
  it "shows exactly one page at a time" do
    s = qt_mem_screen
    st = Crysterm::Widget::StackedWidget.new parent: s, width: 30, height: 10
    p1 = Crysterm::Widget::Box.new content: "1"
    p2 = Crysterm::Widget::Box.new content: "2"
    st.add_page p1
    st.add_page p2
    st.count.should eq 2
    st.current_index.should eq 0
    p1.visible?.should be_true
    p2.visible?.should be_false
    st.current = 1
    st.current_index.should eq 1
    p2.visible?.should be_true
    p1.visible?.should be_false
    st.next_page
    st.current_index.should eq 0
  end
end

describe Crysterm::Widget::Dial do
  it "clamps and steps the value, emitting ValueChange" do
    s = qt_mem_screen
    d = Crysterm::Widget::Dial.new parent: s, minimum: 0, maximum: 10, value: 5, width: 6, height: 4
    changes = [] of Int32
    d.on(Crysterm::Event::ValueChange) { |e| changes << e.value }
    d.increment
    d.value.should eq 6
    d.value = 999
    d.value.should eq 10
    changes.should eq [6, 10]
  end

  it "wraps around the bounds when enabled" do
    s = qt_mem_screen
    d = Crysterm::Widget::Dial.new parent: s, minimum: 0, maximum: 3, value: 3, wrap: true, width: 6, height: 4
    d.increment
    d.value.should eq 0
  end
end

describe "ComboBox editable" do
  it "filters options by typed text and commits the highlighted match" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, editable: true,
      options: ["Apple", "Banana", "Cherry", "Avocado"]
    cb.on_keypress keypress('a')
    cb.on_keypress keypress('v')
    cb.open?.should be_true
    cb.on_keypress(Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter))
    cb.value.should eq "Avocado"
    cb.open?.should be_false
  end

  it "commits free text when nothing matches" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, editable: true, options: ["X", "Y"]
    "zzz".each_char { |c| cb.on_keypress keypress(c) }
    cb.on_keypress(Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter))
    cb.value.should eq "zzz"
  end
end

describe "Splitter multi-pane" do
  it "lays out three panes with two dividers" do
    s = qt_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 31, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    c = Crysterm::Widget::Box.new
    sp.add_pane a
    sp.add_pane b
    sp.add_pane c

    sp.panes.size.should eq 3
    sp.dividers.size.should eq 2
    sp.divider_position(0).should be < sp.divider_position(1)
    a.width.should eq 9
    b.width.should eq 9
    sp.dividers[0].left.should eq 9
    sp.dividers[1].left.should eq 19

    sp.set_divider_position 0, 5
    sp.divider_position(0).should eq 5
    a.width.should eq 5
  end

  it "pulls pinned dividers back inside a shrunken span without inverting" do
    s = qt_mem_screen
    sp = Crysterm::Widget::Splitter.new parent: s, width: 40, height: 10
    a = Crysterm::Widget::Box.new
    b = Crysterm::Widget::Box.new
    c = Crysterm::Widget::Box.new
    sp.add_pane a
    sp.add_pane b
    sp.add_pane c

    # Pin both dividers near the right edge of the wide splitter.
    sp.set_divider_position 0, 23
    sp.set_divider_position 1, 35

    # Shrink the splitter far below where the dividers were pinned and relayout.
    sp.width = 12
    sp.set_divider_position 1, sp.divider_position(1)

    # Dividers stay ordered and inside the new 12-cell span (each pane >= 1 cell).
    sp.divider_position(0).should be < sp.divider_position(1)
    sp.divider_position(1).should be <= 10 # total(12) - 2
    a.width.as(Int32).should be >= 1
    b.width.as(Int32).should be >= 1
  end
end

describe Crysterm::Widget::Tree do
  it "flattens only expanded nodes into rows, indented by depth" do
    s = qt_mem_screen
    tree = Crysterm::Widget::Tree.new parent: s, width: 30, height: 12
    src = tree.add "src"
    src.add "widget"
    src.add "layout"
    tree.add "README.md"

    # Collapsed by default: only the two top-level nodes show.
    tree.nodes.map(&.text).should eq ["src", "README.md"]
    tree.ritems.first.should eq "\u{25b8} src" # ▸ collapsed marker

    tree.expand src
    tree.nodes.map(&.text).should eq ["src", "widget", "layout", "README.md"]
    tree.ritems.first.should eq "\u{25be} src" # ▾ expanded marker
    # depth-1 (2-space) indent + leaf marker (space) + separator space:
    tree.ritems[1].should eq "    widget"

    tree.collapse src
    tree.nodes.map(&.text).should eq ["src", "README.md"]
  end

  it "emits Expand/Collapse and keeps the cursor on the same node" do
    s = qt_mem_screen
    tree = Crysterm::Widget::Tree.new parent: s, width: 30, height: 12
    a = tree.add "a"
    a.add "a1"
    b = tree.add "b"

    expanded = [] of Int32
    collapsed = [] of Int32
    tree.on(Crysterm::Event::Expand) { |e| expanded << e.index }
    tree.on(Crysterm::Event::Collapse) { |e| collapsed << e.index }

    tree.selekt 1 # cursor on "b"
    tree.expand a # inserts "a1" above "b"; cursor should follow "b"
    tree.selected_node.should be(b)
    expanded.should eq [0]

    tree.collapse a
    collapsed.should eq [0]
  end

  it "navigates with Right/Left/Space" do
    s = qt_mem_screen
    tree = Crysterm::Widget::Tree.new parent: s, width: 30, height: 12
    root = tree.add "root"
    child = root.add "child"

    tree.selekt 0
    tree.on_keypress keypress('\0', Tput::Key::Right) # expand
    root.expanded?.should be_true
    tree.on_keypress keypress('\0', Tput::Key::Right) # descend into child
    tree.selected_node.should be(child)
    tree.on_keypress keypress('\0', Tput::Key::Left) # leaf -> jump to parent
    tree.selected_node.should be(root)
    tree.on_keypress keypress(' ') # space toggles -> collapse
    root.expanded?.should be_false
  end

  it "expand_all / collapse_all walk the whole hierarchy" do
    s = qt_mem_screen
    tree = Crysterm::Widget::Tree.new parent: s, width: 30, height: 12
    a = tree.add "a"
    b = a.add "b"
    b.add "c"

    tree.expand_all
    tree.nodes.map(&.text).should eq ["a", "b", "c"]
    tree.collapse_all
    tree.nodes.map(&.text).should eq ["a"]
  end
end

describe "ComboBox mouse wheel" do
  it "cycles the value when wheeled while closed" do
    s = qt_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 16, height: 1,
      options: ["Red", "Green", "Blue"]
    cb.value.should eq "Red"
    s.dispatch_mouse(::Tput::Mouse::Event.new(::Tput::Mouse::Action::WheelDown, ::Tput::Mouse::Button::None, cb.aleft + 2, cb.atop, source: :test))
    cb.value.should eq "Green"
    s.dispatch_mouse(::Tput::Mouse::Event.new(::Tput::Mouse::Action::WheelUp, ::Tput::Mouse::Button::None, cb.aleft + 2, cb.atop, source: :test))
    cb.value.should eq "Red"
  end
end

describe "SpinBox direct entry" do
  it "types a value and commits it on Enter" do
    s = qt_mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 5
    sb.on_keypress keypress('4')
    sb.on_keypress keypress('2')
    sb.editing?.should be_true
    sb.text.should eq "42"
    sb.on_keypress keypress('\r', Tput::Key::Enter)
    sb.editing?.should be_false
    sb.value.should eq 42
  end

  it "clamps a typed value above maximum and discards on Escape" do
    s = qt_mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 50, value: 5
    "999".each_char { |c| sb.on_keypress keypress(c) }
    sb.on_keypress keypress('\r', Tput::Key::Enter)
    sb.value.should eq 50

    "12".each_char { |c| sb.on_keypress keypress(c) }
    sb.on_keypress keypress('\u{1b}', Tput::Key::Escape)
    sb.editing?.should be_false
    sb.value.should eq 50 # unchanged
  end

  it "edits the buffer with Backspace" do
    s = qt_mem_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 0
    "45".each_char { |c| sb.on_keypress keypress(c) }
    sb.on_keypress keypress('\u{8}', Tput::Key::Backspace)
    sb.text.should eq "4"
    sb.on_keypress keypress('\r', Tput::Key::Enter)
    sb.value.should eq 4
  end
end

describe Crysterm::Widget::DoubleSpinBox do
  it "formats to decimals and steps by a float step" do
    s = qt_mem_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 10.0,
      value: 1.5, step: 0.5, decimals: 2
    d.formatted_value.should eq "1.50"
    changes = [] of Float64
    d.on(Crysterm::Event::DoubleValueChange) { |e| changes << e.value }
    d.increment
    d.value.should eq 2.0
    d.value = 99.0 # clamps to 10.0
    d.value.should eq 10.0
    changes.should eq [2.0, 10.0]
  end

  it "accepts typed decimals" do
    s = qt_mem_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 10.0, value: 0.0
    "2.5".each_char { |c| d.on_keypress keypress(c) }
    d.on_keypress keypress('\r', Tput::Key::Enter)
    d.value.should eq 2.5
  end
end

describe "Slider tick marks" do
  it "carries tick configuration without affecting stepping" do
    s = qt_mem_screen
    sl = Crysterm::Widget::Slider.new parent: s, minimum: 0, maximum: 10, value: 5,
      width: 20, height: 3, tick_position: Crysterm::Widget::Slider::TickPosition::Below,
      tick_interval: 2
    sl.tick_position.below?.should be_true
    sl.tick_interval.should eq 2
    sl.increment
    sl.value.should eq 6
  end
end

describe "TabWidget closable / movable / position" do
  it "removes a tab and re-points the current index" do
    s = qt_mem_screen
    tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
    tabs.add_tab "A", Crysterm::Widget::Box.new(content: "a")
    tabs.add_tab "B", Crysterm::Widget::Box.new(content: "b")
    tabs.add_tab "C", Crysterm::Widget::Box.new(content: "c")
    tabs.show_tab 2
    tabs.current_index.should eq 2

    tabs.remove_tab 1
    tabs.pages.size.should eq 2
    tabs.tab_titles.should eq ["A", "C"]
    tabs.current_index.should eq 1 # clamped onto remaining "C"
  end

  it "reorders tabs with move_tab, keeping the same page current" do
    s = qt_mem_screen
    tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10
    tabs.add_tab "A", Crysterm::Widget::Box.new(content: "a")
    tabs.add_tab "B", Crysterm::Widget::Box.new(content: "b")
    tabs.add_tab "C", Crysterm::Widget::Box.new(content: "c")
    tabs.show_tab 0 # "A" current

    tabs.move_tab 0, 2
    tabs.tab_titles.should eq ["B", "C", "A"]
    tabs.current_page.try(&.content).should eq "a"
  end

  it "lays the page below the bar when tab_position is bottom" do
    s = qt_mem_screen
    tabs = Crysterm::Widget::TabWidget.new parent: s, width: 40, height: 10,
      tab_position: Crysterm::Widget::TabWidget::Position::Bottom
    page = Crysterm::Widget::Box.new content: "x"
    tabs.add_tab "A", page
    page.top.should eq 0
    page.bottom.should eq 1 # tab_height reserved at the bottom
  end
end

describe Crysterm::Widget::ScrollBar do
  it "clamps and steps as a standalone control, emitting ValueChange" do
    s = qt_mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 10, value: 0,
      width: 1, height: 5
    changes = [] of Int32
    sb.on(Crysterm::Event::ValueChange) { |e| changes << e.value }
    sb.increment
    sb.value.should eq 1
    sb.on_keypress keypress(' ', Tput::Key::End)
    sb.value.should eq 10
    sb.on_keypress keypress(' ', Tput::Key::Home)
    sb.value.should eq 0
    changes.should eq [1, 10, 0]
  end

  it "reflects and drives a bound scrollable widget" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..20).map { |i| "line#{i}" }.join("\n")
    s._render # establish geometry + wrapped content lines

    sb = Crysterm::Widget::ScrollBar.new parent: s, top: 0, left: 21, width: 1, height: 5
    sb.attach box
    sb.maximum.should be > 0

    sb.value = 2
    box.get_scroll.should eq 2 # the bar drove the box

    box.scroll 3
    sb.value.should eq box.get_scroll # the box drove the bar back
  end

  it "set_range re-clamps the value and emits RangeChange" do
    s = qt_mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 100, value: 80,
      width: 1, height: 5
    ranges = [] of {Int32, Int32}
    sb.on(Crysterm::Event::RangeChange) { |e| ranges << {e.minimum, e.maximum} }
    sb.set_range 0, 50
    sb.maximum.should eq 50
    sb.value.should eq 50 # 80 re-clamped into [0, 50]
    ranges.should eq [{0, 50}]

    sb.range = 0..10
    sb.maximum.should eq 10
    sb.value.should eq 10
    ranges.last.should eq({0, 10})

    sb.set_range 0, 10 # no change → no emit
    ranges.size.should eq 2
  end

  it "single_step aliases step" do
    s = qt_mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 10, value: 0,
      step: 1, width: 1, height: 5
    sb.single_step.should eq 1
    sb.single_step = 3
    sb.step.should eq 3
    sb.increment
    sb.value.should eq 3
  end

  it "defers value to release when tracking is off (slider_position)" do
    s = qt_mem_screen
    sb = Crysterm::Widget::ScrollBar.new parent: s, minimum: 0, maximum: 10, value: 0,
      width: 1, height: 5
    sb.tracking = false
    sb.tracking?.should be_false
    sb.slider_position = 7
    sb.slider_position.should eq 7
    sb.value.should eq 0 # not committed yet

    sb.tracking = true
    sb.slider_position = 4
    sb.value.should eq 4 # committed live
    sb.slider_position.should eq 4
  end
end

describe "Widget::ScrollBarPolicy (auto show/hide)" do
  it "AsNeeded shows the bar only when content overflows" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..20).map { |i| "line#{i}" }.join("\n")
    box.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AsNeeded
    s._render
    box.show_scrollbar?.should be_true
    sb = box.scrollbar_widget.should_not be_nil
    sb.visible?.should be_true
    sb.maximum.should be > 0
  end

  it "AsNeeded keeps the bar hidden when content fits" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 10,
      content: "a\nb\nc"
    s._render
    box.show_scrollbar?.should be_false
    box.scrollbar_widget.try(&.visible?).should_not eq true
  end

  it "AlwaysOn shows the bar even without overflow" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 10,
      content: "a\nb\nc", scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AlwaysOn
    s._render
    box.show_scrollbar?.should be_true
    box.scrollbar_widget.not_nil!.visible?.should be_true
  end

  it "AlwaysOff never shows the bar, even on overflow" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..20).map { |i| "line#{i}" }.join("\n"),
      scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AlwaysOff
    s._render
    box.show_scrollbar?.should be_false
    box.scrollbar_widget.try(&.visible?).should_not eq true
  end

  it "legacy scrollbar: true/false maps to a policy" do
    s = qt_mem_screen
    on = Crysterm::Widget::Box.new parent: s, scrollbar: true, width: 10, height: 5
    on.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AsNeeded
    on.scrollbar?.should be_true
    off = Crysterm::Widget::ScrollableBox.new parent: s, scrollbar: false, width: 10, height: 5
    off.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AlwaysOff
  end

  it "List defaults to AsNeeded and sizes the thumb to its item count" do
    s = qt_mem_screen
    list = Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 5,
      items: (1..20).map { |i| "item#{i}" }
    list.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AsNeeded
    s._render
    list.show_scrollbar?.should be_true
    sb = list.scrollbar_widget.not_nil!
    sb.maximum.should be > 0    # range derived from item count
    sb.page_step.should be <= 5 # thumb page = visible rows
  end
end

describe "Event::Scroll payload (delta / orientation)" do
  it "reports the signed delta and axis on each scroll" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..30).map { |i| "line#{i}" }.join("\n")
    s._render

    events = [] of {Int32, Tput::Orientation}
    box.on(Crysterm::Event::Scroll) { |e| events << {e.delta, e.orientation} }

    box.scroll 4     # down
    box.scroll -2    # up
    box.reset_scroll # back to top (was at base 2)

    events.should eq [
      {4, Tput::Orientation::Vertical},
      {-2, Tput::Orientation::Vertical},
      {-2, Tput::Orientation::Vertical},
    ]
  end

  it "defaults to a zero vertical delta for a bare emit" do
    e = Crysterm::Event::Scroll.new
    e.delta.should eq 0
    e.orientation.should eq Tput::Orientation::Vertical
  end
end

describe "QAbstractScrollArea facade" do
  it "vertical_scrollbar returns (and lazily creates) the bound bar" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..20).map { |i| "line#{i}" }.join("\n")
    box.scrollbar_widget.should be_nil
    bar = box.vertical_scrollbar
    bar.should be_a Crysterm::Widget::ScrollBar
    box.scrollbar_widget.should be bar # cached, same instance

    # Horizontal bar: also lazily created (Qt's object-always-exists shape).
    box.horizontal_scrollbar_widget.should be_nil
    hbar = box.horizontal_scrollbar
    hbar.should be_a Crysterm::Widget::ScrollBar
    hbar.orientation.horizontal?.should be_true
    box.horizontal_scrollbar_widget.should be hbar
  end

  it "vertical_scrollbar_policy aliases scrollbar_policy" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, width: 10, height: 5
    box.vertical_scrollbar_policy.should eq box.scrollbar_policy
    box.vertical_scrollbar_policy = Crysterm::Widget::ScrollBarPolicy::AlwaysOn
    box.scrollbar_policy.should eq Crysterm::Widget::ScrollBarPolicy::AlwaysOn
  end

  it "ensure_visible scrolls an off-screen line into view, and no-ops when visible" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..20).map { |i| "line#{i}" }.join("\n")
    s._render
    box.child_base.should eq 0
    box.ensure_visible(15).should be_true # line 15 below the viewport
    box.child_base.should be > 0
    (box.child_base <= 15).should be_true
    (15 <= box.child_base + (box.aheight - box.iheight) - 1).should be_true # now within view
    box.ensure_visible(15).should be_false                                  # already visible → no move
  end

  it "scroll_contents_by maps dy onto scroll and drives the bound bar" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..20).map { |i| "line#{i}" }.join("\n")
    s._render
    bar = box.vertical_scrollbar
    box.scroll_contents_by(0, 4)
    box.get_scroll.should be > 0
    bar.value.should eq box.get_scroll # Event::Scroll synced the bar
  end

  it "ensure_widget_visible scrolls a descendant into view" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: (1..30).map { |i| "line#{i}" }.join("\n")
    child = Crysterm::Widget::Box.new parent: box, top: 20, left: 0, width: 5, height: 1, content: "x"
    s._render
    box.ensure_widget_visible(child).should be_true
    (box.child_base <= child.rtop).should be_true
  end
end

describe Crysterm::Widget::ToolBox do
  it "shows exactly one expanded section at a time" do
    s = qt_mem_screen
    tb = Crysterm::Widget::ToolBox.new parent: s, width: 30, height: 16
    p1 = Crysterm::Widget::Box.new content: "1"
    p2 = Crysterm::Widget::Box.new content: "2"
    tb.add_item "A", p1
    tb.add_item "B", p2

    tb.sections.size.should eq 2
    tb.current_index.should eq 0
    p1.visible?.should be_true
    p2.visible?.should be_false

    tb.current = 1
    tb.current_index.should eq 1
    p2.visible?.should be_true
    p1.visible?.should be_false
  end
end

describe Crysterm::Widget::Wizard do
  it "navigates pages and finishes / cancels" do
    s = qt_mem_screen
    wiz = Crysterm::Widget::Wizard.new parent: s, width: 50, height: 16
    wiz.add_page Crysterm::Widget::Box.new(content: "1"), title: "One"
    wiz.add_page Crysterm::Widget::Box.new(content: "2"), title: "Two"
    wiz.add_page Crysterm::Widget::Box.new(content: "3"), title: "Three"

    completed = false
    cancelled = false
    wiz.on(Crysterm::Event::Complete) { completed = true }
    wiz.on(Crysterm::Event::Cancel) { cancelled = true }

    wiz.current_index.should eq 0
    wiz.advance
    wiz.current_index.should eq 1
    wiz.advance
    wiz.current_index.should eq 2
    wiz.advance # Finish on the last page
    completed.should be_true
    wiz.current_index.should eq 2 # finishing does not advance past the end

    wiz.back
    wiz.current_index.should eq 1
    wiz.cancel
    cancelled.should be_true
  end
end

describe Crysterm::Widget::Calendar do
  it "moves the selection by day/week/month and emits DateChange" do
    s = qt_mem_screen
    cal = Crysterm::Widget::Calendar.new parent: s, date: Time.local(2024, 1, 15)
    changes = [] of Time
    cal.on(Crysterm::Event::DateChange) { |e| changes << e.date }

    cal.on_keypress keypress(' ', Tput::Key::Right) # +1 day -> 16
    cal.date.day.should eq 16
    cal.on_keypress keypress(' ', Tput::Key::Down) # +7 days -> 23
    cal.date.day.should eq 23
    cal.on_keypress keypress(' ', Tput::Key::PageDown) # +1 month -> Feb
    cal.date.month.should eq 2
    changes.size.should eq 3
  end

  it "clamps the day when stepping into a shorter month" do
    s = qt_mem_screen
    cal = Crysterm::Widget::Calendar.new parent: s, date: Time.local(2024, 1, 31)
    cal.on_keypress keypress(' ', Tput::Key::PageDown) # Jan 31 -> Feb (29 in 2024)
    cal.date.month.should eq 2
    cal.date.day.should eq 29
  end
end

describe Crysterm::Widget::DateEdit do
  it "steps the focused section (day/month/year)" do
    s = qt_mem_screen
    de = Crysterm::Widget::DateEdit.new parent: s, date: Time.local(2024, 1, 15),
      calendar_popup: false
    de.on_keypress keypress(' ', Tput::Key::Up) # day section by default -> 16
    de.date.day.should eq 16
    de.on_keypress keypress(' ', Tput::Key::Left) # -> month section
    de.on_keypress keypress(' ', Tput::Key::Up)   # +1 month -> Feb
    de.date.month.should eq 2
    de.on_keypress keypress(' ', Tput::Key::Left) # -> year section
    de.on_keypress keypress(' ', Tput::Key::Up)   # +1 year -> 2025
    de.date.year.should eq 2025
  end
end

describe Crysterm::Widget::TimeEdit do
  it "steps each section within its own range, wrapping" do
    s = qt_mem_screen
    te = Crysterm::Widget::TimeEdit.new parent: s, time: Time.local(2024, 1, 15, 10, 30, 45)
    changes = [] of Time
    te.on(Crysterm::Event::DateChange) { |e| changes << e.date }

    te.on_keypress keypress(' ', Tput::Key::Up) # hour -> 11
    te.time.hour.should eq 11
    te.on_keypress keypress(' ', Tput::Key::Right) # -> minute section
    te.on_keypress keypress(' ', Tput::Key::Up)    # minute -> 31
    te.time.minute.should eq 31
    changes.size.should eq 2
  end

  it "wraps the hour at 23 without carrying" do
    s = qt_mem_screen
    te = Crysterm::Widget::TimeEdit.new parent: s, time: Time.local(2024, 1, 15, 23, 0, 0)
    te.on_keypress keypress(' ', Tput::Key::Up) # 23 -> 0, day unchanged
    te.time.hour.should eq 0
    te.time.day.should eq 15
  end
end

describe "Menu Qt conveniences" do
  it "adds actions by text and connects a block" do
    s = qt_mem_screen
    m = Crysterm::Widget::Menu.new parent: s
    m.add "One"
    fired = 0
    m.add("Two") { fired += 1 }
    m.actions.size.should eq 2
    m.selekt 1
    m.activate_selected
    fired.should eq 1
  end

  it "adds a submenu via add_menu" do
    s = qt_mem_screen
    m = Crysterm::Widget::Menu.new parent: s
    act = m.add_menu "File", [Crysterm::Action.new("a"), Crysterm::Action.new("b")]
    act.submenu?.should be_true
    act.submenu.not_nil!.size.should eq 2
  end

  it "shows and dismisses as a context-menu popup" do
    s = qt_mem_screen
    m = Crysterm::Widget::Menu.new parent: s, style: Style.new(border: true)
    m.add "Copy"
    m.add "Paste"
    m.popup 5, 5
    m.left.should eq 5
    m.top.should eq 5
    m.visible?.should be_true
    m.hide_popup
    m.visible?.should be_false
  end
end

describe Crysterm::Widget::DateTimeEdit do
  it "steps each of the six sections, wrapping within range" do
    s = qt_mem_screen
    dt = Crysterm::Widget::DateTimeEdit.new parent: s, date_time: Time.local(2024, 1, 31, 23, 59, 59)
    changes = [] of Time
    dt.on(Crysterm::Event::DateChange) { |e| changes << e.date }

    dt.on_keypress keypress('\0', Tput::Key::Up) # year (default section) -> 2025
    dt.date_time.year.should eq 2025

    dt.on_keypress keypress('\0', Tput::Key::Right) # -> month
    dt.on_keypress keypress('\0', Tput::Key::Right) # -> day
    dt.on_keypress keypress('\0', Tput::Key::Up)    # day 31 wraps within month -> 1
    dt.date_time.day.should eq 1

    changes.size.should eq 2
  end
end

describe Crysterm::Widget::StatusBar do
  it "holds a temporary message and permanent sections" do
    s = qt_mem_screen
    bar = Crysterm::Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    bar.show_message "Hello"
    bar.message.should eq "Hello"
    bar.add_permanent "UTF-8"
    bar.add_permanent "Ln 1"
    bar.permanent.should eq ["UTF-8", "Ln 1"]
    bar.clear_message
    bar.message.should eq ""
  end
end

describe Crysterm::Widget::DockWidget do
  it "sets a content widget and emits Close on close_dock" do
    s = qt_mem_screen
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "Files",
      area: Crysterm::Widget::DockWidget::Area::Left
    inner = Crysterm::Widget::Box.new content: "x"
    dock.widget = inner
    dock.widget.should be(inner)

    closed = false
    dock.on(Crysterm::Event::Close) { closed = true }
    dock.close_dock
    closed.should be_true
    dock.visible?.should be_false
  end

  it "toggles floating and emits Float, restoring the prior area" do
    s = qt_mem_screen
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "F",
      area: Crysterm::Widget::DockWidget::Area::Right
    states = [] of Bool
    dock.on(Crysterm::Event::Float) { |e| states << e.value }
    dock.toggle_floating
    dock.floating?.should be_true
    dock.toggle_floating
    dock.floating?.should be_false
    dock.area.right?.should be_true
    states.should eq [true, false]
  end

  it "shows the resize grip only while floating (Qt: no corner grip when docked)" do
    s = qt_mem_screen
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "P",
      area: Crysterm::Widget::DockWidget::Area::Left
    grip = dock.size_grip.not_nil!
    grip.visible?.should be_false # docked → resized via the separator, no grip
    dock.toggle_floating
    grip.visible?.should be_true # floating → grip available
    dock.toggle_floating
    grip.visible?.should be_false # re-docked → grip hidden again

    # A non-floatable dock can't detach, so it has no grip at all.
    fixed = Crysterm::Widget::DockWidget.new parent: s, title: "X",
      area: Crysterm::Widget::DockWidget::Area::Left, floatable: false
    fixed.size_grip.should be_nil
  end

  it "gives the title buttons the bar's background so they are never transparent" do
    # Mimics a Qt theme (e.g. Breeze) that styles the dock title bar with a solid
    # background but its `::close-button`/`::float-button` with a transparent one
    # (for icon images). In a terminal that transparent bg paints the screen
    # default (`-1`) and the glyph renders as a "black hole"; the widget must fall
    # the buttons back to the bar's own background so they stay legible.
    s = qt_mem_screen
    s.stylesheet = "DockWidget::title { background-color: #334455; color: #ffffff; } " \
                   "DockWidget::close-button, DockWidget::float-button { background-color: transparent; }"
    dock = Crysterm::Widget::DockWidget.new parent: s, title: "Panes",
      area: Crysterm::Widget::DockWidget::Area::Floating
    dock.top = 1; dock.left = 1; dock.width = 20; dock.height = 6
    dock.widget = Crysterm::Widget::Box.new content: "x"
    s._render

    bar_bg = dock.titlebar.style.bg
    bar_bg.should eq 0x334455
    [dock.@close_button, dock.@float_button].each do |btn|
      b = btn.not_nil!
      b.style.bg.should eq bar_bg # adopted the bar's bg, not the transparent -1
      b.style.bg.should_not eq -1
    end
  end
end

describe Crysterm::Widget::MainWindow do
  it "arranges the bars, a left dock, and the central widget" do
    s = qt_mem_screen
    win = Crysterm::Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    menu = Crysterm::Widget::Box.new content: "menu"
    status = Crysterm::Widget::Box.new content: "status"
    central = Crysterm::Widget::Box.new content: "central"
    win.menu_bar = menu
    win.status_bar = status
    win.central_widget = central
    win.add_dock Crysterm::Widget::DockWidget.new(title: "L",
      area: Crysterm::Widget::DockWidget::Area::Left, dock_size: 20)
    s._render

    menu.atop.should eq win.atop                     # full-width strip at the top
    status.atop.should eq win.atop + win.aheight - 1 # full-width strip at the bottom
    central.aleft.should eq win.aleft + 20           # right of the 20-wide left dock
    central.atop.should eq win.atop + 1              # below the menu bar
  end
end

describe Crysterm::Widget::ToolTip do
  it "registers hover help and becomes hit-testable" do
    s = qt_mem_screen
    b = Crysterm::Widget::Box.new parent: s, top: 2, left: 2, width: 10, height: 3
    b.wants_mouse?.should be_false
    b.tool_tip = "Help!"
    b.tool_tip.should eq "Help!"
    b.wants_mouse?.should be_true
  end

  it "sizes and positions itself via show_at" do
    s = qt_mem_screen
    tip = Crysterm::Widget::ToolTip.new parent: s
    tip.show_at 3, 4, "Hello"
    tip.visible?.should be_true
    tip.left.should eq 3
    tip.top.should eq 4
    # No stylesheet applied here, so the tooltip is on the unstyled floor and
    # carries its structural border (see `ToolTip#floor_border?`). `show_at`
    # must reserve room for that frame, else the box collapses to a single row
    # (the old "black box with a lone underline" bug).
    tip.css_styled?.should be_false
    tip.width.should eq 9  # "Hello" (5) + 2 padding + border (iwidth 2)
    tip.height.should eq 3 # 1 text line + border (iheight 2)
  end
end

describe Crysterm::Widget::MenuBar do
  it "shows plain titles, opens/switches menus, and tracks the highlight" do
    s = qt_mem_screen
    win = Crysterm::Widget::MainWindow.new parent: s, top: 0, left: 0, width: 60, height: 16
    bar = Crysterm::Widget::MenuBar.new
    win.menu_bar = bar
    fm = bar.add_menu "File"
    fm.add("New") { }
    bar.add_menu "Edit", [Crysterm::Action.new("Cut")]
    s._render

    bar.ritems.should eq ["File", "Edit"] # no "1:" prefix
    sel = -> { bar.items.map(&.state.selected?) }
    sel.call.should eq [false, false] # nothing marked at startup

    bar.open 0
    bar.open_index.should eq 0
    bar.menus[0].visible?.should be_true
    sel.call.should eq [true, false]

    bar.open 1 # switching closes the previous
    bar.open_index.should eq 1
    bar.menus[0].visible?.should be_false
    bar.menus[1].visible?.should be_true
    sel.call.should eq [false, true]

    bar.close
    bar.open_index.should be_nil
    sel.call.should eq [false, false]
  end

  it "activates an action from an open menu" do
    s = qt_mem_screen
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    fired = 0
    fm = bar.add_menu "File"
    fm.add("Quit") { fired += 1 }
    bar.open 0
    fm.selekt 0
    fm.activate_selected
    fired.should eq 1
  end

  it "switches menus via a top-level menu's Left/Right navigation" do
    s = qt_mem_screen
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    bar.add_menu "File", [Crysterm::Action.new("New")]
    bar.add_menu "Edit", [Crysterm::Action.new("Cut")]
    bar.add_menu "Help", [Crysterm::Action.new("About")]
    bar.open 0
    bar.menus[0].on_keypress keypress('\0', Tput::Key::Right) # File -> Edit
    bar.open_index.should eq 1
    bar.menus[1].on_keypress keypress('\0', Tput::Key::Left) # Edit -> File
    bar.open_index.should eq 0
  end
end

describe Crysterm::Widget::LCDNumber do
  it "renders a value as three seven-segment rows, right-aligned" do
    s = qt_mem_screen
    lcd = Crysterm::Widget::LCDNumber.new parent: s, top: 0, left: 0, width: 24, height: 3, digit_count: 3
    lcd.display 42
    lcd.text.should eq "42"
    lcd.content.split('\n').size.should eq 3
  end

  it "formats integers per mode" do
    s = qt_mem_screen
    lcd = Crysterm::Widget::LCDNumber.new parent: s, mode: Crysterm::Widget::LCDNumber::Mode::Hex
    lcd.display 255
    lcd.text.should eq "FF"
    lcd.mode = Crysterm::Widget::LCDNumber::Mode::Bin
    lcd.display 5
    lcd.text.should eq "101"
  end
end

describe Crysterm::Widget::SizeGrip do
  it "resizes its target when dragged" do
    s = qt_mem_screen
    win = Crysterm::Widget::Box.new parent: s, top: 5, left: 0, width: 20, height: 6,
      style: Style.new(border: true)
    grip = Crysterm::Widget::SizeGrip.new parent: win, bottom: 0, right: 0, width: 1, height: 1,
      min_drag_width: 3, min_drag_height: 3
    s._render
    s.dispatch_mouse(::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, grip.aleft, grip.atop, source: :test))
    s.dispatch_mouse(::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::Left, 30, 12, source: :test))
    win.width.should eq 31 # 30 - left(0) + 1
    win.height.should eq 8 # 12 - top(5) + 1
  end
end

describe Crysterm::Widget::ToolBar do
  it "shows plain labels, triggers buttons, and lights checked toggles" do
    s = qt_mem_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    fired = 0
    tb.add_button("New") { fired += 1 }
    bold = Crysterm::Action.new "Bold"
    bold.checkable = true
    item = tb.add_action bold
    tb.add_separator
    s._render

    tb.ritems[0].should eq "New" # no "1:" prefix
    tb.commands[0].callback.try &.call
    fired.should eq 1

    tb.commands[1].callback.try &.call # toggle Bold on
    bold.checked?.should be_true
    item.state.selected?.should be_true
    tb.commands[1].callback.try &.call # toggle off
    bold.checked?.should be_false
    item.state.selected?.should be_false
  end
end

describe Crysterm::Widget::SplashScreen do
  it "centers, shows a message, and finishes" do
    s = qt_mem_screen
    sp = Crysterm::Widget::SplashScreen.new parent: s, width: 30, height: 8,
      content: Crysterm::Widget::Box.new(content: "Loading")
    sp.content_widget.should_not be_nil
    sp.show_message "Init"
    s._render
    sp.aleft.should eq (s.awidth - 30) // 2
    sp.atop.should eq (s.aheight - 8) // 2

    done = false
    sp.on(Crysterm::Event::Complete) { done = true }
    sp.finish
    done.should be_true
    s.children.includes?(sp).should be_false
  end

  it "respects an explicit position" do
    s = qt_mem_screen
    sp = Crysterm::Widget::SplashScreen.new parent: s, top: 1, left: 2, width: 20, height: 6
    s._render
    sp.aleft.should eq 2
    sp.atop.should eq 1
  end
end

describe "MenuBar rendering (regression)" do
  it "appends its pop-up menus to the screen and keeps their rows visible" do
    s = qt_mem_screen
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    fm = bar.add_menu "File"
    # Rows added *after* the menu is hidden (the menu bar hides each menu on
    # creation) must still be visible once shown — they must not snapshot the
    # menu's hidden state via a shared/dup'd style.
    fm.add("New") { }
    fm.add("Open") { }

    s.children.includes?(fm).should be_true # in the render tree, not just screened
    bar.open 0
    fm.visible?.should be_true
    fm.items.size.should eq 2
    fm.items.all?(&.visible?).should be_true
  end
end

describe "Input grab (modal pop-ups)" do
  it "stops hover reaching other widgets while a menu is open, but keeps the bar live" do
    s = qt_mem_screen
    win = Crysterm::Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    menubar = Crysterm::Widget::MenuBar.new
    win.menu_bar = menubar
    fm = menubar.add_menu "File"
    fm.add("New") { }
    menubar.add_menu "Edit", [Crysterm::Action.new("Cut")]
    box = Crysterm::Widget::Box.new content: "x"
    win.central_widget = box
    over = 0
    box.on(Crysterm::Event::MouseOver) { over += 1 }
    s._render

    move = ->(x : Int32, y : Int32) do
      s.dispatch_mouse(::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y, source: :test))
    end
    bar_x = ->(i : Int32) { menubar.items[i].aleft + 1 }

    # Far from the (top-left) menu, well inside the central box.
    move.call 60, 12
    over.should eq 1 # hover reaches the box normally

    menubar.open 0
    s.grabbing?.should be_true
    move.call bar_x.call(0), 0 # park hover on the bar
    move.call 60, 12           # hover the box again, now while the menu is open
    over.should eq 1           # …no new MouseOver: suppressed by the grab

    move.call bar_x.call(1), 0 # the bar stays live: hovering Edit switches menus
    menubar.open_index.should eq 1

    menubar.close
    s.grabbing?.should be_false
    move.call bar_x.call(0), 0
    move.call 60, 12
    over.should eq 2 # hover reaches the box again once the grab is released
  end
end

# A 10-col viewport over a 20-col non-wrapped line, AsNeeded horizontal bar.
private def hbox(s)
  Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 10, height: 4,
    wrap_content: false,
    horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
    content: "ABCDEFGHIJKLMNOPQRST" # 20 cols, viewport 10
end

describe "Horizontal scroll API (workstream D)" do
  it "reports content width and clamps scroll_x into range" do
    s = qt_mem_screen
    box = hbox(s)
    s._render
    box.get_scroll_width.should eq 20
    box.get_scroll_x.should eq 0

    box.scroll_x 100 # clamps to width(20) - viewport(10) = 10
    box.child_base_x.should eq 10
    box.get_scroll_x.should eq 10

    box.scroll_x -100 # clamps to 0
    box.child_base_x.should eq 0
  end

  it "scroll_x_to seeks to an absolute column" do
    s = qt_mem_screen
    box = hbox(s)
    s._render
    box.scroll_x_to 6
    box.child_base_x.should eq 6
    box.scroll_x_to 0
    box.child_base_x.should eq 0
  end

  it "emits Scroll with a horizontal orientation and column delta" do
    s = qt_mem_screen
    box = hbox(s)
    s._render
    events = [] of {Int32, Tput::Orientation}
    box.on(Crysterm::Event::Scroll) { |e| events << {e.delta, e.orientation} }
    box.scroll_x 4
    box.scroll_x -1
    events.should eq [
      {4, Tput::Orientation::Horizontal},
      {-1, Tput::Orientation::Horizontal},
    ]
  end

  it "shows the horizontal bar only on horizontal overflow (AsNeeded)" do
    s = qt_mem_screen
    box = hbox(s)
    s._render
    box.show_horizontal_scrollbar?.should be_true
    box.horizontal_scrollbar_widget.not_nil!.visible?.should be_true

    # Content that fits: no overflow, bar hidden.
    fit = Crysterm::Widget::ScrollableBox.new parent: s, top: 6, left: 0, width: 30, height: 4,
      wrap_content: false,
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded,
      content: "short"
    s._render
    fit.show_horizontal_scrollbar?.should be_false
  end

  it "scrolls horizontally with Left/Right keys" do
    s = qt_mem_screen
    box = hbox(s)
    s._render
    box.on_keypress keypress(' ', Tput::Key::Right)
    box.child_base_x.should eq 1
    box.on_keypress keypress(' ', Tput::Key::Right)
    box.child_base_x.should eq 2
    box.on_keypress keypress(' ', Tput::Key::Left)
    box.child_base_x.should eq 1
  end

  it "scroll_contents_by moves both axes" do
    s = qt_mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0, width: 10, height: 4,
      wrap_content: false,
      content: "ABCDEFGHIJKLMNOPQRST\nline2\nline3\nline4\nline5\nline6\nline7\nline8"
    s._render
    box.scroll_contents_by 5, 2
    box.child_base_x.should eq 5 # horizontal axis moved
    box.get_scroll.should eq 2   # vertical axis moved (combined position)
  end
end
