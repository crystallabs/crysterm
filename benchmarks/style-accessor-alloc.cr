require "../src/crysterm"

# Verifies the per-call allocation of the per-frame style accessors that
# `Widget#_render` invokes (the cross-scope lead claimed ~192 B/call each).
# Deterministic GC.stats measurement over warm iterations.
#
# Run:  crystal run --release benchmarks/style-accessor-alloc.cr

include Crysterm

N = 2_000_000

def per_call(label, &block)
  block.call # warm
  GC.collect
  before = GC.stats.total_bytes
  N.times { block.call }
  total = GC.stats.total_bytes - before
  STDERR.printf "%-34s %7.3f B/call  (%d calls)\n", label, total.to_f / N, N
end

s = Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 120, height: 40, optimization: Crysterm::OptimizationFlag::None)
w = Widget::Box.new(parent: s, top: 0, left: 0, width: 20, height: 5,
  style: Style.new(border: true, padding: 1, fg: "red", bg: "blue"))
10.times { s._render }
STDERR.puts "widget css_styled? #{w.css_styled?}  state=#{w.state}"

st = w.style
per_call("w.style") { w.style }
per_call("st.padding") { st.padding }
per_call("st.border") { st.border }
per_call("st.shadow") { st.shadow }
per_call("st.margin") { st.margin }
per_call("st.alpha?") { st.alpha? }
per_call("st.tint?") { st.tint? }
per_call("st.fill_char") { st.fill_char }
per_call("st.fg") { st.fg }
per_call("st.bold?") { st.bold? }

per_call("style + 6 accessors (per _render)") do
  x = w.style
  x.padding; x.border; x.shadow; x.alpha?; x.tint?; x.fill_char
end

STDERR.puts "\n--- edge paths ---"
# A non-css_styled widget (no theme reaching it) in :focused state that opts
# into floor reverse-highlight: `.style` takes a `dup` (the one allocating path).
s2 = Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 80, height: 24, optimization: Crysterm::OptimizationFlag::None)
btn = Widget::Button.new(parent: s2, top: 0, left: 0, content: "OK")
btn.css_styled = false # simulate "no theme reached this widget"
btn.state = WidgetState::Focused
STDERR.puts "button css_styled? #{btn.css_styled?} state=#{btn.state} floor_focus_reverse? #{btn.floor_focus_reverse?}"
per_call("Button#style (unstyled, focused)") { btn.style }

# Same widget, normal state — no highlight fallback.
btn.state = WidgetState::Normal
per_call("Button#style (unstyled, normal)") { btn.style }

# A css_styled widget in focused state — fallback returns st immediately.
w.state = WidgetState::Focused
per_call("Box#style (css_styled, focused)") { w.style }
