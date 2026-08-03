require "./spec_helper"

include Crysterm

# O8: `Style::AttrMemo` — the shared per-site memo of the
# `Widget.style_to_attr(style)` derivation, gated on
# {style identity via `same?`, `Style#attr_revision`} — and its converted
# per-frame call sites (`Cursor#style_attr`, `Widget::Marquee#render`,
# `Widget::Table`'s recolor/gridline pass, `Widget::TextEdit`'s steady frame,
# and the bar/dial/effect family: `Slider`, `ScrollBar`, `Dial`,
# `ProgressBar`, `BigText`, `StatusBar`, `Effect::Direct`,
# `Effect::SineScroller`, `Chat::Input`'s prompt stamp).

# A `Style` whose `bold?` alternates on every read. `style_to_attr` reads the
# flag exactly once per derivation, so a repeat `fetch` under an unchanged
# {identity, revision} key can only return the first attr if it did NOT
# re-derive — making a memo hit directly observable.
private class FlipStyle < Crysterm::Style
  @flip = false

  def bold? : Bool
    @flip = !@flip
  end
end

# A window at the unstyled floor (no theme), where inline `@style` wins
# wholesale — so the widget-site examples below mutate exactly the object the
# render path resolves.
private def floor_screen(width = nil, height = nil)
  s = headless_screen(width, height, default_quit_keys: true)
  Crysterm::CSS.theme = nil
  s
end

# The active theme / default stylesheet is process-global; restore around each
# example so floor examples can't leak into later specs.
private def with_saved_theme(&)
  saved_theme = Crysterm::CSS.theme
  saved_default = Crysterm::CSS.default_stylesheet
  yield
ensure
  Crysterm::CSS.theme = saved_theme
  Crysterm::CSS.default_stylesheet = saved_default.not_nil!
end

describe Style::AttrMemo do
  it "derives on first fetch and hits on an unchanged {identity, revision} key" do
    memo = Style::AttrMemo.new
    s = FlipStyle.new

    # First derivation reads `bold?` once (-> true): BOLD is packed in.
    first = memo.fetch(s)
    (Attr.flags(first) & Attr::BOLD).should_not eq 0

    # Identity and revision unchanged: a re-derivation would read `bold?`
    # again (-> false) and drop BOLD, so equality proves the cached value was
    # returned without recomputing.
    memo.fetch(s).should eq first

    # Sanity: a direct derivation now really would differ.
    Widget.style_to_attr(s).should_not eq first
  end

  it "invalidates on a style setter (in-place mutation, no object swap)" do
    memo = Style::AttrMemo.new
    s = Style.new(bg: 0x111111)
    a1 = memo.fetch(s)

    s.bg = 0x222222
    a2 = memo.fetch(s)
    a2.should_not eq a1
    a2.should eq Widget.style_to_attr(s)

    # A boolean SGR setter invalidates too.
    s.bold = true
    a3 = memo.fetch(s)
    a3.should_not eq a2
    (Attr.flags(a3) & Attr::BOLD).should_not eq 0
  end

  it "invalidates on a style object swap even at an equal revision" do
    memo = Style::AttrMemo.new
    a = Style.new(bg: 0x111111)
    b = Style.new(bg: 0x222222)
    memo.fetch(a)

    # Align `b`'s counter with `a`'s via same-value re-assignments, so only
    # object identity distinguishes the two.
    while b.attr_revision < a.attr_revision
      b.bg = 0x222222
    end
    b.attr_revision.should eq a.attr_revision

    memo.fetch(b).should eq Widget.style_to_attr(b)
  end
end

describe "Cursor#style_attr (memoized artificial-cursor attr)" do
  it "tracks in-place color mutation and style object swap" do
    c = Cursor.new
    base = c.style_attr
    base.should eq Widget.style_to_attr(c.style)

    # The `set_cursor_color` idiom: in-place `style.fg = ...`, no object swap.
    c.style.fg = 0x336699
    after = c.style_attr
    after.should_not eq base
    after.should eq Widget.style_to_attr(c.style)

    # Swapping the whole style object invalidates by identity.
    c.style = Style.new(bg: 0x102030)
    c.style_attr.should eq Widget.style_to_attr(c.style)
  end
end

describe "Widget::Marquee render attr memo" do
  it "in-place style mutation on a steady frame recolors the field" do
    with_saved_theme do
      s = floor_screen
      m = Widget::Marquee.new parent: s, top: 0, left: 0, width: 10, height: 1,
        text: "ABCDE"
      s.repaint
      s.lines[0][0].attr.should eq Widget.style_to_attr(m.style)

      # In-place mutation, no object swap — via `#restyle`, which also marks
      # the widget dirty so damage tracking re-renders it (a bare in-place
      # write is invisible to damage tracking; see `Mixin::Style#restyle`).
      m.restyle &.bg=(0x102030)
      s.repaint
      s.lines[0][0].attr.should eq Widget.style_to_attr(m.style)
      Attr.bg(s.lines[0][0].attr).should eq Attr.pack_color(0x102030)
    end
  end
