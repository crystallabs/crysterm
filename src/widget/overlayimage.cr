require "./node"
require "./element"
require "w3m_image_display"

module Crysterm
  module Widget
    # Good example of w3mimgdisplay commands:
    # https://github.com/hut/ranger/blob/master/ranger/ext/img_display.py

    # Overlay (w3m-img) image element
    class OverlayImage < Box
      property file : String
      @image : W3MImageDisplay::Image?

      def initialize(
        @file = "/tmp/w3mimagedisplay/examples/image.jpg",
        @stretch = false,
        @center = true,
        **box
      )
        super **box

        @image = W3MImageDisplay::Image.new @file

        @screen.on(RenderEvent) do
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
      end
    end
  end
end
