require "./spec_helper"

# `Escape` in a reading multi-line text widget: not consumed, the widget keeps
# the focus (Qt's `QTextEdit` ignores the key), where ending the read session
# would have rewound the focus to whatever was focused before — or to nothing.
# The single-line `LineEdit` keeps `Escape` as its cancel.

private def esc_window
  Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new, width: 60, height: 20
end

private def esc_press(window)
  e = Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)
  window.emit Crysterm::Event::KeyPress, e
  e
end

describe "Escape in a reading text widget" do
  it "leaves a reading TextBrowser focused and passes the key on" do
    win = esc_window
    begin
      browser = Crysterm::Widget::TextBrowser.new parent: win, width: 40, height: 10, input_on_focus: true
      browser.set_markdown "# Title\n\ntext\n"
      browser.focus
      win.repaint
      win.focused.should eq browser
      browser.escape_cancels?.should be_false
      cancelled = false
      browser.on(Crysterm::Event::Cancelled) { cancelled = true }
      e = esc_press win
      e.accepted?.should be_false
      win.focused.should eq browser
      cancelled.should be_false
      browser.focused?.should be_true
    ensure
      win.destroy
    end
  end

  it "does the same for a PlainTextEdit, even with another widget focused before it" do
    win = esc_window
    begin
      other = Crysterm::Widget::TextBrowser.new parent: win, top: 12, width: 40, height: 5, input_on_focus: true
      edit = Crysterm::Widget::PlainTextEdit.new parent: win, width: 40, height: 10, input_on_focus: true, content: "hello"
      other.focus
      edit.focus
      win.repaint
      esc_press(win).accepted?.should be_false
      win.focused.should eq edit
      # The editor still edits after the key: the read session went on.
      win.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('!')
      edit.value.should eq "hello!"
    ensure
      win.destroy
    end
  end

  it "keeps Escape as the LineEdit's cancel" do
    win = esc_window
    begin
      field = Crysterm::Widget::LineEdit.new parent: win, width: 20, height: 1, content: "x"
      field.escape_cancels?.should be_true
      field.focus
      win.repaint
      cancelled = false
      field.on(Crysterm::Event::Cancelled) { cancelled = true }
      esc_press(win).accepted?.should be_true
      cancelled.should be_true
    ensure
      win.destroy
    end
  end

  it "can be given back to a multi-line widget" do
    win = esc_window
    begin
      edit = Crysterm::Widget::TextEdit.new parent: win, width: 40, height: 10, input_on_focus: true, content: "hello"
      edit.escape_cancels = true
      edit.focus
      win.repaint
      cancelled = false
      edit.on(Crysterm::Event::Cancelled) { cancelled = true }
      esc_press(win).accepted?.should be_true
      cancelled.should be_true
    ensure
      win.destroy
    end
  end
end
