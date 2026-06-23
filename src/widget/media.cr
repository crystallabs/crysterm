module Crysterm
  class Widget
    # Factory for image widgets, ported from Blessed's `image` element.
    #
    # In Blessed, `image` is a thin dispatcher that constructs one of several
    # concrete image widgets depending on `type`. Crystal can't mutate an
    # object's class at runtime the way Blessed does, so here `Media` is a
    # factory: `Media.new` returns the concrete widget for the requested `type`
    # and forwards all other options to it.
    #
    # Every backend is a `Media::Base` (the shared contract: image source,
    # `fit`, animation, and the `image.unsupported` policy), so `Media.new`
    # returns `Media::Base`. They are grouped by how the image's pixels reach the
    # screen — which determines the rendering/erase machinery, and the abstract
    # family base each one inherits:
    #
    # * **cell-grid** (`Media::Cells`) — the image becomes character cells
    #   Crysterm owns and diffs: `Ansi` (`Media::Ansi`) and `Glyph`
    #   (`Media::Glyph`, sub-cell glyphs).
    # * **external overlay** (`Media::External`) — a helper process paints the
    #   pixels in its own window: `Overlay` (`Media::Overlay`, w3mimgdisplay) and
    #   `Ueberzug` (`Media::Ueberzug`).
    # * **in-band terminal graphics** (`Media::Graphics`) — the terminal renders
    #   an escape sequence as pixels: `Sixel` (`Media::Sixel`), `Regis`
    #   (`Media::Regis`), `Kitty` (`Media::Kitty`) and `Iterm` (`Media::Iterm`).
    # * **separate window** — the terminal renders into another window entirely:
    #   `Tek` (`Media::Tek`, Tektronix 4014), directly on `Media::Base`.
    #
    # ```
    # img = Widget::Media.new file: "picture.png", parent: screen # => Media::Ansi
    # img = Widget::Media.new file: "picture.png", type: Widget::Media::Type::Sixel, parent: screen
    # ```
    #
    # The factory forwards a single common option bag (`file`, position, size) to
    # whichever backend is selected; backend-specific options (e.g. Media::Glyph's
    # `mode`, Media::Sixel's `dither`) are best passed by constructing the concrete
    # widget directly.
    module Media
      # 4×4 Bayer ordered-dither matrix (values 0..15), shared by the dithering
      # backends (`Media::Sixel`, `Media::Regis`, `Media::Tek`) which each used
      # to carry their own identical copy.
      BAYER_MATRIX = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
      ]

      # How an image is fit into a box whose aspect ratio differs from the
      # image's — shared by every backend so the behaviour is consistent.
      enum Fit
        Stretch # fill the box exactly, distorting aspect ratio (default)
        Contain # scale to fit inside the box, letterboxing the remainder
        Cover   # scale to fill the box, cropping the overflow

        # Lays an image of *sw*×*sh* into a *bw*×*bh* box, returning the drawn
        # size and top-left offset `{dw, dh, ox, oy}` (offsets are negative for
        # `Cover`, where the image is larger than the box and gets cropped).
        def layout(bw : Int32, bh : Int32, sw : Int32, sh : Int32) : Tuple(Int32, Int32, Int32, Int32)
          return {bw, bh, 0, 0} if stretch? || sw <= 0 || sh <= 0 || bw <= 0 || bh <= 0
          ar = sw.to_f / sh.to_f
          box_ar = bw.to_f / bh.to_f
          # Pin height (derive width) when the box is "wider" than the image for
          # Contain, or "taller" for Cover; pin width otherwise.
          pin_height = contain? ? (box_ar > ar) : (box_ar < ar)
          if pin_height
            dh = bh
            dw = (bh * ar).round.to_i
          else
            dw = bw
            dh = (dw / ar).round.to_i
          end
          dw = 1 if dw < 1
          dh = 1 if dh < 1
          {dw, dh, (bw - dw) // 2, (bh - dh) // 2}
        end
      end

      # Backend used to render the image. See the families described above.
      enum Type
        Ansi     # cell-grid, one cell per pixel (`Media::Ansi`)
        Glyph    # cell-grid, sub-cell Unicode glyphs (`Media::Glyph`)
        Overlay  # screen-owns-pixels, external w3mimgdisplay overlay (`Media::Overlay`)
        Ueberzug # screen-owns-pixels, external überzug overlay (`Media::Ueberzug`)
        Sixel    # screen-owns-pixels, in-band sixel graphics (`Media::Sixel`)
        Regis    # screen-owns-pixels, in-band ReGIS vector graphics (`Media::Regis`)
        Kitty    # screen-owns-pixels, in-band Kitty graphics protocol (`Media::Kitty`)
        Iterm    # screen-owns-pixels, in-band iTerm2 inline images (`Media::Iterm`)
        Tek      # separate window, Tektronix 4014 vectors (`Media::Tek`)
      end

      # The kind of media to display, named after Qt Quick's media elements
      # (`Image`, `AnimatedImage`, `Video`). Used by `resolve` to pick the best
      # default backend, since the ranking differs by kind (e.g. iTerm2 animates
      # GIFs natively so it ranks higher for `AnimatedImage`, but it can't stream
      # raw video so it's excluded from `Video`).
      enum Content
        Image         # a single still image (Qt Quick: Image)
        AnimatedImage # an animated image — GIF / APNG (Qt Quick: AnimatedImage)
        Video         # a video file, decoded via `Media::VideoSource` (Qt Quick: Video)
      end

      # The default backend when `type:` is not given, resolved from the config
      # registry (key `image.backend`, env `CRYSTERM_MEDIA_BACKEND`, CLI
      # `--media-backend`). A concrete value (e.g. `kitty`) is used as-is; the
      # special value `auto` runs `resolve`, picking the content kind from *file*
      # (a video file resolves with `Content::Video`, which excludes backends that
      # can't play decoded frames; anything else with `Content::Image`). An
      # unrecognized value falls back to `Ansi`.
      def self.default_type(file : String? = nil) : Type
        backend = Crysterm::Config.media_backend
        return Type.parse?(backend) || Type::Ansi unless backend == "auto"
        content = (file && VideoSource.video?(file)) ? Content::Video : Content::Image
        resolve content
      end

      # The best backend `Type` for *content* on the current terminal.
      #
      # Walks the ranked candidate list for that content type (most
      # native/optimized first; see `candidates_for`), skips any the user has
      # excluded via the `image.exclude` "umask", and returns the first the
      # terminal supports — falling back to the universal cell grid (`Ansi`) when
      # nothing else qualifies.
      #
      # The terminal is described by *tput* (the live `Tput` from the global
      # screen by default); terminal facts come from `Tput::Emulator`/`Features`,
      # so no escape-sequence probing is done here. With no screen/terminal
      # handle, the safe fallback (the last non-excluded candidate) is returned.
      def self.resolve(content : Content = Content::Image, tput : ::Tput? = nil) : Type
        tput ||= (Crysterm::Screen.total > 0 ? Crysterm::Screen.global.tput : nil)
        excluded = excluded_types
        candidates = candidates_for(content).reject { |t| excluded.includes?(t) }

        if tp = tput
          emu = tp.emulator
          feat = tp.features
          candidates.each do |t|
            return t if backend_supported?(t, emu, feat)
          end
        end

        # No terminal handle, or nothing matched: the safest available fallback
        # (the lists end in `Ansi`, which works anywhere).
        candidates.last? || Type::Ansi
      end

      # Backends the user has excluded from automatic selection via the
      # `image.exclude` config option (a comma/space separated list of backend
      # names, e.g. `"kitty,sixel"`). `resolve` skips these and chooses the best
      # of what remains. Unknown names are ignored.
      def self.excluded_types : Array(Type)
        Crysterm::Config.media_exclude
          .split(/[\s,]+/, remove_empty: true)
          .compact_map { |s| Type.parse?(s) }
      end

      # Ranked best→fallback backend candidates for *content* (see `resolve`).
      private def self.candidates_for(content : Content) : Array(Type)
        case content
        in Content::Image
          [Type::Kitty, Type::Iterm, Type::Sixel, Type::Glyph, Type::Ansi]
        in Content::AnimatedImage
          # iTerm2 animates GIFs natively, so it ranks above Kitty here.
          [Type::Iterm, Type::Kitty, Type::Sixel, Type::Glyph, Type::Ansi]
        in Content::Video
          # iTerm2 / external overlays can't stream raw frames; excluded.
          [Type::Kitty, Type::Sixel, Type::Glyph, Type::Ansi]
        end
      end

      # Whether *type* can render on the terminal described by *emu*/*feat*.
      # Overlay/Ueberzug/Regis/Tek are never auto-selected (set `image.backend`
      # or pass `type:` explicitly for those).
      private def self.backend_supported?(type : Type, emu : ::Tput::Emulator, feat : ::Tput::Features) : Bool
        case type
        when .kitty? then emu.kitty_graphics?
        when .iterm? then emu.iterm_images?
        when .sixel? then emu.sixel?
        when .glyph? then feat.unicode?
        when .ansi?  then true
        else              false
        end
      end

      # Builds the concrete image/media widget for *type*, forwarding all
      # remaining options to its constructor. When *type* is omitted it is
      # resolved for the current terminal and *file*'s content kind via
      # `default_type` (a video file picks a video-capable backend); pass *type*
      # explicitly to force a specific backend.
      def self.new(*, type : Type? = nil, file : String? = nil, **opts) : Media::Base
        type ||= default_type(file)
        opts = opts.merge(file: file)
        case type
        in Type::Ansi     then Ansi.new **opts
        in Type::Glyph    then Glyph.new **opts
        in Type::Overlay  then Overlay.new **opts
        in Type::Ueberzug then Ueberzug.new **opts
        in Type::Sixel    then Sixel.new **opts
        in Type::Regis    then Regis.new **opts
        in Type::Kitty    then Kitty.new **opts
        in Type::Iterm    then Iterm.new **opts
        in Type::Tek      then Tek.new **opts
        end
      end

      # Process-wide decode cache: the same file shown by several widgets (or
      # reloaded) is parsed only once. The decoded `PNGGIF::PNG` holds the
      # full-resolution bitmap + raw frames; every widget derives its sized
      # render from it without mutating it, so the instance is shared read-only.
      # A `nil` value is a cached *failure* (see `decode`).
      @@decode_cache = {} of String => PNGGIF::PNG?

      # Decodes *file* (a local path or `http(s)` URL) once, caching the result
      # keyed on path + size + mtime (so an on-disk change invalidates it).
      # Returns `nil` on failure.
      #
      # Failures are cached too (as a `nil` value): `source` is called on every
      # render pass, so without negative caching a file that fails to decode —
      # especially a video whose ffprobe/ffmpeg pipeline errors — would re-spawn
      # the whole subprocess pipeline every frame and stall the UI. The
      # size+mtime key means a later edit (or a missing file later appearing)
      # produces a new key and re-decodes.
      def self.decode(file : String) : PNGGIF::PNG?
        key = file
        unless file =~ /^https?:/
          if info = File.info?(file)
            key = "#{file}\u{0}#{info.size}\u{0}#{info.modification_time.to_unix}"
          end
        end
        return @@decode_cache[key] if @@decode_cache.has_key?(key)
        png =
          begin
            if VideoSource.video? file
              # Decoded to animation frames via ffmpeg; nil if ffmpeg/ffprobe
              # are missing or decoding fails.
              VideoSource.decode file
            else
              data : String | Bytes = file
              data = Ansi.fetch(file) if file =~ /^https?:/
              PNGGIF::PNG.new(data)
            end
          rescue
            nil
          end
        @@decode_cache[key] = png
        png
      end

      # Empties the decode cache (e.g. to reclaim memory).
      def self.clear_decode_cache
        @@decode_cache.clear
      end
    end
  end
end
