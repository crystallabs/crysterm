require "./spec_helper"

include Crysterm

# Specs for the TrueColor-native color model: `Colors` (parsing, mixing, and
# colorspace-aware SGR output) and `Attr` (Int64 fg/bg/flags packing).
describe Crysterm::Colors do
  describe ".convert" do
    it "parses hex strings into 24-bit RGB ints" do
      Colors.convert("#ff8800").should eq 0xff8800
      Colors.convert("#fff").should eq 0xffffff # short form expands
    end

    it "parses color names into their RGB value" do
      Colors.convert("red").should eq 0xcd0000
      Colors.convert("default").should eq -1
    end

    it "passes through native ints and packs rgb tuples/arrays" do
      Colors.convert(0x123456).should eq 0x123456
      Colors.convert(-1).should eq -1
      Colors.convert({16, 32, 48}).should eq 0x102030
      Colors.convert([255, 0, 255]).should eq 0xff00ff
    end
  end

  describe ".sgr_color" do
    it "emits TrueColor sequences when the terminal supports 16M colors" do
      Colors.sgr_color(0xff8800, true, 0x1000000).should eq "38;2;255;136;0"
      Colors.sgr_color(0x102030, false, 0x1000000).should eq "48;2;16;32;48"
    end

    it "reduces to the 256-color palette" do
      Colors.sgr_color(0xff8800, true, 256).should eq "38;5;208"
    end

    it "reduces to 16/8-color ANSI codes" do
      Colors.sgr_color(0xcd0000, true, 16).should eq "31"  # red fg
      Colors.sgr_color(0xcd0000, false, 16).should eq "41" # red bg
    end

    it "emits the default color code for -1" do
      Colors.sgr_color(-1, true, 0x1000000).should eq "39"
      Colors.sgr_color(-1, false, 256).should eq "49"
    end
  end

  describe ".sgr_color_to" do
    # The allocation-free IO variant must produce byte-for-byte what the
    # String-returning `sgr_color` does, across every encoding depth.
    it "matches sgr_color for every color/depth/ground combination" do
      colors = [0x1000000, 256, 16, 8]
      values = [0xff8800, 0x102030, 0xcd0000, 0x000000, 0xffffff, -1]
      colors.each do |n|
        values.each do |v|
          {true, false}.each do |fg|
            io = IO::Memory.new
            Colors.sgr_color_to(io, v, fg, n)
            io.to_s.should eq Colors.sgr_color(v, fg, n)
          end
        end
      end
    end
  end

  describe ".mix" do
    it "mixes two RGB colors in RGB space" do
      Colors.mix(0x000000, 0xffffff, 0.5).should eq 0x7f7f7f
      Colors.mix(0xff0000, 0x0000ff, 0.5).should eq 0x7f007f
      Colors.mix(0x102030, 0x102030, 0.5).should eq 0x102030
    end
  end

  describe ".blend" do
    it "alpha-composites the fg and bg of two attrs" do
      a = Attr.pack(0, Attr.pack_color(0x000000), Attr.pack_color(0x000000))
      b = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0xffffff))
      blended = Colors.blend(a, b, 0.5)
      Attr.unpack_color(Attr.fg(blended)).should eq 0x7f7f7f
      Attr.unpack_color(Attr.bg(blended)).should eq 0x7f7f7f
    end

    it "leaves a default color untouched when there is nothing to mix it with" do
      a = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0x808080))
      blended = Colors.blend(a, nil, 0.5)
      Attr.unpack_color(Attr.fg(blended)).should eq -1       # default stays default
      Attr.unpack_color(Attr.bg(blended)).should eq 0x404040 # darkened toward black
    end
  end

  describe ".tint" do
    it "overlays the fg and bg toward the tint color by the given strength" do
      a = Attr.pack(0, Attr.pack_color(0x000000), Attr.pack_color(0x000000))
      tinted = Colors.tint(a, 0xffffff, 0.5) # halfway toward white
      Attr.unpack_color(Attr.fg(tinted)).should eq 0x7f7f7f
      Attr.unpack_color(Attr.bg(tinted)).should eq 0x7f7f7f
    end

    it "is a no-op for an unknown (-1) tint color instead of washing toward white" do
      # A tint color of -1 (e.g. a `style.tint` set from a color string that did
      # not parse) has nothing to tint toward, so the attr must come back
      # unchanged — not blended toward 0xFFFFFF as a raw `mix(-1, ...)` would.
      a = Attr.pack(Attr::BOLD, Attr.pack_color(0x102030), Attr.pack_color(0x405060))
      Colors.tint(a, -1, 0.5).should eq a
    end
  end
