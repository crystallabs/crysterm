require "./spec_helper"

include Crysterm

# Regression spec for the BUGS4 menu fix: clicking a separator row must not
# activate an adjacent action. A click lands on the *raw* row index and (for a
# menu, which activates on click) called `enter_selected(i)`; `select_index` then
# `#skip_separators` off the divider onto a neighbor, whose `ActionItem` fired
# `activate_index`. `Menu#enter_selected(i)` now ignores separator rows.

private def menu_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS4 Menu separator click (does not activate a neighbor)" do
  it "ignores a click on the separator row" do
    s = menu_screen
    m = Crysterm::Widget::Menu.new(parent: s)
    fired = [] of String
    m.add("A") { fired << "A" }
    m.add_separator
    m.add("B") { fired << "B" }
    s.render

    # Rows: [A, ───, B]. `enter_selected(1)` is exactly what the separator row's
    # Click handler invokes.
    m.enter_selected 1
    fired.should be_empty
  end

  it "still activates a clicked action row (no regression)" do
    s = menu_screen
    m = Crysterm::Widget::Menu.new(parent: s)
    fired = [] of String
    m.add("A") { fired << "A" }
    m.add_separator
    m.add("B") { fired << "B" }
    s.render

    m.enter_selected 0
    fired.should eq ["A"]

    m.enter_selected 2
    fired.should eq ["A", "B"]
  end
end
