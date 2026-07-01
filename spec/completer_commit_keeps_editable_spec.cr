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

private def build
  s = mem_screen
  other = Crysterm::Widget::Button.new parent: s, top: 0, left: 0, width: 8, height: 1, content: "Other"
  langbox = Crysterm::Widget::LineEdit.new parent: s, top: 5, left: 10, width: 18, height: 1
  completer = Crysterm::Completer.new %w[Crystal Ruby Rust Python Perl]
  completer.attach langbox
  s._render
  # Start focus elsewhere so clicking the box fires a real Focus event that
  # drives read_input (matches the running app; the auto-focus at first render
  # does not go through that path).
  other.focus
  s._render
  {s, langbox, completer}
end

# Regression: committing a completion by clicking a drop-down row used to blur
# the text box (the row's Click handler in `Mixin::ItemView` called `focus` on
# the list unconditionally, ignoring the drop-down's `focus_on_click = false`).
# That tore down the box's read mode, leaving it focused-but-uneditable: the
# caret vanished and a later single click only re-toggled the drop-down instead
# of restoring editing.
describe "Completer keeps the box editable after committing" do
  it "keeps read mode after committing via a row click" do
    s, langbox, completer = build
    lx = langbox.aleft
    ly = langbox.atop

    click s, lx, ly # focus
    s._render
    click s, lx, ly # open dropdown
    s._render
    completer.open?.should be_true

    pop = completer.@popup.not_nil!
    click s, pop.aleft + 2, pop.atop + 1 # commit "Crystal"
    s._render

    langbox.value.should eq "Crystal"
    completer.open?.should be_false
    langbox.focused?.should be_true
    langbox.@_reading.should be_true # still editable, caret still shown
  end

  it "keeps read mode after committing via Enter" do
    s, langbox, completer = build
    lx = langbox.aleft
    ly = langbox.atop

    click s, lx, ly
    s._render
    click s, lx, ly
    s._render
    completer.open?.should be_true

    langbox.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter)
    s._render

    langbox.value.should eq "Crystal"
    completer.open?.should be_false
    langbox.focused?.should be_true
    langbox.@_reading.should be_true
  end
end
