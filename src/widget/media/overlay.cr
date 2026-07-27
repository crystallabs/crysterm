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
        # `Cover` degrade to a rect fill. `animate:` (including a shared
        # `Timer`, like every other backend) is accepted so the `Media`
        # factory can forward it uniformly, but an external helper can't
        # animate — `#play` routes through `#unsupported`.
        @fit : Media::Fit = Media::Fit::Stretch,
        animate : Bool | Timer = false,
        speed : Float64 = 1.0,
        **box,
      )
        super **box
        setup_animate animate
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

      # (Re)paints the loaded image at this widget's current position, or erases
      # it when that position no longer exists (hidden directly or via an
      # ancestor — including a CSS restyle that emits no `Event::Hide` —
      # detached, or degenerate). Runs post-render as the whole `Rendered` half
      # of the `Media::ScreenOverlay` lifecycle, so this single geometry
      # resolution both decides drawability and places the paint.
      private def redraw_image
        image = @image || return
        # `overlay_geometry` is the widget's full rect. For a bordered/padded
        # image widget the correct target is the *content* rect (Qt draws a
        # framed pixmap inside its contents rect). Deferred: insetting it by
        # border+padding touches every image backend that shares
        # `overlay_geometry`, so it wants a media-wide golden pass; border-less
        # image widgets (the common case) are unaffected meanwhile.
        #
        # Nothing drawable ⇒ erase what was painted, mirroring
        # `Media::Graphics#redraw_image`; the helper leaves pixels over the
        # cells, so an un-erased one floats over the UI. `#clear_overlay` nils
        # `@last_drawn`, so this can't loop.
        rect = overlay_geometry
        if rect.nil? || rect[2] <= 0 || rect[3] <= 0
          clear_overlay if @last_drawn
          return
        end
        return if @helper_failed
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

      private def teardown
        teardown_overlay_listeners
      end
    end
  end
end
