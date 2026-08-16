require "./base"

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
    # * the listener-wrapper ivars (`@listener_screen` and `@ev_rendered` from
    #   `Media::WindowListener`, plus `@ev_prerender`) and the `@last_drawn`
    #   cell rectangle,
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
    # register/teardown lives in `Media::RenderHook` instead — the sibling
    # variant of the same `Media::WindowListener` spine both build on.
    module Media::ScreenOverlay
      # `@listener_screen`, `@ev_rendered`, the one-shot wiring guard, the
      # `Attached`/`Reparented`/`Detached` triple and the deferred
      # re-registration all come from here; this module adds the erase-on-move
      # (`PreRender`) half, the `@last_drawn` rectangle, and the extra
      # `Hide`/`Show`/`Destroy` hooks on top via the module's three seams.
      include Media::WindowListener

      # The erase-on-move wrapper — the half `Media::RenderHook` does not have.
      @ev_prerender : ::EventHandler::Subscription?

      # Cell rectangle (`{xi, yi, w, h}`) the overlay was last painted at, used to
      # detect movement/resize so the old position can be cleared.
      @last_drawn : Tuple(Int32, Int32, Int32, Int32)?

      # Scratch `RenderedGeometry` reused by `#invalidate_old_position`, since
      # `coords` with no `into:` allocates a fresh one every window render. Safe
      # to reuse: `PreRender` fires and fully returns (consuming its coords
      # synchronously into a plain `Tuple`) before the next pass, so the value is
      # never held across a yield point.
      @overlay_lpos : RenderedGeometry = RenderedGeometry.new

      # Registers the erase-on-move (`PreRender`) and repaint-on-top (`Rendered`)
      # listeners on *s*, in that order, and remembers *s* + the wrappers; also
      # wires this widget's own lifecycle hooks (once).
      protected def register_overlay_listeners(s : ::Crysterm::Window)
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        # `#redraw_image` is the whole `Rendered` half: erase-or-repaint, decided
        # post-frame from ONE coords resolution.
        #
        # After the frame's cells are flushed the layout is final — a scrolled
        # ancestor's `lpos` now carries THIS frame's scroll base, whereas
        # `PreRender` still saw the previous frame's and resolves coords for a
        # widget that just scrolled out. So the "no longer drawable" case is
        # decided there: a painted graphic with no drawable rect is cleared
        # (`#clear_overlay` schedules the render re-emitting the invalidated
        # cells; a Kitty layer is deleted via `#overlay_cleared`), and the very
        # same rect that survives the check is what gets painted — a separate
        # pre-check could (and did) resolve a different one.
        #
        # Deliberately NOT gated on `visible?`: a CSS restyle (`visibility:
        # hidden`/`display: none`, on this widget or an ancestor) flips the
        # computed style without emitting `Event::Hide`, so the `Hide` hook's
        # `#clear_overlay` fast path never runs — the "not drawable" decision
        # must catch that case too, or the graphic floats over the UI.
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { redraw_image }
        wire_listener_lifecycle
      end

      # `Media::WindowListener` seam: the extra hooks on this widget itself,
      # beyond the shared `Attached`/`Reparented`/`Detached` triple.
      #
      # The overlay lives outside the cell buffer, so hiding would leave it on
      # window: clear it on hide, repaint on show (`#redraw_image` runs every
      # render but skips while hidden). Tear down the window listeners on
      # destroy so they don't leak `self`.
      protected def wire_extra_listener_hooks : Nil
        on(::Crysterm::Event::Hide) { clear_overlay }
        on(::Crysterm::Event::Show) { update! }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      # `Media::WindowListener` seam: a cross-window reparent emits
      # `Detach(previous)` then `Attach(new)`: drop the old window's listeners,
      # then clear the graphic off it; the `Attached` hook re-registers on the
      # new window. Teardown must come FIRST — `#clear_overlay` ends with a
      # render of the old window, which with the `Rendered` listener still
      # registered would repaint the graphic (via the already-linked new window)
      # mid-move.
      protected def on_listener_detached(e : ::Crysterm::Event::Detached) : Nil
        teardown_overlay_listeners
        clear_overlay e.object.as?(::Crysterm::Window)
      end

      # Registers the overlay listeners now when a window is resolvable, else
      # defers to the `Attached`/`Reparented` hooks. A backend built detached (the
      # standard compose-then-attach pattern) has no window at construction, so
      # registering via the raising `window` accessor would crash.
      protected def register_overlay_listeners_deferred
        if s = window?
          on_overlay_window s
        else
          wire_listener_lifecycle
        end
      end

      # `Media::WindowListener` seam: route the deferred `Attached`/`Reparented`
      # registration to the overlay-specific hook backends already override.
      protected def on_listener_window(s : ::Crysterm::Window) : Nil
        on_overlay_window s
      end

      # Hook invoked with the window the overlay is (finally) on. The default
      # just registers the listeners; `Media::Graphics` overrides it to also
      # re-resolve the terminal's real cell pixel size from that window.
      protected def on_overlay_window(s : ::Crysterm::Window)
        register_overlay_listeners s
      end

      # Removes the listeners registered above and forgets the window: the
      # erase-on-move half here, then the shared `Rendered`/`@listener_screen`
      # tail. Nothing observes `@ev_prerender` in between, so clearing it before
      # rather than after the `Rendered` `off` is immaterial.
      protected def teardown_overlay_listeners
        return unless @listener_screen
        @ev_prerender.try &.off
        @ev_prerender = nil
        forget_listener_screen
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
      # hidden never-rendered ancestor would raise (`coords(rendered: false)` itself also
      # returns nil for a self-hidden widget, and uses the nilable `.lpos`
      # accessor, so it cannot raise here).
      private def overlay_drawable_rect : Tuple(Int32, Int32, Int32, Int32)?
        return unless visible_in_tree?
        pos = coords(into: @overlay_lpos) || return
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
        # No explicit `s.update`: inside `PreRender` the ongoing pass flushes
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
        s.update
      end
    end
  end
end
