require "./spec_helper"

include Crysterm

# Differential test for per-widget damage tracking
# (`OptimizationFlag::DamageTracking`, see `src/screen_damage.cr`).
#
# The strongest correctness guarantee the design asks for: damage tracking must
# be *output-equivalent* to the full re-composite. So every scenario here builds
# the same scene twice — once on a plain screen and once on a damage-tracking
# screen — applies the same mutation sequence to both, renders both each step,
# and asserts their cell buffers (`@lines`: attr + char + grapheme overlay) are
# identical cell for cell. Whatever the fast path does, it may never diverge.
#
# A few scenarios additionally assert that the fast path *engaged* (via
# `Screen#damage_fast_frames`), so the suite can't pass trivially by always
# falling back to the full path.

private def new_screen(damage : Bool)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 24,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
end

# Asserts the two screens' cell buffers are identical.
private def assert_same_lines(a : Crysterm::Screen, b : Crysterm::Screen, ctx = "")
  a.lines.size.should eq b.lines.size
  a.lines.each_index do |y|
    la = a.lines[y]
    lb = b.lines[y]
    la.size.should eq lb.size
    la.size.times do |x|
      ca = la[x]
      cb = lb[x]
      if ca.attr != cb.attr || ca.char != cb.char || la.grapheme_at?(x) != lb.grapheme_at?(x)
        fail "cell mismatch at (#{y},#{x}) #{ctx}: " \
             "full=(attr=#{cb.attr},char=#{cb.char.inspect},g=#{lb.grapheme_at?(x).inspect}) " \
             "damage=(attr=#{ca.attr},char=#{ca.char.inspect},g=#{la.grapheme_at?(x).inspect})"
      end
    end
  end
end

