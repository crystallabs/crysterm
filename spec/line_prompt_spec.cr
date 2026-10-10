require "./spec_helper"

include Crysterm

private def key(k : Tput::Key) : Event::KeyPress
  Event::KeyPress.new '\0', k
end

private def row(s, y, width = 40)
  (s.dump(0, width, y, y + 1) || "").lines[2][1..-2].rstrip
end

# A screen with an editor to hold focus and a status bar with a section.
private def stage
  s = headless_screen(40, 5)
  editor = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 3
  bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
  bar.add_permanent "Ln 1"
  editor.focus
  s.repaint
  {s, editor, bar}
end

describe "StatusBar#prompt / Widget::LinePrompt" do
  it "asks in place of the bar, with the value filled in, and answers on Enter" do
    s, editor, bar = stage
    row(s, 4).should end_with "Ln 1"
    answers = [] of String?
    bar.prompt("Save as: ", "a.md") { |v| answers << v }
    s.repaint
    bar.prompting?.should be_true
    field = bar.line_prompt.field
    field.focused?.should be_true
    field.value.should eq "a.md"
    field.cursor_pos.should eq 4
    row(s, 4).should start_with "Save as: a.md"
    row(s, 4).should_not contain "Ln 1"
    field.emit Event::KeyPress, Event::KeyPress.new('x')
    field.emit Event::KeyPress, key(Tput::Key::Enter)
    answers.should eq ["a.mdx"]
    bar.prompting?.should be_false
    editor.focused?.should be_true
    s.repaint
    row(s, 4).should end_with "Ln 1"
  end

  it "answers nil on Escape, and on Backspace with nothing typed, like vi" do
    s, editor, bar = stage
    answers = [] of String?
    bar.prompt("Open: ") { |v| answers << v }
    s.repaint
    bar.line_prompt.field.emit Event::KeyPress, key(Tput::Key::Escape)
    answers.should eq [nil]
    editor.focused?.should be_true

    bar.prompt("Open: ", "x") { |v| answers << v }
    s.repaint
    field = bar.line_prompt.field
    field.emit Event::KeyPress, key(Tput::Key::Backspace) # deletes the x
    field.value.should eq ""
    bar.prompting?.should be_true
    field.emit Event::KeyPress, key(Tput::Key::Backspace) # nothing left: leaves
    answers.should eq [nil, nil]
    bar.prompting?.should be_false
    editor.focused?.should be_true
  end

  it "cycles completions with Tab and Shift+Tab, afresh after an edit" do
    s, _editor, bar = stage
    cl = bar.line_prompt
    cl.completer = ->(text : String) { ["alpha.md", "alps.md", "beta.md"].select(&.starts_with?(text)) }
    answers = [] of String?
    bar.prompt("Save as: ", "al") { |v| answers << v }
    s.repaint
    field = cl.field
    field.emit Event::KeyPress, key(Tput::Key::Tab)
    field.value.should eq "alpha.md"
    field.emit Event::KeyPress, key(Tput::Key::Tab)
    field.value.should eq "alps.md"
    field.emit Event::KeyPress, key(Tput::Key::Tab)
    field.value.should eq "alpha.md"
    field.emit Event::KeyPress, key(Tput::Key::ShiftTab)
    field.value.should eq "alps.md"
    field.value = "b"
    field.emit Event::KeyPress, Event::KeyPress.new('e')
    field.emit Event::KeyPress, key(Tput::Key::Tab)
    field.value.should eq "beta.md"
    field.emit Event::KeyPress, key(Tput::Key::Enter)
    answers.should eq ["beta.md"]
  end

  it "recalls earlier answers with Up, and emits Submitted/Cancelled" do
    s, _editor, bar = stage
    seen = [] of String?
    bar.line_prompt.on(Event::Submitted) { |e| seen << e.value }
    bar.line_prompt.on(Event::Cancelled) { seen << nil }
    bar.prompt("Go: ") { }
    s.repaint
    field = bar.line_prompt.field
    field.emit Event::KeyPress, Event::KeyPress.new('o')
    field.emit Event::KeyPress, key(Tput::Key::Enter)
    bar.prompt("Go: ") { }
    s.repaint
    field.emit Event::KeyPress, key(Tput::Key::Up)
    field.value.should eq "o"
    field.emit Event::KeyPress, key(Tput::Key::Escape)
    seen.should eq ["o", nil]
  end

  it "cancels an open question when a new one is asked, and on cancel" do
    _s, editor, bar = stage
    answers = [] of String?
    bar.prompt("A: ") { |v| answers << "A#{v.inspect}" }
    bar.prompt("B: ") { |v| answers << "B#{v.inspect}" }
    answers.should eq ["Anil"]
    bar.line_prompt.cancel
    answers.should eq ["Anil", "Bnil"]
    bar.prompting?.should be_false
    editor.focused?.should be_true
  end
end
