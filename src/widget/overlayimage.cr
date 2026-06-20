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
        screen.on(::Crysterm::Event::Rendered) { redraw_image }
      end

      def load(file : String)
        @file = file
        @image = W3MImageDisplay::Image.new file
      end

      def on_rendered(e)
        redraw_image
      end

      # (Re)paints the loaded image over the terminal at this widget's current
      # position. Called after every screen render so the overlay stays on top.
      private def redraw_image
        @image.try do |image|
          pos = _get_coords(true) || return
          # TODO - get coords of content only, without borders/padding
          # style.border.try &.adjust(pos)
          rect = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}

          # If the widget has moved or resized since the last paint, clear the
          # overlay at its previous position first; the external w3m image is
          # not part of crysterm's cell buffer, so without this it would leave a
          # ghost behind at the old spot. `Image#clear` erases its
          # previously-drawn pixel region.
          if (last = @last_drawn) && last != rect
            image.clear
          end

          image.draw(*rect, @stretch, @center).sync.sync_communication
          @last_drawn = rect
        end
      end
    end

    alias Overlayimage = OverlayImage
  end
end
