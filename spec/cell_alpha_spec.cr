require "./spec_helper"

include Crysterm

# Step 4: per-cell, per-channel alpha *modes* stored in the free high bits of the
# packed `Int64` attr, plus the `Colors.composite` fold a plane compositor uses.

describe Crysterm::Attr do
  it "defaults to Opaque/Opaque, leaving pre-alpha attrs bit-identical" do
    a = Attr.pack(Attr::BOLD, Attr.pack_color(0xff0000), Attr.pack_color(0x00ff00))
    Attr.fg_alpha(a).should eq Attr::Alpha::Opaque
    Attr.bg_alpha(a).should eq Attr::Alpha::Opaque
    (a >> Attr::FG_ALPHA_SHIFT).should eq 0 # nothing above the flags
  end

  it "stores and reads back per-channel alpha modes without disturbing colors/flags" do
    a = Attr.pack(Attr::BOLD | Attr::ITALIC, Attr.pack_color(0x112233), Attr.pack_color(0x445566))
    a = Attr.with_fg_alpha(a, Attr::Alpha::Blend)
    a = Attr.with_bg_alpha(a, Attr::Alpha::HighContrast)
    Attr.fg_alpha(a).should eq Attr::Alpha::Blend
    Attr.bg_alpha(a).should eq Attr::Alpha::HighContrast
    Attr.flags(a).should eq(Attr::BOLD | Attr::ITALIC)
    Attr.unpack_color(Attr.fg(a)).should eq 0x112233
    Attr.unpack_color(Attr.bg(a)).should eq 0x445566
  end

  it "round-trips all four modes on both channels" do
    {Attr::Alpha::Opaque, Attr::Alpha::Blend, Attr::Alpha::Transparent, Attr::Alpha::HighContrast}.each do |m|
      Attr.fg_alpha(Attr.with_fg_alpha(0_i64, m)).should eq m
      Attr.bg_alpha(Attr.with_bg_alpha(0_i64, m)).should eq m
    end
  end

  it "masks stray high bits out of flags (so alpha can't leak in)" do
    Attr.flags(Attr.pack(0x40, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)).should eq 0 # bit 6 dropped
  end
end

describe "SGR conversion ignores alpha modes" do
  it "emits no SGR for the alpha bits" do
    a = Attr.pack(Attr::BOLD, Attr.pack_color(0xff0000), Attr::COLOR_DEFAULT)
    with_alpha = Attr.with_fg_alpha(a, Attr::Alpha::Blend)
    plain = IO::Memory.new
    alpha = IO::Memory.new
    Crysterm::Screen.code2attr_to(plain, a, 0x1000000)
    Crysterm::Screen.code2attr_to(alpha, with_alpha, 0x1000000)
    alpha.to_s.should eq plain.to_s
  end
end

describe Crysterm::Colors do
  it "composites Opaque as a plain replace" do
    top = Attr.pack(0, Attr.pack_color(0xff0000), Attr.pack_color(0x00ff00))
    under = Attr.pack(0, Attr.pack_color(0x0000ff), Attr.pack_color(0x222222))
    Colors.composite(top, under).should eq top
  end

  it "composites Transparent by showing the channel beneath" do
    top = Attr.with_fg_alpha(Attr.pack(0, Attr.pack_color(0xff0000), Attr.pack_color(0x00ff00)), Attr::Alpha::Transparent)
    under = Attr.pack(0, Attr.pack_color(0x0000ff), Attr.pack_color(0x222222))
    r = Colors.composite(top, under)
    Attr.unpack_color(Attr.fg(r)).should eq 0x0000ff # under (transparent fg)
    Attr.unpack_color(Attr.bg(r)).should eq 0x00ff00 # top (opaque bg)
  end

  it "composites Blend as a 50/50 mix" do
    top = Attr.with_bg_alpha(Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0xff0000)), Attr::Alpha::Blend)
    under = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0x0000ff))
    Attr.unpack_color(Attr.bg(Colors.composite(top, under))).should eq 0x7f007f
  end

  it "produces an Opaque (flattened) result" do
    top = Attr.with_alpha(Attr.pack(0, Attr.pack_color(0x111111), Attr.pack_color(0x222222)), Attr::Alpha::Blend, Attr::Alpha::HighContrast)
    under = Attr.pack(0, Attr.pack_color(0x333333), Attr.pack_color(0xeeeeee))
    r = Colors.composite(top, under)
    Attr.fg_alpha(r).should eq Attr::Alpha::Opaque
    Attr.bg_alpha(r).should eq Attr::Alpha::Opaque
  end
end
