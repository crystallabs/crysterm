require "./spec_helper"

private alias K = Crysterm::Neovim::Keys

private def kitty(number, final = 'u', mods = Tput::Modifiers::None, shifted = nil, text = nil, type = Tput::KeyEvent::Type::Press)
  Tput::KeyEvent.new number, final, mods, type, shifted, nil, text
end

describe Crysterm::Neovim::Keys do
  it "spells typed characters, escaping <" do
    K.notation('a', nil).should eq "a"
    K.notation('A', nil).should eq "A"
    K.notation(' ', nil).should eq " "
    K.notation('<', nil).should eq "<lt>"
    K.notation('>', nil).should eq ">"
    K.notation('\\', nil).should eq "\\"
    K.notation('č', nil).should eq "č"
    K.notation('\0', nil).should be_nil
  end

  it "names the legacy special keys" do
    K.notation('\r', Tput::Key::Enter).should eq "<CR>"
    K.notation('\e', Tput::Key::Escape).should eq "<Esc>"
    K.notation('\t', Tput::Key::Tab).should eq "<Tab>"
    K.notation('\0', Tput::Key::ShiftTab).should eq "<S-Tab>"
    K.notation('\u007f', Tput::Key::Backspace).should eq "<BS>"
    K.notation('\0', Tput::Key::Up).should eq "<Up>"
    K.notation('\0', Tput::Key::CtrlLeft).should eq "<C-Left>"
    K.notation('\0', Tput::Key::ShiftDown).should eq "<S-Down>"
    K.notation('\0', Tput::Key::AltRight).should eq "<M-Right>"
    K.notation('\0', Tput::Key::Delete).should eq "<Del>"
    K.notation('\0', Tput::Key::PageDown).should eq "<PageDown>"
    K.notation('\0', Tput::Key::CtrlEnd).should eq "<C-End>"
    K.notation('\0', Tput::Key::F1).should eq "<F1>"
    K.notation('\0', Tput::Key::F5).should eq "<F5>"
    K.notation('\0', Tput::Key::F12).should eq "<F12>"
  end

  it "spells Ctrl and Alt letters" do
    K.notation('\u0001', Tput::Key::CtrlA).should eq "<C-a>"
    K.notation('\u001a', Tput::Key::CtrlZ).should eq "<C-z>"
    K.notation('x', Tput::Key::AltX).should eq "<M-x>"
    K.notation('\u0001', nil).should eq "<C-a>"
  end

  it "gives nothing for keys that are no keystroke" do
    K.notation('\0', Tput::Key::Mouse).should be_nil
    K.notation('\0', Tput::Key::PasteStart).should be_nil
  end

  it "reads enhanced-protocol key events with every modifier" do
    K.notation(kitty('a'.ord)).should eq "a"
    K.notation(kitty('a'.ord, mods: Tput::Modifiers::Shift, shifted: 'A'.ord)).should eq "A"
    K.notation(kitty('a'.ord, mods: Tput::Modifiers::Shift)).should eq "A"
    K.notation(kitty('1'.ord, mods: Tput::Modifiers::Shift, shifted: '!'.ord)).should eq "!"
    K.notation(kitty(','.ord, mods: Tput::Modifiers::Shift, text: "<")).should eq "<lt>"
    K.notation(kitty('a'.ord, mods: Tput::Modifiers::Ctrl)).should eq "<C-a>"
    K.notation(kitty('a'.ord, mods: Tput::Modifiers::Ctrl | Tput::Modifiers::Shift)).should eq "<S-C-a>"
    K.notation(kitty('x'.ord, mods: Tput::Modifiers::Alt)).should eq "<M-x>"
    K.notation(kitty('s'.ord, mods: Tput::Modifiers::Super)).should eq "<D-s>"
    K.notation(kitty('<'.ord, mods: Tput::Modifiers::Ctrl)).should eq "<C-lt>"
    K.notation(kitty(27)).should eq "<Esc>"
    K.notation(kitty(13, mods: Tput::Modifiers::Alt)).should eq "<M-CR>"
    K.notation(kitty(9, mods: Tput::Modifiers::Shift)).should eq "<S-Tab>"
    K.notation(kitty(127)).should eq "<BS>"
    K.notation(kitty(32, mods: Tput::Modifiers::Ctrl)).should eq "<C-Space>"
    K.notation(kitty(1, 'A')).should eq "<Up>"
    K.notation(kitty(1, 'D', Tput::Modifiers::Ctrl | Tput::Modifiers::Shift)).should eq "<S-C-Left>"
    K.notation(kitty(15, '~')).should eq "<F5>"
    K.notation(kitty(3, '~', Tput::Modifiers::Ctrl)).should eq "<C-Del>"
    K.notation(kitty(1, 'P')).should eq "<F1>"
    # Lock modifiers are no modifiers.
    K.notation(kitty('a'.ord, mods: Tput::Modifiers::NumLock)).should eq "a"
  end

  it "gives nothing for releases and lone modifiers" do
    K.notation(kitty('a'.ord, type: Tput::KeyEvent::Type::Release)).should be_nil
    K.notation(kitty(57441)).should be_nil
    K.notation(kitty(57428)).should be_nil # a kitty media key code (Private Use Area)
  end

  it "translates a KeyPress event by the shape it came in" do
    K.notation(Crysterm::Event::KeyPress.new('q')).should eq "q"
    K.notation(Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter)).should eq "<CR>"
    e = Crysterm::Event::KeyPress.new('\0', nil, nil, kitty('w'.ord, mods: Tput::Modifiers::Ctrl))
    K.notation(e).should eq "<C-w>"
  end
end
