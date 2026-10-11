require "./spec_helper"

include Crysterm

# An open `LinePrompt` question owns the keyboard, as vi's command line does:
# the window-level accelerators — `Action` shortcuts, the menu bar's
# activation key — stand down until it is answered, and the key edits the
# answer instead.

private def key(k : Tput::Key) : Event::KeyPress
  Event::KeyPress.new '\0', k
end

# A screen with an editor holding focus, a menu bar whose one action has a
# shortcut, and a status bar to ask from.
private def stage
  s = headless_screen(40, 6)
  menu_bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
  opened = 0
  open = Action.new "&Open…", shortcut: Tput::Key::CtrlO
  open.on(Event::Triggered) { opened += 1 }
  menu_bar.add_menu "&File", [open]
  editor = Widget::PlainTextEdit.new parent: s, left: 0, top: 1, width: 40, height: 3
  bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
  editor.focus
  s.repaint
  {s, menu_bar, bar, -> { opened }}
end

describe "Widget::LinePrompt and the window's accelerators" do
  it "keeps an action's shortcut from firing into an open question" do
    s, _menu_bar, bar, opened = stage
    s.emit Event::KeyPress, key(Tput::Key::CtrlO)
    opened.call.should eq 1

    answers = [] of String?
    bar.prompt("Save as: ") { |v| answers << v }
    e = key(Tput::Key::CtrlO)
    s.emit Event::KeyPress, e
    e.accepted?.should be_true
    opened.call.should eq 1
    bar.prompting?.should be_true
    # The question goes on being answered.
    s.emit Event::KeyPress, Event::KeyPress.new('x')
    bar.line_prompt.field.value.should eq "x"
    s.emit Event::KeyPress, key(Tput::Key::Enter)
    answers.should eq ["x"]

    # Answered, the shortcut is live again.
    s.emit Event::KeyPress, key(Tput::Key::CtrlO)
    opened.call.should eq 2
    s.destroy
  end

  it "keeps the menu bar's activation key and mnemonics out too" do
    s, menu_bar, bar, _opened = stage
    bar.prompt("Open: ") { }
    s.emit Event::KeyPress, key(Tput::Key::F10)
    menu_bar.focused?.should be_false
    s.emit Event::KeyPress, key(Tput::Key::AltF)
    menu_bar.open_index.should be_nil
    bar.prompting?.should be_true
    bar.line_prompt.cancel
    s.emit Event::KeyPress, key(Tput::Key::AltF)
    menu_bar.open_index.should eq 0
    s.destroy
  end
end
