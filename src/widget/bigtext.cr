require "./box"
require "../font"

module Crysterm
  class Widget
    # Widget for displaying text in a big bitmap font — each character is drawn as
    # a grid of cells. Glyph data comes from `Crysterm::BitmapFont` (the bundled Terminus
    # faces by default); pass `font:` / `font_bold:` to use other ttystudio JSON
    # fonts (https://github.com/chjj/ttystudio).
    #
    # <!-- widget-examples:capture v1 -->
    # ![BigText screenshot](../../tests/widget/bigtext/bigtext.5s.apng)
    # <!-- /widget-examples:capture -->
    class BigText < Widget::Box
      # Optional font-file overrides; `nil` uses the bundled Terminus normal/bold.
      # Getter-only: the fonts are loaded once in the constructor, so assigning
      # after construction had no effect.
      getter font : String?
      getter font_bold : String?

      # Glyph cell size (width×height). Read-only; derived once from the loaded
      # font. Public getter — read by callers to size around the glyph grid.
      getter ratio : Tput::Size = Tput::Size.new 0, 0

      # The big-font text.
      getter text = ""

      # Assigning routes through `#set_content` so a runtime text change repaints
      # (a plain setter left the rendered glyphs stale).
      def text=(value : String) : String
        set_content value
        value
      end

      # TODO This widget isn't very useful as-is.
      # Add support font scaling, character for fg/bg, etc.

      # Loaded fonts; `active_font` points at `normal` or `bold` per the style.
      protected getter normal : BitmapFont
      protected getter bold : BitmapFont
      protected getter active_font : BitmapFont

      @_shrink_width : Bool = false
      @_shrink_height : Bool = false

      # Cached grapheme cluster strings for `@text`, plus the text they were built
      # from (identity-compared) and the memoized shrink-to-content advance width.
      # Rebuilt only when `@text` changes, keeping the per-frame `#render` free of
      # a grapheme array + a `String` per cluster.
      @graphemes = [] of String
      @_graphemes_src : String?
      @_shrink_width_value : Int32?

      # Character used to paint the "on" pixels of the bitmap font. The default
      # space paints them as reverse-video blocks of the fg color; any other
      # char is drawn literally over `Style#fill_char` gaps. Stylesheet
      # equivalent: `BigText { glyph: "#" }` (registry role `BigTextPixel`);
      # this property, when set, wins over the CSS/registry glyph.
      getter foreground_char : Char = ' '

      def foreground_char=(value : Char) : Char
        @foreground_char = value
        request_render
        value
      end

      def initialize(
        @font : String? = nil,
        @font_bold : String? = nil,
        @foreground_char : Char = ' ',
        **box,
      )
        @normal = (f = @font) ? BitmapFont.load(f) : BitmapFont.default_normal
        @bold = (f = @font_bold) ? BitmapFont.load(f) : BitmapFont.default_bold
        @ratio = Tput::Size.new @normal.width, @normal.height

        box["content"]?.try do |c|
          @text = c
        end

        super **box

        @active_font = style.bold? ? @bold : @normal

        # No trailing `set_content "", true` here: `super` routes its own
        # `set_content(content, true)` call through the override below, which
        # already stores `@text` and keeps the plain `content` empty (so the
        # base renderer can't draw normal-size text through the glyph gaps).
        # A trailing call would wipe the `@text` that `super` just set.
      end

      def set_content(content = "", no_clear = false, no_tags = false)
        @content = ""
        @_content_version += 1
        @text = content || ""
        # Glyphs are drawn from `@text`, so a content change must schedule its
        # own repaint the way the base `set_content` does.
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
      # shrink width) when `@text` has changed. Identity compare, so a steady
      # render does no work or allocation.
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
          # codepoint count sizes a CJK/emoji box half as wide as its glyphs need.
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

        default_attr = style_to_attr style
        # Swap fg/bg so the "lit" glyph pixels invert the base colors.
        attr = Attr.pack(Attr.flags(default_attr), Attr.bg(default_attr), Attr.fg(default_attr))

        # `#foreground_char` resolution, hoisted out of the per-pixel loop: the
        # widget property wins when set, else the glyph system (`BigText {
        # glyph: "#" }` in CSS, or the registry's `BigTextPixel` default — a
        # space, selecting the reverse-video block mode below).
        on_char = @foreground_char
        on_char = glyph(Glyphs::Role::BigTextPixel, style) if on_char == ' '

        # One glyph per grapheme cluster (so a base + combining mark is a single
        # glyph slot, not two), keyed into the font by the cluster string.
        graphemes = @graphemes
        # Fit whole glyphs by their real advance widths, not by counting glyphs in
        # half-width cell units (`(right - left)//@ratio.width`): a full-width
        # CJK/emoji glyph advances 2×`@ratio.width`, so a plain count admits more
        # glyphs than fit and pushes `advance` past the interior. Accumulating
        # per-glyph widths matches the pen advance in the paint loop below.
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
          # `BitmapFont#glyph` falls back to "?" then a blank glyph, and pads every
          # row to the font width, so `map[y - top]` is a non-nil row.
          map = @active_font.glyph(ch)
          # Full-width glyphs (CJK, etc.) decode to a 16-px-wide grid even though
          # `@ratio.width` is the half-width cell size (8 for Unifont), so the
          # glyph's own column count is what the pen must advance by.
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

              # Clip at the interior's left edge so a glyph starting before it
              # never paints outside (a negative `x + mx` would wrap to the far
              # right of the screen row). `left` is clamped to 0 as well: it is
              # itself negative when the widget hangs off the left edge.
              if x + mx >= Math.max(left, 0)
                lines[y]?.try(&.[x + mx]?).try do |cell|
                  if on_char != ' '
                    cell.attr = default_attr
                    cell.char = mcell == 1 ? on_char : style.fill_char
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
