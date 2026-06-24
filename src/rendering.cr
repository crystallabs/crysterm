module Crysterm
  # Rendering and drawing optimization flags.
  #
  # Smart CSR: Attempt to perform CSR optimization on all possible elements,
  # and not just on full-width ones, i.e. those with uniform cells to their sides.
  # This is known to cause flickering with elements that are not full-width, but
  # it is more optimal for terminal rendering.
  #
  # Fast CSR: Enable CSR on any element within 20 columns of the screen edges on either side.
  # It is faster than smart_csr, but may cause flickering depending on what is on
  # each side of the element.
  #
  # BCE: Attempt to perform back_color_erase optimizations for terminals that support it.
  # It will also work with terminals that don't support it, but only on lines with
  # the default background color. As it stands with the current implementation,
  # it's uncertain how much terminal performance this adds at the cost of code overhead.
  #
  # DamageTracking: Opt-in per-widget damage tracking. With it off (the default),
  # `Screen#_render` clears the whole cell buffer and re-composites every widget
  # every frame. With it on, a frame in which only a few top-level subtrees
  # changed re-composites just those (clearing their old footprint first) and
  # leaves the rest of the buffer from the previous frame — making a 1-of-N
  # update cost ~O(changed) instead of O(N). It engages only for the tractable
  # subset (no alpha/shadow/tint/z-index/border-docking active, and the changed
  # subtrees don't overlap unchanged ones) and otherwise falls back to the full
  # re-composite, so it is always output-equivalent. See `screen_damage.cr`.
  #
  # NOTE: damage tracking relies on widget mutations going through the tracked
  # setters (`content=`, geometry/size setters, `show`/`hide`, `scroll`, child
  # add/remove) or through `Widget#mark_dirty`/`#request_render`. Mutating a
  # `Style` object in place (e.g. `widget.style.bg = ...`) is NOT observed; call
  # `widget.mark_dirty` after such a change, or leave this flag off.
  @[Flags]
  enum OptimizationFlag
    FastCSR
    SmartCSR
    BCE
    DamageTracking
  end

  # Overflow behavior when rendering and drawing elements.
  enum Overflow
    Ignore        # Render without changes (part goes out of screen and is not visible)
    Hidden        # Clip children to this widget's rectangle (like CSS `overflow: hidden`), even when the widget is not scrollable
    ShrinkWidget  # Make the Widget smaller to fit
    SkipWidget    # Do not render that widget
    StopRendering # End rendering cycle (leave current and remaining widgets unrendered)
    MoveWidget    # Move widget so that it doesn't overflow, if possible (e.g. auto-completion popups)
    # TODO Check whether StopRendering / SkipWidget work OK with things like focus etc.
    # They should be skipped in focus list if they are not rendered, of course.
  end
end
