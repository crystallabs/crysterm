require "./spec_helper"

include Crysterm

# A combo box with a repeated option label must keep #selected pointing at the
# row actually chosen, not snap back to an identical earlier entry.
#
# The defect: `#set_value` re-derived `@selected` from `@options.index(value)`,
# which returns the first matching index, so cycling/committing onto a later
# duplicate resolved back to the first twin — later duplicates were unreachable.

private def cbdup_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "ComboBox with duplicate option labels" do
  it "cycles onto a later duplicate rather than bouncing off its earlier twin" do
    s = cbdup_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["A", "B", "A"]

    cb.selected.should eq 0
    cb.value.should eq "A"

    cb.cycle 1
    cb.selected.should eq 1 # B
    cb.value.should eq "B"

    # Must reach the third entry (index 2), another "A" — not collapse to index 0.
    cb.cycle 1
    cb.selected.should eq 2
    cb.value.should eq "A"

    # And one more wraps cleanly back to the first entry.
    cb.cycle 1
    cb.selected.should eq 0
    cb.value.should eq "A"
  end

  it "commits the duplicate row actually picked from the drop-down" do
    s = cbdup_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["A", "B", "A"]

    # Picking the third row (second "A") must land the selection on index 2.
    cb.commit 2
    cb.selected.should eq 2
    cb.value.should eq "A"
  end
end
