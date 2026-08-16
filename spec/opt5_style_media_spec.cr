require "./spec_helper"

include Crysterm

# Pinning specs for four style/media items:
#
# * O5-20 — `Style#initialize` passes the raw `border`/`padding`/`margin`/
#   `shadow` argument straight to the `X=` setter (one coercion, not two) —
#   these specs pin that construction still produces the exact same `Style`
#   for every currently-accepted argument type of each property.
# * O5-29 — `Style#without_border` (border-only strip, unlike the full
#   `#stripped_frame`) and `GroupBox` routing its `::title` sub-style memo
#   through it via `Style.memo_derive`.
# * O5-34 — the shared `Media::Graphics#dither=` (hoisted out of
#   `Media::Sixel`/`Media::Regis`, which had byte-identical bodies).
# * O5-36 — `TextBlock#slice`/`#format_runs` sharing one private
#   `#each_fragment_overlap` walk.

private def border_fields(b : Crysterm::Border)
  {b.type, b.left, b.top, b.right, b.bottom}
end

private def padding_fields(p : Crysterm::Padding)
  {p.left, p.top, p.right, p.bottom}
end

private def margin_fields(m : Crysterm::Margin)
  {m.left, m.top, m.right, m.bottom}
end

private def shadow_fields(sh : Crysterm::Shadow)
  {sh.left, sh.top, sh.right, sh.bottom, sh.opacity}
end

describe "O5-20: Style constructor coerces border/padding/margin/shadow exactly once" do
  it "matches the setter's result for every accepted `border:` argument type" do
    values = [nil, true, false, Crysterm::BorderType::Double, Crysterm::Border.ltrb(2, 3, 4, 5),
              Crysterm::Side::Left, :right, 3]
    values.each do |v|
      via_ctor = Crysterm::Style.new(border: v)
      via_setter = Crysterm::Style.new
      via_setter.border = v
      border_fields(via_ctor.border).should eq border_fields(via_setter.border)
      # A ctor named-arg `nil` means "omitted" (the same convention as the
      # ctor's boolean args), so it leaves the property unspecified — unlike
      # the setter, where an explicit `nil` assignment stamps the mask.
      via_ctor.specified?(:border).should eq !v.nil?
      via_setter.specified?(:border).should be_true
    end
    # An already-typed `Border` passed through the ctor keeps its identity —
    # a single coercion (`Border.from` on a `Border` is the identity arm)
    # behaves exactly like the old double coercion did.
    b = Crysterm::Border.ltrb(2, 3, 4, 5)
    Crysterm::Style.new(border: b).border.same?(b).should be_true
  end

  it "matches the setter's result for every accepted `padding:` argument type" do
    values = [nil, true, false, Crysterm::Padding.ltrb(1, 2, 3, 4),
              Crysterm::Side::Top, :bottom, 5, {2, 3}, {1, 2, 3, 4}]
    values.each do |v|
      via_ctor = Crysterm::Style.new(padding: v)
      via_setter = Crysterm::Style.new
      via_setter.padding = v
      padding_fields(via_ctor.padding).should eq padding_fields(via_setter.padding)
      # `nil` in the ctor = omitted (unspecified); see the `border:` example.
      via_ctor.specified?(:padding).should eq !v.nil?
      via_setter.specified?(:padding).should be_true
    end
    p = Crysterm::Padding.ltrb(1, 2, 3, 4)
    Crysterm::Style.new(padding: p).padding.same?(p).should be_true
  end

  it "matches the setter's result for every accepted `margin:` argument type" do
    values = [nil, true, false, Crysterm::Margin.ltrb(1, 2, 3, 4),
              Crysterm::Side::Top, :bottom, 5, {2, 3}, {1, 2, 3, 4}]
    values.each do |v|
      via_ctor = Crysterm::Style.new(margin: v)
      via_setter = Crysterm::Style.new
      via_setter.margin = v
      margin_fields(via_ctor.margin).should eq margin_fields(via_setter.margin)
      # `nil` in the ctor = omitted (unspecified); see the `border:` example.
      via_ctor.specified?(:margin).should eq !v.nil?
      via_setter.specified?(:margin).should be_true
    end
    m = Crysterm::Margin.ltrb(1, 2, 3, 4)
    Crysterm::Style.new(margin: m).margin.same?(m).should be_true
  end

  it "matches the setter's result for every accepted `shadow:` argument type" do
    values = [nil, true, false, Crysterm::Shadow.ltrb(1, 1, 1, 1),
              Crysterm::Side::Right, :left, 2.5, 2]
    values.each do |v|
      via_ctor = Crysterm::Style.new(shadow: v)
      via_setter = Crysterm::Style.new
      via_setter.shadow = v
      shadow_fields(via_ctor.shadow).should eq shadow_fields(via_setter.shadow)
      # `nil` in the ctor = omitted (unspecified); see the `border:` example.
      via_ctor.specified?(:shadow).should eq !v.nil?
      via_setter.specified?(:shadow).should be_true
    end
    sh = Crysterm::Shadow.ltrb(1, 1, 1, 1)
    Crysterm::Style.new(shadow: sh).shadow.same?(sh).should be_true
  end
