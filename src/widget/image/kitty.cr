require "base64"
require "./graphics"

module Crysterm
  class Widget
    # Renders an image with the **Kitty graphics protocol**: an in-band APC
    # escape (`ESC _G <control> ; <base64 payload> ESC \`) that a Kitty-protocol
    # terminal (kitty, WezTerm, Konsole, Ghostty, …) draws as true RGBA pixels.
    # Like sixel the pixels are owned by the terminal, so this inherits
    # `Image::Graphics`'s screen-owns-pixels redraw lifecycle.
    #
    # Two things differ from sixel/ReGIS:
    #
    # * The image is transmitted as raw 32-bit RGBA (base64, chunked at 4096
    #   bytes) — no palette quantization, so it's full true-color.
    # * A Kitty image is a *separate layer*, not pixels the cell grid can paint
    #   over. So a stable image+placement id is used (re-transmitting replaces
    #   rather than stacking), and erasing on hide/detach issues an explicit
    #   delete (`a=d`) via the `#graphic_cleared` hook, not a cell invalidate.
    #
    # The image is scaled by the terminal to exactly fill the widget's cell box
    # (`c=`/`r=`), so it fills cleanly regardless of font metrics.
    #
    # ```
    # img = Widget::Image::Kitty.new file: "pic.png", width: 40, height: 12, parent: screen
    # ```
    class Image::Kitty < Image::Graphics
      @@next_id = 0_u32

      # Stable Kitty image id, so re-transmits replace this widget's image
      # instead of piling up new ones.
      @img_id : UInt32

      def initialize(*args, **opts)
        @@next_id += 1
        @img_id = @@next_id
        super *args, **opts
        # A Kitty image isn't erased by re-emitting cells, so delete it on
        # destroy too (Hide/Detach already go through `#graphic_cleared`).
        on(::Crysterm::Event::Destroy) { screen?.try { |s| delete_image s } }
      end

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols * cell_pixel_width, rows * cell_pixel_height}
      end

      # Kitty places at the text cursor (positioned by the base class), so the
      # *ox*/*oy* pixel origin is unused.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32) : String
        # Pack raw RGBA, top-to-bottom.
        rgba = Bytes.new(pw * ph * 4)
        i = 0
        ph.times do |y|
          rin = bmp[y]
          pw.times do |x|
            px = rin[x]?
            if px
              rgba[i] = px.r.to_u8!; rgba[i + 1] = px.g.to_u8!
              rgba[i + 2] = px.b.to_u8!; rgba[i + 3] = px.a.to_u8!
            end
            i += 4
          end
        end

        b64 = Base64.strict_encode rgba

        # Display scaled into the widget's cell box (recovered from the pixel
        # size and cell metrics), so the image fills it exactly.
        cols = cell_pixel_width > 0 ? pw // cell_pixel_width : pw
        rows = cell_pixel_height > 0 ? ph // cell_pixel_height : ph
        cols = 1 if cols < 1
        rows = 1 if rows < 1

        io = String::Builder.new
        chunk = 4096
        offset = 0
        first = true
        total = b64.bytesize
        while offset < total
          slice = b64[offset, Math.min(chunk, total - offset)]
          offset += chunk
          more = offset < total ? 1 : 0
          io << "\e_G"
          if first
            # a=T transmit+display, f=32 RGBA, s/v pixel size, c/r cell box,
            # i/p stable ids (replace, don't accumulate), q=2 suppress replies.
            io << "a=T,f=32,s=" << pw << ",v=" << ph \
              << ",i=" << @img_id << ",p=1,c=" << cols << ",r=" << rows \
              << ",q=2,m=" << more
            first = false
          else
            io << "m=" << more
          end
          io << ';' << slice << "\e\\"
        end
        io.to_s
      end

      # A Kitty image is a separate layer the terminal's cells never overdraw, so
      # it only needs (re)emitting when it actually changes (new frame / move /
      # resize), not on every screen render like sixel.
      protected def repaint_every_frame? : Bool
        false
      end

      # Erase by telling Kitty to delete this image (and its placements);
      # re-emitting cells wouldn't cover a Kitty image.
      protected def graphic_cleared(s : ::Crysterm::Screen)
        delete_image s
      end

      private def delete_image(s : ::Crysterm::Screen)
        s.tput._oprint "\e_Ga=d,d=i,i=#{@img_id},q=2\e\\"
        s.tput.flush
      end
    end
  end
end
