require "./media/fitting"

module Crysterm
  class Widget
    # Factory for image widgets, ported from Blessed's `image` element.
    #
    # Blessed's `image` mutates an object's class at runtime to dispatch to a
    # concrete widget; Crystal can't do that, so `Media` is a factory instead:
    # `Media.new` returns the concrete widget for the requested `type` and
    # forwards all other options to it.
    #
    # Every backend is a `Media::Base` (shared contract: image source, `fit`,
    # animation, `image.unsupported` policy), so `Media.new` returns
    # `Media::Base`. Backends are grouped by how the image's pixels reach the
    # window, which determines the rendering/erase machinery and the abstract
    # family base each inherits:
    #
    # * **cell-grid** (`Media::Cells`) — the image becomes character cells
    #   Crysterm owns and diffs: `Ansi` (`Media::Ansi`, one cell per pixel) and
    #   `Glyph` (`Media::Glyph`, sub-cell glyphs). Each exposes single-variant
    #   subclasses that pin one rendering, grouped by terminal capability: the
    #   no-Unicode `Ascii::TrueColor` / `C256` / `C16` / `C8` (solid, `Ansi`
    #   engine) plus `Ascii::Edge` (contour, `Glyph` engine); and the Unicode
    #   `Unicode::Half` / `Quadrant` / `Sextant` / `Octant` / `Braille` (all
    #   thin `Glyph` subclasses pinning one `Glyph::Mode`).
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
    # img = Widget::Media.new file: "picture.png", parent: window # => Media::Ansi
    # img = Widget::Media.new file: "picture.png", type: Widget::Media::Type::Sixel, parent: window
    # ```
    #
    # The factory forwards a single common option bag (`file`, position, size) to
    # whichever backend is selected; backend-specific options (e.g.
    # Media::Glyph's `mode`, Media::Sixel's `dither`) are best passed by
    # constructing the concrete widget directly.
    module Media
      # The raster/quantize toolkit (Bayer matrix, `Dither` + `dither_rgb`,
      # `luminance`, `clamp8`, `nearest_index`, `each_run`, `dims`,
      # `grid_fits?`, `rgb24`) moved to the pnggif shard as `PNGGIF::Raster` —
      # it is generic bitmap machinery, not widget code. The constants/enums
      # are aliased and the functions delegated here because every backend
      # (and external callers) address them as `Media.*`, and `Dither` is a
      # widget option type.
      BAYER_MATRIX = PNGGIF::Raster::BAYER_MATRIX

      # :ditto:
      alias Dither = PNGGIF::Raster::Dither

      # Quantizes an RGBA *bmp* (*pw*×*ph*) to one backend value per pixel,
      # applying the requested *dither* — see `PNGGIF::Raster.dither_rgb` for
      # the full contract (block per opaque pixel; `into` scratch reuse).
      def self.dither_rgb(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32,
                          dither : Dither, animated : Bool, transparent : V,
                          into : Array(Array(V))? = nil,
                          & : Int32, Int32, Int32, Float64 -> Tuple(V, Int32, Int32, Int32)) : Array(Array(V)) forall V
        PNGGIF::Raster.dither_rgb(bmp, pw, ph, dither, animated, transparent, into) do |r, g, b, t|
          yield r, g, b, t
        end
      end

      # :ditto: `PNGGIF::Raster.luminance`
      def self.luminance(px : PNGGIF::Pixel) : Float64
        PNGGIF::Raster.luminance px
      end

      # :ditto: `PNGGIF::Raster.clamp8`
      def self.clamp8(v : Int32) : Int32
        PNGGIF::Raster.clamp8 v
      end

      # :ditto: `PNGGIF::Raster.nearest_index`
      def self.nearest_index(palette : Array(Int32), r : Int32, g : Int32, b : Int32) : Int32
        PNGGIF::Raster.nearest_index palette, r, g, b
      end

      # :ditto: `PNGGIF::Raster.each_run`
      def self.each_run(row : Indexable(T), width : Int32, & : T, Int32, Int32 ->) forall T
        PNGGIF::Raster.each_run(row, width) { |v, x, rl| yield v, x, rl }
      end

      # :ditto: `PNGGIF::Raster.dims`
      def self.dims(bmp : Array(Array(T))) : Tuple(Int32, Int32) forall T
        PNGGIF::Raster.dims bmp
      end

      # :ditto: `PNGGIF::Raster.grid_fits?`
      def self.grid_fits?(grid : Array(Array(T)), w : Int32, h : Int32) : Bool forall T
        PNGGIF::Raster.grid_fits? grid, w, h
      end

      # :ditto: `PNGGIF::Raster.rgb24`
      @[AlwaysInline]
      def self.rgb24(v : Int32) : Tuple(Int32, Int32, Int32)
        PNGGIF::Raster.rgb24 v
      end

      # Backend used to render the image. See the families described above.
      #
      # `Ansi` and `Glyph` are the cell-grid defaults (mode/colormode selectable
      # on the widget, what auto-selection ranks); each is also offered as
      # single-variant members (`AnsiC256`, `GlyphOctant`, …) for picking one
      # rendering explicitly.
      enum Type
        Ansi          # cell-grid, one cell per pixel, default colormode (`Media::Ansi`)
        AnsiTrueColor # cell-grid, one cell per pixel, 24-bit (`Media::Ascii::TrueColor`)
        AnsiC256      # cell-grid, one cell per pixel, xterm-256 (`Media::Ascii::C256`)
        AnsiC16       # cell-grid, one cell per pixel, ANSI-16 (`Media::Ascii::C16`)
        AnsiC8        # cell-grid, one cell per pixel, ANSI-8 (`Media::Ascii::C8`)
        Glyph         # cell-grid, sub-cell glyphs, default mode (`Media::Glyph`)
        GlyphBlock    # cell-grid, 1×1 solid block (`Media::Ascii::TrueColor`)
        GlyphHalf     # cell-grid, 1×2 half-block (`Media::Unicode::Half`)
        GlyphQuadrant # cell-grid, 2×2 quadrant (`Media::Unicode::Quadrant`)
        GlyphSextant  # cell-grid, 2×3 sextant (`Media::Unicode::Sextant`)
        GlyphOctant   # cell-grid, 2×4 octant (`Media::Unicode::Octant`)
        GlyphBraille  # cell-grid, 2×4 braille dots (`Media::Unicode::Braille`)
        GlyphAscii    # cell-grid, 1×1 ASCII contour (`Media::Ascii::Edge`)
        Overlay       # window-owns-pixels, external w3mimgdisplay overlay (`Media::Overlay`)
        Ueberzug      # window-owns-pixels, external überzug overlay (`Media::Ueberzug`)
        Sixel         # window-owns-pixels, in-band sixel graphics (`Media::Sixel`)
        Regis         # window-owns-pixels, in-band ReGIS vector graphics (`Media::Regis`)
        Kitty         # window-owns-pixels, in-band Kitty graphics protocol (`Media::Kitty`)
        Iterm         # window-owns-pixels, in-band iTerm2 inline images (`Media::Iterm`)
        Tek           # separate window, Tektronix 4014 vectors (`Media::Tek`)
      end

      # Selectable values of the `media.backend` config option: `Auto` (pick the
      # best `Type` the terminal supports) plus one member per `Type`. Members
      # must stay named identically to `Type`'s, so a non-`Auto` choice maps via
      # `Type.parse?(choice.to_s)`.
      enum Backend
        Auto # Pick the best backend the terminal supports (see `resolve`)
        Ansi
        AnsiTrueColor
        AnsiC256
        AnsiC16
        AnsiC8
        Glyph
        GlyphBlock
        GlyphHalf
        GlyphQuadrant
        GlyphSextant
        GlyphOctant
        GlyphBraille
        GlyphAscii
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
      # default backend, since ranking differs by kind (e.g. iTerm2 animates GIFs
      # natively so it ranks higher for `AnimatedImage`, but can't stream raw
      # video so it's excluded from `Video`).
      enum Content
        Image         # a single still image (Qt Quick: Image)
        AnimatedImage # an animated image — GIF / APNG (Qt Quick: AnimatedImage)
        Video         # a video file, decoded via `Media::VideoSource` (Qt Quick: Video)
        Painter       # vector/line-art rasterized fresh each frame (`Graph::Canvas`)
        Background    # an image painted *behind* a widget's content (CSS `background-image`)
      end

      # File extensions that denote an animated image, selecting the
      # `Content::AnimatedImage` ranking. A `.gif` is treated as animated even
      # when the file happens to be a single frame — only the backend preference
      # order differs, and the ranking still renders a still correctly. Ambiguous
      # containers (APNG-in-`.png`, animated `.webp`) can't be told apart by
      # extension and stay `Content::Image`; a caller needing the animated ranking
      # for those must pass an explicit `type:`.
      ANIMATED_IMAGE_EXTENSIONS = %w[gif apng]

      # Whether *file*'s extension denotes an animated image.
      def self.animated_image?(file : String) : Bool
        ANIMATED_IMAGE_EXTENSIONS.includes? File.extname(file).lstrip('.').downcase
      end

      # The default backend when `type:` is not given: classifies *file*'s content
      # kind *by extension* — video, animated image, else still image — and defers
      # to `resolve` for the pin/exclude/capability rules. Content that extension
      # can't disambiguate is the caller's job to declare via an explicit `type:`.
      def self.default_type(file : String? = nil) : Type
        content =
          if file.nil?
            Content::Image
          elsif VideoSource.video?(file)
            Content::Video
          elsif animated_image?(file)
            Content::AnimatedImage
          else
            Content::Image
          end
        resolve content
      end

      # The backend `Type` for *content*, honoring the user's configuration. Every
      # caller must come through here — it is the single point where a backend is
      # chosen, so none can silently diverge:
      #
      # 1. A non-`auto` `media.backend` pin, when compatible with *content*, is
      #    authoritative: returned verbatim, *skipping* the terminal-capability
      #    gate. The user named a backend, so it is used even where the terminal
      #    can't drive it — failing loudly beats a silent downgrade. Unknown names
      #    fall back to `Ansi`. A pin that can't serve the category is ignored and
      #    resolution continues at (2).
      # 2. Otherwise it walks the ranked candidate list for *content*, skips any
      #    excluded via `media.exclude`, and returns the first the terminal
      #    supports — falling back to the universal cell grid (`Ansi`).
      #
      # *tput* describes the terminal (the global window's by default); facts come
      # from `Tput::Emulator`/`Features`, so no probing happens here. With no
      # terminal handle, the last non-excluded candidate is returned.
      def self.resolve(content : Content = Content::Image, tput : ::Tput? = nil) : Type
        # (1) An explicit, non-`auto` pin overrides content ranking *and* terminal
        # capability — but only where it's compatible with the content category,
        # so a background never gets a can't-sit-under-text backend forced on it.
        backend = Crysterm::Config.media_backend
        unless backend.auto?
          pinned = Type.parse?(backend.to_s) || Type::Ansi
          return pinned if backend_applicable?(pinned, content)
        end

        # (2) Auto: rank by content, honor `media.exclude`, gate on capability.
        tput ||= (Crysterm::Window.global?.try(&.tput))
        excluded = excluded_types
        candidates = candidates_for(content).reject { |t| excluded.includes?(t) }

        if tp = tput
          emu = tp.emulator
          feat = tp.features
          candidates.each do |t|
            return t if backend_supported?(t, emu, feat)
          end
        end

        # No terminal handle, or nothing matched: lists end in `Ansi`, which
        # works anywhere.
        candidates.last? || Type::Ansi
      end

      # Backends excluded from automatic selection via `image.exclude` (a
      # comma/space separated list of backend names, e.g. `"kitty,sixel"`).
      # `resolve` skips these. Unknown names are ignored.
      def self.excluded_types : Array(Type)
        Crysterm::Config.media_exclude
          .split(/[\s,]+/, remove_empty: true)
          .compact_map { |s| Type.parse?(s) }
      end

      # Ranked best→fallback backend candidates for *content*.
      private def self.candidates_for(content : Content) : Array(Type)
        # Ranks by family default (`Glyph`/`Ansi`); the widget then picks the
        # concrete mode/colormode. A specific variant can be forced via
        # `image.backend`/`type:`.
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
          # re-blit for thin lines. `Glyph` (braille by default on
          # `Graph::Canvas`) is the universal sub-cell fallback.
          [Type::Kitty, Type::Sixel, Type::Iterm, Type::Glyph, Type::Ansi]
        in Content::Background
          # A background sits *behind* text. Only Kitty draws true pixels under
          # the cell grid (negative `z=`); sixel/iTerm own their cells and can't
          # sit under text, so they're excluded. `Glyph`/`Ansi` render into the
          # buffer and compose under content normally. Exclude `kitty` via
          # `image.exclude` to force the cell-grid look.
          [Type::Kitty, Type::Glyph, Type::Ansi]
        end
      end

      # Whether *type* is compatible with the *content* category — the gate a
      # non-`auto` `media.backend` pin is subject to, distinct from the auto
      # ranking and from terminal capability. Only `Background` constrains it: a
      # background composites *under* the cell grid, so it needs a backend whose
      # pixels sit beneath text — a cell-grid family or `Kitty` (a negative-`z`
      # terminal layer). Sixel/iTerm/ReGIS/Tek own their region and the external
      # overlays paint over it, so a pin to one of those is not honored there.
      # Every other content kind accepts any pinned backend.
      def self.backend_applicable?(type : Type, content : Content) : Bool
        return true unless content.background?
        type.kitty? || cell_grid_type?(type)
      end

      # Whether *type* is a cell-grid backend (`Media::Cells`): an `Ansi`/`Glyph`
      # family member that paints into the window buffer, as opposed to the
      # in-band-graphics, external-overlay, or separate-window families.
      def self.cell_grid_type?(type : Type) : Bool
        case type
        when .ansi?, .ansi_true_color?, .ansi_c256?, .ansi_c16?, .ansi_c8?,
             .glyph?, .glyph_block?, .glyph_half?, .glyph_quadrant?,
             .glyph_sextant?, .glyph_octant?, .glyph_braille?, .glyph_ascii?
          true
        else
          false
        end
      end

      # Whether *type* can render on the terminal described by *emu*/*feat*.
      # Accepts both the family types and their single-variant members, so a
      # specific rendering can be gated. Overlay/Ueberzug/Regis/Tek are never
      # auto-selected and report unsupported here.
      private def self.backend_supported?(type : Type, emu : ::Tput::Emulator, feat : ::Tput::Features) : Bool
        case type
        when .kitty? then emu.kitty_graphics?
        when .iterm? then emu.iterm_images?
        when .sixel? then emu.sixel?
        when .glyph_sextant?
          # Draws from the Unicode legacy-computing sextant range (U+1FB00),
          # which some fonts/terminals lack and render as `?`.
          feat.unicode? && emu.legacy_computing_sextant?
        when .glyph_octant?
          # The octant range (U+1CD00) is newer than sextants, hence gated
          # separately.
          feat.unicode? && emu.legacy_computing_octant?
        when .glyph_ascii?
          true # pure ASCII contour — needs no Unicode
        when .glyph?, .glyph_block?, .glyph_half?, .glyph_quadrant?, .glyph_braille?
          # Block/half/quadrant (U+2580 block elements, Unicode 1.0) and braille
          # (U+2800, Unicode 3.0) are near-universal wherever Unicode works.
          feat.unicode?
        when .ansi?, .ansi_true_color?, .ansi_c256?, .ansi_c16?, .ansi_c8?
          true # the universal cell grid renders anywhere
        else
          false # overlay/ueberzug/regis/tek: gated by `available?`, never auto
        end
      end

      # Whether *type* can actually render in the current environment: terminal
      # capability for the in-band backends and high-res glyph families, Unicode
      # for the rest of the cell grid, helper-binary presence for the external
      # ones (Overlay needs `w3mimgdisplay`, Ueberzug needs `ueberzug`).
      # `Regis`/`Tek` always report unavailable. Use to gate UI selection so an
      # undrivable backend is never invoked. *tput* defaults to the global
      # window's.
      def self.available?(type : Type, tput : ::Tput? = nil) : Bool
        case type
        when .overlay?      then w3m_available?
        when .ueberzug?     then ueberzug_available?
        when .regis?, .tek? then false # no detection
        else
          tp = tput || (Crysterm::Window.global?.try(&.tput))
          if tp
            backend_supported?(type, tp.emulator, tp.features)
          else
            # No terminal handle: the cell grid works anywhere; in-band graphics
            # (Kitty/Iterm/Sixel) can't be confirmed, so report unavailable.
            !(type.kitty? || type.iterm? || type.sixel?)
          end
        end
      end

      # Fetches *url* using `curl` (then `wget`), returning the raw bytes.
      # A generic network fetch shared by every backend that accepts URLs
      # (hoisted here from the `Ansi` backend it historically lived on).
      def self.fetch(url : String) : Bytes
        [{"curl", ["-s", "-A", "", url]}, {"wget", ["-U", "", "-O", "-", url]}].each do |cmd, args|
          io = IO::Memory.new
          status = Process.run(cmd, args, output: io, error: Process::Redirect::Close)
          return io.to_slice if status.success?
        rescue
          # Try the next downloader.
        end
        raise "curl or wget failed."
      end

      # Whether the `w3mimgdisplay` helper is present.
      def self.w3m_available? : Bool
        paths = [Crysterm::Config.environment_w3mimgdisplay,
                 "/usr/lib/w3m/w3mimgdisplay", "/usr/libexec/w3m/w3mimgdisplay",
                 "/usr/lib64/w3m/w3mimgdisplay", "/usr/libexec64/w3m/w3mimgdisplay",
                 "/usr/local/libexec/w3m/w3mimgdisplay"]
        paths.any? { |p| p && File.exists?(p) }
      end

      # Whether an `ueberzug`/`ueberzugpp` helper is on `PATH`. Defers to
      # `Media::Ueberzug.binary`, the single owner of the binary-name list and
      # the `$PATH` probe, rather than re-sweeping `PATH` on every call — this is
      # reached from `.available?`, the gate a UI uses to enumerate backends.
      # The reference is resolved lazily, inside the body, so media.cr does not
      # need to require the backend. Consequence: the answer is memoized
      # process-wide, so a helper installed mid-run is not picked up — which is
      # already true of `Media::Ueberzug` itself, so the two now agree.
      def self.ueberzug_available? : Bool
        !Media::Ueberzug.binary.nil?
      end

      # Builds the concrete image/media widget for *type*, forwarding all
      # remaining options to its constructor. When *type* is omitted it is
      # resolved via `default_type` for the current terminal and *file*'s
      # content kind; pass *type* explicitly to force a specific backend.
      #
      # *double_buffer* applies only to the in-band graphics backends; it is
      # silently ignored on the others, so it can be passed uniformly.
      def self.new(*, type : Type? = nil, file : String? = nil, double_buffer : Bool? = nil, **opts) : Media::Base
        type ||= default_type(file)
        opts = opts.merge(file: file)
        widget =
          case type
          in Type::Ansi          then Ansi.new **opts
          in Type::AnsiTrueColor then Ascii::TrueColor.new **opts
          in Type::AnsiC256      then Ascii::C256.new **opts
          in Type::AnsiC16       then Ascii::C16.new **opts
          in Type::AnsiC8        then Ascii::C8.new **opts
          in Type::Glyph         then Glyph.new **opts
          in Type::GlyphBlock    then Ascii::TrueColor.new **opts
          in Type::GlyphHalf     then Unicode::Half.new **opts
          in Type::GlyphQuadrant then Unicode::Quadrant.new **opts
          in Type::GlyphSextant  then Unicode::Sextant.new **opts
          in Type::GlyphOctant   then Unicode::Octant.new **opts
          in Type::GlyphBraille  then Unicode::Braille.new **opts
          in Type::GlyphAscii    then Ascii::Edge.new **opts
          in Type::Overlay       then Overlay.new **opts
          in Type::Ueberzug      then Ueberzug.new **opts
          in Type::Sixel         then Sixel.new **opts
          in Type::Regis         then Regis.new **opts
          in Type::Kitty         then Kitty.new **opts
          in Type::Iterm         then Iterm.new **opts
          in Type::Tek           then Tek.new **opts
          end
        # Distinguish "not given" (nil) from an explicit `false`: a plain
        # truthiness test would silently drop `double_buffer: false`, leaving
        # the widget on its `true` default.
        unless (db = double_buffer).nil?
          widget.double_buffer = db if widget.is_a?(Graphics)
        end
        widget
      end

      # Process-wide decode cache: the same file shown by several widgets is
      # parsed only once, and every widget derives its sized render from the
      # shared `PNGGIF::PNG` read-only. A `nil` value is a cached *failure*.
      # Bounded LRU, since decoded entries can be large.
      @@decode_cache = Cache::Bounded(String, PNGGIF::PNG?).new(Cache::IMAGE_DECODE_CAPACITY, "image_decode", register: true, lru: true)

      # Resolves a *file* spec to data a `PNGGIF` decoder accepts: an `http(s)`
      # URL is fetched to bytes; a local path passes through as-is.
      def self.source_data(file : String) : String | Bytes
        file =~ /^https?:/ ? Media.fetch(file) : file
      end

      # Decodes *file* (a local path or `http(s)` URL) once, caching the result
      # keyed on path + size + mtime (so an on-disk change invalidates it).
      # Returns `nil` on failure.
      #
      # Failures must be cached too: `source` is called every render pass, so
      # without negative caching a file that fails to decode — especially a video
      # whose ffprobe/ffmpeg pipeline errors — re-spawns the subprocess pipeline
      # every frame and stalls the UI.
      def self.decode(file : String) : PNGGIF::PNG?
        key = file
        unless file =~ /^https?:/
          if info = File.info?(file)
            key = "#{file}\u{0}#{info.size}\u{0}#{info.modification_time.to_unix}"
          end
        end
        # ANSI-art decoding depends on the detail setting, so key on it too.
        key += "\u{0}d#{Crysterm::Config.media_ansi_art_detail}" if file =~ ANSI_ART_RE
        # `fetch` caches the result — including a `nil` failure — and only runs
        # the block on a miss.
        @@decode_cache.fetch(key) do
          if file =~ ANSI_ART_RE
            # ANSI/textmode art: decode CP437 + ANSI sequences to a bitmap.
            raw = file =~ /^https?:/ ? Media.fetch(file) : File.open(file, &.getb_to_end)
            decode_ansi(raw)
          elsif VideoSource.video? file
            # Decoded to animation frames via ffmpeg; nil if missing/failed.
            VideoSource.decode file
          else
            PNGGIF::PNG.new(source_data(file))
          end
        rescue
          nil
        end
      end

      # Empties the decode cache (e.g. to reclaim memory).
      def self.clear_decode_cache
        @@decode_cache.clear
      end
    end
  end
end
