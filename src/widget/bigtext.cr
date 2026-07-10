require "./box"
require "../font"

module Crysterm
  class Widget
    # Widget for displaying text in a big bitmap font — each character is drawn as
    # a grid of cells. Glyph data comes from `Crysterm::Font` (the bundled Terminus
    # faces by default); pass `font:` / `font_bold:` to use other ttystudio JSON
    # fonts (https://github.com/chjj/ttystudio).
    #
    # <!-- widget-examples:capture v1 -->
    # ![BigText screenshot](../../tests/widget/bigtext/bigtext.5s.apng)
    # <!-- /widget-examples:capture -->
    class BigText < Widget::Box
      # Optional font-file overrides; `nil` uses the bundled Terminus normal/bold.
      property font : String?
      property font_bold : String?

      property ratio : Tput::Size = Tput::Size.new 0, 0
      property text = ""

      # TODO This widget isn't very useful as-is.
      # Add support font scaling, character for fg/bg, etc.

      # Loaded fonts; `active_font` points at `normal` or `bold` per the style.
      property normal : Font
      property bold : Font
      property active_font : Font

      property _shrink_width : Bool = false
      property _shrink_height : Bool = false

      # Cached grapheme cluster strings for `@text`, plus the text they were built
      # from (identity-compared) and the memoized shrink-to-content advance width.
      # Rebuilt only when `@text` changes, so the per-frame `#render` no longer
      # allocates a grapheme array + a `String` per cluster.
      @graphemes = [] of String
      @_graphemes_src : String?
      @_shrink_width_value : Int32?

      def initialize(
        @font : String? = nil,
        @font_bold : String? = nil,
        **box,
      )
        @normal = (f = @font) ? Font.load(f) : Font.default_normal
        @bold = (f = @font_bold) ? Font.load(f) : Font.default_bold
        @ratio = Tput::Size.new @normal.width, @normal.height

        box["content"]?.try do |c|
          @text = c
        end

        super **box

        @active_font = style.bold? ? @bold : @normal

        # Text renders as big glyphs from `@text`; clear the plain `content`
        # that `super` set from the same string, otherwise the base renderer
        # draws it as normal-size text showing through the glyph gaps. Done
        # *after* `@active_font` is assigned: calling `set_content` earlier
        # would leave `@active_font` uninitialized, which Crystal rejects as a
        # nilable-ivar access.
        set_content "", true
      end

      def set_content(content : String)
        @content = ""
        @_content_version += 1
        @text = content || ""
        # Glyphs are drawn from `@text`, so a content change must schedule a
        # repaint like the base `set_content` does — otherwise the new text
        # only appears on the next render triggered by something else.
        mark_dirty
      end

      # The rendered column width of one grapheme's glyph: the glyph's own column
      # count (a full-width CJK/emoji glyph decodes to 2×`@ratio.width`), falling
      # back to the cell width for a missing glyph. Shared by the shrink-to-content
      # width and the right-align offset so both match the pen advance in `#render`.
      private def glyph_width(g : String) : Int32
        @active_font.glyph(g)[0]?.try(&.size) || @ratio.width
      end

      # Refreshes the cached `@graphemes` array (and invalidates the memoized
      # shrink width) when `@text` has changed since the last build. Identity
      # compare, so a steady render (unchanged text) does no work or allocation.
      private def ensure_graphemes : Nil
        src = @_graphemes_src
        return if src && src.same?(@text)
        @_graphemes_src = @text
        @graphemes = @text.each_grapheme.map(&.to_s).to_a
        @_shrink_width_value = nil
      end

      def render
        ensure_graphemes
        if @width.nil? || @_shrink_width
          # Sum per-grapheme glyph widths, not `@ratio.width * codepoints`: the
          # renderer advances the pen by each glyph's own column count, so a
          # codepoint-count width sized a CJK/emoji box half as wide as its glyphs
          # need and clipped the text.
          @width = (@_shrink_width_value ||= @graphemes.sum { |g| glyph_width(g) })
          @_shrink_width = true
        end
        if @height.nil? || @_shrink_height
          @height = @ratio.height
          @_shrink_height = true
        end
        coords = _render
        return unless coords

        # A degenerate font ratio (malformed/missing custom font leaves
        # `@ratio` at its 0×0 default) would divide-by-zero below; nothing to
        # draw, so bail out with the computed coords.
        return coords if @ratio.width <= 0 || @ratio.height <= 0

        lines = window.lines
        left = coords.xi + ileft
        top = coords.yi + itop
        right = coords.xl - iright
        bottom = coords.yl - ibottom

        default_attr = sattr style
        # Swap fg/bg so the "lit" glyph pixels invert the base colors.
        attr = Attr.pack(Attr.flags(default_attr), Attr.bg(default_attr), Attr.fg(default_attr))

        # One glyph per grapheme cluster (so a base + combining mark is a single
        # glyph slot, not two), keyed into the font by the cluster string. The
        # cluster strings are cached in `@graphemes` (refreshed by
        # `ensure_graphemes`), so no per-frame array/`String` allocation here.
        graphemes = @graphemes
        # Fit whole glyphs by their real advance widths, not by counting glyphs in
        # half-width cell units (`(right - left)//@ratio.width`). A full-width
        # CJK/emoji glyph advances 2×`@ratio.width`, so the old count admitted more
        # glyphs than fit: `advance` could exceed the interior and a right-aligned
        # `right - advance` pen origin fell left of — even before — `left`, wrapping
        # negative row indices to the far end of the screen row. Accumulating per-
        # glyph widths until the next glyph would overflow keeps `advance` within
        # the interior, and matches the pen advance in the paint loop below.
        interior = right - left
        advance = 0
        max_chars = 0
        while max_chars < graphemes.size
          gw = glyph_width graphemes[max_chars]
          break if advance + gw > interior
          advance += gw
          max_chars += 1
        end

        # Clamp the pen origin so a right-aligned run never starts left of the
        # interior even if a single glyph is wider than the box.
        x = @align.right? ? Math.max(left, right - advance) : left
        max_chars.times do |i|
          ch = graphemes[i]
          # `Font#glyph` falls back to "?" then a blank glyph, and pads every
          # row to the font width, so `map[y - top]` is a non-nil row.
          map = @active_font.glyph(ch)
          # Full-width glyphs (CJK, etc.) decode to a 16-px-wide grid even though
          # `@ratio.width` is the half-width cell size (8 for Unifont). Use the
          # glyph's own column count so wide glyphs render in full and the pen
          # advances past all of them instead of clipping to the left half.
          gw = map[0]?.try(&.size) || @ratio.width
          # Start at row 0 when the widget hangs off the top edge (`top < 0`):
          # negative indices into `lines` would wrap to the bottom of the
          # screen. `map[y - top]` keeps addressing the correct glyph row.
          y = Math.max(top, 0)
          while y < Math.min(bottom, top + @ratio.height)
            mline = map[y - top]
            mx = 0
            while mx < gw && x + mx < right
              mcell = mline[mx]?
              break if mcell.nil?

              # Clip at the interior's left edge: skip cells left of `left` so a
              # glyph that starts before the interior never paints outside it (and
              # never turns into a negative `x + mx` that `Row#[]?` would wrap to
              # the far right of the screen row). Clamp `left` to 0 too — when the
              # widget hangs off the left edge `left` itself is negative and would
              # admit negative columns.
              if x + mx >= Math.max(left, 0)
                lines[y]?.try(&.[x + mx]?).try do |cell|
                  if style.foreground_char != ' '
                    cell.attr = default_attr
                    cell.char = mcell == 1 ? style.foreground_char : style.fill_char
                  else
                    cell.attr = mcell == 1 ? attr : default_attr
                    cell.char = mcell == 1 ? ' ' : style.fill_char
                  end
                end
              end

              mx += 1
            end
            lines[y]?.try &.dirty = true

            y += 1
          end

          x += gw
        end

        coords
      end
    end

    # <!-- widget-examples:capture v1 -->
    # ![BigText screenshot](../../tests/widget/bigtext/bigtext.5s.apng)
    # <!-- /widget-examples:capture -->
    alias Bigtext = BigText
  end
end
