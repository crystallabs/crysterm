require "w3m_image_display"

module Crysterm
  class Widget
    # Good example of w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py

    # Overlay (w3m-img) image element
    class OverlayImage < Box
      property file : String
      @image : W3MImageDisplay::Image?

      @ev_render : Crysterm::Event::Rendered::Wrapper?

      def initialize(
        @file = "/tmp/w3mimagedisplay/examples/image.jpg",
        @stretch = false,
        @center = true,
        **box
      )
        super **box

        @image = W3MImageDisplay::Image.new @file

        on ::Crysterm::Event::Attach, ->on_attach(::Crysterm::Event::Attach)
        on ::Crysterm::Event::Detach, ->on_detach(::Crysterm::Event::Detach)
      end

      def on_attach(e)
        @ev_render = screen.on ::Crysterm::Event::Rendered, ->on_render
      end

      def on_render(e)
        # TODO - get coords of content only, without borders/padding
        pos = _get_coords(true).not_nil!
        @border.try do |b|
          if b.left
            pos.xi += 1
          end
          if b.right
            pos.xl -= 1
          end
          if b.top
            pos.yi += 1
          end
          if b.bottom
            pos.yl -= 1
          end
        end

        @image.try &.draw(pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi, @stretch, @center).sync.sync_communication
      end

      def on_detach(e)
        @ev_render.try do |ev|
          screen.off ::Crysterm::Event::Rendered, ev
        end
      end
    end
  end
end
