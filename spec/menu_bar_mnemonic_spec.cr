require "./spec_helper"

include Crysterm

# Qt-style `&` mnemonics on `MenuBar` titles (`add_menu "&File"`): the marked
# letter renders underlined, `Alt+<letter>` opens the menu from anywhere
# (recording the F10-style return slot, so Escape/activation come back to the
# central widget), and — with the bar active and no menu open — the bare
# letter opens it too. `&&` stays a literal ampersand.

private def mnemonic_screen
  s = headless_screen(80, 24)
  bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  bar.add_menu "&File", [Crysterm::Action.new("New")]
  bar.add_menu "&Edit", [Crysterm::Action.new("Cut")]
  central = Crysterm::Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
  s.repaint
  central.focus
  {s, bar, central}
end

describe "MenuBar & mnemonics" do
  it "parses Qt's & rules: first &X marks, && is literal, lone trailing & survives" do
    Crysterm::Mnemonic.parse("&File").should eq({"File", 'f', 0})
    Crysterm::Mnemonic.parse("E&xit").should eq({"Exit", 'x', 1})
    Crysterm::Mnemonic.parse("Save && Quit").should eq({"Save & Quit", nil, nil})
    Crysterm::Mnemonic.parse("A && &B").should eq({"A & B", 'b', 4})
    Crysterm::Mnemonic.parse("Plain").should eq({"Plain", nil, nil})
    Crysterm::Mnemonic.parse("Odd&").should eq({"Odd&", nil, nil})
    Crysterm::Mnemonic.tagged("&File").should eq({"{underline}F{/underline}ile", 'f'})
    Crysterm::Mnemonic.tagged("Plain").should eq({"Plain", nil})
  end

  it "records mnemonics per menu and underlines the letter in the title" do
    _s, bar, _central = mnemonic_screen
    bar.mnemonics.should eq ['f', 'e']
    bar.@commands[0].text.should contain "{underline}F{/underline}"
  end

  it "opens the menu from anywhere on Alt+letter, first entry selected, and returns focus on Escape" do
    s, bar, central = mnemonic_screen

    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::AltE)
    bar.open_index.should eq 1
    bar.menus[1].@show_highlight.should be_true
    bar.menus[1].current_index.should eq 0

    # The return slot was recorded on the way in: Escape (menu, then bar)
    # lands back on the central widget.
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::Escape)
    bar.open_index.nil?.should be_true
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::Escape)
    s.focused.same?(central).should be_true
  end

  it "switches menus on Alt+letter while another is open, without clobbering the return slot" do
    s, bar, central = mnemonic_screen

    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::AltF)
    bar.open_index.should eq 0
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::AltE)
    bar.open_index.should eq 1

    # Fire "Cut": the whole bar deactivates back to the central widget.
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::Enter)
    bar.open_index.nil?.should be_true
    s.focused.same?(central).should be_true
  end

  it "opens a menu on the bare letter while the bar is active with no menu open" do
    s, bar, _central = mnemonic_screen

    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::F10) # activate the bar
    s.focused.same?(bar).should be_true
    s.emit Crysterm::Event::KeyPress, kp('e')
    bar.open_index.should eq 1
    bar.menus[1].current_index.should eq 0
  end

  it "leaves unrelated letters alone (they do not activate anything from the central area)" do
    s, bar, central = mnemonic_screen
    s.emit Crysterm::Event::KeyPress, kp('f') # bare letter, bar NOT active
    bar.open_index.nil?.should be_true
    s.focused.same?(central).should be_true
  end
end
