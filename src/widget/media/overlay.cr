require "../../widget_media_base"
require "../../widget_media_screen_overlay"
require "w3m_image_display"

module Crysterm
  class Widget
    # Overlay (w3m-img) image element.
    #
    # Reference for the w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py
    #
    # <!-- widget-examples:capture v1 -->
    # ![Overlay screenshot](../../../tests/widget/media/overlay/overlay.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Overlay < Media::External
      include Media::ScreenOverlay

      property image : W3MImageDisplay::Image?

      def initialize(
        @file = nil,
        # w3m can only fill the given rect (aspect lost) or draw at native
        # size; `#fit` maps onto those two — see `#redraw_image`. `Contain`/
        # `Cover` degrade to a rect fill. `animate:` is accepted so the
        # `Media` factory can forward it uniformly, but an external helper
        # can't animate.
        @fit : Media::Fit = Media::Fit::Stretch,
        @animate : Bool = false,
        speed : Float64 = 1.0,
        **box,
      )
        super **box
        # Route through the validating setter so speed: 0/NaN/Infinity is clamped to 1.0.
        self.speed = speed

        @file.try { |f| load f }

        # Redraw after the *window* finishes each render, not after this widget
        # renders: a w3m image is painted directly onto the terminal over
        # whatever cells are there, so it must be drawn after this frame's cells
        # are flushed or they'd land on top and hide it. Registration is deferred
        # until the widget is attached, for detached compose-then-attach use.
        register_overlay_listeners_deferred
      end

      def load(file : String)
        @file = file
        @image = W3MImageDisplay::Image.new file
        # New source: clear the failure latch, or one failed helper run would
        # leave every later `load` of a good file permanently un-drawn.
        @helper_failed = false
        # Explicit request: an external-overlay backend is painted out-of-band
        # by its `#redraw_image` hook (which runs post-render), not by the
        # normal dirty/render path, so nothing else schedules the frame.
        request_render
      end

      # Removes the currently displayed image, clearing its overlay from window.
      def clear_image
        clear_overlay
        @image = nil
        @helper_failed = false
        super # stop + clear file/source/frames
      end

      # The overlay is only on window once an image is loaded. The erase rect
      # stays the default full box, since the external helper paints over the
      # whole box, borders and padding included.
      protected def overlay_visible? : Bool
        !@image.nil?
      end

      # Set once the external helper has failed (e.g. `w3mimgdisplay` not
      # installed), so it isn't retried on every render. Cleared by `#load` and
      # `#clear_image`.
      getter? helper_failed : Bool = false

      # (Re)paints the loaded image at this widget's current position; skips
      # while hidden or detached.
      private def redraw_image
        return if @helper_failed
        @image.try do |image|
          # TODO - get coords of content only, without borders/padding
          rect = overlay_geometry || return
          begin
            # `Fit::None` draws at the source's native size, centered; every
            # scaling mode becomes w3m's rect fill (it can't preserve aspect).
            stretch = !@fit.none?
            image.draw(rect[0], rect[1], rect[2], rect[3], stretch, !stretch).sync.sync_communication
            @last_drawn = rect
          rescue
            # w3mimgdisplay missing/failed: degrade instead of crashing the
            # render fiber.
            @helper_failed = true
          end
        end
      end

      private def teardown
        teardown_overlay_listeners
      end
    end
  end
end
