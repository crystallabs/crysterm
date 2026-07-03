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

      def render
        if @width.nil? || @_shrink_width
          # Sum per-grapheme glyph widths, not `@ratio.width * codepoints`: the
          # renderer advances the pen by each glyph's own column count, so a
          # codepoint-count width sized a CJK/emoji box half as wide as its glyphs
          # need and clipped the text.
          @width = @text.each_grapheme.sum { |g| glyph_width(g.to_s) }
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
        # glyph slot, not two), keyed into the font by the cluster string.
        graphemes = @text.each_grapheme.to_a
        max_chars = Math.min graphemes.size, (right - left)//@ratio.width

        # Right-align by the glyphs' actual advance sum (per-glyph widths, matching
        # the pen), not `max_chars*@ratio.width`, which under-counts full-width
        # glyphs and pushed the text off the right edge.
        advance = 0
        max_chars.times { |i| advance += glyph_width(graphemes[i].to_s) }
        x = @align.right? ? (right - advance) : left
        max_chars.times do |i|
          ch = graphemes[i].to_s
          # `Font#glyph` falls back to "?" then a blank glyph, and pads every
          # row to the font width, so `map[y - top]` is a non-nil row.
          map = @active_font.glyph(ch)
          # Full-width glyphs (CJK, etc.) decode to a 16-px-wide grid even though
          # `@ratio.width` is the half-width cell size (8 for Unifont). Use the
          # glyph's own column count so wide glyphs render in full and the pen
          # advances past all of them instead of clipping to the left half.
          gw = map[0]?.try(&.size) || @ratio.width
          y = top
          while y < Math.min(bottom, top + @ratio.height)
            mline = map[y - top]
            mx = 0
            while mx < gw && x + mx < right
              mcell = mline[mx]?
              break if mcell.nil?

              lines[y]?.try(&.[x + mx]?).try do |cell|
                if style.foreground_char != ' '
                  cell.attr = default_attr
                  cell.char = mcell == 1 ? style.foreground_char : style.fill_char
                else
                  cell.attr = mcell == 1 ? attr : default_attr
                  cell.char = mcell == 1 ? ' ' : style.fill_char
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
