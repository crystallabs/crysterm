require "../src/crysterm"

# Per-frame cost of the selective (damage-tracking) composite in a scene of
# thousands of small, non-overlapping top-level widgets, as a function of how
# many of them change per frame. The overlap pre-check that decides whether
# the changed subtrees need a cluster recomposite compares changed roots
# against every other top-level child, so it is the part that scales with
# `children × changed`.
#
# Method: a headless 200x60 window tiled with 2x1 boxes (6,000 top-level
# children); each frame rewrites the content of K boxes spread evenly over
# the scene and repaints. Reported per K: µs/frame, B/frame, and how many
# frames took the selective path vs. the full one (the window's self-measured
# backstop latches to full when selective stops paying).
#
# Run:  crystal run --release benchmarks/damage-many-roots.cr

alias CT = Crysterm
alias CW = CT::Widgets

CT::Config.set "screen.headless", CT::Headless::Always

W      = 200
H      =  60
FRAMES = (ENV["FRAMES"]? || "300").to_i

s = CT::Window.new input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: W, height: H, optimization: CT::OptimizationFlag::DamageTracking
boxes = [] of CW::Box
H.times do |y|
  (W // 2).times do |x|
    boxes << CW::Box.new(parent: s, top: y, left: x * 2, width: 2, height: 1, content: "ab")
  end
end
s.repaint
puts "#{boxes.size} top-level boxes on #{W}x#{H}"

{1, 10, 100, 500, 1500}.each do |k|
  step = boxes.size // k
  frame = 0
  tick = -> do
    frame += 1
    txt = frame.odd? ? "cd" : "ab"
    k.times { |i| boxes[i * step].content = txt }
    s.repaint
  end
  10.times { tick.call }
  fast0 = s.damage_fast_frames
  full0 = s.damage_full_frames
  GC.collect
  b0 = GC.stats.total_bytes
  t0 = Time.instant
  FRAMES.times { tick.call }
  dt = (Time.instant - t0).total_microseconds / FRAMES
  db = (GC.stats.total_bytes - b0) / FRAMES
  printf "  K=%-5d %9.1f µs/frame  %8d B/frame  selective=%d full=%d\n", k, dt, db,
    s.damage_fast_frames - fast0, s.damage_full_frames - full0
end
