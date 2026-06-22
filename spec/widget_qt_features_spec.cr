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
    error: IO::Memory.new)
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
