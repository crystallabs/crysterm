# Example: Crysterm::Widget::Table
#
# Minimal, self-contained example of a single Table.
# Run it:     crystal run tests/widget/table/table.cr
require "../example"

include Crysterm
include Crysterm::Widgets

# `Table` is the static data grid (`ListTable` is the interactive, selectable
# variant), so the demo animates the *data*: the Commits column ticks up for
# four beats and back down for four, ending exactly on the starting numbers —
# so the looping capture wraps seamlessly on two identical calm frames.
BASE = [128, 942, 377]
STEP = [3, 7, 5]

def rows_at(beat : Int32) : Array(Array(String))
  # Beats 0..4 rise, 5..8 fall back: 0 1 2 3 4 3 2 1 (0 again next cycle).
  k = beat <= 4 ? beat : 8 - beat
  [["Name", "Role", "Commits"],
   ["Ada", "Engineer", (BASE[0] + k * STEP[0]).to_s],
   ["Linus", "Maintainer", (BASE[1] + k * STEP[1]).to_s],
   ["Grace", "Architect", (BASE[2] + k * STEP[2]).to_s]]
end

table : Widget::Table? = nil

Crysterm::WidgetExample.run("Table",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.4
    (1..7).each do |beat|
      d.act(dwell: 0.45) { table.try &.rows = rows_at(beat) }
    end
    d.act(dwell: 0.45) { table.try &.rows = rows_at(0) }
  }) do |window|
  window.stylesheet = "Table { border: solid; color: #c0caf5; }"
  # No fixed `width:` — a content-sized table recomputes its columns purely
  # from the cell text (constant digit counts across the cycle), whereas a
  # fixed width leaves slack whose distribution shifts by a cell on the first
  # post-repaint reload, breaking the loop's first==last frame match.
  table = Table.new \
    parent: window, top: "center", left: "center", height: 10,
    rows: rows_at(0)
end
