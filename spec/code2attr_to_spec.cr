require "./spec_helper"

include Crysterm

# Behavior lock for `Screen.code2attr_to` (packed Int64 attr -> SGR sequence
# written straight into an IO, allocation-free). These pin its output against an
# independent reference that reproduces the previous String-building `code2attr`,
# across the full matrix of flags / colors / color depths, so the hot-path
# version can be trusted to match exactly.
#
# `code2attr_to` is a pure class method (takes the color count directly), so no
# Screen is needed.
describe "Screen.code2attr_to" do
  # Oracle: the old String-building code2attr semantics, expressed via the
  # already-tested `Colors.sgr_color`.
  oracle = ->(code : Int64, n : Int32) do
    flags = Attr.flags(code)
    fg = Attr.unpack_color(Attr.fg(code))
    bg = Attr.unpack_color(Attr.bg(code))
    body = String.build do |o|
      o << "1;" if (flags & Attr::BOLD) != 0
      o << "4;" if (flags & Attr::UNDERLINE) != 0
      o << "5;" if (flags & Attr::BLINK) != 0
      o << "7;" if (flags & Attr::REVERSE) != 0
      o << "8;" if (flags & Attr::INVISIBLE) != 0
      o << "9;" if (flags & Attr::STRIKE) != 0
      if bg != -1
        o << Colors.sgr_color(bg, false, n)
        o << ';'
      end
      if fg != -1
        o << Colors.sgr_color(fg, true, n)
        o << ';'
      end
    end
    body.empty? ? "" : "\e[" + body[0...-1] + "m" # drop trailing ';', add 'm'
  end

  emit = ->(code : Int64, n : Int32) do
    io = IO::Memory.new
    Crysterm::Screen.code2attr_to(io, code, n)
    io.to_s
  end

  dfl = Crysterm::Screen::DEFAULT_ATTR

  codes = {
    "default"        => dfl,
    "bold"           => Attr.pack(Attr::BOLD, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT),
    "strike"         => Attr.pack(Attr::STRIKE, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT),
    "all flags"      => Attr.pack(Attr::BOLD | Attr::UNDERLINE | Attr::BLINK | Attr::REVERSE | Attr::INVISIBLE | Attr::STRIKE, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT),
    "fg only"        => Attr.pack(0, Attr.pack_color(0xff8800), Attr::COLOR_DEFAULT),
    "bg only"        => Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0x102030)),
    "fg + bg"        => Attr.pack(0, Attr.pack_color(0xff8800), Attr.pack_color(0x102030)),
    "bold + fg + bg" => Attr.pack(Attr::BOLD, Attr.pack_color(0x00ff00), Attr.pack_color(0x000080)),
  }

  {2, 8, 16, 256, 0x1000000}.each do |n|
    codes.each do |name, code|
      it "matches code2attr for #{name} at #{n} colors" do
        emit.call(code, n).should eq oracle.call(code, n)
      end
    end
  end

  it "emits nothing for the default attr (matching code2attr's empty string)" do
    emit.call(dfl, 0x1000000).should eq ""
  end

  it "appends to an existing buffer without disturbing prior content" do
    io = IO::Memory.new
    io << "PRE"
    code = Attr.pack(Attr::BOLD, Attr.pack_color(0xff8800), Attr::COLOR_DEFAULT)
    Crysterm::Screen.code2attr_to(io, code, 0x1000000)
    io.to_s.should eq "PRE" + oracle.call(code, 0x1000000)
  end

  it "writes nothing (not even \\e[) into a buffer for the default attr" do
    io = IO::Memory.new
    io << "PRE"
    Crysterm::Screen.code2attr_to(io, dfl, 0x1000000)
    io.to_s.should eq "PRE"
  end
end

describe "Colors.convert_cached" do
  it "matches Colors.convert for named colors, hex, separators, and default" do
    {"red", "blue", "#ff8800", "#fff", "light-gray", "default"}.each do |spec|
      Colors.convert_cached(spec).should eq Colors.convert(spec)
    end
  end

  it "returns the same value on repeated (cached) calls" do
    first = Colors.convert_cached("#abcdef")
    Colors.convert_cached("#abcdef").should eq first
    first.should eq Colors.convert("#abcdef")
  end

  it "handles a nil spec like convert (terminal default)" do
    Colors.convert_cached(nil).should eq -1
  end
end
