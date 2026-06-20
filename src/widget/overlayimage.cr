require "w3m_image_display"

module Crysterm
  class Widget
    # Good example of w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py

    # Overlay (w3m-img) image element
    class OverlayImage < Box
      property file : String?
      property stretch = false
      property center = false
      property image : W3MImageDisplay::Image?

      # Cell rectangle (`{xi, yi, w, h}`) the overlay was last painted at, used
      # to detect movement/resize so the old position can be cleared.
      @last_drawn : Tuple(Int32, Int32, Int32, Int32)? = nil

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
        # `Event::Rendered`, so we hook the screen's event. The previous code
        # used `handle Event::Rendered`, which listens on *this widget* and fires
        # during the buffer-composite phase — before `Screen#draw`. That drew the
        # image first and then flushed the cells over it; it appeared to work
        # only because w3m's async draw sometimes landed after the flush, and it
        # vanished on the very next render. This mirrors Blessed's
        # `onScreenEvent('render')`.
        #
        # `PreRender` runs *before* the cells are composited/flushed; we use it
        # to deal with the overlay left at our previous position when we move
        # (see `#invalidate_old_position`).
        screen.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        screen.on(::Crysterm::Event::Rendered) { redraw_image }
      end

      def load(file : String)
        @file = file
        @image = W3MImageDisplay::Image.new file
      end

      # Before this frame's cells are composited: if the widget has moved since
      # the last paint, force crysterm to re-emit the cells of the *previous*
      # box region so the terminal redraws text over the overlay we left there.
      #
      # The w3m image is an overlay painted on top of the terminal, not part of
      # crysterm's cell buffer, and crysterm's diff renderer skips cells whose
      # text is unchanged — e.g. the green padding shared by the old and new box
      # positions. Without this, the old overlay lingers there as a ghost.
      #
      # We deliberately do NOT w3m-clear the old region: a w3m clear paints
      # black, and crysterm would then refuse to repaint those unchanged cells,
      # leaving black smears (the border/padding artifacts). Re-emitting the
      # cells instead lets the terminal's own text rendering cover the stale
      # overlay — the green padding stays green, the border is redrawn.
      private def invalidate_old_position
        return unless @image
        last = @last_drawn || return
        pos = _get_coords(false) || return
        rect = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
        return if last == rect

        screen.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
      end

      # (Re)paints the loaded image over the terminal at this widget's current
      # position. Called after every screen render so the overlay stays on top.
      private def redraw_image
        @image.try do |image|
          pos = _get_coords(true) || return
          # TODO - get coords of content only, without borders/padding
          # style.border.try &.adjust(pos)
          image.draw(pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi, @stretch, @center).sync.sync_communication
          @last_drawn = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
        end
      end
    end

    alias Overlayimage = OverlayImage
  end
end
