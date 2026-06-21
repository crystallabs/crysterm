require "../image"
require "w3m_image_display"

module Crysterm
  class Widget
    # Good example of w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py

    # Overlay (w3m-img) image element
    class Image::Overlay < Box
      property file : String?
      property stretch = false
      property center = false
      property image : W3MImageDisplay::Image?

      # Cell rectangle (`{xi, yi, w, h}`) the overlay was last painted at, used
      # to detect movement/resize so the old position can be cleared.
      @last_drawn : Tuple(Int32, Int32, Int32, Int32)? = nil

      # The screen the render listeners below were registered on, kept so they
      # can be removed on destroy even after the widget has been detached (when
      # `#screen?` is already nil).
      @listener_screen : ::Crysterm::Screen?
      @ev_prerender : ::Crysterm::Event::PreRender::Wrapper?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      def initialize(
        @file = nil,
        @stretch = false,
        @center = true,
        **box,
      )
        super **box

        @file.try { |f| load f }

        # Redraw the image after the *screen* finishes each render, not after
        # this widget renders. A w3m image is an external overlay painted
        # directly onto the terminal, on top of whatever cells are currently
        # there — so it must be (re)drawn *after* `Screen#draw` has flushed this
        # frame's cells, or those cells land on top and hide it.
        #
        # `Screen#_render` flushes its cell buffer (`draw`) and only *then* emits
        # `Event::Rendered`, so we hook the screen's event. `PreRender` runs
        # *before* the cells are composited/flushed; we use it to deal with the
        # overlay left at our previous position when we move (see
        # `#invalidate_old_position`). This mirrors Blessed's
        # `onScreenEvent('render')`.
        s = screen
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { redraw_image }

        # The overlay lives outside the cell buffer, so hiding/detaching the
        # widget would leave it on screen. Clear it on hide/detach and let it be
        # repainted on show/attach (`#redraw_image` runs every render but skips
        # while hidden). Tear the screen listeners down on destroy so they don't
        # keep firing or leak `self`.
        on(::Crysterm::Event::Hide) { clear_overlay }
        on(::Crysterm::Event::Detach) { |e| clear_overlay e.object.as?(::Crysterm::Screen) }
        on(::Crysterm::Event::Show) { screen?.try &.render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      def load(file : String)
        @file = file
        @image = W3MImageDisplay::Image.new file
      end

      # Displays *file*, replacing any image currently shown, and re-renders.
      def set_image(file : String)
        load file
        screen?.try &.render
      end

      # Removes the currently displayed image, clearing its overlay from screen.
      def clear_image
        clear_overlay
        @image = nil
        @file = nil
      end

      # Before this frame's cells are composited: if the widget has moved since
      # the last paint, force crysterm to re-emit the cells of the *previous*
      # box region so the terminal redraws text over the overlay we left there.
      #
      # crysterm's diff renderer skips cells whose text is unchanged (e.g. green
      # padding shared by the old and new box positions); without this the old
      # overlay would linger there as a ghost. We deliberately do NOT w3m-clear
      # the old region — a w3m clear paints black into cells crysterm then
      # refuses to repaint, leaving black smears. Re-emitting the cells lets the
      # terminal's own text rendering cover the stale overlay.
      private def invalidate_old_position
        return unless @image && visible?
        last = @last_drawn || return
        pos = _get_coords(false) || return
        rect = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
        return if last == rect

        screen.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
      end

      # (Re)paints the loaded image over the terminal at this widget's current
      # position. Called after every screen render so the overlay stays on top;
      # skips while the widget is hidden or detached.
      private def redraw_image
        return unless visible?
        screen? || return
        @image.try do |image|
          pos = _get_coords(true) || return
          # TODO - get coords of content only, without borders/padding
          # style.border.try &.adjust(pos)
          image.draw(pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi, @stretch, @center).sync.sync_communication
          @last_drawn = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
        end
      end

      # Erases the overlay at its last painted position by forcing crysterm to
      # re-emit those cells (covering the external w3m image), then forgets the
      # position. *on_screen* lets the caller pass the screen explicitly (e.g.
      # the `Detach` event, fired after `#screen?` has already been cleared).
      private def clear_overlay(on_screen : ::Crysterm::Screen? = nil)
        last = @last_drawn || return
        s = on_screen || screen? || return
        s.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
        @last_drawn = nil
        s.render
      end

      private def teardown
        s = @listener_screen || return
        @ev_prerender.try { |w| s.off ::Crysterm::Event::PreRender, w }
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_prerender = nil
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
