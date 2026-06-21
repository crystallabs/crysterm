# FEATURE: layout engines (grid + inline/masonry).
#
# A `Layout` widget arranges its children automatically. Crysterm ships two
# strategies: `:grid` (table-like rows and columns) and `:inline` (masonry-like
# flow). Both are shown side by side; a highlight walks the children so you can
# see the arrangement each engine produces.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Layout"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Layout engines:  :grid (left)   vs   :inline / masonry (right){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#304030")

grid = Widget::Layout.new \
  parent: s, top: 1, left: 0, width: 39, height: 14,
  layout: :grid, overflow: :ignore

inline = Widget::Layout.new \
  parent: s, top: 1, left: 40, width: 39, height: 14,
  layout: :inline, overflow: :ignore

grid_boxes = [] of Widget::Box
inline_boxes = [] of Widget::Box

base = "#204060"
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
  grid_boxes[i % grid_boxes.size].style.bg = "#a05020"
  inline_boxes[i % inline_boxes.size].style.bg = "#a05020"
  i += 1
end

s.exec
