require "./spec_helper"

include Crysterm

# Qt-style `&` mnemonics on menu ENTRIES (`add_action "&New"`): the marked
# letter renders underlined in the row (only that row's box parses tags), and
# pressing the bare letter in an open menu activates the row — a submenu opens
# with its first child selected, a checkable toggles in place (matching the
# Space semantics), a leaf fires and dismisses the chain. Plain label sites
# (`Action#display_label`, e.g. tool-bar buttons) show the clean text instead.

private def item_bar
  s = headless_screen(80, 24)
  bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  new_fired = [false]
  new_action = Crysterm::Action.new "&New"
  new_action.on(Crysterm::Event::Triggered) { new_fired[0] = true }
  wrap = Crysterm::Action.new "&Word Wrap", checkable: true
  sub = Crysterm::Action.new "&Recent"
  sub.menu = [Crysterm::Action.new("old-1"), Crysterm::Action.new("old-2")]
  off = Crysterm::Action.new "&Disabled"
  off.enabled = false
  menu = bar.add_menu "&File", [new_action, wrap, sub, off]
  central = Crysterm::Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
  s.repaint
  central.focus
  {s, bar, menu, central, new_fired, wrap}
end

describe "Menu entry & mnemonics" do
  it "exposes the mnemonic on Action and strips it from display_label" do
    a = Crysterm::Action.new "&New"
    a.mnemonic.should eq 'n'
    a.display_label.should eq "New"
    a.icon = "+"
    a.display_label.should eq "+ New"
    Crysterm::Action.new("Save && Quit").display_label.should eq "Save & Quit"
    Crysterm::Action.new("Plain").mnemonic.nil?.should be_true
  end

  it "underlines the marked letter in its row only, via per-row tag parsing" do
    s, bar, menu, _central, _f, _wrap = item_bar
    bar.open 0
    s.repaint

    menu.@item_boxes[0].content.should contain "{underline}N{/underline}"
    menu.@item_boxes[0].parse_tags?.should be_true
  end

  it "does not widen the menu for the invisible markup" do
    s1 = headless_screen(80, 24)
    m1 = Crysterm::Widget::Menu.new parent: s1
    m1 << Crysterm::Action.new "&Wrapping"
    s2 = headless_screen(80, 24)
    m2 = Crysterm::Widget::Menu.new parent: s2
    m2 << Crysterm::Action.new "Wrapping"
    m1.fit_to_content
    m2.fit_to_content
    m1.width.should eq m2.width
  end

  it "keeps markup intact on the exact-fit widest row (no mid-tag truncation)" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    menu = bar.add_menu "&Help", [Crysterm::Action.new("&About")]
    s.repaint
    bar.open 0
    s.repaint # size_rows runs at render; the widest row's pad is exactly 0
    menu.@item_boxes[0].content.should eq "{underline}A{/underline}bout"
  end

  it "fires a leaf on its bare letter and dismisses the chain, deactivating the bar" do
    s, bar, _menu, central, new_fired, _wrap = item_bar
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::F10)
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::Down) # open "File"
    bar.open_index.should eq 0

    s.emit Crysterm::Event::KeyPress, kp('n')
    new_fired[0].should be_true
    bar.open_index.nil?.should be_true
    s.focused.same?(central).should be_true
  end

  it "toggles a checkable row in place on its letter, keeping the menu open" do
    _s, bar, menu, _central, _f, wrap = item_bar
    bar.open 0

    menu.on_keypress kp('w')
    wrap.checked?.should be_true
    bar.open_index.should eq 0

    menu.on_keypress kp('w')
    wrap.checked?.should be_false
  end

  it "opens a submenu row on its letter with the first child selected" do
    _s, bar, menu, _central, _f, _wrap = item_bar
    bar.open 0

    menu.on_keypress kp('r')
    child = menu.@submenu_open
    child.nil?.should be_false
    child.try(&.@show_highlight).should be_true
    child.try(&.current_index).should eq 0
  end

  it "ignores letters of disabled entries and unmarked letters" do
    _s, bar, menu, _central, _f, _wrap = item_bar
    bar.open 0

    menu.on_keypress kp('d') # "&Disabled" is disabled
    bar.open_index.should eq 0
    menu.on_keypress kp('z') # no such mnemonic
    bar.open_index.should eq 0
  end
end
