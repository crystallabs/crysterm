module Crysterm
  # Rendering and drawing optimization flags.
  #
  # Smart CSR: Perform CSR optimization on all elements, not just full-width
  # ones (uniform cells to their sides). Known to cause flickering with
  # non-full-width elements, but more optimal for terminal rendering.
  #
  # Fast CSR: Enable CSR on any element within 20 columns of the window edges.
  # Faster than smart_csr, but may flicker depending on what's on each side.
  #
  # BCE: Perform back_color_erase optimizations for terminals that support it.
  # Also works on terminals that don't, but only on lines with the default
  # background color.
  #
  # DamageTracking: Per-widget damage tracking — **on by default** (see
  # `Config` `render.optimization`). With it off, `Window#_render` clears the
  # whole cell buffer and re-composites every widget every frame. With it on, a
  # frame where only a few top-level subtrees changed re-composites just those
  # (clearing their old footprint first), leaving the rest of the buffer from
  # the previous frame — making a 1-of-N update cost ~O(changed) instead of
  # O(N). It engages for the tractable subset (changed subtrees and anything
  # they overlap, including alpha/shadow/tint blends and a single z-index
  # plane) and falls back to full re-composite otherwise (multi-plane, nested
  # layers, border docking, out-of-cell-model writes), so it's always
  # output-equivalent. See `window_damage.cr`.
  #
  # NOTE: damage tracking relies on widget mutations going through the tracked
  # setters (`content=`, geometry/size setters, `show`/`hide`, `scroll`, child
  # add/remove) or `Widget#mark_dirty`/`#request_render`. Mutating a `Style`
  # object in place (e.g. `widget.style.bg = ...`) is NOT observed; call
  # `widget.mark_dirty` after such a change. Since this is on by default, that's
  # the one rule to remember; a UI that can't guarantee it can opt out via
  # `render.optimization = OptimizationFlag::None` (or any set without
  # `DamageTracking`).
  @[Flags]
  enum OptimizationFlag
    FastCSR
    SmartCSR
    BCE
    DamageTracking
  end

  # Overflow behavior when rendering and drawing elements.
  enum Overflow
    Ignore        # Render without changes (part goes out of window and is not visible)
    Hidden        # Clip children to this widget's rectangle (like CSS `overflow: hidden`), even when not scrollable
    ShrinkWidget  # Make the Widget smaller to fit
    SkipWidget    # Do not render that widget
    StopRendering # End rendering cycle (leave current and remaining widgets unrendered)
    MoveWidget    # Move widget so it doesn't overflow, if possible (e.g. auto-completion popups)
    # TODO Check whether StopRendering / SkipWidget work OK with focus etc.
    # They should be skipped in focus list if not rendered.
  end
end
