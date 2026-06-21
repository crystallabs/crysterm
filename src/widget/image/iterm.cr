require "base64"
require "./graphics"

module Crysterm
  class Widget
    # Renders an image with the **iTerm2 inline images protocol** (`OSC 1337 ;
    # File=…`): the original, *undecoded* image file is base64-encoded and sent
    # in-band, and a supporting terminal (iTerm2, WezTerm, Konsole, mintty,
    # VS Code's terminal, …) decodes and draws it at the cursor. Like sixel the
    # pixels are owned by the terminal, so this inherits `Image::Graphics`'s
    # screen-owns-pixels redraw/erase lifecycle (the image occupies cells, so
    # re-emitting them clears it — no special delete needed, unlike Kitty).
    #
    # Because the protocol carries the encoded file as-is (PNG/JPEG/GIF), this
    # backend doesn't decode at all — it overrides `#build_payload` to wrap the
    # raw bytes, and sizes the image to the widget's cell box in *cells*
    # (`width=`/`height=`, `preserveAspectRatio=0`).
    #
    # ```
    # img = Widget::Image::Iterm.new file: "pic.png", width: 40, height: 12, parent: screen
    # ```
    class Image::Iterm < Image::Graphics
      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        # Unused (we size in cells), but feeds the payload cache key.
        {cols, rows}
      end

      # Wrap the original file bytes in the OSC 1337 sequence, sized to the cell
      # box. iTerm2 draws at the cursor (positioned by the base), so the pixel
      # origin is irrelevant.
      protected def build_payload(pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                                  cols : Int32, rows : Int32) : String?
        bytes = raw_bytes || return nil
        b64 = Base64.strict_encode bytes
        # iTerm2 letterboxes within the width×height cell box when
        # preserveAspectRatio=1; Stretch wants it off. (Cover/crop isn't
        # expressible in the protocol, so it falls back to preserving aspect.)
        par = @fit.stretch? ? 0 : 1
        String.build do |io|
          io << "\e]1337;File=inline=1;size=" << bytes.size \
            << ";width=" << cols << ";height=" << rows \
            << ";preserveAspectRatio=" << par << ':' << b64 << '\a'
        end
      end

      # iTerm2 animates an inline GIF itself, so we transmit the whole file and
      # let the terminal play it — no per-frame loop on our side.
      protected def needs_frame_loop? : Bool
        false
      end

      # Never called — `#build_payload` is overridden to skip decoding.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32) : String
        raise "Image::Iterm transmits the raw file via #build_payload; #encode is unused"
      end
    end
  end
end
