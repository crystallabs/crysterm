require "./spec_helper"

include Crysterm

# Regression specs for BUGS14 findings:
#
#   S1 — `ColorValue.parse_rgb`/`parse_hsl`/`hue_degrees` parsed numeric channels
#        with strict `String#to_f`, which raises `ArgumentError` (ERANGE) on a
#        numeric literal past Float64 range (309+ digits). One such token in a
#        generated/hot-reloaded stylesheet raised out of the cascade. `to_f?`
#        now drops the bad token (clamp to 0 / fall back to nil) — never raises.
#   R2 — `Font.decode_hex` parsed a `.hex` bitmap payload with strict
#        `String#to_u32(16)`, raising `ArgumentError` on any non-hex char in a
#        corrupt/hand-made font. `to_u32?` now treats a bad row as all-off.
#   R4 — propagation was depth-first and un-ordered: an `Effect` reading two
#        `Computed`s over a shared upstream `Signal` observed an impossible
#        half-updated pair and ran twice (even inside a `batch`). Propagation is
#        now glitch-free — leaf effects defer until the wave settles.

describe "BUGS14 S1 — oversized numeric color literal must not raise" do
  it "does not raise on an out-of-Float64-range rgb() channel" do
    huge = "9" * 320
    # Must not raise; the oversized channel clamps rather than crashing.
    result = Crysterm::CSS::ColorValue.resolve("rgb(#{huge}, 0, 0)", nil)
    # The unparseable channel drops to a clamped 0, yielding black — the point
    # is simply that it produced no ArgumentError out of the cascade.
    result.should eq (0 << 16) | (0 << 8) | 0
  end

  it "does not raise on an out-of-Float64-range hsl() hue" do
    huge = "9" * 320
    # The oversized hue is dropped from `numbers`, leaving fewer than 3 args, so
    # `parse_hsl` bails to nil — a graceful fallback rather than a raise.
    result = Crysterm::CSS::ColorValue.resolve("hsl(#{huge}, 50%, 50%)", nil)
    result.should be_nil
  end

  it "does not raise on an oversized stop inside a gradient" do
    huge = "9" * 320
    # Reached via gradient_color -> solid -> resolve; must not raise.
    Crysterm::CSS::ColorValue.resolve(
      "linear-gradient(to right, rgb(#{huge}, 0, 0), blue)", nil)
  end
end

describe "BUGS14 R2 — malformed .hex bitmap must fall back, not raise" do
  it "treats a non-hex bitmap payload as an all-off glyph" do
    path = File.tempname("bugs14", ".hex")
    # Codepoint 0x0041 ('A') with a correctly-sized (32 hex-digit) but
    # all-bad-character bitmap: 16 rows x 2 hex digits, "ZZ" per row.
    File.write path, "0041:#{"ZZ" * 16}\n"
    begin
      font = Crysterm::Font.load path
      # Must not raise ArgumentError from decode_hex.
      grid = font.glyph("A")
      grid.size.should eq font.height
      # A row that failed to parse falls back to all-off (0) pixels.
      grid.all? { |row| row.all? { |px| px == 0 } }.should be_true
    ensure
      File.delete path if File.exists? path
    end
  end
end

describe "BUGS14 R4 — glitch-free propagation for a Computed diamond" do
  it "never observes an impossible half-updated pair and runs once per write" do
    n = Crysterm::Reactive::Signal.new 0
    even = Crysterm::Reactive::Computed(Bool).new { n.value.even? }
    odd = Crysterm::Reactive::Computed(Bool).new { n.value.odd? }

    observed = [] of {Bool, Bool}
    Crysterm::Reactive.effect { observed << {even.value, odd.value} }
    observed.should eq [{true, false}] # initial run: 0 is even

    n.value = 1

    # The impossible {false, false} (neither even nor odd) must never appear.
    observed.includes?({false, false}).should be_false
    # Exactly one re-run after the write: initial + one = two entries.
    observed.should eq [{true, false}, {false, true}]
  end

  it "runs the effect once for a Computed diamond inside a batch" do
    n = Crysterm::Reactive::Signal.new 1
    even = Crysterm::Reactive::Computed(Bool).new { n.value.even? }
    odd = Crysterm::Reactive::Computed(Bool).new { n.value.odd? }

    observed = [] of {Bool, Bool}
    Crysterm::Reactive.effect { observed << {even.value, odd.value} }
    observed.should eq [{false, true}] # initial: 1 is odd

    Crysterm::Reactive.batch { n.value = 2 }

    # No impossible {true, true}, and the effect ran exactly once for the batch.
    observed.includes?({true, true}).should be_false
    observed.should eq [{false, true}, {true, false}]
  end
end
