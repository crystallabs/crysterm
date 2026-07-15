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
  # DamageTracking: Per-widget damage tracking — **on by default**. Re-composites
  # only the changed subtrees (clearing their old footprint first) and keeps the
  # rest of the previous frame's buffer, making a 1-of-N update cost ~O(changed)
  # instead of O(N). Falls back to a full re-composite for cases it can't track
  # (multi-plane, nested layers, border docking, out-of-cell-model writes), so
  # it is always output-equivalent.
  #
  # NOTE: damage tracking only observes mutations made through the tracked
  # setters (`content=`, geometry/size setters, `show`/`hide`, `scroll`, child
  # add/remove) or `Widget#mark_dirty`/`#request_render`. Mutating a `Style`
  # object in place (e.g. `widget.style.bg = ...`) is NOT observed; call
  # `widget.mark_dirty` after such a change, or opt out via
  # `render.optimization = OptimizationFlag::None`.
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
