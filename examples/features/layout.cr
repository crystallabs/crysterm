# FEATURE: layout engines (grid + inline/masonry).
#
# Any container widget arranges its children automatically once a layout engine
# is installed via `widget.layout = ...`. Crysterm ships `Layout::UniformGrid`
# (tiled, uniform-width cells) and `Layout::Masonry` (masonry-like flow), plus
# `Layout::Grid`/`Layout::HBox`/`Layout::VBox` and more. Two are shown side by
# side; a highlight walks the children so you can see each arrangement.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Layout"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Layout engines:  :grid (left)   vs   :inline / masonry (right){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#304030")

grid = Widget::Box.new \
  parent: s, top: 1, left: 0, width: 39, height: 14,
  layout: Layout::UniformGrid.new, overflow: :ignore

inline = Widget::Box.new \
  parent: s, top: 1, left: 40, width: 39, height: 14,
  layout: Layout::Masonry.new, overflow: :ignore

grid_boxes = [] of Widget::Box
inline_boxes = [] of Widget::Box

base = 0x204060
6.times do |i|
  grid_boxes << Widget::Box.new(
    parent: grid, width: 12, height: 4, align: :hcenter,
    content: "grid #{i + 1}", style: Style.new(fg: "white", bg: base, border: true))
end

sizes = [{18, 4}, {16, 3}, {12, 5}, {20, 3}, {14, 4}, {16, 3}]
sizes.each_with_index do |(w, h), i|
  inline_boxes << Widget::Box.new(
    parent: inline, width: w, height: h, align: :hcenter,
    content: "inline #{i + 1}", style: Style.new(fg: "white", bg: base, border: true))
end

all = grid_boxes + inline_boxes

i = 0
s.every(0.4.seconds) do
  all.each { |b| b.style.bg = base }
  grid_boxes[i % grid_boxes.size].style.bg = 0xa05020
  inline_boxes[i % inline_boxes.size].style.bg = 0xa05020
  i += 1
end

s.exec
