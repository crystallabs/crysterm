require "./widget_media_base"

module Crysterm
  class Widget
    # Shared window-overlay lifecycle for image backends whose pixels are owned
    # by the terminal (or an external helper) rather than Crysterm's cell
    # buffer, so they must be (re)painted after the window flushes each
    # frame's cells and erased-by-re-emitting-cells when the widget moves or
    # hides.
    #
    # Factors out boilerplate `Media::Graphics` (in-band sixel/ReGIS/Kitty/
    # iTerm) and `Media::Overlay` (w3m) would otherwise each carry verbatim:
    #
    # * the listener-wrapper ivars (`@listener_screen`, `@ev_prerender`,
    #   `@ev_rendered`) and the `@last_drawn` cell rectangle,
    # * `#register_overlay_listeners`/`#teardown_overlay_listeners`, adding and
    #   removing the `PreRender` (erase-on-move) and `Rendered`
    #   (repaint-on-top) listeners in a fixed order,
    # * a generic `#invalidate_old_position` and `#clear_overlay`, driven by
    #   `#overlay_rect` (cell rectangle this widget occupies — `Media::Graphics`
    #   insets by border/padding, `Media::Overlay` uses the full box) and
    #   `#overlay_visible?` (the `@file`/`@image` guard).
    #
    # The two backends supply `#redraw_image` (post-render paint), the two
    # hooks, and optionally override `#overlay_cleared` to drop backend-specific
    # state on erase.
    #
    # The über-zug and Tek backends are deliberately not mixed in here: they
    # register a single `Rendered` listener (no erase-on-move), don't track
    # `@last_drawn`, and dispatch to their own paint method — too little shared
    # to fold in cleanly. Their smaller shared register/teardown lives in
    # `Media::RenderHook` instead.
    module Media::ScreenOverlay
      # Window the listeners below were registered on, kept so they can be
      # removed on destroy even after the widget is detached (`#window?` nil).
      @listener_screen : ::Crysterm::Window?
      @ev_prerender : ::Crysterm::Event::PreRender::Wrapper?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      # Cell rectangle (`{xi, yi, w, h}`) the overlay was last painted at, used to
      # detect movement/resize so the old position can be cleared.
      @last_drawn : Tuple(Int32, Int32, Int32, Int32)?

      # Registers the erase-on-move (`PreRender`) and repaint-on-top (`Rendered`)
      # listeners on *s*, in that order, and remembers *s* + the wrappers; then
      # wires this widget's `Hide`/`Detach`/`Show`/`Destroy` lifecycle.
      protected def register_overlay_listeners(s : ::Crysterm::Window)
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { redraw_image }

        # The overlay lives outside the cell buffer, so hiding/detaching would
        # leave it on window: clear it on hide/detach, repaint on show
        # (`#redraw_image` runs every render but skips while hidden). Tear down
        # window listeners on destroy so they don't leak `self`.
        on(::Crysterm::Event::Hide) { clear_overlay }
        on(::Crysterm::Event::Detach) { |e| clear_overlay e.object.as?(::Crysterm::Window) }
        on(::Crysterm::Event::Show) { request_render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      # Registers the overlay listeners now when a window is resolvable, else
      # defers to a one-shot `Attach`/`Reparent` hook. A backend built detached
      # (the standard compose-then-attach pattern, or a parent not yet on a
      # `Window`) has no window at construction, so calling the raising `window`
      # accessor to register would crash — this waits until the widget lands on
      # a window.
      protected def register_overlay_listeners_deferred
        if s = window?
          on_overlay_window s
        else
          on(::Crysterm::Event::Attach) { try_register_overlay_deferred }
          on(::Crysterm::Event::Reparent) { try_register_overlay_deferred }
        end
      end

      # Fires from the deferred `Attach`/`Reparent` hook: registers once a window
      # exists, guarded on `@listener_screen` so a re-attach doesn't double-register.
      private def try_register_overlay_deferred
        return if @listener_screen
        s = window? || return
        on_overlay_window s
      end

      # Hook invoked with the window the overlay is (finally) on. The default
      # just registers the listeners; `Media::Graphics` overrides it to also
      # re-resolve the terminal's real cell pixel size from that window.
      protected def on_overlay_window(s : ::Crysterm::Window)
        register_overlay_listeners s
      end

      # Removes the listeners registered above and forgets the window.
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

      # NOTE: the including backend must define `#overlay_visible? : Bool` —
      # whether an image is loaded (the `@file`/`@image` guard). Duck-typed
      # rather than `abstract def`, which tripped a codegen crash when a module
      # was included by more than one widget (see `Mixin::Popup`).

      # Before this frame's cells are composited: if moved since the last
      # paint, force re-emit of the previous region's cells so the terminal's
      # text rendering covers the overlay left there. Not explicitly cleared —
      # a re-emitted cell covers stale pixels without the black smears an
      # explicit clear would leave.
      private def invalidate_old_position
        return unless overlay_visible? && visible?
        last = @last_drawn || return
        pos = _get_coords(false) || return
        rect = overlay_rect(pos)
        return if last == rect
        window.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
      end

      # Hook run by `#clear_overlay` before cells are invalidated, for backends
      # that must drop extra state (or delete a separate image layer) on erase.
      # No-op by default.
      protected def overlay_cleared(s : ::Crysterm::Window)
      end

      # Erases the overlay at its last painted position by forcing those cells
      # to be re-emitted, then forgets the position. *on_screen* lets the
      # caller pass the window explicitly (e.g. `Detach`, fired after
      # `#window?` is already cleared).
      private def clear_overlay(on_screen : ::Crysterm::Window? = nil)
        last = @last_drawn || return
        s = on_screen || window? || return
        overlay_cleared s
        s.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
        @last_drawn = nil
        s.render
      end
    end
  end
end
