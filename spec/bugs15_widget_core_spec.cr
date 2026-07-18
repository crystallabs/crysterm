require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 #90, #91, #92 (widget-core). Headless harness
# mirrors spec/bugs15_scrolling_chrome_spec.cr / spec/bugs15_content_spec.cr.

private def headless_screen(w = 40, h = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS15 #90 — `insert_line(line : String)`'s no-index append overload
# resolved its insert point off `@_clines.ftor.size`, which stays 0 for
# content seeded while the widget is detached (`process_content` bails until
# `window?`, so only `fake` fills up). The "append" call then computed index
# 0 and spliced the new line before all existing ones. Fixed by keying the
# default off `@_clines.fake.size`, matching `append_line`/`remove_last_line`/
# `delete_line`'s clamp.
describe "BUGS15 90: insert_line's no-index overload appends after the last logical line" do
  it "appends after content seeded while detached, instead of inserting at the top" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 30, height: 5
    # A parentless `Widget::Box.new` auto-attaches to the global fallback
    # window (see Widget#determine_window), so genuine detachment (window?
    # nil) requires building attached, then explicitly detaching — matching
    # the report's repro ("remove_from_parent clears both parent and window").
    w.detach_from_tree
    w.window?.should be_nil

    w.replace_line 0, "a"
    w.replace_line 1, "b"
    # Before the fix: ftor.size == 0 (process_content never ran), so this
    # resolved to insert_line(0, "c") -> "c", "a", "b".
    w.insert_line "c"

    w.lines.should eq ["a", "b", "c"]
  end

  it "still appends after the last line for an attached (parsed) widget" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 30, height: 5

    w.replace_line 0, "a"
    w.replace_line 1, "b"
    # Attached: process_content runs on each replace_line, so ftor.size ==
    # fake.size == 2 already — behavior here must be unchanged by the fix.
    w.insert_line "c"

    w.lines.should eq ["a", "b", "c"]
  end
end

private def backdrop_attr_at(y : Int32, x : Int32) : Int64
  s = headless_screen
  Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 12,
    style: Crysterm::Style.new(bg: "red")
  s._render
  Crysterm::Attr.bg(s.lines[y][x].attr)
end

private def padding_ring_attr(fill : Bool)
  s = headless_screen
  Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 12,
    style: Crysterm::Style.new(bg: "red")

  st = Crysterm::Style.new(bg: "blue")
  st.alpha = 0.5
  st.fill = fill
  st.padding = 1

  b = Widget::Box.new parent: s, top: 2, left: 2, width: 10, height: 6,
    style: st, content: ""
  s._render

  lp = b.lpos.not_nil!
  {Crysterm::Attr.bg(s.lines[lp.yi][lp.xi].attr), lp}
end

# BUGS15 #91 — the alpha pre-blend in `_render`'s pre-fill block ran
# unconditionally, painting a `fill: false` widget's padding/valign bands even
# though its whole contract is to draw no background of its own. The sibling
# opaque-fill branches were already gated on `fill`; only the alpha branch was
# not. Fixed by gating it too: `if (alpha = style_alpha) && fill`.
describe "BUGS15 91: alpha pre-blend honors fill: false" do
  it "leaves the padding ring showing the backdrop untouched when fill: false" do
    attr, lp = padding_ring_attr(false)
    expected = backdrop_attr_at(lp.yi, lp.xi)
    # Before the fix, this padding cell was blended toward blue even though
    # fill: false means the widget should paint nothing of its own.
    attr.should eq expected
  end

  it "still blends the padding ring toward the widget's own color when fill: true" do
    attr, lp = padding_ring_attr(true)
    backdrop = backdrop_attr_at(lp.yi, lp.xi)
    # fill: true keeps painting (this is not the bug): the blend must still
    # happen, so the ring differs from the untouched backdrop.
    attr.should_not eq backdrop
  end
end

# BUGS15 #92 — `content_margin_x`/`hscrollbar_rows` read the *live*
# `scrollbar_width`/`scrollbar_height` properties every frame, but the
# `ScrollBar` children were created once with the construction-time thickness
# baked into their geometry and never re-asserted afterward. A runtime
# `scrollbar_width=`/`scrollbar_height=` change then desynced the reserved
# content margin from the actual bar size, leaving a dead reserved stripe.
# Fixed by re-asserting `sb.width`/`hb.height` in `update_scrollbar_widget`'s
# per-frame reconcile (already change-guarded, so free when unchanged).
describe "BUGS15 92: runtime scrollbar_width=/scrollbar_height= keep the ScrollBar chrome in sync" do
  it "widens the vertical bar to match content_margin_x after scrollbar_width=" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 8,
      scrollable: true
    box.scrollbar_policy = Widget::ScrollBarPolicy::AlwaysOn
    box.set_content(Array.new(20) { |i| "line #{i}" }.join("\n"))

    s._render
    sb = box.scrollbar_widget.not_nil!
    sb.width.should eq 1
    box.content_margin_x.should eq 1
    width_before = box.content_width

    box.scrollbar_width = 2
    s._render # reparse + reconcile

    box.content_margin_x.should eq 2
    box.content_width.should eq width_before - 1
    # Before the fix, the memoized bar stayed 1 column wide here, leaving a
    # dead reserved column between content and bar.
    sb.width.should eq 2
  end

  it "heightens the horizontal bar to match hscrollbar_rows after scrollbar_height=" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 8,
      scrollable: true
    box.horizontal_scrollbar_policy = Widget::ScrollBarPolicy::AlwaysOn

    s._render
    hb = box.horizontal_scrollbar_widget.not_nil!
    hb.height.should eq 1
    box.hscrollbar_rows.should eq 1
    rows_before = box.aheight - box.ivertical - box.hscrollbar_rows

    box.scrollbar_height = 2
    s._render

    box.hscrollbar_rows.should eq 2
    (box.aheight - box.ivertical - box.hscrollbar_rows).should eq rows_before - 1
    # Before the fix, the memoized bar stayed 1 row tall here.
    hb.height.should eq 2
  end
end
