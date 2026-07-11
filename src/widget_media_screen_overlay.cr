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

      # One-shot guard for the self lifecycle hooks (`#wire_overlay_lifecycle_hooks`),
      # so re-registering the window listeners after a cross-window move doesn't
      # stack duplicate `Hide`/`Detach`/... handlers on this widget.
      @overlay_hooks_wired = false

      # Scratch `LPos` reused by both `#invalidate_old_position` (the
      # `PreRender` listener) and `#overlay_rendered` (the `Rendered`
      # listener) to avoid a heap `LPos` allocation every window render
      # (`_get_coords` with no `into:` allocates fresh; see
      # widget_position.cr:638-641). Safe to share a single buffer: within one
      # render pass `PreRender` fires and fully returns (consuming its coords
      # synchronously into a plain `Tuple`) before `Rendered` fires later in
      # the same pass — the two never interleave or hold the value across a
      # yield point, so there's no risk of one clobbering the other's live
      # value.
      @overlay_lpos : LPos = LPos.new

      # Registers the erase-on-move (`PreRender`) and repaint-on-top (`Rendered`)
      # listeners on *s*, in that order, and remembers *s* + the wrappers; also
      # wires this widget's own lifecycle hooks (once).
      protected def register_overlay_listeners(s : ::Crysterm::Window)
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { overlay_rendered }
        wire_overlay_lifecycle_hooks
      end

      # Wires this widget's own lifecycle hooks, exactly once per widget.
      #
      # The overlay lives outside the cell buffer, so hiding/detaching would
      # leave it on window: clear it on hide/detach, repaint on show
      # (`#redraw_image` runs every render but skips while hidden). Tear down
      # window listeners on destroy so they don't leak `self`.
      private def wire_overlay_lifecycle_hooks
        return if @overlay_hooks_wired
        @overlay_hooks_wired = true
        on(::Crysterm::Event::Hide) { clear_overlay }
        # A cross-window reparent emits `Detach(previous)` then `Attach(new)`:
        # drop the old window's `PreRender`/`Rendered` listeners, then clear the
        # graphic off it; the `Attach` hook below re-registers on the new window
        # (and the old window stops referencing `self`). Teardown must come
        # FIRST: `#clear_overlay` ends with a render of the old window, and with
        # the `Rendered` listener still registered there it would repaint the
        # graphic (via the already-linked new window) in the middle of the move.
        on(::Crysterm::Event::Detach) do |e|
          teardown_overlay_listeners
          clear_overlay e.object.as?(::Crysterm::Window)
        end
        on(::Crysterm::Event::Show) { request_render }
        on(::Crysterm::Event::Destroy) { teardown }
        # (Re)attach hooks — wired unconditionally, not only when built detached,
        # so a widget constructed already-attached still migrates its listeners
        # when later moved to a different window. `#try_register_overlay_deferred`'s
        # `@listener_screen` guard makes a same-window `Reparent` a no-op.
        on(::Crysterm::Event::Attach) { try_register_overlay_deferred }
        on(::Crysterm::Event::Reparent) { try_register_overlay_deferred }
      end

      # Registers the overlay listeners now when a window is resolvable, else
      # defers to the `Attach`/`Reparent` hooks. A backend built detached
      # (the standard compose-then-attach pattern, or a parent not yet on a
      # `Window`) has no window at construction, so calling the raising `window`
      # accessor to register would crash — this waits until the widget lands on
      # a window.
      protected def register_overlay_listeners_deferred
        if s = window?
          on_overlay_window s
        else
          wire_overlay_lifecycle_hooks
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
        s = window? || return
        pos = _get_coords(false, into: @overlay_lpos)
        rect = pos.try { |p| overlay_rect(p) }
        # Scrolled or clipped out of an ancestor's viewport: coords are
        # unresolvable (or the rect degenerate), so `#redraw_image` won't run and
        # nothing would ever cover the graphic left behind — a Kitty image is a
        # separate layer re-emitted cells can't paint over. Treat it as a
        # move-away: run the clear path here, once (`@last_drawn = nil` stops it
        # re-running every frame). Scrolling back in repaints via `#redraw_image`
        # since `#overlay_cleared` drops the emit-skip key. No explicit
        # `s.render` — we're inside `PreRender`, the ongoing pass flushes the
        # invalidated cells. (`#overlay_rendered` runs the same check post-frame,
        # where a scrolled ancestor's *fresh* lpos is finally visible.)
        if rect.nil? || rect[2] <= 0 || rect[3] <= 0
          overlay_cleared s
          s.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
          @last_drawn = nil
          return
        end
        return if last == rect
        s.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
      end

      # The `Rendered` listener body: erase-or-repaint, decided post-frame.
      #
      # After the frame's cells are flushed the layout is final — in particular
      # a scrolled ancestor's `lpos` now carries THIS frame's scroll base,
      # whereas `PreRender` (and thus `#invalidate_old_position`) still saw the
      # previous frame's, resolving coords for a widget that just scrolled out.
      # So the "no longer drawable" case is decided here: a painted graphic with
      # no drawable rect anymore is cleared (`#clear_overlay` schedules the
      # render that re-emits the invalidated cells; a Kitty layer is deleted via
      # `#overlay_cleared`). Otherwise fall through to the backend's repaint.
      private def overlay_rendered
        if @last_drawn && overlay_visible? && visible?
          pos = _get_coords(false, into: @overlay_lpos)
          rect = pos.try { |p| overlay_rect(p) }
          if rect.nil? || rect[2] <= 0 || rect[3] <= 0
            clear_overlay
            return
          end
        end
        redraw_image
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
