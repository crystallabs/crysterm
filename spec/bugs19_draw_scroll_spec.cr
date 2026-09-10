require "./spec_helper"

include Crysterm

# Regression specs for two contracts:
#
# * `Window#draw` tracks the terminal's real SGR state: each row starts from
#   the bare `\e[m` reset state (`Window::DEFAULT_ATTR`), so cells whose attr
#   equals a non-default `Window#default_attr` still get their SGR emitted, a
#   row ending in such an attr still gets its trailing reset, and the BCE
#   clear-to-EOL look-ahead never treats decorated blanks as `el`-erasable.
# * `Widget#csr_region_for` rejects a degenerate band (`top > bottom`, as
#   produced when a scrollable ancestor's viewport clips the painted rows
#   below the widget's own insets), and `Widget#scroll` uses the CSR line-op
#   fast path only when the scroll distance fits within the painted band —
#   otherwise the scroll falls back to the ordinary repaint.

# Spec-only access to the protected CSR band validator.
class Crysterm::Widget
  # :nodoc:
  def spec_csr_region_for(top : Int32, bottom : Int32) : {Int32, Int32}?
    csr_region_for(top, bottom)
  end
end

# All DECSTBM (`\e[<top>;<bottom>r`) parameter pairs in *bytes*, as integers.
private def b19_scroll_regions(bytes : String) : Array({Int32, Int32})
  bytes.scan(/\e\[(\d+);(\d+)r/).map { |m| {m[1].to_i, m[2].to_i} }
end

describe "draw with a non-default window default_attr" do
  it "emits the SGR for cells whose attr equals default_attr, and resets at row end" do
    w = headless_screen(40, 5)
    outbuf = w.output.as(IO::Memory)
    red = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0xAA0000))
    w.default_attr = red
    outbuf.clear

    w.fill_region red, 'x', 0, w.awidth, 1, 2
    w.draw

    # The exact set sequence the engine produces for this attr at the window's
    # output depth.
    expected = IO::Memory.new
    SGR.write(expected, red, w.color_count)
    sgr = expected.to_s
    sgr.empty?.should be_false

    s = outbuf.to_s
    # The terminal is in the bare reset state at row start, so the coloured
    # cells must be preceded by their SGR even though their attr equals the
    # window's default_attr.
    s.includes?(sgr).should be_true
    # And a row whose last cell carries that attr must not leak it into the
    # next row: a reset follows the coloured run.
    i = s.rindex!(sgr)
    s.index("\e[m", i + sgr.size).nil?.should be_false

    w.destroy
  end

  it "does not el-clear decorated blanks whose attr equals default_attr" do
    w = headless_screen(40, 5)
    w.optimization = Crysterm::OptimizationFlag::BCE
    outbuf = w.output.as(IO::Memory)
    ul = Attr.pack(Attr::UNDERLINE, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    w.default_attr = ul

    # Previous frame: visible content on row 1.
    w.fill_region ul, 'x', 0, w.awidth, 1, 2
    w.draw
    outbuf.clear

    # This frame: the row becomes underlined blanks, attr-equal to
    # default_attr. `el` fills with background only, so the run must be
    # printed with its underline SGR, not erased.
    w.fill_region ul, ' ', 0, w.awidth, 1, 2
    w.draw

    s = outbuf.to_s
    s.includes?("\e[K").should be_false
    s.includes?("\e[4m").should be_true

    w.destroy
  end
end

describe "csr_region_for band validation" do
  it "returns nil for an inverted or off-screen band, a tuple for a valid one" do
    s = headless_screen(40, 12)
    w = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 6,
      scrollable: true
    w.set_content((1..40).map { |i| "line #{i}" }.join('\n'))
    s.repaint

    # Inverted band: names no rows, so no CSR region.
    w.spec_csr_region_for(3, 2).nil?.should be_true
    # Degenerate band at the screen edge.
    w.spec_csr_region_for(s.aheight, s.aheight - 1).nil?.should be_true
    # Valid bands (single-row and multi-row) still pass.
    w.spec_csr_region_for(2, 2).should eq({2, 2})
    w.spec_csr_region_for(2, 3).should eq({2, 3})
  ensure
    s.try &.destroy
  end

  it "a widget clipped to fewer rows than its insets scrolls without an inverted DECSTBM" do
    s = headless_screen(40, 12)
    container = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 6,
      scrollable: true
    inner = Widget::Box.new parent: container, top: 4, left: 0, width: "100%", height: 8,
      scrollable: true, style: Style.new(border: true)
    inner.set_content((1..40).map { |i| "line #{i}" }.join('\n'))
    s.repaint
    outbuf = s.output.as(IO::Memory)
    outbuf.clear

    # Only 2 of the bordered widget's rows are painted (the container's
    # viewport clips the rest), so its band is degenerate: the scroll must
    # fall back to a repaint instead of emitting an inverted scroll region
    # or desyncing the cell buffer.
    inner.scroll(1, true) # must not raise
    s.repaint

    inner.child_base.should be > 0
    b19_scroll_regions(outbuf.to_s).all? { |(t, b)| t <= b }.should be_true
    s.cell_rows.size.should eq s.aheight
  ensure
    s.try &.destroy
  end

  it "bounds the CSR fast path by the painted band, not the spec row count" do
    s = headless_screen(40, 12)
    container = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 6,
      scrollable: true
    inner = Widget::Box.new parent: container, top: 4, left: 0, width: "100%", height: 8,
      scrollable: true
    inner.set_content((1..40).map { |i| "line #{i}" }.join('\n'))
    s.repaint
    outbuf = s.output.as(IO::Memory)
    outbuf.clear

    # The painted band is rows 4..5 (2 rows; the container clips the rest of
    # the widget's 8 spec rows). A 1-row scroll fits the band and may use the
    # CSR line ops.
    inner.scroll(1, true)
    s.repaint
    b19_scroll_regions(outbuf.to_s).includes?({5, 6}).should be_true

    outbuf.clear

    # A 3-row scroll exceeds the 2-row painted band (while staying under the
    # spec-based visible row count of 8): no line op can preserve any painted
    # row, so the scroll must repaint instead of emitting CSR ops.
    inner.scroll(3, true) # must not raise
    s.repaint
    b19_scroll_regions(outbuf.to_s).empty?.should be_true
    s.cell_rows.size.should eq s.aheight
  ensure
    s.try &.destroy
  end
end
