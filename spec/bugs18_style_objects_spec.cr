require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 style-object findings:
#
# B18-34 — `Style#alternate_row`'s composed memo (and its identity-keyed
#          siblings: `ListTable#alt_row_style`, the reverse-video fallback
#          memos) must invalidate on *in-place* mutation of the base style,
#          not only when the base object is replaced. Programmatic styling
#          without CSS mutates the same `Style` object forever, so an
#          identity-only guard froze alternate rows/highlights at
#          first-compose values. Guarded now by `Style#attr_fingerprint`.
#
# B18-35 — `Styles.default` must deep-copy the per-state styles. The shallow
#          copy shared `DEFAULT`'s `focused`/`hovered`/... `Style` objects
#          across every widget (and with `DEFAULT` itself), so one widget's
#          `hide` (which writes `visible` through `Styles#visible=`) or a
#          per-widget `styles.focused.bg = ...` edit bled app-wide.
#
# B18-38 — In-place box mutations through the lazy getters
#          (`style.border.left = 1`, `style.padding.left = 2`) never stamp
#          `specified_mask`, so `ensure_floor_border` wiped them and the
#          cascade's inline fold dropped them. `Style#box_touched?` now
#          treats a materialized box with any non-zero side as user-set.

# A headless screen with the unstyled floor forced: no theme installed and the
# default stylesheet empty, so `apply_stylesheet` is a no-op. `ensure_theme`
# runs once on construction, so the theme is cleared *after* the screen exists.
private def b18_floor_screen(width = 40, height = 12)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  Crysterm::CSS.theme = nil
  s
end

private def b18_screen(width = 80, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private def b18_cell_fg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(screen.lines[y][x].attr))
end

private def b18_cell_bg(screen, y, x)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(screen.lines[y][x].attr))
end

# Count cells that carry BOTH the given foreground and background.
private def b18_count_cells_fg_bg(screen, fg, bg)
  n = 0
  (0...screen.height).each do |y|
    next unless screen.lines[y]?
    (0...screen.width).each do |x|
      n += 1 if b18_cell_fg(screen, y, x) == fg && b18_cell_bg(screen, y, x) == bg
    end
  end
  n
end

# Exposes the private non-CSS alternate-row memo for the residual-hole test
# (explicit sub-style, no `alternate-background-color`).
private class B18AltRowProbeTable < Crysterm::Widget::ListTable
  def probe_alt_row_style : Crysterm::Style
    alt_row_style
  end
end

# Exposes the protected reverse-video fallback memo core.
private class B18MemoProbeBox < Crysterm::Widget::Box
  def probe_reverse_memo(st, skip, src, copy, fp)
    reverse_fallback_memo st, skip, src, copy, fp
  end
end

# Test-only restore hook: there is no public way to un-set a per-state style,
# and the B18-35 spec must leave `Styles::DEFAULT` exactly as found so the
# mutation cannot leak into other spec files.
class Crysterm::Styles
  def _b18_spec_restore_focused(@focused : Crysterm::Style?)
  end
end

describe "BUGS18 B18-34 alternate_row composes live across in-place mutations" do
  it "recomposes after an in-place fg mutation of the base style" do
    s = Style.new
    s.alternate_background_color = 0x222222
    s.alternate_row.fg.should be_nil # memoize the composed copy
    s.fg = 0xff0000
    alt = s.alternate_row
    alt.fg.should eq 0xff0000
    alt.bg.should eq 0x222222
  end

  it "recomposes after an in-place attribute mutation of the base style" do
    s = Style.new
    s.alternate_background_color = 0x222222
    s.alternate_row.bold?.should be_false
    s.bold = true
    s.alternate_row.bold?.should be_true
  end

  it "tracks visible across repeated hide/show flips" do
    s = Style.new
    s.alternate_background_color = 0x222222
    s.visible = false
    s.alternate_row.visible?.should be_false
    s.visible = true
    s.alternate_row.visible?.should be_true
    # The second flip changes neither `specified_mask` (the bit is already
    # set) nor any other field but `visible` itself — the exact case an
    # incomplete fingerprint would miss.
    s.visible = false
    s.alternate_row.visible?.should be_false
  end

  it "still reuses the memoized composition while the base is unchanged" do
    s = Style.new
    s.alternate_background_color = 0x222222
    a = s.alternate_row
    s.alternate_row.same?(a).should be_true
  end

  it "invalidates the reverse-video fallback memo on in-place attribute mutation" do
    w = B18MemoProbeBox.new
    st = Style.new
    r1, src1, copy1, fp1 = w.probe_reverse_memo(st, false, nil, nil, nil)
    r1.reverse?.should be_true
    # Unchanged source: the memoized copy is reused.
    r2, _, _, _ = w.probe_reverse_memo(st, false, src1, copy1, fp1)
    r2.same?(r1).should be_true
    # In-place mutation of the same object: the copy is rebuilt.
    st.bold = true
    r3, _, _, _ = w.probe_reverse_memo(st, false, src1, copy1, fp1)
    r3.same?(r1).should be_false
    r3.bold?.should be_true
    r3.reverse?.should be_true
  end

  it "rederives ListTable's alt-row style when an explicit sub-style is mutated in place" do
    t = B18AltRowProbeTable.new alternate_rows: true
    # Explicit sub-style (no alternate-background-color): `Style#alternate_row`
    # returns this very object forever, so only the fingerprint can catch the
    # in-place edit. The border forces `without_border` to memoize a dup.
    sub = Style.new(border: true)
    t.styles.normal.alternate_row = sub
    first = t.probe_alt_row_style
    first.border.left.should eq 0 # border stripped for row use
    sub.fg = 0xff0000
    again = t.probe_alt_row_style
    again.fg.should eq 0xff0000
    again.border.left.should eq 0
  end

  # End-to-end: programmatic styling without CSS, mutating the same per-state
  # Style object between frames (the failure scenario from the report).
  it "renders alternate Table rows with a fg set in place after the first frame" do
    saved_theme = Crysterm::CSS.theme
    saved_default = Crysterm::CSS.default_stylesheet
    begin
      s = b18_floor_screen 40, 12
      t = Widget::Table.new parent: s, top: 0, left: 0, width: 24,
        rows: [["h1", "h2"], ["a", "b"], ["c", "d"], ["e", "f"]], alternate_rows: true
      s.apply_stylesheet
      t.styles.normal.alternate_background_color = "#333333"
      s.repaint # first frame memoizes the composed alternate-row style
      t.css_styled?.should be_false
      t.styles.normal.fg = "#ff0000" # in-place: same Style object
      t.mark_dirty
      s.repaint
      b18_count_cells_fg_bg(s, 0xff0000, 0x333333).should be > 0
    ensure
      Crysterm::CSS.theme = saved_theme
      Crysterm::CSS.default_stylesheet = saved_default
    end
  end
