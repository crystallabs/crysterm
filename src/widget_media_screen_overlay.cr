require "./widget_media_base"

module Crysterm
  class Widget
    # Shared window-overlay lifecycle for image backends whose pixels are owned
    # by the terminal (or an external helper) rather than Crysterm's cell
    # buffer, so they must be (re)painted after the window flushes each frame's
    # cells and erased-by-re-emitting-cells when the widget moves or hides.
    #
    # Shared by `Media::Graphics` (in-band sixel/ReGIS/Kitty/iTerm) and
    # `Media::Overlay` (w3m):
    #
    # * the listener-wrapper ivars (`@listener_screen`, `@ev_prerender`,
    #   `@ev_rendered`) and the `@last_drawn` cell rectangle,
    # * `#register_overlay_listeners`/`#teardown_overlay_listeners`, adding and
    #   removing the `PreRender` (erase-on-move) and `Rendered`
    #   (repaint-on-top) listeners in a fixed order,
    # * `#invalidate_old_position` and `#clear_overlay`, driven by
    #   `#overlay_rect` (cell rectangle this widget occupies — `Media::Graphics`
    #   insets by border/padding, `Media::Overlay` uses the full box) and
    #   `#overlay_visible?` (the `@file`/`@image` guard).
    #
    # Backends supply `#redraw_image` (post-render paint), the two hooks, and
    # optionally override `#overlay_cleared` to drop backend-specific state on
    # erase.
    #
    # The über-zug and Tek backends are deliberately not mixed in: they register
    # a single `Rendered` listener (no erase-on-move), don't track `@last_drawn`,
    # and dispatch to their own paint method. Their smaller shared
    # register/teardown lives in `Media::RenderHook` instead.
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
      # stack duplicate `Hide`/`Detached`/... handlers on this widget.
      @overlay_hooks_wired = false

      # Scratch `RenderedGeometry` reused by `#invalidate_old_position` and
      # `#overlay_rendered`, since `coords` with no `into:` allocates a fresh one
      # every window render. Safe to share one buffer: within a render pass
      # `PreRender` fires and fully returns (consuming its coords synchronously
      # into a plain `Tuple`) before `Rendered` fires, so neither holds the value
      # across a yield point or clobbers the other's.
      @overlay_lpos : RenderedGeometry = RenderedGeometry.new

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
        # drop the old window's listeners, then clear the graphic off it; the
        # `Attached` hook re-registers on the new window. Teardown must come FIRST —
        # `#clear_overlay` ends with a render of the old window, which with the
        # `Rendered` listener still registered would repaint the graphic (via the
        # already-linked new window) mid-move.
        on(::Crysterm::Event::Detached) do |e|
          teardown_overlay_listeners
          clear_overlay e.object.as?(::Crysterm::Window)
        end
        on(::Crysterm::Event::Show) { request_render }
        on(::Crysterm::Event::Destroy) { teardown }
        # (Re)attach hooks — wired unconditionally, not only when built detached,
        # so a widget constructed already-attached still migrates its listeners
        # when later moved to another window. The `@listener_screen` guard in
        # `#try_register_overlay_deferred` makes a same-window `Reparented` a no-op.
        on(::Crysterm::Event::Attached) { try_register_overlay_deferred }
        on(::Crysterm::Event::Reparented) { try_register_overlay_deferred }
      end

      # Registers the overlay listeners now when a window is resolvable, else
      # defers to the `Attached`/`Reparented` hooks. A backend built detached (the
      # standard compose-then-attach pattern) has no window at construction, so
      # registering via the raising `window` accessor would crash.
      protected def register_overlay_listeners_deferred
        if s = window?
          on_overlay_window s
        else
          wire_overlay_lifecycle_hooks
        end
      end

      # Fires from the deferred `Attached`/`Reparented` hook: registers once a window
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
      # whether an image is loaded (the `@file`/`@image` guard). Duck-typed, not
      # `abstract def`, which trips a codegen crash when a module is included by
      # more than one widget.

      # The cell rectangle the overlay can be painted at this frame, or `nil`
      # when it isn't drawable at all — hidden directly or via an ancestor
      # (including CSS `visibility: hidden`/`display: none`, which flips
      # `style.visible` without ever emitting `Event::Hide`), scrolled/clipped
      # out of a viewport (unresolvable coords), or a degenerate rect.
      # `visible_in_tree?` is checked BEFORE `coords`: resolving against a
      # hidden never-rendered ancestor would raise (`coords(false)` itself also
      # returns nil for a self-hidden widget, and uses the nilable `.lpos`
      # accessor, so it cannot raise here).
      private def overlay_drawable_rect : Tuple(Int32, Int32, Int32, Int32)?
        return unless visible_in_tree?
        pos = coords(false, into: @overlay_lpos) || return
        rect = overlay_rect(pos)
        return if rect[2] <= 0 || rect[3] <= 0
        rect
      end

      # Before this frame's cells are composited: if moved since the last paint,
      # force re-emit of the previous region's cells so the terminal's text
      # rendering covers the overlay left there. Deliberately not an explicit
      # clear — a re-emitted cell covers stale pixels without the black smears an
      # explicit clear would leave.
      private def invalidate_old_position
        return unless overlay_visible?
        last = @last_drawn || return
        s = window? || return
        rect = overlay_drawable_rect
        # Scrolled or clipped out of an ancestor's viewport (coords
        # unresolvable / rect degenerate), or hidden by a CSS restyle that
        # never emits `Event::Hide`: `#redraw_image` won't run and nothing
        # would cover the graphic left behind — a Kitty image is a separate
        # layer re-emitted cells can't paint over. Treat it as a move-away and
        # run the clear path once (`@last_drawn = nil` stops it re-running
        # every frame); scrolling back in / re-showing repaints via
        # `#redraw_image`, since `#overlay_cleared` drops the emit-skip key.
        # No explicit `s.render`: inside `PreRender` the ongoing pass flushes
        # the invalidated cells.
        if rect.nil?
          overlay_cleared s
          invalidate_rect s, last
          @last_drawn = nil
          return
        end
        return if last == rect
        invalidate_rect s, last
      end

      # The `Rendered` listener body: erase-or-repaint, decided post-frame.
      #
      # After the frame's cells are flushed the layout is final — a scrolled
      # ancestor's `lpos` now carries THIS frame's scroll base, whereas
      # `PreRender` still saw the previous frame's and resolves coords for a
      # widget that just scrolled out. So the "no longer drawable" case is decided
      # here: a painted graphic with no drawable rect is cleared (`#clear_overlay`
      # schedules the render re-emitting the invalidated cells; a Kitty layer is
      # deleted via `#overlay_cleared`). Otherwise repaint via the backend.
      #
      # Deliberately NOT gated on `visible?`: a CSS restyle (`visibility:
      # hidden`/`display: none`, on this widget or an ancestor) flips the
      # computed style without emitting `Event::Hide`, so the `Hide` hook's
      # `#clear_overlay` fast path never runs — the "not drawable" decision
      # here must catch that case too, or the graphic floats over the UI.
      private def overlay_rendered
        if @last_drawn && overlay_visible?
          unless overlay_drawable_rect
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

      # Invalidates the cells covered by a `{xi, yi, w, h}` painted rect on *s*,
      # converting it to `#invalidate_region`'s `(x0, x1, y0, y1)` bounds.
      private def invalidate_rect(s, rect)
        s.invalidate_region(rect[0], rect[0] + rect[2], rect[1], rect[1] + rect[3])
      end

      # Erases the overlay at its last painted position by forcing those cells
      # to be re-emitted, then forgets the position. *on_screen* lets the
      # caller pass the window explicitly (e.g. `Detached`, fired after
      # `#window?` is already cleared).
      private def clear_overlay(on_screen : ::Crysterm::Window? = nil)
        last = @last_drawn || return
        s = on_screen || window? || return
        overlay_cleared s
        invalidate_rect s, last
        @last_drawn = nil
        s.render
      end
    end
  end
end
