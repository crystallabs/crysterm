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

      # Which double-buffer the *next* emit targets. Toggled once per emitted
      # frame (not derived from `@anim_index`), so a streaming video — which
      # pins `@anim_index` at 0 every frame — and an odd-length animation that
      # wraps last→0 both still alternate buffers, keeping the place-then-delete
      # swap atomic.
      @buffer_parity = false

      # Stacking order, mapped to the Kitty placement `z=` parameter. `nil`
      # (default) omits `z=`, drawing on top of text. Negative draws under text:
      # `z = -1` shows through default-background cells but is hidden by a
      # concrete background color; below `INT32_MIN/2` (`-1_073_741_824`) also
      # goes under non-default cell backgrounds.
      getter z : Int32?

      # Runtime setter: `z` is baked into the encoded payload (`,z=`) by `#encode`,
      # and the payload is memoized per geometry, while `#redraw_image`'s emit-skip
      # compares a z-free key — so a plain assignment would neither re-encode nor
      # re-emit, leaving the image on its old stacking layer until an unrelated
      # move/resize changed the geometry key. Drop the payload cache and request a
      # render so the new stacking order takes effect immediately.
      def z=(v : Int32?) : Int32?
        return v if v == @z
        @z = v
        reset_payload_cache
        request_render
        v
      end

      # Convenience: render as a background (under text, `z = -1`) or back to the
      # default on-top placement (`z = nil`). Routes through `#z=` so the change
      # actually re-emits.
      def background=(on : Bool) : Bool
        self.z = on ? -1 : nil
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

      # Placeholders `#encode` bakes into the cached payload in place of the
      # concrete image ids; `#finalize_payload` substitutes the real ids per
      # emit. They must never collide with the base64 payload (alphabet
      # `A-Za-z0-9+/=`) or the numeric control keys — the braces guarantee that.
      ID_PLACEHOLDER    = "{i}"
      OTHER_PLACEHOLDER = "{o}"

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        pw = cols * cell_pixel_width
        ph = rows * cell_pixel_height
        # The terminal scales the image to the cell box (c=/r=), so transmitting
        # more pixels than the source has is pure waste — for animation/video it
        # would re-upload a full-window frame every tick, tanking frame rate and
        # flashing blank during the multi-chunk replace. Cap resolution to the
        # source's, scaling uniformly to keep the box aspect distortion-free.
        # Skip the cap for `Fit::None`: its whole point is a fixed native pixel
        # size independent of the box, which is NOT invariant under a box
        # reduction — the reduced box makes `Media::Fitting.compose` crop the
        # source, and the terminal's c=/r= then re-inflates that crop to fill the
        # cell box (a magnified band instead of the native-size centered image).
        # Stretch/Contain/Cover preserve aspect and are safe to cap.
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

      # Reused RGBA scratch, sized to the current `pw*ph*4` and refilled in place
      # each frame. A Kitty-backed chart/donut re-encodes every changed frame, so
      # a fresh `Bytes.new(pw*ph*4)` here (plus the same-size base64 `String`
      # below) was hundreds of KB of transient garbage *per frame* — the dominant
      # per-frame allocation on the graphics path. Encoding runs only on the
      # single render fiber, so one shared buffer is safe. Every byte is rewritten
      # each frame (the `else` branch zeroes transparent pixels), so no stale
      # bytes from a previous frame can survive the reuse.
      @rgba_scratch : Bytes = Bytes.empty

      # Kitty places at the text cursor (positioned by the base class), so the
      # *ox*/*oy* pixel origin is unused.
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

        # Pre-size the builder to the payload's known final size when reuse is on,
        # so a ~230 KB frame doesn't grow (and re-copy) the builder's buffer from
        # its 64-byte default up in doublings — halving the per-frame payload
        # garbage. The final `String` itself is inherent (its bytes change every
        # frame), but the doubling copies are not. Estimate: base64 of `need`
        # bytes + a per-chunk escape wrapper (`\e_Gm=1;` … `\e\\`) + the
        # double-buffer delete suffix.
        io = if Config.media_reuse_buffers
               b64_len = ((need + 2) // 3) * 4
               n_chunks = (need + 3071) // 3072
               String::Builder.new(b64_len + n_chunks * 72 + 96)
             else
               String::Builder.new
             end
        # Stream base64 straight into the payload in transmit-chunk units rather
        # than materializing the whole encoded string first (a second same-size
        # transient). 3072 raw bytes encode to exactly 4096 base64 chars with no
        # interior padding (3072 % 3 == 0), so each chunk is self-contained and
        # their concatenation is byte-identical to encoding the full buffer —
        # only the final (short) chunk carries any `=` padding, exactly as before.
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
            # Optional `z=` sets stacking order (negative under text; see `#z`).
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
        # placed. Wrapped by the base in synchronized output, so place+delete
        # present as one atomic swap. (Deleting a never-created id is a no-op
        # under q=2.) The concrete ids are filled in per emit by
        # `#finalize_payload` — see below.
        if double_buffer?
          io << "\e_Ga=d,d=i,i=" << OTHER_PLACEHOLDER << ",q=2\e\\"
        end
        io.to_s
      end

      # Substitute the concrete image ids at emit time. Because
      # `Media::Graphics#payload_for` memoizes the encoded string per frame, the
      # id must *not* be baked in — otherwise a fixed-size looping animation
      # serves every frame from cache after the first loop and the buffer
      # alternation (which defeats tearing) freezes to a per-index parity. Doing
      # the swap here, per emit, keeps alternation tied to emit order. When not
      # double-buffering there is a single buffer (`@id_a`) and no swap.
      #
      # Kept as the string-returning contract (exercised directly by specs); the
      # per-emit hot path is `#emit_payload`, which streams the same bytes into the
      # output builder without materializing the full substituted payload.
      def finalize_payload(payload : String) : String
        io = String::Builder.new
        emit_payload io, payload
        io.to_s
      end

      # Streams the payload with its `{i}`/`{o}` id placeholders resolved straight
      # into *io*. The literal runs around the placeholders are split once per
      # distinct cached payload (`#payload_segments`, keyed on object identity) and
      # reused across emits, so a looping animation/video avoids `gsub`-copying
      # the whole (multi-MB) base64 frame twice per emitted frame — it just writes
      # the cached segments + the current ids. Buffer parity toggles once per emit
      # (see `#finalize_payload`).
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
      # placeholders, plus the ordered placeholder key (`'i'`/`'o'`) sitting in
      # each gap. Cached by payload object identity: `payload_for` hands back the
      # same `String` object for every emit of a given frame, so the scan/split
      # runs once per distinct frame instead of once per emit.
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

      # Switching to single-buffer while a double-buffered frame is still placed
      # under `@id_b`: single-buffer only ever uses `@id_a`, so the last
      # double-buffered frame parked under `@id_b` would linger as a frozen ghost
      # layer. Delete it now (a no-op if `@id_b` was never placed, under q=2).
      # The false→true direction needs no terminal action — the dropped payload
      # cache re-encodes the place-then-delete swap into subsequent frames.
      protected def on_double_buffer_changed(v : Bool)
        return if v
        window?.try do |s|
          s.tput._oprint "\e_Ga=d,d=i,i=#{@id_b},q=2\e\\"
          s.tput.flush
        end
      end
    end
  end
end
