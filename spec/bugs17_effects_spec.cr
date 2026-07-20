require "./spec_helper"

include Crysterm

# Regression specs for two effect-area bugs:
#
#   * B17-24 — `Marquee#text=` rebuilt `@chars` but never called `mark_dirty`,
#     so a reassignment on a static (non-running) marquee was never reflected.
#   * B17-38 — effect color math added an Int32 term on the LEFT of an Int64
#     `@frame` product. Crystal mixed-width arithmetic returns the LEFT operand's
#     type (checked), so once `frame * speed` exceeded `Int32::MAX` the addition
#     raised `OverflowError` and killed the animation/render fiber. The fix puts
#     the wide Int64 operand first and narrows only the post-`% 360` result.
#
# Everything is driven headlessly over in-memory IOs; `#step`/`#render` are
# synchronous so no animation fiber is needed.

private def effects_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

private def cell_char(screen, y, x)
  screen.lines[y][x].char
end

# Top content row, rendered, as a String.
private def row0(screen, w)
  String.build { |io| (0...w).each { |x| io << cell_char(screen, 0, x) } }
end

# A frame value large enough that `frame * speed` blows past Int32::MAX for any
# of the default hue speeds (6/8/9), reproducing the pre-fix OverflowError.
private BIG_FRAME = Int32::MAX.to_i64

# Test subclasses that expose the otherwise-encapsulated `@frame` counter so the
# overflow horizon can be reached without stepping billions of times.
private class FrameMarquee < Crysterm::Widget::Marquee
  def frame=(v : Int64)
    @frame = v
  end
end

private class FrameCopperBar < Crysterm::Widget::Effect::CopperBar
  def frame=(v : Int64)
    @frame = v
  end
end

private class FrameSpray < Crysterm::Widget::Effect::Spray
  def frame=(v : Int64)
    @frame = v
  end

  # `#colorize` is private; expose it for the overflow assertion.
  def colorize_at(i : Int32, phase : Crysterm::Widget::Effect::Spray::Phase) : Int32
    colorize(i, phase)
  end
end

describe "BUGS17 effects" do
  describe "B17-24 Marquee#text=" do
    it "reflects a runtime text= on the next render of a non-running marquee" do
      s = effects_screen
      m = Crysterm::Widget::Marquee.new parent: s, top: 0, left: 0,
        width: 9, height: 1, text: "OLD"
      w = m.awidth

      s.repaint # frame 0
      old = row0(s, w)
      old.should eq String.build { |io| (0...w).each { |x| io << "OLD"[x % 3] } }

      m.text = "NEW"
      m.text.should eq "NEW"
      s.repaint
      row0(s, w).should eq String.build { |io| (0...w).each { |x| io << "NEW"[x % 3] } }
      row0(s, w).should_not eq old
    end
  end

  describe "B17-38 effect color-math overflow" do
    it "does not raise rendering a rainbow marquee past the Int32 frame horizon" do
      s = effects_screen
      m = FrameMarquee.new parent: s, top: 0, left: 0,
        width: 8, height: 1, text: "AB", rainbow: true, hue_speed: 8, hue_spread: 7
      m.frame = BIG_FRAME

      (BIG_FRAME.to_i64 * 8).should be > Int32::MAX # pre-fix overflow condition
      s.repaint                                     # rainbow_fg used to raise OverflowError here
    end

    it "does not raise scrolling a :right marquee past the Int32 frame horizon" do
      s = effects_screen
      # `:right` computes `-f + x`; the pre-fix `x - f` overflowed Int32 once
      # f exceeded Int32::MAX in magnitude.
      m = FrameMarquee.new parent: s, top: 0, left: 0,
        width: 8, height: 1, text: "ABCDE", direction: :right
      m.frame = 3_000_000_000_i64
      s.repaint
    end

    it "does not raise computing a CopperBar color past the Int32 frame horizon" do
      s = effects_screen
      bar = FrameCopperBar.new parent: s, top: 0, left: 0,
        width: 10, height: 1, hue_offset: 0, hue_speed: 9
      bar.frame = BIG_FRAME

      c = bar.color # used to raise OverflowError
      c.should be_a Int32
      # Equivalent to the safe Int64-first computation.
      hue = ((BIG_FRAME.to_i64 * 9 + 0) % 360).to_i32
      c.should eq Crysterm::Colors.hsv_i(hue)
    end

    it "does not raise computing Spray flight/landed colors past the Int32 frame horizon" do
      s = effects_screen
      spray = FrameSpray.new parent: s, top: 0, left: 0, width: 10, height: 3
      spray.frame = BIG_FRAME

      spray.colorize_at(1, Crysterm::Widget::Effect::Spray::Phase::Flight)
      spray.colorize_at(1, Crysterm::Widget::Effect::Spray::Phase::Landed)
    end
  end
end
