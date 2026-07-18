require "../src/crysterm"

# Whole-frame profile on a representative UI: nested bordered boxes with content,
# a list, and per-frame mutation (simulating an animation/live update). Reports
# heap allocation per frame plus the render-vs-draw time split (from the
# screen's own per-frame counters).
#
# Run:  crystal run --release benchmarks/frame-profile.cr

include Crysterm

# Pinned to the full-recomposite path to measure baseline per-frame compositing
# cost. Damage tracking is the default, so without this the STATIC pass would
# hit the no-change fast-path skip; OFF/ON passes below do the damage comparison.
screen = Window.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 120, height: 40,
  optimization: Crysterm::OptimizationFlag::None)

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
list.items = (0...12).map { |i| "item #{i}" }

FRAMES = 3000

# Warm up: first renders allocate the persistent caches (lpos, content index…).
50.times { screen._render }

STDERR.puts "widgets≈#{4 + 4*6 + 1 + 12} (4 panels x6 rows + list x12 items), #{FRAMES} frames each"

# Pass A: STATIC — nothing changes, just re-render. Baseline per-frame
# compositing cost with no content reparse.
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
    list.current_index = (f % 12)
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

# Pass C: DAMAGE TRACKING — same scene as above, but only ONE widget changes
# per frame, comparing `OptimizationFlag::DamageTracking` off vs on. Off
# re-composites all ~41 widgets every frame (O(N)); on, only the changed
# subtree is repainted (O(changed)).
private def build_scene(damage)
  s = Crysterm::Window.new(
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
# overlapping panels, spaced apart). When one panel changes, damage tracking
# recomposites just its cluster in z-order, not the whole tree; off, every
# panel is re-composited each frame. A fully *connected* overlap chain would
# pull every panel into one cluster, degenerating to a full recomposite — the
# gain here depends on clusters staying small relative to the widget count.
private def build_overlap_scene(damage)
  s = Crysterm::Window.new(
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

# Pass E: PHASE 3 (alpha) — disjoint clusters, each an opaque base panel with a
# translucent panel layered over it. One cluster's base changes per frame,
# and its overlay re-blends. Off, every panel and blend is recomputed each
# frame; on, only the changed cluster's pair is recomposited.
private def build_alpha_scene(damage)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
  bases = [] of Widget::Box
  6.times do |i|
    base = i * 20
    b = Widget::Box.new(parent: s, top: 0, left: base, width: 16, height: 12,
      style: Style.new(bg: 0x202020), content: "B#{i}")
    Widget::Box.new(parent: s, top: 3, left: base + 3, width: 10, height: 6,
      style: Style.new(bg: 0x00aa55, opacity: 0.5), content: "a#{i}")
    bases << b
  end
  {s, bases}
end

[{"OFF (full recomposite)", false}, {"ON  (damage tracking)", true}].each do |label, dmg|
  s, bases = build_alpha_scene dmg
  50.times { s._render }
  GC.collect
  before4 = GC.stats.total_bytes
  wall_e = Time.measure do
    FRAMES.times do |f|
      bases[f % bases.size].content = "B#{f % bases.size}.#{f}"
      s._render
    end
  end
  alloc_e = GC.stats.total_bytes - before4
  STDERR.printf "ALPHA   %-22s render/frame: %5.1f µs   alloc/frame: %5d bytes\n",
    label, wall_e.total_microseconds / FRAMES, alloc_e // FRAMES
  if dmg
    STDERR.printf "        fast frames: %d / %d  (full: %d)\n",
      s.damage_fast_frames, FRAMES + 50, s.damage_full_frames
  end
end

# Pass F: PHASE 4 (z-index plane) — a static scene of several opaque base panels
# plus ONE translucent z-indexed overlay (a modal) covering a corner. Each frame,
# a base panel *under* the overlay changes, forcing the overlay to re-blend over
# the rebuilt region. Off, every panel and the whole plane are re-folded each
# frame (O(N)); on, only the changed panels and the plane's covered region are
# rebuilt (O(changed ∪ covered)). Before Phase 4, ON matched OFF here (planes
# always fell back to the full path).
private def build_plane_scene(damage)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 120, height: 40,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
  bases = [] of Widget::Box
  6.times do |i|
    b = Widget::Box.new(parent: s, top: 0, left: i * 20, width: 18, height: 12,
      style: Style.new(border: true, bg: 0x202020), content: "B#{i}")
    bases << b
  end
  # One translucent z-indexed overlay over the far-left two panels (cols ~6..30).
  # z-index/opacity must be set via CSS to promote a widget to a plane — an
  # inline `style.z_index=` is dropped by the first cascade run.
  overlay = Widget::Box.new(parent: s, top: 2, left: 6, width: 24, height: 8,
    style: Style.new(border: true, bg: 0x0055aa), content: "overlay")
  overlay.add_css_class "ov"
  s.stylesheet = ".ov { z-index: 5; opacity: 0.6; }"
  {s, bases}
end

[{"OFF (full recomposite)", false}, {"ON  (damage tracking)", true}].each do |label, dmg|
  s, bases = build_plane_scene dmg
  50.times { s._render }
  GC.collect
  before5 = GC.stats.total_bytes
  wall_f = Time.measure do
    FRAMES.times do |f|
      # A base panel UNDER the overlay changes each frame (panels 0 and 1).
      bases[f % 2].content = "B#{f % 2}.#{f}"
      s._render
    end
  end
  alloc_f = GC.stats.total_bytes - before5
  STDERR.printf "PLANE   %-22s render/frame: %5.1f µs   alloc/frame: %5d bytes\n",
    label, wall_f.total_microseconds / FRAMES, alloc_f // FRAMES
  if dmg
    STDERR.printf "        fast frames: %d / %d  (full: %d)\n",
      s.damage_fast_frames, FRAMES + 50, s.damage_full_frames
  end
end
