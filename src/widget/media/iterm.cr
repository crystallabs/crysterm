require "base64"
require "../../widget_media_graphics"

module Crysterm
  class Widget
    # Renders an image with the **iTerm2 inline images protocol** (`OSC 1337 ;
    # File=…`): the original, undecoded image file is base64-encoded and sent
    # in-band, and a supporting terminal (iTerm2, WezTerm, Konsole, mintty, …)
    # decodes and draws it at the cursor. The terminal owns the pixels, so this
    # inherits `Media::Graphics`'s redraw/erase lifecycle; re-emitting cells
    # clears the image, so no explicit delete is needed.
    #
    # The protocol carries the encoded file as-is (PNG/JPEG/GIF), so this backend
    # never decodes: `#build_payload` wraps the raw bytes, sized to the widget's
    # box in *cells*.
    #
    # ```
    # img = Widget::Media::Iterm.new file: "pic.png", width: 40, height: 12, parent: window
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Iterm screenshot](../../../tests/widget/media/iterm/iterm.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Iterm < Media::Graphics
      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        # Unused (we size in cells), but feeds the payload cache key.
        {cols, rows}
      end

      # Wraps the original file bytes in the OSC 1337 sequence, sized to the cell
      # box. iTerm2 draws at the cursor, so the pixel origin is irrelevant.
      protected def build_payload(pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                                  cols : Int32, rows : Int32) : String?
        bytes = raw_bytes || return nil
        b64 = Base64.strict_encode bytes
        # iTerm2 letterboxes within the width×height cell box when
        # preserveAspectRatio=1; Stretch wants it off. Cover/crop isn't
        # expressible in the protocol, so it falls back to preserving aspect.
        par = @fit.stretch? ? 0 : 1
        String.build do |io|
          io << "\e]1337;File=inline=1;size=" << bytes.size \
            << ";width=" << cols << ";height=" << rows \
            << ";preserveAspectRatio=" << par << ':' << b64 << '\a'
        end
      end

      # iTerm2 animates an inline GIF itself, so the whole file is transmitted
      # once and no per-frame loop is needed.
      protected def needs_frame_loop? : Bool
        false
      end

      # Unused: `#build_payload` is overridden to skip decoding.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                 cols : Int32, rows : Int32) : String
        raise "Media::Iterm transmits the raw file via #build_payload; #encode is unused"
      end
    end
  end
end
