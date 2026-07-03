require "../../widget_media_base"
require "../../widget_media_screen_overlay"
require "w3m_image_display"

module Crysterm
  class Widget
    # Good example of w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py

    # Overlay (w3m-img) image element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Overlay screenshot](../../../tests/widget/media/overlay/overlay.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Overlay < Media::External
      include Media::ScreenOverlay

      property stretch = false
      property center = false
      property image : W3MImageDisplay::Image?

      # `@last_drawn` and the listener-wrapper ivars (`@listener_screen`,
      # `@ev_prerender`, `@ev_rendered`) come from `Media::ScreenOverlay`.

      def initialize(
        @file = nil,
        @stretch = false,
        @center = true,
        # The shared `Media::Base` contract knobs are accepted (so the `Media`
        # factory can forward them uniformly) but advisory here: an external
        # helper does its own scaling and can't animate. See `Media::External`.
        @fit : Media::Fit = Media::Fit::Stretch,
        @animate : Bool = false,
        @speed : Float64 = 1.0,
        **box,
      )
        super **box

        @file.try { |f| load f }

        # Redraw after the *window* finishes each render, not after this widget
        # renders: a w3m image is painted directly onto the terminal on top of
        # whatever cells are there, so it must be drawn after `Window#draw` has
        # flushed this frame's cells or they'd land on top and hide it.
        #
        # `Window#_render` flushes cells then emits `Event::Rendered`, so we
        # hook that. `PreRender` runs before flush; used to clean up the overlay
        # left at our previous position when we move (see
        # `#invalidate_old_position`). Mirrors Blessed's `onScreenEvent('render')`.
        # When built detached (compose-then-attach), this defers registration
        # until the widget is attached to a window.
        register_overlay_listeners_deferred
      end

      def load(file : String)
        @file = file
        @image = W3MImageDisplay::Image.new file
      end

      # Displays *file*, replacing any image currently shown, and re-renders.
      def set_image(file : String)
        load file
        request_render
      end

      # Removes the currently displayed image, clearing its overlay from window.
      def clear_image
        clear_overlay
        @image = nil
        super # stop + clear file/source/frames
      end

      # The overlay is only on window once an image is loaded. (Erase rect is the
      # full box — `Media::ScreenOverlay#overlay_rect`'s default — since the
      # external helper paints over the whole box, borders/padding included.)
      protected def overlay_visible? : Bool
        !@image.nil?
      end

      # Set once the external helper has failed (e.g. `w3mimgdisplay` not
      # installed), so we stop retrying it every render.
      @helper_failed = false

      # (Re)paints the loaded image at this widget's current position. Called
      # after every window render; skips while hidden or detached.
      private def redraw_image
        return if @helper_failed
        # Bail when this widget OR any ancestor is hidden: a standalone
        # `Rendered` listener must not resolve `_get_coords(true)` against a
        # hidden ancestor with no rendered position (it would raise and kill the
        # render fiber). Mirrors `Media::Graphics#redraw_image`.
        return unless visible_in_tree?
        window? || return
        @image.try do |image|
          pos = _get_coords(true) || return
          # TODO - get coords of content only, without borders/padding
          # style.border.try &.adjust(pos)
          begin
            image.draw(pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi, @stretch, @center).sync.sync_communication
            @last_drawn = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
          rescue
            # w3mimgdisplay missing/failed: degrade instead of crashing the
            # render fiber. Selection UIs should gate on `Media.available?`;
            # this is a backstop.
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
