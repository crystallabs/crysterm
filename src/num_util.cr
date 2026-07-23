module Crysterm
  # A `Float64`→`Int32` narrowing that can never raise `OverflowError`.
  #
  # NaN slips straight through a comparison-based `.clamp` — every comparison
  # against NaN is false — and reaches `.to_i`/`.round.to_i`, which raises. It
  # arises from `0 * ±Infinity` (a legitimately 0-extent basis times a percent
  # that saturated to infinity while parsing a pathological string, B17-05) or
  # from an explicitly NaN `Float64` handed to a typed constructor. Neutralize
  # it to 0 *before* the clamp, since `Float64#clamp` passes NaN through: any
  # finite percent of a 0 extent is correctly 0, and it's a safe NaN default.
  #
  # Shared by `Dim#resolve`/`#resolve_viewport` and `CSS::Length.to_cell_count`
  # (B18-22, B18-27), which each historically carried their own copy of this
  # guard since they live in different modules. Two entry points because the
  # rounding mode is not interchangeable: `#resolve`'s percent/center branch
  # truncates (`.to_i` on the product, no `.round`) and its docs promise
  # byte-for-byte the same arithmetic as the historical path, so it must use
  # the truncating form; `#resolve_viewport` and `to_cell_count` round.

  # NaN-safe *rounding* narrowing: neutralize NaN, `.round`, clamp, narrow.
  def self.saturate_cells_round(v : Float64, lo : Float64 = Int32::MIN.to_f64, hi : Float64 = Int32::MAX.to_f64) : Int32
    v = 0.0 if v.nan?
    v.round.clamp(lo, hi).to_i
  end

  # NaN-safe *truncating* narrowing: neutralize NaN, clamp, narrow (no `.round`,
  # so it matches `#resolve`'s `.to_i` on the product).
  def self.saturate_cells_trunc(v : Float64, lo : Float64 = Int32::MIN.to_f64, hi : Float64 = Int32::MAX.to_f64) : Int32
    v = 0.0 if v.nan?
    v.clamp(lo, hi).to_i
  end

  # True when every argument is finite (neither NaN nor ±Infinity). Collapses
  # the fixed-arity `a.finite? && b.finite? && …` guards the per-frame graph
  # primitives repeat before mapping logical coordinates to device pixels: a
  # non-finite operand maps to the far-off-canvas sentinel and, left unchecked,
  # draws a stray ray plus ~10^6 rejected plots, or spins an unterminated spoke
  # loop. Shared by `Graph::Painter` and `Graph::Map` (and the float meters'
  # range guards) so a new coordinate can't be silently dropped from one copy
  # of the chain — the exact gap BUGS16-18 repeatedly hit. Callers pass `.to_f`
  # for `Number` inputs so the splat stays `Float64`-typed.
  def self.all_finite?(*vals : Float64) : Bool
    vals.all? &.finite?
  end
end
