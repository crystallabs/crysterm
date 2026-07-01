require "benchmark"
require "../src/crysterm"

# Event-driven micro-benchmarks for the terminal **input parser**
# (`Tput::Input#listen` + `Tput::Key.read_control` + `read_mouse` +
# `parse_key_event`). See TP.md for the full plan.
#
# Each stream is a recorded byte sequence fed through `#listen`. We rewind one
# reusable `IO::Memory` between iterations, so the harness allocates nothing per
# iteration — every byte of B/event is the parser's own cost.
#
# The reliable signal on this noisy machine is **B/event** (deterministic);
# ns/event is reported too but treat it as noisy (interleave / re-run).
#
# Caveat: `IO::Memory` is not a tty, so `with_raw_input` and the
# `read_timeout=` toggle in `next_char(true)` are no-ops here — the real STDIN
# path pays the timeout toggle, which this harness doesn't see, but it doesn't
# allocate so B/event is unaffected.
#
# Run:  crystal run --release benchmarks/input-parse.cr

include Crysterm

# The realistic input streams (highest-frequency real input first).
STREAMS = {
  # A mouse drag: a burst of SGR motion reports — the highest-frequency real
  # input, worth optimizing most.
  "sgr_drag" => String.build { |s|
    100.times { |i| s << "\e[<35;#{(i % 200) + 1};#{(i % 50) + 1}M" }
  },
  # Plain ASCII typing.
  "ascii" => "The quick brown fox jumps over the lazy dog. " * 4,
  # Arrow / nav / function escape sequences interleaved.
  "nav_keys" => ("\e[A\e[B\e[C\e[D\e[H\e[F\e[5~\e[6~\e[3~\eOP\e[15~\e[1;5C" * 8),
  # A large bracketed paste (one event, big body).
  "paste" => "\e[200~" + ("lorem ipsum dolor sit amet " * 80) + "\e[201~",
  # Kitty enhanced key events (the double-parse path).
  "kitty" => ("\e[97;5u\e[97u\e[1;5:1A\e[97;1;97u\e[97:65;2u" * 8),
}

# One reusable parser per stream (rewound between iterations so neither the
# Tput nor the IO::Memory is reallocated during measurement).
struct Driver
  getter io : IO::Memory
  getter tput : Tput
  getter events : Int32

  def initialize(data : String)
    @io = IO::Memory.new data
    @tput = Tput.new input: @io, output: IO::Memory.new,
      screen_size: Tput::DEFAULT_SCREEN_SIZE, probe: false
    # Count events for per-event normalization.
    n = 0
    @io.rewind
    @tput.listen { n += 1 }
    @events = n
  end

  @[AlwaysInline]
  def run : Int32
    @io.rewind
    n = 0
    @tput.listen { n += 1 }
    n
  end
end

drivers = STREAMS.transform_values { |data| Driver.new data }

# --- B/event (deterministic) ------------------------------------------------
ROUNDS = 20_000

def bytes_per_event(rounds, driver) : Float64
  GC.collect
  before = GC.stats.total_bytes
  rounds.times { driver.run }
  total = (GC.stats.total_bytes - before).to_f
  total / (rounds * driver.events)
end

puts "=" * 64
puts "Input parser — B/event  (#{ROUNDS} rounds, deterministic)"
puts "=" * 64
drivers.each do |name, d|
  bpe = bytes_per_event ROUNDS, d
  printf "  %-10s  %4d events/stream   %8.1f B/event\n", name, d.events, bpe
end

# --- ns/event (noisy, secondary) --------------------------------------------
puts "\n" + "=" * 64
puts "Input parser — ns/event  (ips, NOISY — re-run / interleave)"
puts "=" * 64
Benchmark.ips do |x|
  drivers.each do |name, d|
    x.report("#{name} (#{d.events} ev)") { d.run }
  end
end
