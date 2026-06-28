module Crysterm
  class Widget
    # Minimal *single post-render listener* lifecycle for the image backends whose
    # pixels live outside Crysterm's cell buffer but which — unlike the
    # `Media::ScreenOverlay` family — do NOT need the erase-on-move (`PreRender`)
    # half or the `@last_drawn` cell-rectangle tracking:
    #
    # * `Media::Ueberzug` — an override-redirect helper window that stays on top,
    #   so it only re-sends `add`/`remove` when the cell rectangle changes.
    # * `Media::Tek` — a separate Tektronix window driven entirely by its own
    #   PAGE-clear redraw, not by re-emitting cells.
    #
    # Both register a single `Rendered` listener (dispatching to their own paint
    # method) and tear it down on destroy, with byte-identical boilerplate for the
    # listener-wrapper ivars and the add/remove dance. That boilerplate lives here;
    # each backend supplies just the paint block and whatever extra teardown it
    # needs (`Media::Tek` stops its animation loop, `Media::Ueberzug` removes its
    # placement). `Media::ScreenOverlay` documents why these two are kept out of
    # *its* (two-listener) lifecycle.
    module Media::RenderHook
      # Screen the listener below was registered on, kept so it can be removed on
      # destroy even after the widget has been detached (when `#screen?` is nil).
      @listener_screen : ::Crysterm::Screen?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      # Registers *block* to run after every screen render on *s*, remembering *s*
      # and the wrapper so it can be removed later.
      protected def register_render_hook(s : ::Crysterm::Screen, &block : ::Crysterm::Event::Rendered ->)
        @listener_screen = s
        @ev_rendered = s.on(::Crysterm::Event::Rendered, &block)
      end

      # Removes the listener registered above and forgets the screen.
      protected def teardown_render_hook
        s = @listener_screen || return
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