end

describe "O5-29: Style#without_border / GroupBox title-style memo" do
  it "clears only the border, leaving padding/fg/etc untouched" do
    src = Crysterm::Style.new(border: true, padding: 2, fg: "#ff0000")
    copy = src.without_border
    copy.border.left.should eq 0
    copy.border.top.should eq 0
    copy.border.right.should eq 0
    copy.border.bottom.should eq 0
    copy.padding.left.should eq 2
    copy.fg.should eq 0xff0000
    # The source is untouched.
    src.border.left.should eq 1
  end

  it "GroupBox pushes a border-stripped, padding/color-preserving copy of style.title onto its label" do
    s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, width: 40, height: 10, default_quit_keys: false)
    s.stylesheet = "GroupBox::title { border: solid; padding: 1; color: #ff0000; }"
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", width: 30, height: 8
    s.repaint

    copy1 = gb.@_title_style_copy
    copy1.should_not be_nil
    c1 = copy1.not_nil!
    c1.border.left.should eq 0                                       # border stripped
    c1.padding.left.should eq 1                                      # padding kept
    c1.fg.should eq 0xff0000                                         # label color kept
    gb.@label_widget.not_nil!.styles.normal.same?(c1).should be_true # actually pushed

    # Stable across frames while `style.title` is untouched.
    s.repaint
    gb.@_title_style_copy.not_nil!.same?(c1).should be_true

    # An in-place mutation of `style.title` (no object swap) still refreshes
    # the memo — this is exactly what routing through `Style.memo_derive`
    # (rather than a plain `same?` check) buys over the old hand-rolled memo.
    # The mutation itself is invisible to damage tracking (no setter fires),
    # so route it through `#restyle`, which marks the widget dirty after the
    # in-place write; the fingerprint then catches the change when the widget
    # re-renders.
    gb.restyle &.title.fg = "#00ff00"
    s.repaint
    c2 = gb.@_title_style_copy.not_nil!
    c2.same?(c1).should be_false
    c2.fg.should eq 0x00ff00
    c2.border.left.should eq 0  # still stripped
    c2.padding.left.should eq 1 # still kept
  ensure
    s.try &.destroy
  end
end

