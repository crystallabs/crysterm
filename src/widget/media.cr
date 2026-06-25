require "../widget_media_fit"

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

      # How an image's colors are dithered when they have to be reduced to a
      # smaller palette than the source (the fixed sixel grid, ReGIS' 8 colors,
      # the xterm-256/16 cube, or Tek's 1 bit). Shared by every backend that
      # quantizes, so the option means the same thing everywhere.
      #
      # Dithering trades spatial resolution for perceived color depth: instead of
      # snapping each pixel to its nearest palette entry (which bands smooth
      # gradients), it scatters the two nearest entries so the eye averages them
      # back to the in-between color.
      enum Dither
        None      # snap to the nearest palette entry — cleanest, but bands gradients
        Ordered   # 4×4 Bayer ordered dither — deterministic per pixel, so frame-stable
        Diffusion # Floyd–Steinberg error diffusion — best for a still; shimmers if animated
        Auto      # Diffusion for a still image, Ordered for an animation (default)

        # Collapses `Auto` to a concrete method: error diffusion gives the nicest
        # still, but its irregular stipple changes from frame to frame and would
        # shimmer in an animation, so an animated source falls back to the
        # frame-stable ordered dither. Any non-`Auto` value is returned as-is.
        def resolve(animated : Bool) : Dither
          return self unless auto?
          animated ? Ordered : Diffusion
        end
      end

      # Quantizes an RGBA *bmp* (*pw*×*ph*) to one backend value per pixel,
      # applying the requested *dither*. This is the shared color-reduction loop
      # for every palette backend (`Media::Sixel`, `Media::Regis`, `Media::Ansi`);
      # `Media::Tek` does its own 1-bit variant.
      #
      # The block is invoked once per opaque pixel with the channels to quantize
      # and an ordered-dither threshold *t* (the Bayer offset in `[-0.5, 0.5)` for
      # `Ordered`, else `0.0`); it must return `{value, qr, qg, qb}` — the value
      # to store (a palette index, or a packed `0xRRGGBB`) plus the RGB that value
      # actually resolves to, so `Diffusion` can spread the residual (target −
      # chosen) onto the not-yet-visited neighbours. Fully transparent pixels
      # (`a == 0`, or missing) are assigned *transparent* and never reach the
      # block. *animated* collapses `Dither::Auto` (see `Dither#resolve`).
      def self.dither_rgb(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32,
                          dither : Dither, animated : Bool, transparent : V,
                          & : Int32, Int32, Int32, Float64 -> Tuple(V, Int32, Int32, Int32)) : Array(Array(V)) forall V
        mode = dither.resolve(animated)
        diffuse = mode.diffusion?
        # Per-channel Floyd–Steinberg error carried to the current and next scan
        # line (kept as a two-row sliding window rather than a full-image buffer).
        cur_r = Array(Float64).new(pw, 0.0); cur_g = Array(Float64).new(pw, 0.0); cur_b = Array(Float64).new(pw, 0.0)
        nxt_r = Array(Float64).new(pw, 0.0); nxt_g = Array(Float64).new(pw, 0.0); nxt_b = Array(Float64).new(pw, 0.0)

        out = Array(Array(V)).new(ph)
        ph.times do |y|
          rin = bmp[y]
          row = Array(V).new(pw, transparent)
          pw.times do |x|
            px = rin[x]?
            if px.nil? || px.a == 0
              row[x] = transparent
              next
            end
            if diffuse
              wr = px.r + cur_r[x]; wg = px.g + cur_g[x]; wb = px.b + cur_b[x]
              value, qr, qg, qb = yield wr.round.to_i, wg.round.to_i, wb.round.to_i, 0.0
              row[x] = value
              er = wr - qr; eg = wg - qg; eb = wb - qb
              if x + 1 < pw
                cur_r[x + 1] += er * 7.0 / 16.0; cur_g[x + 1] += eg * 7.0 / 16.0; cur_b[x + 1] += eb * 7.0 / 16.0
                nxt_r[x + 1] += er * 1.0 / 16.0; nxt_g[x + 1] += eg * 1.0 / 16.0; nxt_b[x + 1] += eb * 1.0 / 16.0
              end
              nxt_r[x] += er * 5.0 / 16.0; nxt_g[x] += eg * 5.0 / 16.0; nxt_b[x] += eb * 5.0 / 16.0
              if x > 0
                nxt_r[x - 1] += er * 3.0 / 16.0; nxt_g[x - 1] += eg * 3.0 / 16.0; nxt_b[x - 1] += eb * 3.0 / 16.0
              end
            else
              t = mode.ordered? ? (BAYER_MATRIX[y & 3][x & 3] + 0.5) / 16.0 - 0.5 : 0.0
              value, _qr, _qg, _qb = yield px.r, px.g, px.b, t
              row[x] = value
            end
          end
          out << row
          # The next line's accumulated error becomes the current line's; reuse
          # the drained buffers as the new (zeroed) next line.
          cur_r, nxt_r = nxt_r, cur_r; cur_g, nxt_g = nxt_g, cur_g; cur_b, nxt_b = nxt_b, cur_b
          nxt_r.fill(0.0); nxt_g.fill(0.0); nxt_b.fill(0.0)
        end
        out
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

      # Selectable values of the `media.backend` config option: the special
      # `Auto` (pick the best `Type` the terminal supports) plus one member per
      # `Type`, named identically so a non-`Auto` choice maps to its `Type` via
      # `Type.parse?(choice.to_s)`. A real enum (rather than a free string) so
      # the option is an explicit, validated, dump-round-trippable choice.
      enum Backend
        Auto # Pick the best backend the terminal supports (see `resolve`)
        Ansi
        Glyph
        Overlay
        Ueberzug
        Sixel
        Regis
        Kitty
        Iterm
        Tek
      end

      # Selectable values of the `media.unsupported` config option: what a
      # backend does when asked for a feature it can't provide (see `#unsupported`).
      enum Unsupported
        Ignore # Do what the backend can; skip the unsupported part
        Error  # Raise `Media::UnsupportedError`
      end

      # Selectable values of the `media.video_decode` config option (see
      # `VideoSource.mode`). `Auto` decides per-file from the estimated length.
      enum VideoDecode
        Auto   # Stream when the estimated frame count exceeds `video.max_frames`, else eager
        Eager  # Decode all frames into memory (best for short loops)
        Stream # Decode on demand at constant memory (best for long videos)
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
        Painter       # vector/line-art rasterized fresh each frame (`Graph::Canvas`)
        Background    # an image painted *behind* a widget's content (CSS `background-image`)
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
        # A non-`auto` choice shares its name with the matching `Type`.
        return Type.parse?(backend.to_s) || Type::Ansi unless backend.auto?
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
        in Content::Painter
          # Vector strokes: Sixel's crisp pixel control beats iTerm's per-frame
          # re-blit for thin lines, so it ranks above iTerm here. `Glyph` (braille
          # by default, set on `Graph::Canvas`) is the universal sub-cell fallback.
          [Type::Kitty, Type::Sixel, Type::Iterm, Type::Glyph, Type::Ansi]
        in Content::Background
          # A background sits *behind* text. Only Kitty draws true pixels under the
          # cell grid (negative `z=`); the in-band raster backends (sixel/iTerm)
          # own their cells and can't sit under text, so they're excluded. The
          # cell-grid backends (`Glyph`/`Ansi`) render the image *into* the buffer,
          # so they compose under content the ordinary way — the universal fallback.
          # The user picks among these via `image.exclude` (e.g. exclude `kitty` to
          # force the cell-grid look).
          [Type::Kitty, Type::Glyph, Type::Ansi]
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
      #
      # *double_buffer* is applied only to the in-band graphics backends it
      # applies to (`Media::Graphics`: sixel/regis/kitty/iterm); on cell/external
      # backends it is silently ignored, so it can be passed uniformly here.
      def self.new(*, type : Type? = nil, file : String? = nil, double_buffer : Bool? = nil, **opts) : Media::Base
        type ||= default_type(file)
        opts = opts.merge(file: file)
        widget =
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
        if (db = double_buffer) && widget.is_a?(Graphics)
          widget.double_buffer = db
        end
        widget
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