end

describe "BUGS18 B18-35 Styles.default deep-copies the per-state styles" do
  it "gives each copy independent per-state Style objects" do
    saved = Crysterm::Styles::DEFAULT.@focused
    begin
      Crysterm::Styles::DEFAULT.focused = Style.new(bg: "blue")
      blue = Crysterm::Styles::DEFAULT.focused.bg
      s1 = Crysterm::Styles.default
      s2 = Crysterm::Styles.default
      s1.own_focused?.should be_true
      s1.focused.same?(s2.focused).should be_false
      s1.focused.same?(Crysterm::Styles::DEFAULT.focused).should be_false
      # The hide/show path writes `visible` through `Styles#visible=` in place;
      # it must stay local to the one widget's copy.
      s1.visible = false
      s2.focused.visible?.should be_true
      Crysterm::Styles::DEFAULT.focused.visible?.should be_true
      # A per-widget color edit stays local too.
      s1.focused.bg = 0xff0000
      s2.focused.bg.should eq blue
      Crysterm::Styles::DEFAULT.focused.bg.should eq blue
    ensure
      Crysterm::Styles::DEFAULT._b18_spec_restore_focused(saved)
    end
  end

  it "keeps unset states unset and normal independent" do
    if Crysterm::Styles::DEFAULT.@focused.nil?
      # An unset state must not materialize in the copy (`own_focused?` drives
      # e.g. floor selection/focus coloring).
      Crysterm::Styles.default.own_focused?.should be_false
    end
    Crysterm::Styles.default.normal.same?(Crysterm::Styles::DEFAULT.normal).should be_false
  end
end

describe "BUGS18 B18-38 in-place box mutations count as user-set" do
  it "box_touched? distinguishes read, in-place mutation, and setter" do
    s = Style.new
    s.box_touched?(:border).should be_false
    s.border                                # merely reading materializes an all-zero box…
    s.box_touched?(:border).should be_false # …which must stay untouched
    s.border.left = 1
    s.box_touched?(:border).should be_true

    s.box_touched?(:padding).should be_false
    s.padding.left = 2
    s.box_touched?(:padding).should be_true

    s.box_touched?(:margin).should be_false
    s.margin.top = 1
    s.box_touched?(:margin).should be_true

    s.box_touched?(:shadow).should be_false
    s.shadow.right = 2
    s.box_touched?(:shadow).should be_true
  end

  it "box_touched? counts an explicit all-zero setter assignment (border: false)" do
    s = Style.new
    s.border = false
    s.box_touched?(:border).should be_true # explicit "off" is a user choice
  end

  it "keeps an in-place styles.normal.border mutation at the unstyled floor" do
    saved_theme = Crysterm::CSS.theme
    saved_default = Crysterm::CSS.default_stylesheet
    begin
      s = b18_floor_screen
      b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
      b.styles.normal.border.left = 1
      s.apply_stylesheet
      s.repaint
      b.css_styled?.should be_false
      # Before the fix, ensure_floor_border saw specified?(:border) == false
      # and replaced the border with Border.from(false), wiping the side.
      b.styles.normal.border.left.should eq 1
      b.ileft.should eq 1
    ensure
      Crysterm::CSS.theme = saved_theme
      Crysterm::CSS.default_stylesheet = saved_default
    end
  end

  it "folds an in-place inline padding mutation into the computed style under CSS" do
    s = b18_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
    inline = Style.new
    w.style = inline
    inline.padding.left = 2 # in place — no mask bit stamped
    s.stylesheet = "Box { color: #ff0000 }"
    s.repaint
    w.css_styled?.should be_true
    # Before the fix, fold_specified_onto skipped the unstamped padding and the
    # computed style rendered with zero padding.
    w.style.padding.left.should eq 2
  end
end