# Builds a grid of `count` non-overlapping bordered panels (with a nested
# content row each) on `screen` and returns them.
private def build_panels(screen, count = 4)
  panels = [] of Widget::Box
  count.times do |p|
    panel = Widget::Box.new(
      parent: screen,
      top: (p // 2) * 10, left: (p % 2) * 28,
      width: 26, height: 8,
      style: Style.new(border: true),
      content: "Panel #{p}")
    Widget::Box.new(parent: panel, top: 1, left: 1, width: 22, height: 1,
      content: "row #{p}")
    panels << panel
  end
  panels
end

# Builds two deliberately overlapping bordered boxes (B drawn over A) on
# `screen` and returns {A, B}.
private def build_overlap(screen)
  a = Widget::Box.new(parent: screen, top: 0, left: 0, width: 20, height: 10,
    style: Style.new(border: true), content: "A")
  b = Widget::Box.new(parent: screen, top: 5, left: 5, width: 20, height: 10,
    style: Style.new(border: true), content: "B")
  {a, b}
end

# Builds a scene with several opaque base panels and one translucent z-indexed
# overlay (a plane) over the left two of them. The overlay is promoted to a layer
# via CSS (the supported path — an inline `style.z_index=` is dropped by the
# cascade). Returns {base panels, overlay}.
private def build_plane(screen)
  bases = [] of Widget::Box
  3.times do |i|
    bases << Widget::Box.new(parent: screen, top: 0, left: i * 18, width: 16, height: 10,
      style: Style.new(border: true, bg: 0x202020), content: "B#{i}")
  end
  overlay = Widget::Box.new(parent: screen, top: 2, left: 6, width: 18, height: 6,
    style: Style.new(border: true, bg: 0x0055aa), content: "ov")
  overlay.add_css_class "ov"
  screen.stylesheet = ".ov { z-index: 5; opacity: 0.6; }"
  {bases, overlay}
end

# Builds an opaque base box with a translucent box layered over it; returns
# {base, alpha}.
private def build_alpha(screen)
  base = Widget::Box.new(parent: screen, top: 0, left: 0, width: 30, height: 12,
    style: Style.new(bg: 0x202020), content: "base")
  a = Widget::Box.new(parent: screen, top: 2, left: 2, width: 10, height: 5,
    style: Style.new(bg: 0x00ff00, alpha: 0.5), content: "x")
  {base, a}
end

describe "damage tracking" do
  it "is output-equivalent when one of N opaque panels updates per frame" do
    plain = new_screen false
    dmg = new_screen true
    pp = build_panels plain
    dp = build_panels dmg

    plain._render
    dmg._render
    assert_same_lines dmg, plain, "(initial)"

    5.times do |f|
      i = f % pp.size
      pp[i].content = "Panel #{i} @ #{f}"
      dp[i].content = "Panel #{i} @ #{f}"
      plain._render
      dmg._render
      assert_same_lines dmg, plain, "(frame #{f})"
    end

    # The whole point: these frames went through the selective path, not the
    # full re-composite fallback.
    dmg.damage_fast_frames.should be > 0
  end

  it "is output-equivalent when a nested child updates" do
    plain = new_screen false
    dmg = new_screen true
    pp = build_panels plain
    dp = build_panels dmg
    plain._render; dmg._render

    # Mutate the nested row of panel 1, not the panel itself.
    pp[1].children.first.content = "changed row"
    dp[1].children.first.content = "changed row"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(nested child)"
    dmg.damage_fast_frames.should be > 0
  end

  it "clears vacated cells when a widget moves (geometry change)" do
    plain = new_screen false
    dmg = new_screen true
    pp = build_panels plain
    dp = build_panels dmg
    plain._render; dmg._render

    pp[0].left = 4
    pp[0].top = 2
    dp[0].left = 4
    dp[0].top = 2
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(moved)"
  end

  it "clears vacated cells when a widget is hidden" do
    plain = new_screen false
    dmg = new_screen true
    pp = build_panels plain
    dp = build_panels dmg
    plain._render; dmg._render

    pp[3].hide
    dp[3].hide
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(hidden)"
  end

  it "is output-equivalent when a widget shrinks (stale-cell hazard)" do
    plain = new_screen false
    dmg = new_screen true
    pp = build_panels plain
    dp = build_panels dmg
    plain._render; dmg._render

    pp[0].width = 14
    pp[0].height = 4
    dp[0].width = 14
    dp[0].height = 4
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(shrunk)"
  end

  # --- Phase 2: overlap & z-order -----------------------------------------

  it "recomposites overlapping widgets in z-order when the lower one updates" do
    plain = new_screen false
    dmg = new_screen true
    pa, _pb = build_overlap plain
    da, _db = build_overlap dmg
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(overlap initial)"

    before = dmg.damage_fast_frames
    pa.content = "A2"
    da.content = "A2"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(lower update)"
    # The overlap was handled by the selective (Phase 2) path, not a full fallback.
    dmg.damage_fast_frames.should be > before
  end

  it "recomposites overlapping widgets in z-order when the upper one updates" do
    plain = new_screen false
    dmg = new_screen true
    _pa, pb = build_overlap plain
    _da, db = build_overlap dmg
    plain._render; dmg._render

    before = dmg.damage_fast_frames
    pb.content = "B2"
    db.content = "B2"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(upper update)"
    dmg.damage_fast_frames.should be > before
  end

  it "is equivalent for a transitive chain of three overlapping widgets" do
    plain = new_screen false
    dmg = new_screen true
    build = ->(s : Crysterm::Screen) {
      a = Widget::Box.new(parent: s, top: 0, left: 0, width: 16, height: 8,
        style: Style.new(border: true), content: "A")
      b = Widget::Box.new(parent: s, top: 4, left: 8, width: 16, height: 8,
        style: Style.new(border: true), content: "B")
      c = Widget::Box.new(parent: s, top: 8, left: 16, width: 16, height: 8,
        style: Style.new(border: true), content: "C")
      {a, b, c}
    }
    pa, _pb, _pc = build.call plain
    da, _da2, _da3 = build.call dmg
    plain._render; dmg._render

    # Update the first link; the change reaches the third only transitively.
    pa.content = "A2"
    da.content = "A2"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(chain update)"
  end

  it "handles a widget moving into overlap with another" do
    plain = new_screen false
    dmg = new_screen true
    # Two initially disjoint boxes.
    pa = Widget::Box.new(parent: plain, top: 0, left: 0, width: 14, height: 6,
      style: Style.new(border: true), content: "A")
    Widget::Box.new(parent: plain, top: 0, left: 30, width: 14, height: 6,
      style: Style.new(border: true), content: "B")
    da = Widget::Box.new(parent: dmg, top: 0, left: 0, width: 14, height: 6,
      style: Style.new(border: true), content: "A")
    Widget::Box.new(parent: dmg, top: 0, left: 30, width: 14, height: 6,
      style: Style.new(border: true), content: "B")
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(disjoint)"

    # Move A so it now overlaps B.
    pa.left = 24
    da.left = 24
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(moved into overlap)"
  end

  it "handles a widget moving out of overlap (vacated cells)" do
    plain = new_screen false
    dmg = new_screen true
    pa, _pb = build_overlap plain
    da, _db = build_overlap dmg
    plain._render; dmg._render

    # Move A away from B.
    pa.left = 38
    pa.top = 14
    da.left = 38
    da.top = 14
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(moved out of overlap)"
  end

  it "handles two independent overlap clusters updating at once" do
    plain = new_screen false
    dmg = new_screen true
    build = ->(s : Crysterm::Screen) {
      a1 = Widget::Box.new(parent: s, top: 0, left: 0, width: 12, height: 6,
        style: Style.new(border: true), content: "1")
      Widget::Box.new(parent: s, top: 3, left: 4, width: 12, height: 6,
        style: Style.new(border: true), content: "2")
      b1 = Widget::Box.new(parent: s, top: 14, left: 40, width: 12, height: 6,
        style: Style.new(border: true), content: "3")
      Widget::Box.new(parent: s, top: 17, left: 44, width: 12, height: 6,
        style: Style.new(border: true), content: "4")
      {a1, b1}
    }
    pa1, pb1 = build.call plain
    da1, db1 = build.call dmg
    plain._render; dmg._render

    pa1.content = "1x"; pb1.content = "3x"
    da1.content = "1x"; db1.content = "3x"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(two clusters)"
  end

  # --- Phase 3: alpha / shadow / tint -------------------------------------

  it "re-blends a translucent widget over its base when the widget changes" do
    plain = new_screen false
    dmg = new_screen true
    _pbase, pa = build_alpha plain
    _dbase, da = build_alpha dmg
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(alpha initial)"

    before = dmg.damage_fast_frames
    pa.content = "y"
    da.content = "y"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(alpha widget update)"
    dmg.damage_fast_frames.should be > before # handled selectively (Phase 3), not full
  end

  it "re-blends a translucent widget when the base UNDER it changes" do
    plain = new_screen false
    dmg = new_screen true
    pbase, _pa = build_alpha plain
    dbase, _da = build_alpha dmg
    plain._render; dmg._render

    # Change only the base; the alpha widget must re-blend over the new base.
    before = dmg.damage_fast_frames
    pbase.content = "BASE!"
    dbase.content = "BASE!"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(base under alpha update)"
    dmg.damage_fast_frames.should be > before
  end

  it "clears the old shadow band when a shadowed widget moves" do
    plain = new_screen false
    dmg = new_screen true
    mk = ->(s : Crysterm::Screen) {
      Widget::Box.new(parent: s, top: 2, left: 2, width: 12, height: 6,
        style: Style.new(border: true, shadow: true), content: "S")
    }
    pb = mk.call plain
    db = mk.call dmg
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(shadow initial)"

    pb.left = 20; pb.top = 10
    db.left = 20; db.top = 10
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(shadow moved — old band cleared)"
  end

  it "re-blends a shadow over a widget under it when that widget changes" do
    plain = new_screen false
    dmg = new_screen true
    build = ->(s : Crysterm::Screen) {
      # `under` sits where `caster`'s shadow falls (to its lower-right).
      under = Widget::Box.new(parent: s, top: 6, left: 12, width: 12, height: 6,
        style: Style.new(border: true), content: "U")
      Widget::Box.new(parent: s, top: 2, left: 2, width: 12, height: 6,
        style: Style.new(border: true, shadow: true), content: "C")
      under
    }
    pu = build.call plain
    du = build.call dmg
    plain._render; dmg._render

    pu.content = "U2"
    du.content = "U2"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(under-shadow update)"
  end

  it "is equivalent when a tinted widget updates" do
    plain = new_screen false
    dmg = new_screen true
    mk = ->(s : Crysterm::Screen) {
      box = Widget::Box.new(parent: s, top: 1, left: 1, width: 16, height: 6,
        content: "t")
      box.style.tint = 0xff0000
      box.style.tint_alpha = 0.4
      box
    }
    pb = mk.call plain
    db = mk.call dmg
    plain._render; dmg._render

    before = dmg.damage_fast_frames
    pb.content = "tinted!"
    db.content = "tinted!"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(tint update)"
    dmg.damage_fast_frames.should be > before
  end

  it "composites two overlapping widgets that BOTH change in one frame in z-order" do
    plain = new_screen false
    dmg = new_screen true
    pa, pb = build_overlap plain
    da, db = build_overlap dmg
    plain._render; dmg._render

    # Mutate the UPPER (b) first, then the LOWER (a): the dirty set's insertion
    # order is then the reverse of @children z-order, which must not affect the
    # composited result (regression test for dirty/dirty z-ordering).
    pb.content = "B2"; pa.content = "A2"
    db.content = "B2"; da.content = "A2"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(both overlapping changed)"
  end

  it "does not disturb a widget sitting in the gap between two clusters" do
    plain = new_screen false
    dmg = new_screen true
    build = ->(s : Crysterm::Screen) {
      # Two overlap pairs at the far left and far right, plus a lone box in the
      # middle that lies inside the bounding box of the two pairs but overlaps
      # neither — it must survive a selective frame untouched.
      l1 = Widget::Box.new(parent: s, top: 0, left: 0, width: 10, height: 6,
        style: Style.new(border: true), content: "L1")
      Widget::Box.new(parent: s, top: 3, left: 4, width: 10, height: 6,
        style: Style.new(border: true), content: "L2")
      Widget::Box.new(parent: s, top: 16, left: 26, width: 8, height: 5,
        style: Style.new(border: true), content: "MID")
      r1 = Widget::Box.new(parent: s, top: 0, left: 48, width: 10, height: 6,
        style: Style.new(border: true), content: "R1")
      Widget::Box.new(parent: s, top: 3, left: 52, width: 10, height: 6,
        style: Style.new(border: true), content: "R2")
      {l1, r1}
    }
    pl1, pr1 = build.call plain
    dl1, dr1 = build.call dmg
    plain._render; dmg._render

    pl1.content = "L1x"; pr1.content = "R1x"
    dl1.content = "L1x"; dr1.content = "R1x"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(gap widget preserved)"
  end

  # --- Phase 4: z-index planes --------------------------------------------

  it "re-folds the plane over a freshly rebuilt base when the base UNDER it changes" do
    plain = new_screen false
    dmg = new_screen true
    pbases, _pov = build_plane plain
    dbases, _dov = build_plane dmg
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(plane initial)"

    before = dmg.damage_fast_frames
    3.times do |f|
      pbases[0].content = "X#{f}"
      dbases[0].content = "X#{f}"
      plain._render; dmg._render
      assert_same_lines dmg, plain, "(base under plane, frame #{f})"
    end
    # Handled by the selective Phase 4 plane path, not a full fallback.
    dmg.damage_fast_frames.should be > before
  end

  it "re-renders and re-folds the plane when the overlay itself changes" do
    plain = new_screen false
    dmg = new_screen true
    _pbases, pov = build_plane plain
    _dbases, dov = build_plane dmg
    plain._render; dmg._render

    before = dmg.damage_fast_frames
    pov.content = "overlay!"
    dov.content = "overlay!"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(overlay changed)"
    dmg.damage_fast_frames.should be > before
  end

  it "clears the vacated region and re-folds when the plane moves" do
    plain = new_screen false
    dmg = new_screen true
    _pbases, pov = build_plane plain
    _dbases, dov = build_plane dmg
    plain._render; dmg._render

    before = dmg.damage_fast_frames
    pov.left = 20; pov.top = 8
    dov.left = 20; dov.top = 8
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(plane moved)"
    dmg.damage_fast_frames.should be > before
  end

  it "shows bare base where the plane was when the plane hides" do
    plain = new_screen false
    dmg = new_screen true
    _pbases, pov = build_plane plain
    _dbases, dov = build_plane dmg
    plain._render; dmg._render

    pov.hide
    dov.hide
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(plane hidden)"
  end

  it "is equivalent when a base panel far from the plane changes" do
    plain = new_screen false
    dmg = new_screen true
    pbases, _pov = build_plane plain
    dbases, _dov = build_plane dmg
    plain._render; dmg._render

    pbases[2].content = "far away"
    dbases[2].content = "far away"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(base far from plane)"
  end

  it "stays equivalent for a multi-plane scene (full-path fallback)" do
    # Two distinct z-indices = two planes; Phase 4 handles only a single plane,
    # so this must fall back to the full path and stay output-equivalent.
    build = ->(s : Crysterm::Screen) {
      base = Widget::Box.new(parent: s, top: 0, left: 0, width: 40, height: 16,
        style: Style.new(border: true, bg: 0x101010), content: "base")
      o1 = Widget::Box.new(parent: s, top: 2, left: 2, width: 16, height: 6,
        style: Style.new(border: true, bg: 0x0055aa), content: "o1")
      o1.add_css_class "o1"
      o2 = Widget::Box.new(parent: s, top: 6, left: 14, width: 16, height: 6,
        style: Style.new(border: true, bg: 0xaa5500), content: "o2")
      o2.add_css_class "o2"
      s.stylesheet = ".o1 { z-index: 5; opacity: 0.6; } .o2 { z-index: 8; opacity: 0.5; }"
      {base, o1}
    }
    plain = new_screen false
    dmg = new_screen true
    pbase, _po1 = build.call plain
    dbase, _do1 = build.call dmg
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(multi-plane initial)"

    pbase.content = "BASE2"
    dbase.content = "BASE2"
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(multi-plane base change)"
  end

  it "is output-equivalent across child add and remove" do
    plain = new_screen false
    dmg = new_screen true
    pp = build_panels plain
    dp = build_panels dmg
    plain._render; dmg._render

    # Add a child.
    Widget::Box.new(parent: pp[2], top: 3, left: 1, width: 10, height: 1, content: "new")
    Widget::Box.new(parent: dp[2], top: 3, left: 1, width: 10, height: 1, content: "new")
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(after add)"

    # Remove a child.
    pp[2].remove pp[2].children.last
    dp[2].remove dp[2].children.last
    plain._render; dmg._render
    assert_same_lines dmg, plain, "(after remove)"
  end

  it "is output-equivalent when nothing changes between frames" do
    plain = new_screen false
    dmg = new_screen true
    build_panels plain
    build_panels dmg
    plain._render; dmg._render

    3.times do
      plain._render
      dmg._render
    end
    assert_same_lines dmg, plain, "(idle)"
  end
end