# A left-to-right red gradient — sensitive enough to the dither mode that
# `Dither::Auto` and `Dither::None` encode to different payload bytes.
private def dither_gradient_bitmap(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array(Array(PNGGIF::Pixel)).new(h) do
    Array(PNGGIF::Pixel).new(w) { |x| PNGGIF::Pixel.new((x * 255 // (w - 1)).to_u8, 0u8, 0u8, 255u8) }
  end
end

# Exposes the private per-frame payload cache so its drop/retention can be
# pinned directly, mirroring `SixelProbe` in bugs16_capture_sixel_spec.cr.
private class SixelDitherProbe < Crysterm::Widget::Media::Sixel
  def probe_payload_geom
    @payload_geom
  end

  def probe_frame_payloads
    @frame_payloads
  end
end

private class RegisDitherProbe < Crysterm::Widget::Media::Regis
  def probe_payload_geom
    @payload_geom
  end

  def probe_frame_payloads
    @frame_payloads
  end
end

describe "O5-34: Media::Graphics#dither= (shared by Sixel and Regis)" do
  it "Sixel: drops the payload cache on a real dither change, no-ops on the same value" do
    s = headless_screen(20, 10)
    img = SixelDitherProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = dither_gradient_bitmap(40, 60)
    s.repaint

    img.probe_payload_geom.should_not be_nil
    img.probe_frame_payloads.empty?.should be_false

    img.dither = img.dither # already Auto — no-op
    img.probe_payload_geom.should_not be_nil

    img.dither = Crysterm::Widget::Media::Dither::None # real change
    img.probe_payload_geom.should be_nil
    img.probe_frame_payloads.empty?.should be_true

    s.repaint # re-encodes under the new mode instead of raising/staying empty
    img.probe_frame_payloads.empty?.should be_false
  ensure
    s.try &.destroy
  end

  it "Regis: drops the payload cache on a real dither change, no-ops on the same value" do
    s = headless_screen(20, 10)
    img = RegisDitherProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = dither_gradient_bitmap(40, 60)
    s.repaint

    img.probe_payload_geom.should_not be_nil
    img.probe_frame_payloads.empty?.should be_false

    img.dither = img.dither # already None — no-op
    img.probe_payload_geom.should_not be_nil

    img.dither = Crysterm::Widget::Media::Dither::Auto # real change
    img.probe_payload_geom.should be_nil
    img.probe_frame_payloads.empty?.should be_true

    s.repaint
    img.probe_frame_payloads.empty?.should be_false
  ensure
    s.try &.destroy
  end
end

describe "O5-36: TextBlock#slice / #format_runs share one fragment-overlap walk" do
  fmt_bold = Crysterm::TextCharFormat.new(bold: true)
  fmt_italic = Crysterm::TextCharFormat.new(italic: true)
  fmt_plain = Crysterm::TextCharFormat.default

  block = Crysterm::TextBlock.new([
    Crysterm::TextFragment.new("Hello", fmt_bold),
    Crysterm::TextFragment.new(" World", fmt_italic),
    Crysterm::TextFragment.new("!!!", fmt_plain),
  ])

  it "block is 14 codepoints across 3 fragments" do
    block.size.should eq 14
    block.fragments.size.should eq 3
  end

  it "slice: mid-range spanning multiple fragments, end-exclusive" do
    sl = block.slice(3, 10)
    sl.text.should eq "lo Worl"
    sl.fragments.map(&.format).should eq [fmt_bold, fmt_italic]
  end

  it "slice: the full range is an equivalent copy" do
    sl = block.slice(0, block.size)
    sl.text.should eq block.text
    sl.fragments.map(&.format).should eq block.fragments.map(&.format)
  end

  it "slice: starting exactly at a fragment boundary" do
    block.slice(5, 11).text.should eq " World"
  end

  it "slice: a degenerate (empty) range yields an empty block, at a boundary or mid-fragment" do
    block.slice(0, 0).text.should eq ""
    block.slice(5, 5).text.should eq "" # exact boundary between fragments
    block.slice(2, 2).text.should eq "" # strictly inside a fragment
  end

  it "format_runs: full range returns one run per fragment with exact bounds" do
    block.format_runs(0, block.size).should eq [
      {0, 5, fmt_bold},
      {5, 11, fmt_italic},
      {11, 14, fmt_plain},
    ]
  end

  it "format_runs: a partial range clips the edge fragments and drops the untouched one" do
    block.format_runs(3, 10).should eq [
      {3, 5, fmt_bold},
      {5, 10, fmt_italic},
    ]
  end

  it "format_runs: a degenerate range exactly at a fragment boundary yields nothing" do
    block.format_runs(5, 5).should eq [] of {Int32, Int32, Crysterm::TextCharFormat}
  end

  it "format_runs: a degenerate range strictly inside a fragment yields one zero-width run" do
    block.format_runs(2, 2).should eq [{2, 2, fmt_bold}]
  end
end
