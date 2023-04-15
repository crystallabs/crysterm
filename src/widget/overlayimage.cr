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

      def initialize(
        @file = nil,
        @stretch = false,
        @center = true,
        **box
      )
        super **box

        @file.try { |f| load f }

        handle ::Crysterm::Event::Rendered
      end

      def load(@file)
        @image = W3MImageDisplay::Image.new @file
      end

      def on_rendered(e)
        @image.try do |image|
          pos = _get_coords(true).not_nil!
          # TODO - get coords of content only, without borders/padding
          # style.border.try &.adjust(pos)
          image.try &.draw(pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi, @stretch, @center).sync.sync_communication
        end
      end
    end

    alias Overlayimage = OverlayImage
  end
end
