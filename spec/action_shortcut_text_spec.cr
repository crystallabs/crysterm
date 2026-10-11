require "./spec_helper"

include Crysterm

# `Action#shortcut_text` and the helpers behind it print a shortcut the way
# Qt's `QKeySequence::toString` does, and `Action.parse_key_stroke` reads
# every label they print back to the same `Tput::Key` member.

describe "Action.key_stroke_text" do
  it "joins the modifier to the key's name with a plus, as Qt spells shortcuts" do
    Action.key_stroke_text(Tput::Key::CtrlS).should eq "Ctrl+S"
    Action.key_stroke_text(Tput::Key::AltG).should eq "Alt+G"
    Action.key_stroke_text(Tput::Key::ShiftTab).should eq "Shift+Tab"
    Action.key_stroke_text(Tput::Key::AltEnter).should eq "Alt+Enter"
    Action.key_stroke_text(Tput::Key::CtrlPageDown).should eq "Ctrl+PgDown"
    Action.key_stroke_text(Tput::Key::AltUp).should eq "Alt+Up"
  end

  it "names an unmodified key as Qt does, abbreviating what Qt abbreviates" do
    Action.key_stroke_text(Tput::Key::F10).should eq "F10"
    Action.key_stroke_text(Tput::Key::Escape).should eq "Esc"
    Action.key_stroke_text(Tput::Key::Insert).should eq "Ins"
    Action.key_stroke_text(Tput::Key::Delete).should eq "Del"
    Action.key_stroke_text(Tput::Key::PageUp).should eq "PgUp"
    Action.key_stroke_text(Tput::Key::PageDown).should eq "PgDown"
    Action.key_stroke_text(Tput::Key::Home).should eq "Home"
    Action.key_stroke_text(Tput::Key::Space).should eq "Space"
    Action.key_stroke_text(Tput::Key::Backspace).should eq "Backspace"
    Action.key_stroke_text(Tput::Key::Enter).should eq "Enter"
    Action.key_stroke_text(Tput::Key::Tab).should eq "Tab"
    Action.key_stroke_text(Tput::Key::Clear).should eq "Clear" # no modifier, though it starts with a C
    Action.key_stroke_text(Tput::Key::Menu).should eq "Menu"
  end

  it "prints the member that shares a code under its plain name" do
    # `CtrlI` is `Tab` and `CtrlM` is `Enter`; the enum names them by their
    # first member, and so does the label.
    Action.key_stroke_text(Tput::Key::CtrlI).should eq "Tab"
    Action.key_stroke_text(Tput::Key::CtrlM).should eq "Enter"
  end

  it "round-trips with Action.parse_key_stroke for every key" do
    Tput::Key.each do |key|
      Action.parse_key_stroke(Action.key_stroke_text(key)).should eq key
    end
  end
end

describe "Action.key_sequence_text" do
  it "separates a chord's strokes with a comma, like the parser expects them" do
    seq = [Tput::Key::CtrlK, Tput::Key::CtrlB]
    Action.key_sequence_text(seq).should eq "Ctrl+K, Ctrl+B"
    Action.parse_key_sequence(Action.key_sequence_text(seq)).should eq seq
    Action.key_sequence_text([Tput::Key::F5]).should eq "F5"
  end
end

describe "Action#shortcut_text" do
  it "shows the primary shortcut in Qt's form, and nothing without one" do
    a = Action.new "Save", shortcut: Tput::Key::CtrlS
    a.shortcut_text.should eq "Ctrl+S"
    a.shortcut = "Ctrl+K, Ctrl+B"
    a.shortcut_text.should eq "Ctrl+K, Ctrl+B"
    a.shortcuts = [[Tput::Key::AltG], [Tput::Key::F3]]
    a.shortcut_text.should eq "Alt+G"
    Action.new("Plain").shortcut_text.should eq ""
  end

  it "is what a menu prints in its shortcut column" do
    s = headless_screen(40, 10)
    menu = Widget::Menu.new parent: s, top: 0, left: 0
    menu << Action.new("Open…", shortcut: Tput::Key::CtrlO)
    menu.popup 0, 0
    s.repaint
    s.dump.to_s.should contain "Ctrl+O"
    s.dump.to_s.should_not contain "CtrlO"
    s.destroy
  end
end