end

describe "Widget::Table recolor attr memos" do
  it "steady repaints keep header/cell attrs current under in-place sub-style mutation" do
    with_saved_theme do
      s = floor_screen
      st = Style.new(border: true,
        header: Style.new(bg: 0x101010),
        cell: Style.new(bg: 0x202020))
      t = Widget::Table.new parent: s, top: 0, left: 0,
        rows: [["Aa", "Bb"], ["Cc", "Dd"]], style: st
      s.repaint

      hx = t.ileft
      hy = t.itop
      s.lines[hy][hx].attr.should eq Widget.style_to_attr(st.header)

      # Steady frame: unchanged styles keep the same attrs.
      s.repaint
      s.lines[hy][hx].attr.should eq Widget.style_to_attr(st.header)

      # In-place mutation of the header sub-style — no object swap — must
      # defeat the memo on the next repaint. Through `#restyle` so damage
      # tracking re-renders the widget (the write itself is invisible to it).
      t.restyle &.header.bg=(0x445566)
      s.repaint
      s.lines[hy][hx].attr.should eq Widget.style_to_attr(st.header)
      Attr.bg(s.lines[hy][hx].attr).should eq Attr.pack_color(0x445566)

      # Swapping the sub-style object invalidates by identity.
      t.restyle &.header=(Style.new(bg: 0x778899))
      s.repaint
      Attr.bg(s.lines[hy][hx].attr).should eq Attr.pack_color(0x778899)
    end
  end
end

describe "Widget::ProgressBar fill attr memo (swapped fg/bg)" do
  it "steady frames keep the swapped fill attr current under in-place indicator mutation" do
    with_saved_theme do
      s = floor_screen
      st = Style.new(indicator: Style.new(fg: 0x336699, bg: 0x101010))
      pb = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 10, height: 1,
        value: 100, style: st
      s.repaint

      # The fill renders fg/bg-inverted; the memoized plain attr with its
      # color fields swapped must pack the identical value as the explicit
      # `style_to_attr(ind, ind.bg, ind.fg)` spelling.
      ind = pb.style.indicator
      swapped = Widget.style_to_attr(ind, ind.bg, ind.fg)
      s.lines[0][0].attr.should eq swapped
      Attr.bg(swapped).should eq Attr.pack_color(0x336699)

      # Steady frame: unchanged style keeps the same attr.
      s.repaint
      s.lines[0][0].attr.should eq swapped

      # In-place mutation of the indicator sub-style — no object swap — must
      # defeat the memo on the next repaint.
      pb.restyle &.indicator.fg=(0x445566)
      s.repaint
      s.lines[0][0].attr.should eq Widget.style_to_attr(ind, ind.bg, ind.fg)
      Attr.bg(s.lines[0][0].attr).should eq Attr.pack_color(0x445566)
    end
  end
end

describe "Widget::ScrollBar render attr memos" do
  it "thumb and trough attrs stay current under in-place style mutation" do
    with_saved_theme do
      s = floor_screen
      st = Style.new(bg: 0x202020, indicator: Style.new(bg: 0x101010))
      sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 5,
        style: st
      s.repaint

      # Value at the minimum: thumb on the first row; below it the add-page
      # trough, whose slot resolution falls back to the bar's base style.
      s.lines[0][0].attr.should eq Widget.style_to_attr(st.indicator)
      s.lines[3][0].attr.should eq Widget.style_to_attr(st)

      # In-place mutations — no object swaps — must defeat both memos on the
      # next repaint (the trough memo's key object IS the base style, via the
      # slot fallback).
      sb.restyle do |style|
        style.indicator.bg = 0x445566
        style.bg = 0x334455
      end
      s.repaint
      Attr.bg(s.lines[0][0].attr).should eq Attr.pack_color(0x445566)
      Attr.bg(s.lines[3][0].attr).should eq Attr.pack_color(0x334455)
    end
  end
end

describe "Widget::TextEdit steady-frame attr memo" do
  it "in-place style mutation still refreshes the background on a steady frame" do
    with_saved_theme do
      s = floor_screen(40, 8)
      te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8,
        content: "Hi"
      s.repaint

      # Steady frame: layout unchanged, memo stamped.
      te.process_content.should be_false

      # In-place mutation, no object swap: the memoized derivation must
      # re-fire and recolor the fill on the next repaint. Through `#restyle`
      # so damage tracking re-renders the widget.
      te.restyle &.bg=(0x102030)
      s.repaint
      Attr.bg(s.lines[0][10].attr).should eq Attr.pack_color(0x102030)
      te.process_content.should be_false
    end
  end
end
