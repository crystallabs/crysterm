require "base64"
require "../../widget_media_graphics"

module Crysterm
  class Widget
    # Renders an image with the **Kitty graphics protocol**: an in-band APC
    # escape (`ESC _G <control> ; <base64 payload> ESC \`) that a Kitty-protocol
    # terminal (kitty, WezTerm, Konsole, Ghostty, …) draws as true RGBA pixels.
    # The terminal owns the pixels, so this inherits `Media::Graphics`'s redraw
    # lifecycle.
    #
    # Differs from sixel/ReGIS:
    #
    # * Transmitted as raw 32-bit RGBA (base64, chunked at 4096 bytes) — no
    #   palette quantization, full true-color.
    # * A Kitty image is a *separate layer*, not pixels the cell grid can paint
    #   over. A stable image+placement id is used, so re-transmitting replaces
    #   rather than stacks; erasing needs an explicit delete (`a=d`), not a cell
    #   invalidate.
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

      # Which double-buffer the *next* emit targets. Must be toggled per emitted
      # frame rather than derived from `@anim_index`: a streaming video pins
      # `@anim_index` at 0, and an odd-length animation wraps last→0, and both
      # must still alternate buffers to keep the swap atomic.
      @buffer_parity = false

      # Stacking order, mapped to the Kitty placement `z=` parameter. `nil`
      # (default) omits `z=`, drawing on top of text. Negative draws under text:
      # `z = -1` shows through default-background cells but is hidden by a
      # concrete background color; below `INT32_MIN/2` (`-1_073_741_824`) also
      # goes under non-default cell backgrounds.
      getter z : Int32?

      # `z` is baked into the memoized payload and the emit-skip key ignores it,
      # so a change must drop the payload cache and request a render or the image
      # stays on its old stacking layer until an unrelated move/resize.
      def z=(v : Int32?) : Int32?
        return v if v == @z
        @z = v
        reset_payload_cache
        request_render
        v
      end

      # Renders as a background (under text, `z = -1`) or back to the default
      # on-top placement (`z = nil`).
      def background=(on : Bool) : Bool
        self.z = on ? -1 : nil
        on
      end

      def background? : Bool
        (@z || 0) < 0
      end

      # A negative `z` places the image under the cell text (the whole point of
      # `background=`), so a capture must composite it before the text pass.
      def capture_under_text? : Bool
        (@z || 0) < 0
      end

      def initialize(*args, **opts)
        @@next_id += 1; @id_a = @@next_id
        @@next_id += 1; @id_b = @@next_id
        super *args, **opts
        # A Kitty image isn't erased by re-emitting cells, so it must be deleted
        # explicitly on destroy.
        on(::Crysterm::Event::Destroy) { window?.try { |s| delete_image s } }
      end

      # Stand in for the concrete image ids in the cached payload; the real ids
      # are substituted per emit. They must never collide with the base64
      # alphabet (`A-Za-z0-9+/=`) or the numeric control keys — hence the braces.
      ID_PLACEHOLDER    = "{i}"
      OTHER_PLACEHOLDER = "{o}"

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        pw = cols * cell_pixel_width
        ph = rows * cell_pixel_height
        # The terminal scales to the cell box (c=/r=), so transmitting more
        # pixels than the source has only wastes bandwidth: cap resolution to
        # the source's, scaling uniformly to keep the box aspect intact.
        # `Fit::None` must not be capped — a reduced box makes the compose step
        # crop the source, and c=/r= then re-inflates that crop to fill the box,
        # yielding a magnified band instead of a native-size centered image.
        if (res = source_resolution) && !@fit.none?
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

      # Reused RGBA scratch, sized to `pw*ph*4` and refilled in place each frame;
      # a fresh buffer per frame would be hundreds of KB of garbage. Safe because
      # encoding runs only on the single render fiber and every byte is rewritten
      # each frame (transparent pixels are explicitly zeroed).
      @rgba_scratch : Bytes = Bytes.empty

      # Kitty places at the text cursor, so the *ox*/*oy* pixel origin is unused.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                 cols : Int32, rows : Int32) : String
        # Pack raw RGBA, top-to-bottom, into the reused scratch.
        need = pw * ph * 4
        rgba = @rgba_scratch
        rgba = @rgba_scratch = Bytes.new(need) if rgba.size != need
        i = 0
        ph.times do |y|
          rin = bmp[y]
          pw.times do |x|
            px = rin[x]?
            if px
              rgba[i] = px.r.to_u8!; rgba[i + 1] = px.g.to_u8!
              rgba[i + 2] = px.b.to_u8!; rgba[i + 3] = px.a.to_u8!
            else
              # Reused buffer: a transparent pixel must clear the previous
              # frame's bytes at this position, not inherit them.
              rgba[i] = 0u8; rgba[i + 1] = 0u8; rgba[i + 2] = 0u8; rgba[i + 3] = 0u8
            end
            i += 4
          end
        end

        # Display scaled into the widget's cell box (c=/r=), filling it exactly
        # regardless of transmitted pixel size.
        cols = 1 if cols < 1
        rows = 1 if rows < 1

        # Pre-size the builder to the payload's known final size, so a large
        # frame doesn't grow (and re-copy) the buffer up from the 64-byte default
        # in doublings. Estimate: base64 of `need` bytes + a per-chunk escape
        # wrapper (`\e_Gm=1;` … `\e\\`) + the double-buffer delete suffix.
        io = if Config.media_reuse_buffers
               b64_len = ((need + 2) // 3) * 4
               n_chunks = (need + 3071) // 3072
               String::Builder.new(b64_len + n_chunks * 72 + 96)
             else
               String::Builder.new
             end
        # Stream base64 into the payload in transmit-chunk units rather than
        # materializing the whole encoded string first. 3072 raw bytes encode to
        # exactly 4096 base64 chars with no interior padding (3072 % 3 == 0), so
        # each chunk is self-contained and the concatenation is identical to
        # encoding the full buffer; only the final short chunk carries padding.
        chunk_raw = 3072
        offset = 0
        first = true
        while offset < need
          n = Math.min(chunk_raw, need - offset)
          offset += n
          more = offset < need ? 1 : 0
          io << "\e_G"
          if first
            # a=T transmit+display, f=32 RGBA, s/v pixel size, c/r cell box,
            # i/p stable ids (replace, don't accumulate), q=2 suppress replies.
            # C=1 keeps the text cursor put: otherwise a full-height image would
            # scroll the window, carrying off cells above it (e.g. a title row).
            io << "a=T,f=32,s=" << pw << ",v=" << ph \
              << ",i=" << ID_PLACEHOLDER << ",p=1,c=" << cols << ",r=" << rows \
              << ",C=1,q=2"
            @z.try { |z| io << ",z=" << z }
            io << ",m=" << more
            first = false
          else
            io << "m=" << more
          end
          io << ';'
          Base64.strict_encode(rgba[offset - n, n], io)
          io << "\e\\"
        end
        # Double-buffer: delete the *other* buffer now that the new frame is
        # placed. This must stay inside the synchronized-output wrapper so
        # place+delete present as one atomic swap. Deleting a never-created id is
        # a no-op under q=2.
        if double_buffer?
          io << "\e_Ga=d,d=i,i=" << OTHER_PLACEHOLDER << ",q=2\e\\"
        end
        io.to_s
      end

      # Substitutes the concrete image ids at emit time. The encoded payload is
      # memoized per frame, so the ids must *not* be baked in: a looping
      # animation would serve every frame from cache and the buffer alternation
      # that defeats tearing would freeze to a per-index parity.
      def finalize_payload(payload : String) : String
        io = String::Builder.new
        emit_payload io, payload
        io.to_s
      end

      # Streams the payload with its `{i}`/`{o}` id placeholders resolved straight
      # into *io*, writing cached literal runs rather than `gsub`-copying the
      # whole (multi-MB) base64 frame on every emit.
      protected def emit_payload(io : String::Builder, payload : String) : Nil
        literals, keys = payload_segments payload
        if double_buffer?
          primary, other = @buffer_parity ? {@id_b, @id_a} : {@id_a, @id_b}
          @buffer_parity = !@buffer_parity # next emit targets the other buffer
          write_segments io, literals, keys, primary, other
        else
          # Single buffer: `{i}` -> @id_a, and any (never-present) `{o}` is left
          # literal.
          write_segments io, literals, keys, @id_a, nil
        end
      end

      # Interleaves the literal *literals* runs with the per-gap id chosen by
      # *keys* (`'i'` -> *id_i*, `'o'` -> *id_o*, or the placeholder left literal
      # when *id_o* is nil). `literals.size == keys.size + 1`.
      private def write_segments(io : String::Builder, literals : Array(String),
                                 keys : Array(Char), id_i : UInt32, id_o : UInt32?)
        literals.each_with_index do |lit, k|
          io << lit
          next unless k < keys.size
          case keys[k]
          when 'i' then io << id_i
          when 'o'
            if id_o
              io << id_o
            else
              io << OTHER_PLACEHOLDER
            end
          end
        end
      end

      # Split of the current cached payload into literal runs around the id
      # placeholders, plus the ordered placeholder key (`'i'`/`'o'`) in each gap.
      # Cached by payload object identity — the same `String` object comes back
      # for every emit of a frame — so the split runs once per distinct frame.
      @seg_for : String?
      @seg_literals : Array(String)?
      @seg_keys : Array(Char)?

      private def payload_segments(payload : String) : Tuple(Array(String), Array(Char))
        f = @seg_for
        if f && f.same?(payload)
          return {@seg_literals.as(Array(String)), @seg_keys.as(Array(Char))}
        end
        literals = [] of String
        keys = [] of Char
        pos = 0
        loop do
          ii = payload.index(ID_PLACEHOLDER, pos)
          oo = payload.index(OTHER_PLACEHOLDER, pos)
          if ii && (oo.nil? || ii < oo)
            literals << payload[pos...ii]
            keys << 'i'
            pos = ii + ID_PLACEHOLDER.size
          elsif oo
            literals << payload[pos...oo]
            keys << 'o'
            pos = oo + OTHER_PLACEHOLDER.size
          else
            literals << payload[pos..]
            break
          end
        end
        @seg_for = payload
        @seg_literals = literals
        @seg_keys = keys
        {literals, keys}
      end

      # A Kitty image is a separate layer the terminal's cells never overdraw, so
      # it only needs (re)emitting on actual change (frame/move/resize).
      protected def repaint_every_frame? : Bool
        false
      end

      # Erase by telling Kitty to delete this image (and its placements);
      # re-emitting cells wouldn't cover a Kitty image.
      protected def graphic_cleared(s : ::Crysterm::Window)
        delete_image s
      end

      # The delete-placement control sequence for one concrete image id
      # (`a=d` delete, `d=i` by id, `q=2` suppress replies).
      private def delete_seq(id : UInt32) : String
        "\e_Ga=d,d=i,i=#{id},q=2\e\\"
      end

      private def delete_image(s : ::Crysterm::Window)
        # Two args (not a concatenated string): `_oprint` joins them straight to
        # the output IO, skipping the intermediate allocation.
        s.tput._oprint delete_seq(@id_a), delete_seq(@id_b)
        s.tput.flush
      end

      # Single-buffer only ever uses `@id_a`, so on the true→false switch the last
      # frame parked under `@id_b` would linger as a frozen ghost layer; delete
      # it (a no-op under q=2 if never placed). The false→true direction needs no
      # terminal action, as the next encode carries the place-then-delete swap.
      protected def on_double_buffer_changed(v : Bool)
        return if v
        window?.try do |s|
          s.tput._oprint delete_seq(@id_b)
          s.tput.flush
        end
      end
    end
  end
end
