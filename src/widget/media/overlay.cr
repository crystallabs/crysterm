require "../../widget_media_external"
require "../../widget_media_screen_overlay"
require "w3m_image_display"

module Crysterm
  class Widget
    # Good example of w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py

    # Overlay (w3m-img) image element
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
        # helper does its own scaling (`stretch`/`center`) and can't animate.
        # See `Media::External`.
        @fit : Media::Fit = Media::Fit::Stretch,
        @animate : Bool = false,
        @speed : Float64 = 1.0,
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
        register_overlay_listeners screen

        # The overlay lives outside the cell buffer, so hiding/detaching the
        # widget would leave it on screen. Clear it on hide/detach and let it be
        # repainted on show/attach (`#redraw_image` runs every render but skips
        # while hidden). Tear the screen listeners down on destroy so they don't
        # keep firing or leak `self`.
        on(::Crysterm::Event::Hide) { clear_overlay }
        on(::Crysterm::Event::Detach) { |e| clear_overlay e.object.as?(::Crysterm::Screen) }
        on(::Crysterm::Event::Show) { request_render }
        on(::Crysterm::Event::Destroy) { teardown }
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

      # Removes the currently displayed image, clearing its overlay from screen.
      def clear_image
        clear_overlay
        @image = nil
        super # stop + clear file/source/frames
      end

      # The overlay is only on screen once an image is loaded. (The erase rect is
      # the full box — `Media::ScreenOverlay#overlay_rect`'s default — since the
      # external helper paints over the whole box, borders/padding included.)
      protected def overlay_visible? : Bool
        !@image.nil?
      end

      # (Re)paints the loaded image over the terminal at this widget's current
      # position. Called after every screen render so the overlay stays on top;
      # skips while the widget is hidden or detached.
      # Set once the external helper has failed (e.g. `w3mimgdisplay` is not
      # installed), so we stop hammering it every render and never crash.
      @helper_failed = false

      private def redraw_image
        return if @helper_failed
        return unless visible?
        screen? || return
        @image.try do |image|
          pos = _get_coords(true) || return
          # TODO - get coords of content only, without borders/padding
          # style.border.try &.adjust(pos)
          begin
            image.draw(pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi, @stretch, @center).sync.sync_communication
            @last_drawn = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
          rescue
            # w3mimgdisplay missing/failed: degrade instead of crashing the render
            # fiber. Selection UIs should gate on `Media.available?`; this is a
            # backstop.
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
