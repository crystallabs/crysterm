# The hello box, animated: the same single box as hello.cr, except it hops to
# a random spot every 2 seconds and its background is a rainbow marquee — the
# hue travels across the cells while the text stays black.
require "../../src/crysterm"

include Crysterm
include Crysterm::Widgets

window = Window.new title: "hello2"

box = Widget::Box.new \
  parent: window,
  top: :center, left: :center, width: 20, height: 5,
  content: "\n{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,
  style: Style.new(fg: "black")

# The rainbow: after the standard box/content pass, repack every cell's
# *background* to the hue at its column, leaving the glyphs and their black
# foreground as rendered. Backgrounds always fill whole cells, so the slab's
# edges land exactly on cell boundaries.
phase = 0
box.paint_handler do |_xi, _xl, _yi, _yl|
  next unless rect = box.absolute_geometry
  rows = window.cell_rows
  (Math.max(rect.yi, 0)...rect.yl).each do |y|
    next unless line = rows[y]?
    (Math.max(rect.xi, 0)...rect.xl).each do |x|
      next unless cell = line[x]?
      hue = Attr.pack_color Colors.hsv_i((phase - (x - rect.xi) * 15) % 360)
      attr = Attr.with_bg cell.attr, hue
      next if attr == cell.attr
      cell.attr = attr
      cell.mark_dirty
    end
  end
end

# Advance the marquee. `update!` (not `update`) — an animation deliberately
# asks for another frame even though no tracked widget state changed.
Timer.every(0.05.seconds) do
  phase += 8
  box.update!
end

# Hop to a random position, keeping the box on screen. `immediate: false`
# leaves the first 2 seconds centered; the position setters schedule the
# repaint themselves.
mover = Timer.new 2.seconds, immediate: false
mover.on_tick do
  box.left = rand(0..Math.max(0, window.awidth - 20))
  box.top = rand(0..Math.max(0, window.aheight - 5))
end
mover.start

window.exec
