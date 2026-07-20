require "./spec_helper"

include Crysterm

# BUGS15 misc render/mixin/device fixes:
#   #29 @plane_buckets grows without bound when a z-indexed layer animates opacity
#   #35 ActionBar sizes command boxes by codepoint count, not display columns
#   #38 Explicit runtime glyph_tier pin is lost across reconnect/reattach

private def sized_screen(w, h, *, force_unicode = false, full_unicode = false)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, force_unicode: force_unicode, full_unicode: full_unicode)
end

describe "BUGS15 #29: @plane_buckets pruning" do
  # Two distinct z-index values keep `composite_planes` on the full path every
  # frame (the damage-tracking fast path only engages for a single z-index
  # plane — see `window_damage.cr`'s `damage_plane_composite`), so this
  # isolates the bucket-growth bug from damage tracking's separate fast path.
  it "does not retain a stale {z, alpha} entry once a bucket goes empty" do
    s = sized_screen 20, 6
    a = Widget::Box.new parent: s, left: 0, top: 0, width: 5, height: 3
    a.style.z_index = 1
    b = Widget::Box.new parent: s, left: 10, top: 0, width: 5, height: 3
    b.style.z_index = 2

    s.repaint
    20.times do |i|
      # A tweened opacity (CSS transition/keyframes) mints a near-unique
      # {z, alpha} key every frame. Without pruning, each frame's stale key
      # (from the previous frame's now-different alpha) stays in the hash
      # forever.
      a.style.opacity = 0.1 + i * 0.01
      a.mark_dirty
      s.repaint
    end

    # Only the buckets actually in use this frame (one per live z-index)
    # should remain — not one per rendered frame.
    s.@plane_buckets.size.should eq 2
  end
end

describe "BUGS15 #35: ActionBar sizes command boxes by display columns" do
  # `full_unicode?` requires both the option and a Unicode-capable terminal;
  # `force_unicode: true` satisfies the capability half in a headless spec
  # (see other specs' `force_unicode: true, full_unicode: true` pattern).
  it "sizes a CJK label's box by display width, not codepoint count" do
    s = sized_screen(40, 3, force_unicode: true, full_unicode: true)
    bar = Widget::ListBar.new parent: s
    bar.auto_prefix = false # isolate the label's own width from the "N:" prefix
    label = "ファイル"          # 4 codepoints, 8 display columns (East-Asian wide)
    bar.add_item label

    cmd = bar.commands.first
    cmd.width.should eq Crysterm::Unicode.display_width(label) + 2
    cmd.width.should eq 10 # 8 display columns + 2, not 4 codepoints + 2
  end

  # Without full_unicode in effect, the content engine lays one codepoint per
  # cell, so `.size` remains the correct (and only consistent) measure — this
  # must NOT change.
  it "keeps codepoint-count sizing in legacy (non-full_unicode) mode" do
    s = sized_screen 40, 3
    bar = Widget::ListBar.new parent: s
    bar.auto_prefix = false
    label = "ファイル"
    bar.add_item label

    cmd = bar.commands.first
    cmd.width.should eq label.size + 2
  end

  it "sizes a separator by display width too" do
    s = sized_screen(40, 3, force_unicode: true, full_unicode: true)
    bar = Widget::ListBar.new parent: s
    bar.auto_prefix = false
    bar.add_item "a"
    bar.add_separator "日"

    sep = bar.commands.last
    sep.separator?.should be_true
    sep.width.should eq Crysterm::Unicode.display_width("日") + 2
    sep.width.should eq 4
  end
end

describe "BUGS15 #38: glyph_tier pin survives reconnect" do
  it "carries an explicit runtime glyph_tier= pin across Screen#reconnected" do
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
    s.glyph_tier_explicit?.should be_false # sanity: not pinned yet

    s.glyph_tier = Glyphs::Tier::Ascii
    s.glyph_tier_explicit?.should be_true

    s2 = s.reconnected(IO::Memory.new, IO::Memory.new)
    s2.glyph_tier_explicit?.should be_true
    s2.glyph_tier.should eq Glyphs::Tier::Ascii
  end

  it "does not fabricate a pin when the tier was never set explicitly" do
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
    s.glyph_tier_explicit?.should be_false

    s2 = s.reconnected(IO::Memory.new, IO::Memory.new)
    s2.glyph_tier_explicit?.should be_false
  end

  it "a reattached window (Window#connect) keeps an explicit glyph_tier pin" do
    w = sized_screen 20, 5
    w.glyph_tier = Glyphs::Tier::Ascii
    w.screen.glyph_tier_explicit?.should be_true

    w.disconnect
    w.connect(IO::Memory.new, IO::Memory.new)

    w.screen.glyph_tier_explicit?.should be_true
    w.glyph_tier.should eq Glyphs::Tier::Ascii

    w.destroy
  end
end
