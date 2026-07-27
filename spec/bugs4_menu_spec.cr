require "./spec_helper"

include Crysterm

# Regression spec for the BUGS4 menu fix: clicking a separator row must not
# activate an adjacent action. A click lands on the *raw* row index and (for a
# menu, which activates on click) called `activate_item(index)`; `current_index=` then
# `#skip_separators` off the divider onto a neighbor, whose `ItemActivated` fired
# `activate_index`. `Menu#activate_item(index)` now ignores separator rows.

describe "BUGS4 Menu separator click (does not activate a neighbor)" do
  it "ignores a click on the separator row" do
    s = headless_screen(80, 24)
    m = Crysterm::Widget::Menu.new(parent: s)
    fired = [] of String
    m.add_action("A") { fired << "A" }
    m.add_separator
    m.add_action("B") { fired << "B" }
    s.render

    # Rows: [A, ───, B]. `activate_item(1)` is exactly what the separator row's
    # Click handler invokes.
    m.activate_item 1
    fired.should be_empty
  end

  it "still activates a clicked action row (no regression)" do
    s = headless_screen(80, 24)
    m = Crysterm::Widget::Menu.new(parent: s)
    fired = [] of String
    m.add_action("A") { fired << "A" }
    m.add_separator
    m.add_action("B") { fired << "B" }
    s.render

    m.activate_item 0
    fired.should eq ["A"]

    m.activate_item 2
    fired.should eq ["A", "B"]
  end
end
