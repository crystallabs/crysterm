# FEATURE: Layout engines, part two.
#
# tests/misc/layouts.cr shows six of the layout engines — HBox, VBox, Grid,
# Form, Border and Wrap. This program shows the remaining ones: Box (the
# single-axis engine behind HBox/VBox, used directly for its justify/align
# knobs), Stack (pages; cycled once per second here), Masonry (wrapping flow
# with upward gravitation), UniformGrid (wrapping flow snapped to uniform
# columns), Manual (no engine — children position themselves) and Radial
# (children on a ring).
#
# The SAME five children (A-E, one color each) are shown arranged by six
# different engines, one per panel.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Layout engines 2"

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
  content: "{center}One set of five children, six more layout engines{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

# The six panels are themselves laid out by a Grid — no manual geometry anywhere.
root = Widget::Box.new parent: s, top: 1, left: 0, width: "100%", height: "100%-1",
  layout: Layout::Grid.new(columns: 3)

# Box: the engine behind HBox/VBox, used directly for its extra knobs — fixed-
# size children don't stretch, so justify spreads the leftover and align
# centers them on the cross axis.
p1 = panel root, "Box (justify/align)"
p1.layout = Layout::Box.new justify: :space_between, align: :center
%w[A B C D E].each { |n| child p1, n, width: 3, height: 3 }

# Stack: all pages occupy the same area; only current_index is shown.
# A timer below cycles the pages, one per second.
p2 = panel root, "Stack"
stack = Layout::Stack.new
p2.layout = stack
%w[A B C D E].each { |n| child p2, n }

# Masonry: children flow and wrap like Wrap, then gravitate up beneath the
# nearest child of the row above — varied heights pack without gaps.
p3 = panel root, "Masonry"
p3.layout = Layout::Masonry.new
{2, 4, 3, 2, 3}.each_with_index { |h, i| child p3, "ABCDE"[i].to_s, width: 8, height: h }

# UniformGrid: wraps like Masonry, but every child snaps to a column of the
# widest child's width — varied widths still land on a regular grid.
p4 = panel root, "UniformGrid"
{5, 8, 6, 4, 7}.each_with_index { |w, i| child p4, "ABCDE"[i].to_s, width: w, height: 2 }
p4.layout = Layout::UniformGrid.new

# Manual: no engine at all — each child resolves its own coordinates
# (a diagonal cascade of absolute positions here).
p5 = panel root, "Manual"
%w[A B C D E].each_with_index { |n, i| child p5, n, left: i * 4, top: i, width: 9, height: 3 }

# Radial: children on a ring, evenly spaced, first at 12 o'clock.
p6 = panel root, "Radial"
p6.layout = Layout::Radial.new
%w[A B C D E].each { |n| child p6, n, width: 7, height: 3 }

# One page per second; five pages, so the 5-second capture loops seamlessly.
s.every(1.second) do
  stack.current_index = (stack.current_index + 1) % 5
end

s.exec
