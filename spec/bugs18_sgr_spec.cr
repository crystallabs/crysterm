require "./spec_helper"

include Crysterm

# BUGS18 findings #33, #36 — both in `Screen.sgr_to_attr_impl` (src/screen_attributes.cr),
# the shared SGR parameter-state-machine used by Widget::Terminal's apply_sgr,
# widget_rendering.cr, and widget_content.cr alike.
#
#   #33 — SGR 58 (set underline color) had no `case` arm at all, so its payload
#         parameters (`58;2;r;g;b` / `58;5;n`) fell through and were re-parsed
#         as independent top-level SGR codes: a `0` channel triggered a full
#         attribute reset (SGR 0), `5` turned on blink, and 30..49/90..107
#         channels recolored fg/bg. The colon form (`58:2::r:g:b`) happened to
#         be silently skipped by the residual-colon guard, which is exactly why
#         only the semicolon form (vim's default t_8u for undercurl) corrupted.
#   #36 — the 38/48 extended-color branch consumed only the fields it itself
#         understood (mode + 1 or 3-4 value fields) and discarded each field's
#         colon flag, so any further ITU T.416 trailing sub-parameters (unused
#         / tolerance / tolerance-colorspace) were left for the residual-colon
#         skip guard — which was explicitly disabled for codes 38/48 on the
#         (wrong) assumption the branch always consumed everything — and so
#         leaked into the top-level loop as standalone codes (a stray `0`
#         resets the very attribute the sequence just set).
describe "BUGS18 SGR 58/38/48 sub-parameter consumption (#33/#36)" do
  dfl = Crysterm::Window::DEFAULT_ATTR
  apply = ->(code : String) { Crysterm::Screen.sgr_to_attr(code, dfl, dfl) }
  # Same as `apply` but starting from an attribute that already has bold set
  # and a distinctive fg/bg, so a stray reset/recolor is observable.
  fixture = Attr.pack(Attr::BOLD, Attr.pack_color(0xFF0000_i64), Attr.pack_color(0x00FF00_i64))
  apply_on = ->(code : String) { Crysterm::Screen.sgr_to_attr(code, fixture, dfl) }

  describe "#33 SGR 58 (underline color)" do
    it "does not reset attributes for the truecolor semicolon form (58;2;r;g;b)" do
      # Old bug: 58 (ignored), 2 (ignored), 255 (ignored), 0 -> SGR 0 -> full reset.
      a = apply_on.call("\e[58;2;255;0;0m")
      (Attr.flags(a) & Attr::BOLD).should_not eq 0
      Attr.unpack_color(Attr.fg(a)).should eq 0xFF0000
      Attr.unpack_color(Attr.bg(a)).should eq 0x00FF00
    end

    it "does not turn on blink for the palette semicolon form (58;5;n)" do
      # Old bug: 58 (ignored), 5 -> SGR 5 -> blink on.
      a = apply_on.call("\e[58;5;196m")
      (Attr.flags(a) & Attr::BLINK).should eq 0
      (Attr.flags(a) & Attr::BOLD).should_not eq 0
    end

    it "does not recolor fg via a trailing channel (58;2;r;g;b)" do
      # Old bug: the trailing "30" channel parsed as SGR 30 (black fg).
      a = apply_on.call("\e[58;2;10;20;30m")
      Attr.unpack_color(Attr.fg(a)).should eq 0xFF0000
    end

    it "is a no-op for the colon form (58:2::r:g:b)" do
      a = apply_on.call("\e[58:2::255:0:0m")
      a.should eq fixture
    end

    it "is a no-op for the colon palette form (58:5:n)" do
      a = apply_on.call("\e[58:5:196m")
      a.should eq fixture
    end

    it "drains a colon-form payload but still applies a following semicolon param (58:5:196;1)" do
      a = apply.call("\e[58:5:196;1m")
      (Attr.flags(a) & Attr::BOLD).should_not eq 0
    end

    it "leaves 59 (default underline color) a harmless no-op" do
      a = apply_on.call("\e[59m")
      a.should eq fixture
    end
  end

  describe "#36 SGR 38/48 trailing ITU T.416 sub-parameters" do
    it "does not reset the attribute via a trailing unused/tolerance field (38:2:cs:r:g:b:x:tol)" do
      # Old bug: the leftover "0" field after b parsed as SGR 0 (full reset).
      a = apply_on.call("\e[38:2:0:255:0:0:0:0m")
      Attr.unpack_color(Attr.fg(a)).should eq 0xFF0000
      (Attr.flags(a) & Attr::BOLD).should_not eq 0
    end

    it "does not bold-ify via a trailing field on the 256-color colon form (38:5:196:1)" do
      # Old bug: the leftover "1" field parsed as SGR 1 (bold), a false positive
      # bold that must not appear on an otherwise-unbolded attribute.
      a = apply.call("\e[38:5:196:1m")
      Attr.unpack_color(Attr.fg(a)).should eq Colors.palette_to_rgb(196)
      (Attr.flags(a) & Attr::BOLD).should eq 0
    end

    it "drains trailing fields on an unrecognized mode too (38:6:1:2:3)" do
      # The `else` branch (unknown mode / truncated payload) must also drain
      # its trailing colon sub-parameters, not just the mode-5/mode-2 arms.
      a = apply.call("\e[38:6:1:2:3m")
      (Attr.flags(a) & Attr::BOLD).should eq 0
    end

    it "still applies a following semicolon param after an earlier bold is set (1;38:2:0:255:0:0:0:0)" do
      a = apply.call("\e[1;38:2:0:255:0:0:0:0m")
      (Attr.flags(a) & Attr::BOLD).should_not eq 0
      Attr.unpack_color(Attr.fg(a)).should eq 0xFF0000
    end

    it "keeps the semicolon form unaffected (38;2;255;0;0;1 still applies trailing bold)" do
      a = apply.call("\e[38;2;255;0;0;1m")
      Attr.unpack_color(Attr.fg(a)).should eq 0xFF0000
      (Attr.flags(a) & Attr::BOLD).should_not eq 0
    end
  end
end

private def png(s : String)
  Crysterm::Widget::Media.decode_ansi(s.to_slice)
end

describe "BUGS18 decode_ansi SGR 58 sub-parameter consumption (#33 sibling)" do
  it "does not misread a 58;2;r;g;b payload's trailing 0 as a reset" do
    # Old bug (sibling parser): 58 falls to `else`, its payload bytes re-parse
    # as standalone codes; a 0 channel resets fg/bg/rev.
    with_bold = png("\e[1m\e[31m\e[58;2;255;0;0mX")
    without = png("\e[1m\e[31mX")
    with_bold.bmp[0][0].should eq without.bmp[0][0]
  end

  it "does not recolor via a 58;2;r;g;b trailing 30..47 channel" do
    red_only = png("\e[31m\e[58;2;10;20;30mX")
    red_plain = png("\e[31mX")
    red_only.bmp[0][0].should eq red_plain.bmp[0][0]
  end
end
