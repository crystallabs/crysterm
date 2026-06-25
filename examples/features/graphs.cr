# IMPRESSIVE DEMO: the block-glyph graphing widgets.
#
# Shows the data-graph family ported from blessed-contrib, rendered with Unicode
# eighth-block glyphs for smooth sub-cell resolution:
#
#   * `Widget::Graph::Bar`        — vertical bar chart (labels, values, colors)
#   * `Widget::Graph::StackedBar` — stacked bars with a color-key legend
#   * `Widget::Gauge`             — horizontal meter, single and stacked
#   * a one-row `Bar` used as a sparkline
#
# Everything animates off one timer. Press `q` / Ctrl+C to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Graphs"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}blessed-contrib-style graphs — q to quit{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202838")

# ── Vertical bar chart ──────────────────────────────────────────────────────
bar = Widget::Graph::Bar.new \
  parent: s, top: 2, left: 1, width: 38, height: 12,
  label: " Bar ", min: 0.0, max: 100.0,
  bar_width: 4, bar_spacing: 2, show_values: true,
  labels: %w[cpu mem net dsk gpu pwr],
  colors: %w[green cyan yellow magenta blue red],
  style: Style.new(fg: "white", bg: "#101820", border: true)

# ── Stacked bar chart ───────────────────────────────────────────────────────
stacked = Widget::Graph::StackedBar.new \
  parent: s, top: 2, left: 41, width: 38, height: 12,
  label: " StackedBar ", max: 100.0,
  bar_width: 4, bar_spacing: 4,
  colors: %w[green yellow red],
  segment_labels: %w[idle warn crit],
  labels: %w[web db cache mq],
  style: Style.new(fg: "white", bg: "#101820", border: true)

# ── Single gauge ────────────────────────────────────────────────────────────
gauge = Widget::Gauge.new \
  parent: s, top: 15, left: 1, width: 38, height: 3,
  label: " Gauge ", fill_color: "cyan", value: 0,
  style: Style.new(fg: "white", bg: "#101820", border: true)

# ── Stacked gauge ───────────────────────────────────────────────────────────
Widget::Gauge.new \
  parent: s, top: 15, left: 41, width: 38, height: 3,
  label: " Stacked gauge ",
  segments: [
    Widget::Gauge::Segment.new(45, "green", "ok"),
    Widget::Gauge::Segment.new(35, "yellow", "warn"),
    Widget::Gauge::Segment.new(20, "red", "crit"),
  ],
  style: Style.new(fg: "white", bg: "#101820", border: true)

# ── Sparkline (a one-row Bar) ───────────────────────────────────────────────
spark = Widget::Graph::Bar.new \
  parent: s, top: 19, left: 1, width: 78, height: 3,
  label: " Sparkline ", min: 0.0, max: 1.0,
  style: Style.new(fg: "green", bg: "#101820", border: true)

phase = 0.0
s.every(0.12.seconds) do
  # Bars wander around with per-bar sine waves.
  bar.values = Array.new(6) { |i| (Math.sin(phase + i * 0.9) * 0.5 + 0.5) * 100 }

  # Stacked: each bar's three segments breathe a little.
  stacked.values = Array.new(4) do |i|
    a = Math.sin(phase + i) * 20 + 50
    b = Math.cos(phase * 1.3 + i) * 15 + 25
    [a.clamp(5.0, 90.0), b.clamp(5.0, 60.0), 20.0]
  end

  gauge.value = (Math.sin(phase) * 0.5 + 0.5) * 100

  spark.values = Array.new(72) { |i| Math.sin(phase + i * 0.3) * 0.5 + 0.5 }

  phase += 0.25
end

s.exec
