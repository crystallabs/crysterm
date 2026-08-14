require "./spec_helper"

include Crysterm

# API.md §5.1 (Top-20 #7), second half — the `#style` reader can no longer
# silently drop writes. In the one case where it returns a transient object
# (the focus/selection reverse-video fallback copy at the unstyled floor),
# that copy is frozen: an attribute write raises `Style::FrozenError` pointing
# at the persistent write paths (`restyle`/`state_style`/`inline_style=`).
# Every other `#style` result is the persistent per-state style itself, where
# in-place mutation is supported and damage-tracked (§5.2).
#
# The floor cases run `without_default_theme`: under any active theme every
# widget is `css_styled` and the fallback copies never exist.

describe "frozen transient style copies (§5.1)" do
  it "keeps the common animation idiom working: style writes on a normal widget persist" do
    without_default_theme do
      s = headless_screen(80, 24)
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
      s.repaint

      w.style.frozen?.should be_false
      w.style.fg = 0xff0000 # the cracktro/CopperBar idiom
      w.style.fg.should eq 0xff0000
      w.style.same?(w.state_style).should be_true # one persistent object
    end
  end

  it "returns a frozen reverse-video copy for a selected widget at the unstyled floor" do
    without_default_theme do
      s = headless_screen(80, 24)
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
      s.repaint

      w.state = :selected
      w.style.frozen?.should be_true
      w.style.reverse?.should be_true       # the floor highlight
      w.state_style.frozen?.should be_false # the persistent style stays writable
      w.style.same?(w.style).should be_true # memoized: same copy within the frame
    end
  end

  it "raises Style::FrozenError instead of silently dropping the write" do
    without_default_theme do
      s = headless_screen(80, 24)
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
      s.repaint
      w.state = :selected

      expect_raises(Style::FrozenError, /restyle/) do
        w.style.bg = "red"
      end
    end
  end

  it "restyle remains the write path, and the write dissolves the copy" do
    without_default_theme do
      s = headless_screen(80, 24)
      w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
      s.repaint
      w.state = :selected

      w.restyle &.bg = "#ff0000"
      # Now visibly styled: no fallback copy — #style is the persistent style.
      w.style.frozen?.should be_false
      w.style.same?(w.state_style).should be_true
      w.style.bg.should eq 0xff0000
    end
  end

  it "a dup of a frozen copy is mutable (dup-then-mutate stays sanctioned)" do
    st = Style.new
    st.freeze!
    copy = st.dup
    copy.frozen?.should be_false
    copy.underline = true
    copy.underline?.should be_true
  end

  it "is a tripwire, not full immutability: only attribute setters are guarded" do
    st = Style.new
    st.freeze!
    expect_raises(Style::FrozenError) { st.bold = true }
    expect_raises(Style::FrozenError) { st.fg = 0x123456 }
    expect_raises(Style::FrozenError) { st.visible = false }
    st.opacity = 0.5 # non-attribute fields stay unguarded, by contract
    st.opacity.should eq 0.5
  end
end
