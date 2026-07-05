require "./spec_helper"

# `Media.decode_ansi` parses `;`-separated decimal CSI parameters by
# accumulating `cur = cur * 10 + digit`. A pathological digit run (10+ digits,
# from a corrupt or oversized parameter) overflowed `Int32` on the multiply and
# raised `OverflowError`, aborting the *entire* decode — even though every
# consumer already range-clamps positions (`clampx`/`clampy`) so an out-of-range
# value should simply clamp. The accumulator now saturates instead of
# overflowing, so such a file still decodes.

describe "Crysterm::Widget::Media.decode_ansi oversized CSI parameter" do
  it "clamps an oversized cursor parameter instead of overflowing Int32" do
    # `ESC[99999999999H` — an 11-digit row parameter (well past Int32 max when
    # accumulated). Followed by a printed glyph so there is content to render.
    png = Crysterm::Widget::Media.decode_ansi("\e[99999999999HX".to_slice)
    png.should be_a(PNGGIF::PNG)
    # A bare glyph decodes to the same 1-cell-wide grid (the CUP row is clamped,
    # the column defaults to 1), so the width matches a plain 'X'.
    png.width.should eq Crysterm::Widget::Media.decode_ansi("X".to_slice).width
  end
end
