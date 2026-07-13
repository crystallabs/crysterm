require "../widget_media_fitting"

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
      # 4×4 Bayer ordered-dither matrix (values 0..15), shared by the dithering
      # backends (`Media::Sixel`, `Media::Regis`, `Media::Tek`).
      BAYER_MATRIX = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
      ]

      # How an image's colors are dithered when reduced to a smaller palette than
      # the source (sixel grid, ReGIS' 8 colors, xterm-256/16 cube, Tek's 1 bit).
      # Shared by every quantizing backend, so the option means the same thing
      # everywhere.
      #
      # Dithering trades spatial resolution for perceived color depth: instead of
      # snapping each pixel to its nearest palette entry (which bands gradients),
      # it scatters the two nearest entries so the eye averages them back to the
      # in-between color.
      enum Dither
        None      # snap to the nearest palette entry — cleanest, but bands gradients
        Ordered   # 4×4 Bayer ordered dither — deterministic per pixel, so frame-stable
        Diffusion # Floyd–Steinberg error diffusion — best for a still; shimmers if animated
        Auto      # Diffusion for a still image, Ordered for an animation (default)

        # Collapses `Auto` to a concrete method: error diffusion looks best on a
        # still, but its irregular stipple shimmers across frames, so an animated
        # source falls back to the frame-stable ordered dither.
        def resolve(animated : Bool) : Dither
          return self unless auto?
          animated ? Ordered : Diffusion
        end

        # Coerces a constructor's legacy `Dither | Bool` `dither:` argument to a
        # `Dither`: a `Dither` value passes through unchanged; a `Bool` maps
        # `true` to *if_true* (the backend's prior "dithering on" default) and
        # `false` to `None`. Shared by `Media::Sixel`, `Media::Regis`, and
        # `Media::Tek`.
        def self.from_arg(dither : Dither | Bool, if_true : Dither) : Dither
          dither.is_a?(Bool) ? (dither ? if_true : None) : dither
        end
      end

      # Quantizes an RGBA *bmp* (*pw*×*ph*) to one backend value per pixel,
      # applying the requested *dither*. Shared color-reduction loop for every
      # palette backend (`Media::Sixel`, `Media::Regis`, `Media::Ansi`);
      # `Media::Tek` does its own 1-bit variant.
      #
      # The block is invoked once per opaque pixel with the channels to quantize
      # and an ordered-dither threshold *t* (Bayer offset in `[-0.5, 0.5)` for
      # `Ordered`, else `0.0`); it must return `{value, qr, qg, qb}` — the stored
      # value (palette index or packed `0xRRGGBB`) plus the RGB it resolves to, so
      # `Diffusion` can spread the residual onto not-yet-visited neighbours. Fully
      # transparent pixels (`a == 0` or missing) are assigned *transparent* and
      # never reach the block. *animated* collapses `Dither::Auto`.
      # *into*, when non-nil and already sized *ph* rows × *pw* wide, is reused as
      # the output grid (rows overwritten in place, no per-frame outer/row
      # allocation) — every cell is assigned on every pass (`transparent` or the
      # block's value), so no stale value from a previous frame can survive. A
      # per-frame-re-encoding backend (`Media::Sixel` with `media.reuse_buffers`)
      # passes a persistent scratch here; callers that cache the result
      # (`Media::Ansi`'s dither plane) must NOT, and leave it nil.
      def self.dither_rgb(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32,
                          dither : Dither, animated : Bool, transparent : V,
                          into : Array(Array(V))? = nil,
                          & : Int32, Int32, Int32, Float64 -> Tuple(V, Int32, Int32, Int32)) : Array(Array(V)) forall V
        mode = dither.resolve(animated)
        diffuse = mode.diffusion?
        # Per-channel Floyd–Steinberg error carried to the current and next scan
        # line (kept as a two-row sliding window rather than a full-image buffer).
        # Only diffusion needs them; ordered/none leave them empty so an animated
        # (ordered) sixel/regis frame doesn't allocate six pw-wide scratch rows it
        # never reads.
        dsize = diffuse ? pw : 0
        cur_r = Array(Float64).new(dsize, 0.0); cur_g = Array(Float64).new(dsize, 0.0); cur_b = Array(Float64).new(dsize, 0.0)
        nxt_r = Array(Float64).new(dsize, 0.0); nxt_g = Array(Float64).new(dsize, 0.0); nxt_b = Array(Float64).new(dsize, 0.0)

        reuse = !into.nil? && into.size == ph && (into[0]?.try(&.size) || 0) == pw
        out = (reuse ? into : nil) || Array(Array(V)).new(ph)
        ph.times do |y|
          rin = bmp[y]
          row = reuse ? out.unsafe_fetch(y) : Array(V).new(pw, transparent)
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
          out << row unless reuse
          # Next line's accumulated error becomes the current line's; reuse the
          # drained buffers as the new (zeroed) next line. No-ops for the empty
          # ordered/none buffers.
          cur_r, nxt_r = nxt_r, cur_r; cur_g, nxt_g = nxt_g, cur_g; cur_b, nxt_b = nxt_b, cur_b
          nxt_r.fill(0.0); nxt_g.fill(0.0); nxt_b.fill(0.0)
        end
        out
      end

      # Rec.709 relative luminance of *px* (`0.2126·R + 0.7152·G + 0.0722·B`), in
      # the channels' own 0..255 scale. Shared brightness measure for backends
      # mapping colour to a glyph/bit/intensity (`Media::Glyph`, `Media::Tek`,
      # `Media::Ansi`). Callers fold alpha/scale themselves on the result (e.g.
      # `Media::Ansi`: `luminance(px) * a / 255`).
      def self.luminance(px : PNGGIF::Pixel) : Float64
        0.2126 * px.r + 0.7152 * px.g + 0.0722 * px.b
      end

      # Clamps *v* into the `0..255` byte range. Shared by the palette backends
      # (`Media::Ansi`, `Media::Regis`) when nudging a channel by a dither offset
      # before the nearest-color search.
      def self.clamp8(v : Int32) : Int32
        v < 0 ? 0 : (v > 255 ? 255 : v)
      end

      # Index of the nearest entry in *palette* (packed `0xRRGGBB` values) to
      # *r*,*g*,*b* by squared RGB distance; ties go to the lower index. Shared
      # nearest-color search behind `Media::Ansi` (xterm-256/16 cube) and
      # `Media::Regis` (8 named colors), differing only in the palette passed.
      def self.nearest_index(palette : Array(Int32), r : Int32, g : Int32, b : Int32) : Int32
        best = 0
        bestd = Int32::MAX
        i = 0
        n = palette.size
        while i < n
          rgb = palette.unsafe_fetch(i)
          dr = r - ((rgb >> 16) & 0xff)
          dg = g - ((rgb >> 8) & 0xff)
          db = b - (rgb & 0xff)
          d = dr*dr + dg*dg + db*db
          if d < bestd
            bestd = d
            best = i
          end
          i += 1
        end
        best
      end

      # Scans a *row* of *width* values into maximal runs of equal adjacent
      # values, yielding each run's value, start column, and length. Shared
      # horizontal run-length kernel for the vector/RLE graphics backends —
      # `Media::Sixel` (sixel RLE bands), `Media::Regis`/`Media::Tek` (one
      # horizontal vector per run).
      def self.each_run(row : Indexable(T), width : Int32, & : T, Int32, Int32 ->) forall T
        x = 0
        while x < width
          v = row[x]
          rl = 1
          while x + rl < width && row[x + rl] == v
            rl += 1
          end
          yield v, x, rl
          x += rl
        end
      end

      # Dimensions `{w, h}` of a row-major 2D grid *bmp* (`bmp.size` rows, each
      # `bmp[0].size` wide; `{0, 0}` if empty). Shared by every backend that
      # derives a bitmap's size from its rows instead of tracking it separately
      # — generic so it covers both a `PNGGIF::Bitmap` and other row-major
      # grids (e.g. a glyph mask, `Array(Array(Int32))`).
      def self.dims(bmp : Array(Array(T))) : Tuple(Int32, Int32) forall T
        h = bmp.size
        w = h > 0 ? bmp[0].size : 0
        {w, h}
      end

      # Unpacks a packed `0xRRGGBB` color into its `{r, g, b}` byte channels.
      # Shared by every backend that stores colors packed (`Graph::Painter`,
      # ANSI-art decoding) instead of as separate channels. `@[AlwaysInline]`
      # because the dither backends call it per pixel — inlining lets LLVM
      # scalarize the intermediate tuple away, matching the old open-coded shifts.
      @[AlwaysInline]
      def self.rgb24(v : Int32) : Tuple(Int32, Int32, Int32)
        Colors.rgb_channels(v)
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
      # best `Type` the terminal supports) plus one member per `Type`, named
      # identically so a non-`Auto` choice maps via `Type.parse?(choice.to_s)`.
      # A real enum keeps the option explicit, validated, and dump-round-trippable.
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
      # `Content::AnimatedImage` ranking (which favors backends that animate
      # natively, e.g. iTerm2 for GIFs). A `.gif` is treated as animated even
      # when a particular file happens to be a single frame — the ranking still
      # renders a still correctly; only the backend *preference order* differs.
      # Ambiguous containers can't be told apart by extension — a `.png` that is
      # really APNG, an animated `.webp` — so auto-detection stays with
      # `Content::Image` for those; a caller that needs the animated ranking must
      # pass an explicit `type:` rather than rely on it being inferred.
      ANIMATED_IMAGE_EXTENSIONS = %w[gif apng]

      # Whether *file*'s extension denotes an animated image (see
      # `ANIMATED_IMAGE_EXTENSIONS`).
      def self.animated_image?(file : String) : Bool
        ANIMATED_IMAGE_EXTENSIONS.includes? File.extname(file).lstrip('.').downcase
      end

      # The default backend when `type:` is not given: classifies *file*'s content
      # kind *by extension* — video, animated image, else still image — and defers
      # to `resolve`, which applies the `media.backend` pin (config /
      # `CRYSTERM_MEDIA_BACKEND` / `--media-backend`), `media.exclude`, and
      # terminal-capability ranking uniformly — the same rules `Graph::Canvas` /
      # `Video` / `Background` get, by construction. Content that extension can't
      # disambiguate (APNG-in-`.png`, animated `.webp`) is the caller's job to
      # declare via an explicit `type:`.
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

      # The backend `Type` for *content*, honoring the user's configuration. This
      # is the **single** point where a backend is chosen, so every caller — the
      # image factory (`default_type`), `Graph::Canvas`, `Video`, `Background` —
      # gets identical rules and none can silently diverge:
      #
      # 1. A non-`auto` `media.backend` pin (config / `CRYSTERM_MEDIA_BACKEND` /
      #    `--media-backend`), when *compatible* with *content* (see
      #    `backend_applicable?`), is authoritative: returned verbatim, *skipping*
      #    the terminal-capability gate. The user named a backend, so it is used
      #    even where the terminal can't drive it — failing loudly beats a silent
      #    downgrade. Unknown names fall back to `Ansi`. A pin that *can't* serve
      #    the category (e.g. `sixel` for a `Background`, which must sit under
      #    text) is ignored, and resolution continues at (2) for that category.
      # 2. Otherwise (`auto`, or an inapplicable pin) it walks the ranked candidate
      #    list for *content* (most native/optimized first; see `candidates_for`),
      #    skips any excluded via `media.exclude`, and returns the first the
      #    terminal supports — falling back to the universal cell grid (`Ansi`)
      #    when nothing qualifies.
      #
      # *tput* describes the terminal (the global window's by default); facts
      # come from `Tput::Emulator`/`Features`, so no probing happens here. With
      # no window/terminal handle, the last non-excluded candidate is returned.
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
        tput ||= (Crysterm::Window.total > 0 ? Crysterm::Window.global.tput : nil)
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

      # Ranked best→fallback backend candidates for *content* (see `resolve`).
      private def self.candidates_for(content : Content) : Array(Type)
        # Auto-selection ranks by family default (`Glyph`/`Ansi`); the widget
        # then picks the concrete mode/colormode (e.g. `Graph::Canvas` sets
        # braille). A specific variant can be forced via `image.backend`/`type:`.
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

      # Whether *type* is *compatible* with the *content* category — the gate a
      # non-`auto` `media.backend` pin is subject to, distinct from
      # `candidates_for` (the narrower auto ranking) and `backend_supported?`
      # (terminal capability). Only `Background` constrains it: a background
      # composites *under* the cell grid, so it needs a backend whose pixels sit
      # beneath text — a cell-grid family (`Ansi`/`Glyph`, painted into the
      # buffer) or `Kitty` (a negative-`z` terminal layer). Sixel/iTerm/ReGIS/Tek
      # own their region and the external overlays paint over it, so none can be
      # a background; a pin to one of those is *not* honored there (normal
      # resolution proceeds instead). Every other content kind accepts any pinned
      # backend — an incapable terminal then fails visibly rather than silently.
      def self.backend_applicable?(type : Type, content : Content) : Bool
        return true unless content.background?
        type.kitty? || cell_grid_type?(type)
      end

      # Whether *type* is a cell-grid backend (`Media::Cells`) — an `Ansi`/`Glyph`
      # family member that paints into the window buffer, as opposed to the
      # in-band-graphics (sixel/regis/kitty/iterm), external-overlay
      # (overlay/ueberzug), or separate-window (tek) families.
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
      # Accepts both the family types (`Glyph`/`Ansi`, what `resolve` ranks) and
      # their single-variant members (`GlyphOctant`, `AnsiC256`, …), so
      # `available?` can gate a specific rendering. Overlay/Ueberzug/Regis/Tek
      # are never auto-selected (set `image.backend` or pass `type:` explicitly
      # for those) and report unsupported here.
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
          # The octant range (U+1CD00) is newer than sextants and gated
          # separately (see `Tput::Emulator#legacy_computing_octant?`).
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

      # Whether *type* can actually render in the current environment — terminal
      # capability for in-band backends (Kitty/Iterm/Sixel) and the high-res
      # glyph families (see `backend_supported?`), Unicode for the rest of the
      # cell grid, helper-binary presence for the external ones (Overlay needs
      # `w3mimgdisplay`, Ueberzug needs `ueberzug`). `Regis`/`Tek` always report
      # unavailable. Accepts family types and their single-variant members
      # (`GlyphOctant`, `AnsiC256`, …), so a specific rendering can be gated. Use
      # to gate UI selection so an undrivable backend is never invoked. *tput*
      # defaults to the global window's.
      def self.available?(type : Type, tput : ::Tput? = nil) : Bool
        case type
        when .overlay?      then w3m_available?
        when .ueberzug?     then ueberzug_available?
        when .regis?, .tek? then false # no detection
        else
          tp = tput || (Crysterm::Window.total > 0 ? Crysterm::Window.global.tput : nil)
          if tp
            backend_supported?(type, tp.emulator, tp.features)
          else
            # No terminal handle: the cell grid works anywhere; in-band graphics
            # (Kitty/Iterm/Sixel) can't be confirmed, so report unavailable.
            !(type.kitty? || type.iterm? || type.sixel?)
          end
        end
      end

      # Whether the `w3mimgdisplay` helper (used by `Media::Overlay`) is present.
      def self.w3m_available? : Bool
        paths = [Crysterm::Config.environment_w3mimgdisplay,
                 "/usr/lib/w3m/w3mimgdisplay", "/usr/libexec/w3m/w3mimgdisplay",
                 "/usr/lib64/w3m/w3mimgdisplay", "/usr/libexec64/w3m/w3mimgdisplay",
                 "/usr/local/libexec/w3m/w3mimgdisplay"]
        paths.any? { |p| p && File.exists?(p) }
      end

      # Whether an `ueberzug`/`ueberzugpp` helper (used by `Media::Ueberzug`) is
      # on `PATH`.
      def self.ueberzug_available? : Bool
        {"ueberzug", "ueberzugpp", "ueberzug++"}.any? { |n| Process.find_executable(n) }
      end

      # Builds the concrete image/media widget for *type*, forwarding all
      # remaining options to its constructor. When *type* is omitted it is
      # resolved via `default_type` for the current terminal and *file*'s
      # content kind; pass *type* explicitly to force a specific backend.
      #
      # *double_buffer* applies only to the in-band graphics backends
      # (`Media::Graphics`: sixel/regis/kitty/iterm); silently ignored on
      # cell/external backends, so it can be passed uniformly here.
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

      # Process-wide decode cache: the same file shown by several widgets (or
      # reloaded) is parsed only once. Every widget derives its sized render
      # from the shared `PNGGIF::PNG` read-only. A `nil` value is a cached
      # *failure* (see `decode`).
      # Bounded, least-recently-used: decoded entries can be large, so cap the
      # window and evict the least-recently-shown ones. See
      # `Cache::IMAGE_DECODE_CAPACITY`.
      @@decode_cache = Cache::Bounded(String, PNGGIF::PNG?).new(Cache::IMAGE_DECODE_CAPACITY, "image_decode", register: true, lru: true)

      # Resolves a *file* spec to data a `PNGGIF` decoder accepts: an `http(s)`
      # URL is fetched to bytes (via `Ansi.fetch`); a local path passes through
      # as-is. Shared by `#decode` and `Media::Tek`.
      def self.source_data(file : String) : String | Bytes
        file =~ /^https?:/ ? Ansi.fetch(file) : file
      end

      # Decodes *file* (a local path or `http(s)` URL) once, caching the result
      # keyed on path + size + mtime (so an on-disk change invalidates it).
      # Returns `nil` on failure.
      #
      # Failures are cached too: `source` is called every render pass, so
      # without negative caching a file that fails to decode — especially a
      # video whose ffprobe/ffmpeg pipeline errors — would re-spawn the
      # subprocess pipeline every frame and stall the UI.
      def self.decode(file : String) : PNGGIF::PNG?
        key = file
        unless file =~ /^https?:/
          if info = File.info?(file)
            key = "#{file}\u{0}#{info.size}\u{0}#{info.modification_time.to_unix}"
          end
        end
        # ANSI-art decoding depends on the detail setting, so key on it too.
        key += "\u{0}d#{Crysterm::Config.media_ansi_art_detail}" if file =~ ANSI_ART_RE
        # `fetch` caches the result — including a `nil` *failure* (negative
        # caching; see above) — and only runs the block on a miss.
        @@decode_cache.fetch(key) do
          begin
            if file =~ ANSI_ART_RE
              # ANSI/textmode art: decode CP437 + ANSI sequences to a bitmap
              # (see `#decode_ansi`).
              raw = file =~ /^https?:/ ? Ansi.fetch(file) : File.open(file, &.getb_to_end)
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
      end

      # Empties the decode cache (e.g. to reclaim memory).
      def self.clear_decode_cache
        @@decode_cache.clear
      end
    end
  end
end
