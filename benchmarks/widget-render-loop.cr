require "benchmark"
require "../src/crysterm"

# Per-frame cost of the `Widget#_render` content loop (`widget_rendering.cr`):
# the per-cell walk that lays `@_pcontent` into the screen's `@lines` buffer.
# This is the heavy per-widget composite cost (run for every widget, every
# frame). The existing `widget-content.cr` harness covers `process_content` /
# wrapping / tag parsing; this one targets the cell-painting loop itself.
#
# A box is filled with multi-line text and `_render`ed in a tight loop. The
# content is unchanged between frames (the steady-state common case), so
# `process_content` takes its cache-hit path and the cost is dominated by the
# per-cell loop. Output never touches the terminal (headless Screen over
# /dev/null).
#
# Deterministic metric: bytes allocated per render (should be ~0 in steady
# state). ips is CPU-noise-dominated; read it as a coarse trend only.
#
# Run:  crystal run --release benchmarks/widget-render-loop.cr

include Crysterm

devnull = File.open("/dev/null", "w")
devin = File.open("/dev/null", "r")

W = 200
H =  60

screen = Screen.new output: devnull, input: devin, width: W, height: H
screen.width = W
screen.height = H
screen.realloc

# A large content box: plain ASCII paragraph that fills the whole interior.
line_text = "The quick brown fox jumps over the lazy dog. "
plain = Widget::Box.new parent: screen, top: 0, left: 0, width: W, height: H,
  content: (line_text * 8 + "\n") * (H - 2)
plain.process_content

# A box with inline SGR color escapes (exercises the escape-scan branch).
colored_src = (0...40).map { |i| "\e[3#{i % 8}mword#{i}\e[0m" }.join(" ")
colored = Widget::Box.new parent: screen, top: 0, left: 0, width: W, height: H,
  content: (colored_src + "\n") * (H - 2)
colored.process_content

def alloc_kb(n, &block)
  GC.collect
  before = GC.stats.total_bytes
  n.times { block.call }
  (GC.stats.total_bytes - before) / 1024.0
end

def ns_per(rounds, &block) : Float64
  best = Float64::INFINITY
  3.times do
    el = Time.measure { rounds.times { block.call } }
    ns = el.total_nanoseconds / rounds
    best = ns if ns < best
  end
  best
end

ROUNDS = 5000

puts "=" * 64
printf "%-22s %12s %14s\n", "scenario", "ns/render", "KB/render"
puts "=" * 64

{"plain text" => plain, "colored SGR" => colored}.each do |name, w|
  ns = ns_per(ROUNDS) { w._render }
  kb = alloc_kb(ROUNDS) { w._render } / ROUNDS
  printf "%-22s %12.0f %14.4f\n", name, ns, kb
end
