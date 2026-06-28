require "./widget_media_base"

module Crysterm
  class Widget
    # Shared *screen-overlay* lifecycle for the image backends whose pixels are
    # owned by the terminal (or an external helper) rather than by Crysterm's
    # cell buffer, and which therefore must be (re)painted *after* the screen
    # flushes each frame's cells and erased-by-re-emitting-cells when the widget
    # moves or hides.
    #
    # It factors out the near-identical boilerplate that `Media::Graphics`
    # (in-band sixel/ReGIS/Kitty/iTerm) and `Media::Overlay` (w3m) used to each
    # carry verbatim:
    #
    # * the listener-wrapper ivars (`@listener_screen`, `@ev_prerender`,
    #   `@ev_rendered`) and the `@last_drawn` cell rectangle,
    # * `#register_overlay_listeners` / `#teardown_overlay_listeners`, which add
    #   and remove the `PreRender` (erase-on-move) and `Rendered` (repaint-on-top)
    #   listeners in a fixed order,
    # * a generic `#invalidate_old_position` and `#clear_overlay`, both driven by
    #   the single `#overlay_rect` hook (the cell rectangle this widget occupies —
    #   `Media::Graphics` insets it by border/padding, `Media::Overlay` uses the
    #   full box) and the `#overlay_visible?` hook (the `@file`/`@image` guard).
    #
    # The two backends supply `#redraw_image` (the post-render paint), the two
    # hooks, and optionally override `#overlay_cleared` (a chance to drop
    # backend-specific state when the overlay is erased). Behaviour is identical
    # to the hand-written versions; only the duplication is gone.
    #
    # The über-zug and Tek backends are deliberately NOT mixed in here: they
    # register a single `Rendered` listener (no `PreRender`/erase-on-move), don't
    # track `@last_drawn`, and dispatch to their own paint method — they share too
    # little with this lifecycle to fold in without unused state or behaviour
    # changes. Their (smaller) shared register/teardown lives in
    # `Media::RenderHook` instead.
    module Media::ScreenOverlay
      # Screen the listeners below were registered on, kept so they can be removed
      # on destroy even after the widget has been detached (when `#screen?` is
      # already nil).
      @listener_screen : ::Crysterm::Screen?
      @ev_prerender : ::Crysterm::Event::PreRender::Wrapper?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      # Cell rectangle (`{xi, yi, w, h}`) the overlay was last painted at, used to
      # detect movement/resize so the old position can be cleared.
      @last_drawn : Tuple(Int32, Int32, Int32, Int32)?

      # Registers the erase-on-move (`PreRender`) and repaint-on-top (`Rendered`)
      # listeners on *s*, in that order, and remembers *s* + the wrappers; then
      # wires this widget's own `Hide`/`Detach`/`Show`/`Destroy` lifecycle. Mirrors
      # what both backends did inline in their constructor.
      protected def register_overlay_listeners(s : ::Crysterm::Screen)
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { redraw_image }

        # The overlay lives outside the cell buffer, so hiding/detaching the widget
        # would leave it on screen: clear it on hide/detach and let it be repainted
        # on show (`#redraw_image` runs every render but skips while hidden). Tear
        # the screen listeners down on destroy so they don't keep firing or leak
        # `self`.
        on(::Crysterm::Event::Hide) { clear_overlay }
        on(::Crysterm::Event::Detach) { |e| clear_overlay e.object.as?(::Crysterm::Screen) }
        on(::Crysterm::Event::Show) { request_render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      # Removes the listeners registered above and forgets the screen.
      protected def teardown_overlay_listeners
        s = @listener_screen || return
        @ev_prerender.try { |w| s.off ::Crysterm::Event::PreRender, w }
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_prerender = nil
        @ev_rendered = nil
        @listener_screen = nil
      end

      # The cell rectangle (`{xi, yi, w, h}`) this widget currently occupies, for
      # the given coords *pos*. Default is the full box; `Media::Graphics`
      # overrides to inset by border/padding so it tracks the content area.
      protected def overlay_rect(pos) : Tuple(Int32, Int32, Int32, Int32)
        {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
      end

      # NOTE: the including backend must define `#overlay_visible? : Bool` — whether
      # an image is currently loaded (the `@file`/`@image` guard). Left as a
      # duck-typed requirement rather than an `abstract def`, which tripped a
      # codegen crash when a module was included by more than one widget (see
      # `Mixin::Popup`).

      # Before this frame's cells are composited: if we've moved since the last
      # paint, force Crysterm to re-emit the cells of the *previous* region so the
      # terminal's own text rendering covers the overlay we left there. We do NOT
      # explicitly clear the old region — a re-emitted cell covers the stale
      # pixels and avoids the black smears an explicit overlay-clear would leave.
      private def invalidate_old_position
        return unless overlay_visible? && visible?
        last = @last_drawn || return
        pos = _get_coords(false) || return
        rect = overlay_rect(pos)
        return if last == rect
        screen.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
      end

      # Hook run by `#clear_overlay` before the cells are invalidated, for backends
      # that must drop extra state (or delete a separate image layer) on erase.
      # No-op by default.
      protected def overlay_cleared(s : ::Crysterm::Screen)
      end

      # Erases the overlay at its last painted position by forcing those cells to
      # be re-emitted, then forgets the position. *on_screen* lets the caller pass
      # the screen explicitly (e.g. the `Detach` event, fired after `#screen?` has
      # already been cleared).
      private def clear_overlay(on_screen : ::Crysterm::Screen? = nil)
        last = @last_drawn || return
        s = on_screen || screen? || return
        overlay_cleared s
        s.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
        @last_drawn = nil
        s.render
      end
    end
  end
end
