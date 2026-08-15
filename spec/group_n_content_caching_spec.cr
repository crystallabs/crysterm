require "./spec_helper"

include Crysterm

# State-change-driven content caches (CheckBox/RadioButton marker line, Loading
# compact line, BigText grapheme array + shrink width, Splitter even positions,
# StatusBar truncation) replace simple per-frame content rebuilds.
# These specs assert the *observable* rendered value is unchanged by
# the caching: it is correct after the first render, identical after a redundant
# second render, and updated after the relevant state change.

describe "Group N per-frame content caching" do
  describe Crysterm::Widget::CheckBox do
    it "renders the marker line, is stable across a redundant render, and updates on state change" do
      s = headless_screen(40, 12)
      cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept"

      cb.paint
      cb.rendered_content.should eq "[ ] Accept"
      # A second render with no state change must yield the identical string.
      cb.paint
      cb.rendered_content.should eq "[ ] Accept"

      cb.check
      cb.paint
      cb.rendered_content.should eq "[x] Accept"

      cb.uncheck
      cb.paint
      cb.rendered_content.should eq "[ ] Accept"

      cb.text = "Other"
      cb.paint
      cb.rendered_content.should eq "[ ] Other"
    end

    it "reflects the partially-checked marker" do
      s = headless_screen(40, 12)
      cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, tristate: true, content: "All"
      cb.paint
      cb.rendered_content.should eq "[ ] All"
      cb.partial
      cb.paint
      cb.rendered_content.should eq "[-] All"
    end
  end

  describe Crysterm::Widget::RadioButton do
    it "renders the marker line, stable across redundant render, updates on check" do
      s = headless_screen(40, 12)
      rb = Crysterm::Widget::RadioButton.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "One"
      rb.paint
      rb.rendered_content.should eq "( ) One"
      rb.paint
      rb.rendered_content.should eq "( ) One"
      rb.check
      rb.paint
      rb.rendered_content.should eq "(*) One"
    end
  end

  describe Crysterm::Widget::Loading do
    it "caches the compact line and refreshes it on a spinner step" do
      s = headless_screen(40, 12)
      l = Crysterm::Widget::Loading.new parent: s, compact: true,
        frames: ["a", "b", "c"], content: "Working"
      l.paint
      l.content.should eq "a Working"
      # Redundant render: identical.
      l.paint
      l.content.should eq "a Working"
      # Advancing the spinner rebuilds the cached compact line.
      l.step
      l.paint
      l.content.should eq "b Working"
    end
  end

  describe Crysterm::Widget::BigText do
    it "caches grapheme clusters + shrink width, stable across renders, updated on set_content" do
      s = headless_screen(40, 12)
      bt = Crysterm::Widget::BigText.new parent: s, top: 0, left: 0, content: "Hi"
      bt.paint
      bt.@graphemes.should eq ["H", "i"]
      w1 = bt.@_shrink_width_value
      w1.should_not be_nil
      w1.not_nil!.should be > 0

      # Redundant render: the cached width value is reused unchanged.
      bt.paint
      bt.@_shrink_width_value.should eq w1

      bt.set_content "ABC"
      bt.paint
      bt.@graphemes.should eq ["A", "B", "C"]
      bt.@_shrink_width_value.should_not eq w1 # three glyphs wider than two
    end
  end

  describe Crysterm::Widget::Splitter do
    it "fills even positions in place, stable across redundant renders" do
      s = headless_screen(60, 20)
      sp = Crysterm::Widget::Splitter.new parent: s, width: 60, height: 20
      sp.add_widget Crysterm::Widget::Box.new content: "a"
      sp.add_widget Crysterm::Widget::Box.new content: "b"
      sp.add_widget Crysterm::Widget::Box.new content: "c"

      s.repaint
      pos1 = sp.@positions.dup
      pos1.size.should eq 2    # n-1 dividers
      pos1.should eq pos1.sort # ascending
      (pos1[0] < pos1[1]).should be_true

      # Redundant render must not change the evenly-distributed positions.
      s.repaint
      sp.@positions.should eq pos1

      # Pinning a divider still works (user-positioned clamp path).
      sp.set_divider_position 0, 10
      s.repaint
      sp.divider_position(0).should eq 10
    end
  end

  describe Crysterm::Widget::StatusBar do
    it "caches the left-truncated permanent tail, stable across renders, updated on change" do
      s = headless_screen(10, 3)
      bar = Crysterm::Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: 10, height: 1
      bar.add_permanent "AAAA"
      bar.add_permanent "BBBB" # permanent_text "AAAA │ BBBB" (11) overflows width 10

      s.repaint
      t1 = bar.@_trunc
      t1.empty?.should be_false
      # Truncated tail keeps the most-recent (right) sections.
      bar.@permanent_text.ends_with?(t1).should be_true

      # Redundant render: identical cached value.
      s.repaint
      bar.@_trunc.should eq t1

      # Changing the permanent text rebuilds the cache.
      bar.add_permanent "CCCC"
      s.repaint
      bar.@permanent_text.ends_with?(bar.@_trunc).should be_true
    end
  end
end
