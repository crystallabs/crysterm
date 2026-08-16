# FEATURE: Layout engines.
#
# Crysterm ships a family of Qt-style layout engines — HBox, VBox, Grid (with
# row/column spans), Form (label/field rows), Border (dock to N/S/E/W/center)
# and Wrap (flow with wrapping) — plus Box, Stack, Masonry, UniformGrid,
# Radial and Manual (shown in layouts2.cr). Attach one to any container via
# `layout:`; children are placed and sized for you, with per-child placement
# expressed through `layout_hint:`.
#
# The SAME five children (A-E, one color each) are shown arranged by six
# different engines, one per panel.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Layout engines"

# One color per child; every panel gets an identical set.
CHILD_BG = {
  "A" => 0xE06C75, "B" => 0xE5C07B, "C" => 0x98C379,
  "D" => 0x61AFEF, "E" => 0xC678DD,
}

def child(parent, name, **opts)
  Widget::Box.new **opts, parent: parent, content: "{center}#{name}{/center}", parse_tags: true,
    style: Style.new(fg: "black", bg: CHILD_BG[name])
end

def panel(parent, title)
  Widget::Box.new parent: parent, label: " #{title} ",
    style: Style.new(border: true, fg: "#c0caf5", bg: "#10141c")
end

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}One set of five children, six layout engines{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

# The six panels are themselves laid out by a Grid — no manual geometry anywhere.
root = Widget::Box.new parent: s, top: 1, left: 0, width: "100%", height: "100%-1",
  layout: Layout::Grid.new(columns: 3)

# HBox: children share the row equally, stretched to full height.
p1 = panel root, "HBox"
p1.layout = Layout::HBox.new
%w[A B C D E].each { |n| child p1, n }

# VBox: same, stacked vertically.
p2 = panel root, "VBox"
p2.layout = Layout::VBox.new
%w[A B C D E].each { |n| child p2, n }

# Grid: 3 columns; A takes a 2-column span, the rest auto-flow row-major.
p3 = panel root, "Grid"
p3.layout = Layout::Grid.new(columns: 3)
child p3, "A", layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, column_span: 2)
%w[B C D E].each { |n| child p3, n }

# Form: label/field pairs, one per row; the trailing unpaired child spans.
p4 = panel root, "Form"
p4.layout = Layout::Form.new(label_width: 8)
%w[A B C D].each { |n| child p4, n, height: 1 }
child p4, "E", height: 1

# Border: each child docked to an edge (or the center) by a Border::Hint.
p5 = panel root, "Border"
p5.layout = Layout::Dock.new
child p5, "A", height: 1, layout_hint: Layout::Dock::Hint.new(:top)
child p5, "B", height: 1, layout_hint: Layout::Dock::Hint.new(:bottom)
child p5, "C", width: 6, layout_hint: Layout::Dock::Hint.new(:left)
child p5, "D", width: 6, layout_hint: Layout::Dock::Hint.new(:right)
child p5, "E", layout_hint: Layout::Dock::Hint.new(:center)

# Wrap: fixed-size children flow left-to-right and wrap onto new lines.
p6 = panel root, "Wrap"
p6.layout = Layout::Wrap.new
%w[A B C D E].each { |n| child p6, n, width: 7, height: 2 }

s.exec
