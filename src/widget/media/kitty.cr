require "base64"
require "../../widget_media_graphics"

module Crysterm
  class Widget
    # Renders an image with the **Kitty graphics protocol**: an in-band APC
    # escape (`ESC _G <control> ; <base64 payload> ESC \`) that a Kitty-protocol
    # terminal (kitty, WezTerm, Konsole, Ghostty, …) draws as true RGBA pixels.
    # Like sixel the pixels are owned by the terminal, so this inherits
    # `Media::Graphics`'s window-owns-pixels redraw lifecycle.
    #
    # Differs from sixel/ReGIS:
    #
    # * Transmitted as raw 32-bit RGBA (base64, chunked at 4096 bytes) — no
    #   palette quantization, full true-color.
    # * A Kitty image is a *separate layer*, not pixels the cell grid can paint
    #   over. A stable image+placement id is used (re-transmitting replaces
    #   rather than stacking); erasing on hide/detach issues an explicit
    #   delete (`a=d`) via `#graphic_cleared`, not a cell invalidate.
    #
    # The image is scaled by the terminal to exactly fill the widget's cell box
    # (`c=`/`r=`), regardless of font metrics.
    #
    # ```
    # img = Widget::Media::Kitty.new file: "pic.png", width: 40, height: 12, parent: window
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Kitty screenshot](../../../tests/widget/media/kitty/kitty.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Kitty < Media::Graphics
      @@next_id = 0_u32

      # Two Kitty image ids for double-buffering. With `double_buffer` on, an
      # animation alternates ids per frame (even→`@id_a`, odd→`@id_b`): each
      # frame transmits+places its id and *then* deletes the other, so the new
      # frame is fully present before the old is removed — no mid-update blank.
      # With `double_buffer` off, only `@id_a` is used and re-transmits replace
      # it in place.
      @id_a : UInt32
      @id_b : UInt32

      # Stacking order, mapped to the Kitty placement `z=` parameter. `nil`
      # (default) omits `z=`, drawing on top of text. Negative draws under text:
      # `z = -1` shows through default-background cells but is hidden by a
      # concrete background color; below `INT32_MIN/2` (`-1_073_741_824`) also
      # goes under non-default cell backgrounds.
      property z : Int32?

      # Convenience: render as a background (under text, `z = -1`) or back to the
      # default on-top placement (`z = nil`).
      def background=(on : Bool) : Bool
        @z = on ? -1 : nil
        on
      end

      def background? : Bool
        (@z || 0) < 0
      end

      def initialize(*args, **opts)
        @@next_id += 1; @id_a = @@next_id
        @@next_id += 1; @id_b = @@next_id
        super *args, **opts
        # A Kitty image isn't erased by re-emitting cells, so delete it on
        # destroy too (Hide/Detach already go through `#graphic_cleared`).
        on(::Crysterm::Event::Destroy) { window?.try { |s| delete_image s } }
      end

      # The image id this frame transmits to: the front buffer when not
      # double-buffering, else the buffer chosen by the frame's parity.
      private def frame_id : UInt32
        double_buffer? && !@anim_index.even? ? @id_b : @id_a
      end

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        pw = cols * cell_pixel_width
        ph = rows * cell_pixel_height
        # The terminal scales the image to the cell box (c=/r=), so transmitting
        # more pixels than the source has is pure waste — for animation/video it
        # would re-upload a full-window frame every tick, tanking frame rate and
        # flashing blank during the multi-chunk replace. Cap resolution to the
        # source's, scaling uniformly to keep the box aspect distortion-free.
        if res = source_resolution
          sw, sh = res
          long_box = {pw, ph}.max
          long_src = {sw, sh}.max
          if long_src > 0 && long_box > long_src
            scale = long_src / long_box.to_f
            pw = (pw * scale).round.to_i
            ph = (ph * scale).round.to_i
          end
        end
        {pw < 1 ? 1 : pw, ph < 1 ? 1 : ph}
      end

      # Kitty places at the text cursor (positioned by the base class), so the
      # *ox*/*oy* pixel origin is unused.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                 cols : Int32, rows : Int32) : String
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

        # Display scaled into the widget's cell box (c=/r=), filling it exactly
        # regardless of transmitted pixel size.
        cols = 1 if cols < 1
        rows = 1 if rows < 1

        id = frame_id
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
            # C=1 keeps the text cursor put: otherwise a full-height image would
            # scroll the window, carrying off cells above it (e.g. a title row).
            # Optional `z=` sets stacking order (negative under text; see `#z`).
            io << "a=T,f=32,s=" << pw << ",v=" << ph \
              << ",i=" << id << ",p=1,c=" << cols << ",r=" << rows \
              << ",C=1,q=2"
            @z.try { |z| io << ",z=" << z }
            io << ",m=" << more
            first = false
          else
            io << "m=" << more
          end
          io << ';' << slice << "\e\\"
        end
        # Double-buffer: delete the *other* buffer now that the new frame is
        # placed. Wrapped by the base in synchronized output, so place+delete
        # present as one atomic swap. (Deleting a never-created id is a no-op
        # under q=2.)
        if double_buffer?
          other = id == @id_a ? @id_b : @id_a
          io << "\e_Ga=d,d=i,i=" << other << ",q=2\e\\"
        end
        io.to_s
      end

      # A Kitty image is a separate layer the terminal's cells never overdraw,
      # so it only needs (re)emitting on actual change (frame/move/resize), not
      # on every window render like sixel.
      protected def repaint_every_frame? : Bool
        false
      end

      # Erase by telling Kitty to delete this image (and its placements);
      # re-emitting cells wouldn't cover a Kitty image.
      protected def graphic_cleared(s : ::Crysterm::Window)
        delete_image s
      end

      private def delete_image(s : ::Crysterm::Window)
        s.tput._oprint "\e_Ga=d,d=i,i=#{@id_a},q=2\e\\\e_Ga=d,d=i,i=#{@id_b},q=2\e\\"
        s.tput.flush
      end
    end
  end
end
