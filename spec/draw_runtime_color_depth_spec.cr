require "./spec_helper"

include Crysterm

# `Window#draw` reduces each cell's SGR colors to the output terminal's color
# depth. `Screen#colors` resolves that depth fresh (honoring the `colors.depth`
# config/env override "applied at any point"), but `draw` used to read the
# frozen `caps.ncolors` snapshot taken once at `compute_draw_caps` — so a depth
# changed at runtime (e.g. toggling truecolor) never reached the wire. `draw`
# must use the live depth.
private def color_screen(buf)
  s = Crysterm::Window.new(input: IO::Memory.new, output: buf, error: IO::Memory.new,
    width: 6, height: 1)
  s.alloc
  s
end

describe "Window#draw runtime color depth" do
  it "reduces SGR colors to a depth changed after construction" do
    buf = IO::Memory.new
    s = color_screen buf
    begin
      tc = Attr.pack(0, Attr.pack_color(0x123456), Attr::COLOR_DEFAULT)
      s.lines[0][0].attr = tc
      s.lines[0][0].char = 'X'
      s.lines[0].dirty = true

      # Sanity: at the default (auto/truecolor here) depth, a 24-bit SGR is emitted.
      buf.clear
      s.draw
      pending! "environment is not truecolor" unless s.colors >= 0x1000000
      buf.to_s.should contain("38;2;") # truecolor form

      # Pin the depth to 16 colors at runtime.
      Config.colors_depth = Crysterm::ColorDepth::Ansi
      s.colors.should eq 16

      # Re-emit the same cell (poison @olines so it differs) and confirm the
      # color is now reduced — no 24-bit sequence survives.
      s.olines[0][0].char = '?'
      s.lines[0].dirty = true
      buf.clear
      s.draw
      buf.to_s.should_not contain("38;2;")
    ensure
      Config.colors_depth = Crysterm::ColorDepth::Auto
    end
  end
end
