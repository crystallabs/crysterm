require "../src/crysterm"

# Terminal output produced by registering clickable widgets while mouse
# reporting is already on (a UI that keeps registering rows through
# `Window#register_clickable` at runtime).
# The mouse modes are device state, so a registration should write nothing;
# this counts the bytes written and the time per widget.
#
# Run:  crystal run --release benchmarks/mouse-register.cr

alias CT = Crysterm
alias CW = CT::Widgets

CT::Config.set "screen.headless", CT::Headless::Always

N = 2000

sink = IO::Memory.new
s = CT::Window.new input: IO::Memory.new, output: sink, error: IO::Memory.new, width: 80, height: 24
s.enable_mouse
s.repaint
s.tput.flush
before = sink.bytesize
t0 = Time.instant
N.times { |i| s.register_clickable CW::Box.new(parent: s, top: i % 24, left: 0, width: 6, height: 1) }
dt = (Time.instant - t0).total_microseconds / N
s.tput.flush
printf "%d clickable widgets registered: %d bytes written (%.1f B/widget), %.2f µs/widget\n",
  N, sink.bytesize - before, (sink.bytesize - before) / N.to_f, dt
