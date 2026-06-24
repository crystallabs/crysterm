require "../src/crysterm"

# Whole-frame profile on a representative UI: nested bordered boxes with content,
# a list, and per-frame mutation (simulating an animation/live update). Reports
# the deterministic metric that matters — heap allocation per frame — plus the
# render-vs-draw time split (from the screen's own per-frame counters). Use this
# to judge whether the per-frame path still has fat to trim, or whether further
# wins require structural change (damage tracking, etc.).
#
# Run:  crystal run --release benchmarks/frame-profile.cr

include Crysterm

screen = Screen.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 120, height: 40)

# A realistic-ish dashboard: a few bordered panels, each with content and
# nested children, plus a list.
panels = [] of Widget::Box
4.times do |p|
  panel = Widget::Box.new(
    parent: screen,
    top: (p // 2) * 20, left: (p % 2) * 60,
    width: 58, height: 18,
    style: Style.new(border: true),
    content: "Panel #{p}")
  panels << panel
  6.times do |i|
    Widget::Box.new(parent: panel, top: i + 1, left: 2, width: 50, height: 1,
      content: "row #{i}: {bold}value{/bold} #{i * p}", parse_tags: true)
  end
end

list = Widget::List.new(parent: screen, top: 1, left: 1, width: 20, height: 16)
list.set_items (0...12).map { |i| "item #{i}" }

FRAMES = 3000

# Warm up: first renders allocate the persistent caches (lpos, content index…).
50.times { screen._render }

STDERR.puts "widgets≈#{4 + 4*6 + 1 + 12} (4 panels x6 rows + list x12 items), #{FRAMES} frames each"

# Pass A: STATIC — nothing changes, just re-render. Isolates the baseline
# per-frame compositing cost with no content reparse.
GC.collect
before = GC.stats.total_bytes
wall_a = Time.measure { FRAMES.times { screen._render } }
static_alloc = GC.stats.total_bytes - before
STDERR.printf "STATIC  alloc/frame: %5d bytes   wall/frame: %5.1f µs\n",
  static_alloc // FRAMES, wall_a.total_microseconds / FRAMES

# Pass B: LIVE — mutate 4 panels' content + list selection each frame, forcing
# content reparse on the mutated widgets.
GC.collect
before = GC.stats.total_bytes
rsum = 0_i64
dsum = 0_i64
wall_b = Time.measure do
  FRAMES.times do |f|
    panels.each_with_index { |pn, i| pn.content = "Panel #{i} @ #{f}" }
    list.selected = (f % 12)
    screen._render
    rsum += screen.render_rate
    dsum += screen.draw_rate
  end
end
live_alloc = GC.stats.total_bytes - before
STDERR.printf "LIVE    alloc/frame: %5d bytes   wall/frame: %5.1f µs   (render %d / draw %d fps-eq)\n",
  live_alloc // FRAMES, wall_b.total_microseconds / FRAMES, rsum // FRAMES, dsum // FRAMES
STDERR.printf "delta (4 content updates + list sel): %d bytes/frame (~%d per content update)\n",
  (live_alloc - static_alloc) // FRAMES, (live_alloc - static_alloc) // FRAMES // 4

# Pass C: DAMAGE TRACKING — the headline metric for damage tracking. The SAME
# scene as above, but only ONE widget changes per frame and the screen runs with
# `OptimizationFlag::DamageTracking`. With damage tracking off this re-composites
# all ~41 widgets every frame (O(N)); with it on, only the single changed
# subtree is repainted (O(changed)). Compares both so the speedup is visible.
private def build_scene(damage)
  s = Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
  ps = [] of Widget::Box
  4.times do |p|
    panel = Widget::Box.new(
      parent: s, top: (p // 2) * 20, left: (p % 2) * 60,
      width: 58, height: 18, style: Style.new(border: true), content: "Panel #{p}")
    ps << panel
    6.times do |i|
      Widget::Box.new(parent: panel, top: i + 1, left: 2, width: 50, height: 1,
        content: "row #{i}: value #{i * p}")
    end
  end
  {s, ps}
end

[{"OFF (full recomposite)", false}, {"ON  (damage tracking)", true}].each do |label, dmg|
  s, ps = build_scene dmg
  50.times { s._render } # warm caches + first full frame
  GC.collect
  before2 = GC.stats.total_bytes
  rsum2 = 0_i64
  wall_c = Time.measure do
    FRAMES.times do |f|
      # Exactly ONE widget changes per frame.
      ps[f % 4].content = "Panel #{f % 4} @ #{f}"
      s._render
      rsum2 += s.render_rate
    end
  end
  alloc_c = GC.stats.total_bytes - before2
  STDERR.printf "1-OF-N  %-22s render/frame: %5.1f µs   alloc/frame: %5d bytes   (render %d fps-eq)\n",
    label, wall_c.total_microseconds / FRAMES, alloc_c // FRAMES, rsum2 // FRAMES
  if dmg
    STDERR.printf "        fast frames: %d / %d  (full: %d)\n",
      s.damage_fast_frames, FRAMES + 50, s.damage_full_frames
  end
end

# Pass D: PHASE 2 (overlap) — several *disjoint* overlap clusters (pairs of
# overlapping panels, with pairs spaced apart). When one panel changes, damage
# tracking recomposites just that panel's cluster (its pair) in z-order, not the
# whole tree. With it off, every panel is re-composited each frame. (A fully
# *connected* overlap chain would pull every panel into one cluster — then Phase
# 2 correctly degenerates to a full recomposite with no win; the gain is real
# only when clusters stay small relative to the widget count, as here.)
private def build_overlap_scene(damage)
  s = Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
  ps = [] of Widget::Box
  6.times do |pair|
    base = pair * 20 # pairs 20 cols apart; each pair spans ~16 cols (disjoint)
    2.times do |k|
      ps << Widget::Box.new(parent: s, top: k * 3, left: base + k * 3,
        width: 12, height: 10, style: Style.new(border: true), content: "P#{pair}.#{k}")
    end
  end
  {s, ps}
end

[{"OFF (full recomposite)", false}, {"ON  (damage tracking)", true}].each do |label, dmg|
  s, ps = build_overlap_scene dmg
  50.times { s._render }
  GC.collect
  before3 = GC.stats.total_bytes
  wall_d = Time.measure do
    FRAMES.times do |f|
      ps[f % ps.size].content = "P#{f % ps.size}.#{f}"
      s._render
    end
  end
  alloc_d = GC.stats.total_bytes - before3
  STDERR.printf "OVERLAP %-22s render/frame: %5.1f µs   alloc/frame: %5d bytes\n",
    label, wall_d.total_microseconds / FRAMES, alloc_d // FRAMES
  if dmg
    STDERR.printf "        fast frames: %d / %d  (full: %d)\n",
      s.damage_fast_frames, FRAMES + 50, s.damage_full_frames
  end
end
