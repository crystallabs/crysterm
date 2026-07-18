require "./spec_helper"

include Crysterm

# Group N (ALLOCS.md) — the simple per-frame content rebuilds were converted to
# state-change-driven caches (CheckBox/RadioButton marker line, Loading compact
# line, BigText grapheme array + shrink width, Splitter even positions, StatusBar
# truncation). These specs assert the *observable* rendered value is unchanged by
# the caching: it is correct after the first render, identical after a redundant
# second render, and updated after the relevant state change.

private def n_screen(w = 40, h = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "Group N per-frame content caching" do
  describe Crysterm::Widget::CheckBox do
    it "renders the marker line, is stable across a redundant render, and updates on state change" do
      s = n_screen
      cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept"

      cb.render
      cb.content.should eq "[ ] Accept"
      # A second render with no state change must yield the identical string.
      cb.render
      cb.content.should eq "[ ] Accept"

      cb.check
      cb.render
      cb.content.should eq "[x] Accept"

      cb.uncheck
      cb.render
      cb.content.should eq "[ ] Accept"

      cb.text = "Other"
      cb.render
      cb.content.should eq "[ ] Other"
    end

    it "reflects the partially-checked marker" do
      s = n_screen
      cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, tristate: true, content: "All"
      cb.render
      cb.content.should eq "[ ] All"
      cb.partial
      cb.render
      cb.content.should eq "[-] All"
    end
  end

  describe Crysterm::Widget::RadioButton do
    it "renders the marker line, stable across redundant render, updates on check" do
      s = n_screen
      rb = Crysterm::Widget::RadioButton.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "One"
      rb.render
      rb.content.should eq "( ) One"
      rb.render
      rb.content.should eq "( ) One"
      rb.check
      rb.render
      rb.content.should eq "(*) One"
    end
  end

  describe Crysterm::Widget::Loading do
    it "caches the compact line and refreshes it on a spinner step" do
      s = n_screen
      l = Crysterm::Widget::Loading.new parent: s, compact: true,
        frames: ["a", "b", "c"], content: "Working"
      l.render
      l.content.should eq "a Working"
      # Redundant render: identical.
      l.render
      l.content.should eq "a Working"
      # Advancing the spinner rebuilds the cached compact line.
      l.step
      l.render
      l.content.should eq "b Working"
    end
  end

  describe Crysterm::Widget::BigText do
    it "caches grapheme clusters + shrink width, stable across renders, updated on set_content" do
      s = n_screen
      bt = Crysterm::Widget::BigText.new parent: s, top: 0, left: 0, content: "Hi"
      bt.render
      bt.@graphemes.should eq ["H", "i"]
      w1 = bt.@_shrink_width_value
      w1.should_not be_nil
      w1.not_nil!.should be > 0

      # Redundant render: the cached width value is reused unchanged.
      bt.render
      bt.@_shrink_width_value.should eq w1

      bt.set_content "ABC"
      bt.render
      bt.@graphemes.should eq ["A", "B", "C"]
      bt.@_shrink_width_value.should_not eq w1 # three glyphs wider than two
    end
  end

  describe Crysterm::Widget::Splitter do
    it "fills even positions in place, stable across redundant renders" do
      s = n_screen 60, 20
      sp = Crysterm::Widget::Splitter.new parent: s, width: 60, height: 20
      sp.add_pane Crysterm::Widget::Box.new content: "a"
      sp.add_pane Crysterm::Widget::Box.new content: "b"
      sp.add_pane Crysterm::Widget::Box.new content: "c"

      s._render
      pos1 = sp.@positions.dup
      pos1.size.should eq 2    # n-1 dividers
      pos1.should eq pos1.sort # ascending
      (pos1[0] < pos1[1]).should be_true

      # Redundant render must not change the evenly-distributed positions.
      s._render
      sp.@positions.should eq pos1

      # Pinning a divider still works (user-positioned clamp path).
      sp.set_divider_position 0, 10
      s._render
      sp.divider_position(0).should eq 10
    end
  end

  describe Crysterm::Widget::StatusBar do
    it "caches the left-truncated permanent tail, stable across renders, updated on change" do
      s = n_screen 10, 3
      bar = Crysterm::Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: 10, height: 1
      bar.add_permanent "AAAA"
      bar.add_permanent "BBBB" # permanent_text "AAAA │ BBBB" (11) overflows width 10

      s._render
      t1 = bar.@_trunc
      t1.empty?.should be_false
      # Truncated tail keeps the most-recent (right) sections.
      bar.@permanent_text.ends_with?(t1).should be_true

      # Redundant render: identical cached value.
      s._render
      bar.@_trunc.should eq t1

      # Changing the permanent text rebuilds the cache.
      bar.add_permanent "CCCC"
      s._render
      bar.@permanent_text.ends_with?(bar.@_trunc).should be_true
    end
  end
end
