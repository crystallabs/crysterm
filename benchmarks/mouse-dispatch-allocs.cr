require "../src/crysterm"

# Deterministic allocation check for ALLOCS.md Group B mouse-dispatch fixes.
#
# B1 — `Window#widget_at` traversed with `each_descendant do |el| … end`, which
#      reifies a heap closure (capturing found/found_key/x/y/skip) on *every*
#      call, i.e. every mouse report including all motion. The fix replaces it
#      with a recursive `hit_scan` accumulating the best hit in scratch ivars —
#      no captured Proc.
#
# B2 — `dispatch_mouse` allocated a fresh `Event::Mouse` (and hover
#      MouseOver/Move/Out) per report whenever a listener was installed (a
#      screen-level listener is routine — every pop-up installs one). The fix
#      pools one mutable event per concrete class per Window and `reset`s it.
#
# Metric is bytes allocated (deterministic), not ips. The OLD closure path is
# reconstructed inline; the NEW path drives the real `widget_at` /
# `dispatch_mouse`.
#
# Run:  crystal run --release benchmarks/mouse-dispatch-allocs.cr

include Crysterm

def alloc_bytes(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  GC.stats.total_bytes - before
end

ROUNDS   = 50_000
CHILDREN =      8

puts "=" * 64
puts "mouse dispatch allocations: OLD vs NEW  (#{ROUNDS} rounds)"
puts "=" * 64

s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: 60, height: 30)
box = Crysterm::Widget.new parent: s, top: 0, left: 0, width: 40, height: 20
box.clickable = true
CHILDREN.times do |i|
  c = Crysterm::Widget.new parent: box, top: i, left: 0, width: 20, height: 1
  c.clickable = true
end
s.render

# --- B1: widget_at traversal --------------------------------------------------
# OLD: the captured-block traversal reified a closure per call.
old_wa = alloc_bytes(ROUNDS) do
  found = nil
  found_key = {0, 0}
  x = 5
  y = 4
  skip = nil
  s.each_descendant do |el|
    next if skip && el == skip
    _ = {found, found_key, x, y} # keep captures live
  end
  found
end

# NEW: recursive hit_scan into scratch ivars, no captured Proc.
new_wa = alloc_bytes(ROUNDS) { s.widget_at 5, 4 }

puts "\n#1 widget_at over #{CHILDREN} children"
puts "   OLD (each_descendant closure)  #{old_wa} bytes  (#{(old_wa / ROUNDS.to_f).round(1)} B/op)"
puts "   NEW (hit_scan scratch ivars)   #{new_wa} bytes  (#{(new_wa / ROUNDS.to_f).round(1)} B/op)"

# --- B2: mouse event object per report while a listener exists ----------------
# A routine screen-level listener (as every pop-up installs).
sink = 0
s.on(Crysterm::Event::Mouse) { |e| sink += e.x }

# Alternate coords so hover transitions and motion both fire.
new_dispatch = alloc_bytes(ROUNDS) do
  x = 3 + (sink & 1)
  s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, 2, source: :test)
end

# Reference: a fresh Event::Mouse per report (what the old splat form did while
# subscribed).
ev = ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 3, 2, source: :test)
old_alloc = alloc_bytes(ROUNDS) { Crysterm::Event::Mouse.new(ev) }

puts "\n#2 dispatch_mouse (Move) with a screen-level Event::Mouse listener"
puts "   OLD reference: one Event::Mouse.new per report  #{old_alloc} bytes  (#{(old_alloc / ROUNDS.to_f).round(1)} B/op)"
puts "   NEW dispatch_mouse end-to-end (pooled event)     #{new_dispatch} bytes  (#{(new_dispatch / ROUNDS.to_f).round(1)} B/op)"
puts "   (NEW includes the whole dispatch path; the per-report event alloc is gone)"
