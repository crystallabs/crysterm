require "./spec_helper"

include Crysterm

# Regression specs for BUGS-F1 findings owned by the menu / action-bar / children
# files: 7 (calendar nav menu invisible), 9 (action-bar shared style),
# 51 (action-bar tag-markup width), 14 (same-parent reorder index), and
# 31 (Window#remove of a non-direct-child).

private def f1_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Whole rendered screen as one string (all rows joined), for text-presence checks.
private def f1_screen_text(s) : String
  String.build do |io|
    (0...s.lines.size).each do |y|
      row = s.lines[y]
      (0...row.size).each { |x| io << row[x].char }
      io << '\n'
    end
  end
end

describe "BUGS-F1 #7 Calendar month dropdown renders (not invisible)" do
  it "attaches the nav menu to the window and paints its rows" do
    s = f1_screen
    # Shown month is June, so the nav bar shows 'June' — 'January' can only
    # appear on screen if the (all-months) dropdown actually rendered.
    cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0,
      width: 30, height: 14, date: Time.local(2024, 6, 15)
    s._render

    # 'January' must NOT be on screen before the dropdown opens.
    f1_screen_text(s).includes?("January").should be_false

    # Click the month field in the nav bar (content col 2.., row 0).
    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + 4, ay)

    menu = cal.month_menu
    menu.should_not be_nil
    menu = menu.not_nil!

    # The menu was created with `window:` only; #popup must have attached it into
    # the window's children so it can be laid out and painted.
    s.children.includes?(menu).should be_true

    s._render
    # Rendering assertion: a month name from the dropdown (not the nav bar) is
    # now visible in the cell buffer.
    f1_screen_text(s).includes?("January").should be_true
  end
end

describe "BUGS-F1 #9 ActionBar items don't share one mutable Style" do
  it "keeps scrolled-off items hidden when the bar overflows" do
    s = f1_screen
    bar = Crysterm::Widget::ListBar.new parent: s, top: 0, left: 0, width: 20
    bar.items = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    s._render

    # Scroll the selection to the far right so the left edge scrolls off.
    bar.select_index bar.items.size - 1
    s._render

    bar.left_base.should be > 0

    # The scrolled-off item (index 0 < left_base) must actually be hidden. With
    # a shared Style the render loop's later `show`s flipped the one shared
    # `visible` flag back to true, leaving it painted over the visible items.
    bar.items[0].visible?.should be_false
    # A visible (>= left_base) item is shown.
    bar.items[bar.left_base].visible?.should be_true
  end
end

describe "BUGS-F1 #51 ActionBar command width ignores tag markup" do
  it "sizes a tagged command to its rendered width, not its markup length" do
    s = f1_screen
    bar = Crysterm::Widget::ListBar.new parent: s, top: 0, left: 0, width: 40
    bar.auto_prefix = false
    plain = bar.add_item "File"
    tagged = bar.add_item "{bold}File{/bold}"

    # Both render 'File' (4 cols) + 2 for the box padding => equal width.
    plain.width.should eq tagged.width
    tagged.width.should eq 6
  end
end

describe "BUGS-F1 #14 same-parent insert_before/insert_after index" do
  it "insert_before places the widget just before the target" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s
    a = Crysterm::Widget::Box.new parent: box
    b = Crysterm::Widget::Box.new parent: box
    c = Crysterm::Widget::Box.new parent: box
    box.children.should eq [a, b, c]

    # Move a to just before c -> [b, a, c] (not [b, c, a]).
    box.insert_before a, c
    box.children.should eq [b, a, c]
  end

  it "insert_after places the widget just after the target" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s
    a = Crysterm::Widget::Box.new parent: box
    b = Crysterm::Widget::Box.new parent: box
    c = Crysterm::Widget::Box.new parent: box
    box.children.should eq [a, b, c]

    # Move a to just after b -> [b, a, c] (not [b, c, a]).
    box.insert_after a, b
    box.children.should eq [b, a, c]
  end
end

describe "BUGS-F1 #31 Window#remove of a non-direct-child is a no-op" do
  it "leaves a nested widget attached and keeps its focus" do
    s = f1_screen
    box = Crysterm::Widget::Box.new parent: s
    inner = Crysterm::Widget::Box.new parent: box, keys: true
    s._render

    inner.focus
    s.focused.should eq inner

    # `inner` is a nested descendant, not a direct child of the window: removing
    # it here must be a no-op (not strip registries / detach / rewind focus).
    s.remove inner

    box.children.includes?(inner).should be_true
    inner.parent.should eq box
    inner.window?.should eq s
    # Focus was not yanked off the still-attached widget.
    s.focused.should eq inner
  end
end
