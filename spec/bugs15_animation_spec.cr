require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 @keyframes driver fixes (`src/widget_animation.cr`).
#
#  #47 `animation-iteration-count: 0` means "play zero times": with the default
#      fill-mode the widget must keep its base style, NOT be stamped with the
#      final keyframe's values.
#  #48 A `tint`-only keyframe animation must carry the tint *color* (not just the
#      strength), else `Style#tint?` stays nil and the overlay is invisible.

private def anim_window(w = 10, h = 3)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS15 #47 animation-iteration-count 0" do
  it "keeps the base style (does not stamp the final keyframe) for count 0" do
    s = anim_window
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "zero"
    # `to { opacity: 0 }` — a bug would settle the box at opacity 0 on tick 1.
    s.stylesheet = "@keyframes zero { to { opacity: 0; } } " \
                   ".zero { animation: zero 1s 0; }"
    s._render # would start (and immediately settle) the animation

    # Base alpha (unset) preserved: the 100% keyframe (opacity 0) was never applied.
    b.style.opacity.should be_nil
    2.times do
      sleep 0.03.seconds
      s._render
    end
    b.style.opacity.should be_nil
  ensure
    s.try &.destroy
  end
end

describe "BUGS15 #48 tint-only keyframe animation" do
  it "carries the tint color so the overlay is actually applied" do
    s = anim_window
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "flash"
    # Tint-only animation: no other rule sets a tint color. Without the fix the
    # keyframe animates only tint_alpha and `style.tint` stays nil (invisible).
    s.stylesheet = "@keyframes flash { from { tint: red 0.0; } to { tint: red 0.8; } } " \
                   ".flash { animation: flash 0.1s infinite; }"
    s._render # starts the animation

    seen_tint = false
    12.times do
      sleep 0.02.seconds
      seen_tint = true if b.style.tint
      break if seen_tint
    end
    seen_tint.should be_true
    b.style.tint.should_not be_nil
  ensure
    s.try &.destroy
  end
end
