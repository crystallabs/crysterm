require "./spec_helper"

include Crysterm

# Regression specs for BUGS6 section "Buttons & Dialogs".
#
#  BUG 1 (fixed in src/widget/abstract_button.cr): `AbstractButton#press` called
#     `focus` unconditionally as its first action, ignoring a widget's
#     `focus_on_click: false` opt-out. On a mouse click of a dialog button (built
#     with `focus_on_click: false`) this stole focus off a live `LineEdit` read,
#     whose read-time Blur handler ended the read as a cancel — so clicking
#     "Okay" on a `Prompt` discarded the typed text and behaved like Cancel.
#     `#press` now focuses only when `#focus_on_click?`.
#
#  BUG 2 (doc fix in src/widget/button.cr): `getter? default` was documented as
#     "activated by a bare Enter", but nothing wires Enter to the default button;
#     it is a styling marker only. Docstring corrected (no behavioral spec).
#
#  BUG 3 (cleanup in src/widget/tool_button.cr): `#cycle_menu` had a dead
#     negative-index correction (`@menu_index += acts.size if @menu_index < 0`)
#     that could never run — Crystal's `%` with a positive divisor is never
#     negative. Removed; cycling still wraps correctly in both directions.

private def bugs6_screen
  Crysterm::Window.new(
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

private def bugs6_wheel(dir : Tput::Mouse::Action)
  Crysterm::Event::Mouse.new(Tput::Mouse::Event.new(dir, Tput::Mouse::Button::Left, 0, 0))
end

describe "BUGS6 AbstractButton#press honors focus_on_click (bug 1)" do
  it "a focus_on_click:false button does NOT steal focus when clicked" do
    s = bugs6_screen
    a = Crysterm::Widget::Button.new parent: s, top: 0, content: "A"
    b = Crysterm::Widget::Button.new parent: s, top: 1, content: "B", focus_on_click: false

    a.focus
    a.focused?.should be_true

    b.on_click nil # simulate a mouse click -> #press

    # b opted out of click-to-focus, so pressing it must leave focus on a.
    a.focused?.should be_true
    b.focused?.should be_false
  end

  it "a normal (focus_on_click:true) button still takes focus when clicked" do
    s = bugs6_screen
    a = Crysterm::Widget::Button.new parent: s, top: 0, content: "A"
    c = Crysterm::Widget::Button.new parent: s, top: 1, content: "C" # default true

    a.focus
    c.on_click nil # simulate a mouse click -> #press

    c.focused?.should be_true
    a.focused?.should be_false
  end

  it "clicking Okay on a Prompt submits the typed text instead of cancelling" do
    s = bugs6_screen
    prompt = Crysterm::Widget::Prompt.new parent: s, content: "Name?"

    got_data : String? = nil
    called = false
    prompt.read_input do |_err, data|
      called = true
      got_data = data
    end

    # Type into the live LineEdit read (feeds the read's KeyPress listener).
    "hi".each_char { |ch| prompt.textinput.emit keypress(ch) }

    ok = prompt.children.find! do |c|
      c.is_a?(Crysterm::Widget::Button) && c.content == "Okay"
    end.as(Crysterm::Widget::Button)

    ok.on_click nil # mouse-click the Okay button

    called.should be_true
    got_data.should eq "hi" # submitted value, NOT nil (cancel)
  end
end

describe "BUGS6 ToolButton#cycle_menu wrapping (bug 3)" do
  it "cycles forward past the end, wrapping to the first action" do
    s = bugs6_screen
    m = Crysterm::Widget::Menu.new
    fired = [] of String
    m.add("One") { fired << "One" }
    m.add("Two") { fired << "Two" }
    m.add("Three") { fired << "Three" }
    tb = Crysterm::Widget::ToolButton.new parent: s, content: "Tools", menu: m

    # Starting at index 0, each wheel-down advances one activatable action; the
    # third wrap lands back on the first. (index+1)%3: Two, Three, One, Two.
    4.times { tb.emit Crysterm::Event::Mouse, bugs6_wheel(Tput::Mouse::Action::WheelDown).mouse }
    fired.should eq %w[Two Three One Two]
  end

  it "cycles backward from the start, wrapping to the last action" do
    s = bugs6_screen
    m = Crysterm::Widget::Menu.new
    fired = [] of String
    m.add("One") { fired << "One" }
    m.add("Two") { fired << "Two" }
    m.add("Three") { fired << "Three" }
    tb = Crysterm::Widget::ToolButton.new parent: s, content: "Tools", menu: m

    # (0 - 1) % 3 == 2 in Crystal, so a backward step from the start wraps to the
    # last action WITHOUT the (removed) negative-index correction.
    tb.emit Crysterm::Event::Mouse, bugs6_wheel(Tput::Mouse::Action::WheelUp).mouse
    fired.should eq %w[Three]
  end
end
