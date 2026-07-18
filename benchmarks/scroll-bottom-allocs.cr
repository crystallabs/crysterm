require "../src/crysterm"

# Deterministic allocation check for the C1 fix in `Widget#_scroll_bottom`
# (src/widget_scrolling.cr).
#
# `_scroll_bottom` reduces over the scrollable widget's non-fixed children and,
# for each `window?` child, calls `coords false, true` to get the child's
# unscrolled extent. Without an `into:` argument that call hits the `RenderedGeometry.new`
# fallback (src/widget_position.cr:637) and allocates one `RenderedGeometry` per non-fixed
# child. The `@lpos._scroll_bottom` memo is reset every frame by `RenderedGeometry#reset`
# (the render path reuses `@lpos`), so this reduce — and its per-child garbage —
# re-runs every frame via update_scrollbar_widget -> scroll_height ->
# _scroll_bottom (called twice per frame, incl. sync_from_target).
#
# FIX: route the per-child `coords` through a reused scratch ivar
# (`@_scrollb_lpos ||= RenderedGeometry.new`), mirroring `@_shrink_child_lpos` in
# src/widget_size.cr:212. The result is consumed immediately within the reduce,
# so a single reused RenderedGeometry is safe.
#
# Metric is bytes allocated (deterministic), not ips (noise-dominated). The
# inline OLD/NEW reconstructs the exact reduce both ways; the end-to-end section
# drives the real `scroll_height` across re-renders (which reset the memo,
# so the reduce genuinely re-runs each frame).
#
# Measured (12 non-fixed children):
#   inline reduce   OLD 2304 B/op (~192 B/child)   NEW 0 B/op
#   end-to-end scroll_height contributes 0 B; only the render itself remains.
#
# Run:  crystal run --release benchmarks/scroll-bottom-allocs.cr

include Crysterm

def alloc_bytes(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  GC.stats.total_bytes - before
end

ROUNDS   = 20_000
CHILDREN =     12

puts "=" * 64
puts "_scroll_bottom allocations: OLD vs NEW  (#{ROUNDS} rounds, #{CHILDREN} children)"
puts "=" * 64

s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
box = Crysterm::Widget.new parent: s, top: 0, left: 0, width: 30, height: 6, scrollable: true
CHILDREN.times do |i|
  Crysterm::Widget.new parent: box, top: i * 3, left: 0, width: 10, height: 2
end
s.render

children = box.@children

# OLD: per-child coords without `into:` -> RenderedGeometry.new fallback per child.
old_scratch_free = alloc_bytes(ROUNDS) do
  children.reduce(0) do |current, el|
    next current if el.fixed?
    el_bottom = if el.window? && (lpos = el.coords false, true)
                  el.rtop + (lpos.yl - lpos.yi)
                else
                  el.rtop + el.aheight
                end
    Math.max current, el_bottom
  end
end

# NEW: per-child coords through a single reused scratch RenderedGeometry.
scratch = Crysterm::RenderedGeometry.new
new_scratch = alloc_bytes(ROUNDS) do
  children.reduce(0) do |current, el|
    next current if el.fixed?
    el_bottom = if el.window? && (lpos = el.coords(false, true, into: scratch))
                  el.rtop + (lpos.yl - lpos.yi)
                else
                  el.rtop + el.aheight
                end
    Math.max current, el_bottom
  end
end

puts "\n#1 inline reduce over #{CHILDREN} children"
puts "   OLD  #{old_scratch_free} bytes  (#{(old_scratch_free / ROUNDS.to_f).round(1)} B/op)"
puts "   NEW  #{new_scratch} bytes  (#{(new_scratch / ROUNDS.to_f).round(1)} B/op)"
saved = old_scratch_free - new_scratch
puts "   saved #{saved} bytes  (#{(saved / ROUNDS.to_f).round(1)} B/op, ~#{(old_scratch_free / (CHILDREN * ROUNDS).to_f).round(0).to_i} B/child)"

# End-to-end: the real method across re-renders. Re-rendering resets the @lpos
# memo, so _scroll_bottom's reduce genuinely re-runs each frame — this is what
# the per-frame render path pays.
E2E = 2_000
e2e = alloc_bytes(E2E) do
  s.render          # resets @lpos memo (RenderedGeometry#reset zeroes _scroll_bottom)
  box.scroll_height # -> _scroll_bottom reduce over children
end
puts "\n#2 end-to-end scroll_height across re-renders (#{E2E} frames)"
puts "   #{e2e} bytes total incl. full render (#{(e2e / E2E.to_f).round(1)} B/frame)"
puts "   (with the fix, _scroll_bottom contributes 0 B; remainder is render itself)"
