require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 findings A4 and A10 — content caches missing
# inputs, leaving stale output on the window.
#
#  A4 (src/widget/graph/line_chart.cr): `refresh_ticks`' cache key didn't
#     include `Axis#label_format`, so changing the format kept the old tick
#     labels until the range or tick count changed.
#
#  A10 (src/widget/gauge.cr, gauge_list.cr): the content-cache keys ignored the
#     glyph-resolution inputs `{style.glyphs, glyph_tier, Glyphs.generation}`,
#     so a tier switch / `Glyphs.set` / CSS `glyphs:` change kept a stale ramp.

private def sc_screen(w = 60, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def sc_text(s) : String
  String.build do |io|
    s.aheight.times do |y|
      s.awidth.times { |x| io << s.lines[y][x].char }
      io << '\n'
    end
  end
end

describe "BUGS13 A4: LineChart tick labels refresh when label_format changes" do
  it "re-formats the tick labels on an Axis#label_format change" do
    s = sc_screen
    chart = Widget::Graph::LineChart.new parent: s, top: 0, left: 0,
      width: 56, height: 18, show_legend: false
    chart.add_line "sig", [{0.0, 0.0}, {1.0, 1.0}]
    s.repaint
    sc_text(s).should_not contain "0.250"

    chart.axis_y.label_format = "%.3f"
    chart.refresh
    s.repaint

    # Range 0..1, 5 ticks -> 0.000 / 0.250 / 0.500 / 0.750 / 1.000.
    sc_text(s).should contain "0.250"
  end
end

describe "BUGS13 A10: Gauge/GaugeList rebuild content when glyph inputs change" do
  it "re-resolves the Gauge fill ramp after a glyph tier switch" do
    s = sc_screen
    Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1,
      value: 100, show_label: false
    s.repaint
    s.lines[0][0].char.should eq '█' # Unicode eighth-block ramp

    s.glyph_tier = Glyphs::Tier::Ascii
    s.repaint
    s.lines[0][0].char.should eq '@' # ASCII density ramp; stale '█' before fix
  end

  it "re-resolves the GaugeList fill ramp after a glyph tier switch" do
    s = sc_screen
    gl = Widget::GaugeList.new parent: s, top: 4, left: 0, width: 20, height: 2
    gl.add_item "x", 100
    s.repaint
    # Row layout: label (1 col) + gap + bar; the bar's first cell is col 2.
    s.lines[4][2].char.should eq '█'

    s.glyph_tier = Glyphs::Tier::Ascii
    s.repaint
    s.lines[4][2].char.should eq '@'
  end
end
