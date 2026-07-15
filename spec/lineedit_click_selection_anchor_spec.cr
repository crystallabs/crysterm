require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def down(s, x, y)
  s.dispatch_mouse(Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y, source: :test))
end

private def up(s, x, y)
  s.dispatch_mouse(Tput::Mouse::Event.new(Tput::Mouse::Action::Up, Tput::Mouse::Button::Left, x, y, source: :test))
end

private def click(s, x, y)
  down s, x, y
  up s, x, y
end

private def backspace(w)
  w.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('', Tput::Key::Backspace)
end

# Regression: a plain single click positioned the caret but also seeded a
# "phantom" selection anchor at the caret. It reported as no-selection while the
# caret stayed put, but the first cursor-moving edit left it stale, forming a
# bogus range whose end exceeded the now-shorter value — crashing the input
# fiber on the *next* edit with an IndexError. See mixin/text_editing.cr.
describe "LineEdit selection anchor after a plain click" do
  it "does not leave a phantom selection that crashes a later Backspace (via Completer)" do
    s = mem_screen
    langbox = Crysterm::Widget::LineEdit.new parent: s, top: 5, left: 10, width: 18, height: 1
    other = Crysterm::Widget::Button.new parent: s, top: 10, left: 10, width: 8, height: 1, content: "High"
    completer = Crysterm::Completer.new %w[Crystal Ruby Rust Python Perl PHP Go Groovy Java JavaScript Kotlin Lua]
    completer.attach langbox
    s._render

    lx = langbox.aleft
    ly = langbox.atop

    # Click into the box: focuses it and opens the popup (empty box -> whole model).
    click s, lx, ly
    completer.open?.should be_true

    # Click the first row ("Crystal") in the popup to commit it.
    s._render
    pop = completer.@popup.not_nil!
    click s, pop.aleft + 2, pop.atop + 1
    langbox.value.should eq "Crystal"

    # Click a different widget (blurs the box), then click back into the box near
    # the end of the text so a Backspace still leaves a matching prefix.
    click s, other.aleft, other.atop
    click s, lx + 7, ly
    langbox.focused?.should be_true
    langbox.selection_anchor.should be_nil

    # Two Backspaces: previously crashed with IndexError on the second.
    backspace langbox
    s._render
    backspace langbox
    s._render

    langbox.value.should eq "Cryst"
    langbox.selection?.should be_false
  end

  it "does not select the just-typed character after a plain click" do
    s = mem_screen
    box = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "hello"
    s._render
    box.read_input

    # Plain click to reposition the caret at the end, then type: no phantom
    # selection should exist (the typed char must not come back reverse-videoed,
    # nor should the anchor linger to corrupt a later edit).
    click s, box.aleft + 5, box.atop
    box.selection_anchor.should be_nil
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('x')
    box.selection?.should be_false
    box.value.should eq "hellox"
  end
end