end

describe Crysterm::Attr do
  it "round-trips fg, bg and flags through pack/unpack" do
    a = Attr.pack(Attr::BOLD | Attr::UNDERLINE, Attr.pack_color(0xff8800), Attr.pack_color(0x102030))

    Attr.unpack_color(Attr.fg(a)).should eq 0xff8800
    Attr.unpack_color(Attr.bg(a)).should eq 0x102030
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    (Attr.flags(a) & Attr::UNDERLINE).should_not eq 0
    (Attr.flags(a) & Attr::BLINK).should eq 0
  end

  it "represents the terminal default color with a sentinel" do
    field = Attr.pack_color(-1)
    Attr.default?(field).should be_true
    Attr.unpack_color(field).should eq -1
  end

  it "keeps full 24-bit precision (white does not collide with the default sentinel)" do
    a = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0xffffff))
    Attr.unpack_color(Attr.fg(a)).should eq 0xffffff
    Attr.unpack_color(Attr.bg(a)).should eq 0xffffff
    Attr.default?(Attr.fg(a)).should be_false
  end

  describe ".hsv_i" do
    it "yields the packed 0xRRGGBB int for the primary hues" do
      Colors.hsv_i(0).should eq 0xff0000
      Colors.hsv_i(120).should eq 0x00ff00
      Colors.hsv_i(240).should eq 0x0000ff
    end

    it "honours saturation and value" do
      Colors.hsv_i(0, 0.0, 1.0).should eq 0xffffff # no saturation -> white
      Colors.hsv_i(0, 1.0, 0.0).should eq 0x000000 # no value -> black
    end

    # Behavior-lock: `hsv` is just `hsv_i` formatted, delegated to the
    # `TermColors` shard, which *rounds* each channel via `clamp_byte`
    # (`value.round.to_i.clamp(0, 255)`) rather than truncating. This reference
    # mirrors that rounding so the lock tracks the shard's intended behavior.
    it "stays byte-for-byte compatible with the hsv string formatting" do
      old = ->(h : Float64, s : Float64, v : Float64) {
        hh = h % 360.0
        hh += 360.0 if hh < 0
        c = v * s
        x = c * (1 - (((hh / 60.0) % 2) - 1).abs)
        m = v - c
        rf, gf, bf = case (hh.to_i // 60) % 6
                     when 0 then {c, x, 0.0}
                     when 1 then {x, c, 0.0}
                     when 2 then {0.0, c, x}
                     when 3 then {0.0, x, c}
                     when 4 then {x, 0.0, c}
                     else        {c, 0.0, x}
                     end
        r = ((rf + m) * 255).round.to_i.clamp(0, 255)
        g = ((gf + m) * 255).round.to_i.clamp(0, 255)
        b = ((bf + m) * 255).round.to_i.clamp(0, 255)
        "#%02x%02x%02x" % {r, g, b}
      }
      [-30, 0, 1, 47, 120, 200, 359, 360, 400, 720].each do |h|
        {1.0, 0.5}.each do |s|
          {1.0, 0.3}.each do |v|
            Colors.hsv(h, s, v).should eq old.call(h.to_f, s, v)
          end
        end
      end
    end
  end
end
