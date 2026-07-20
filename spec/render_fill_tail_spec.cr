require "./spec_helper"

include Crysterm

# Gating specs for the content-loop restructure (PERF.md Phase 3): once a
# widget's content is exhausted, the rest of the box is painted by a per-row
# `fill_region` sweep instead of the per-cell machinery, and the padding/valign
# pre-fill covers only the bands the content loop doesn't visit. These pin the
# semantics the fast path must preserve: fill char, SGR attr continuity past
# the content end, valign gap painting, alpha blending (which must NOT take the
# bulk path), and wide fill chars under full_unicode (ditto).

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "content-exhausted fill tail" do
  it "fills the tail with the fill char and leaves content intact" do
    s = headless_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: "hello"
    w.style.fill_char = '.'
    s.repaint
    String.build { |io| 5.times { |x| io << s.lines[0][x].char } }.should eq "hello"
    s.lines[0][10].char.should eq '.'
    s.lines[3][7].char.should eq '.' # a row fully past the content
  end

  it "keeps a dangling SGR attribute across the filled tail" do
    s = headless_screen
    Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4,
      content: "\e[41mx" # red bg opened, never closed
    s.repaint
    red = Attr.bg(s.lines[0][0].attr)
    red.should_not eq Attr.bg(Window::DEFAULT_ATTR)
    # The dangling attr keeps painting the fill cells, rows later.
    Attr.bg(s.lines[0][10].attr).should eq red
    Attr.bg(s.lines[2][5].attr).should eq red
  end

  it "paints the valign gap and the padding bands" do
    s = headless_screen
    Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6,
      content: "x", align: Tput::AlignFlag::Bottom,
      style: Style.new(padding: 1, fill_char: '.')
    s.repaint
    s.lines[0][5].char.should eq '.' # top padding band
    s.lines[2][5].char.should eq '.' # valign gap row (interior)
    s.lines[1][0].char.should eq '.' # left padding band
    s.lines[4][1].char.should eq 'x' # content landed at the bottom interior row
  end

  it "still blends per cell for an alpha widget's tail" do
    s = headless_screen
    Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      style: Style.new(bg: 0x0000ff)
    Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: "x", style: Style.new(bg: 0xff0000, opacity: 0.5)
    s.repaint
    # A tail cell of the translucent overlay must show a mix, not the overlay's
    # own bg (bulk fill would stamp the raw attr over the backdrop).
    mixed = Attr.bg s.lines[2][10].attr
    mixed.should_not eq Attr.bg(sattr_of(s, 0x0000ff))
    mixed.should_not eq Attr.bg(sattr_of(s, 0xff0000))
  end

  it "lays a wide fill char one per cell under full_unicode (no continuation claim)" do
    # Fill cells have `has_content == false`, so the content loop never
    # measures or clusters them: a wide fill char occupies every cell as its
    # own lead, with no continuation cells — on the bulk path exactly as on
    # the per-cell path. (Whether that per-cell layout is itself desirable is a
    # separate question; this pins that the bulk fill matches it.)
    s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, full_unicode: true)
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 2
    w.style.fill_char = '好'
    s.repaint
    s.lines[1][0].char.should eq '好'
    s.lines[1][1].char.should eq '好'
    s.lines[1][5].char.should eq '好'
  end
end

# Packs a bare bg color the way the render path does, for attr comparison.
private def sattr_of(s, bg : Int32) : Int64
  Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(bg))
end
