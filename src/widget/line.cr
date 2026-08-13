module Crysterm
  class Widget
    # Draws a horizontal or vertical line.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Line screenshot](../../tests/widget/line/line.5s.apng)
    # <!-- /widget-examples:capture -->
    class Line < Box
      @shrink_to_fit = true

      @orientation : Tput::Orientation = :horizontal

      # The stroke axes, giving a separator the border vocabulary
      # (plans/BORDERS.md § 5.1 — a separator is a one-axis stroke):
      # `medium` picks the ink (line glyphs, block ramps, braille dots),
      # `stroke` the dash pattern, `ratio` the weight/thickness (a line
      # medium above 1/2 goes heavy `━`; block/braille quantize it to their
      # sub-cell grids). An explicit `char:` still overrides everything,
      # exactly as before.
      getter medium : Border::Medium = Border::Medium::Line
      getter stroke : Border::Stroke = Border::Stroke::Solid
      getter ratio : Float64 = 0.5

      # An explicitly given `char:` — pinned across orientation changes;
      # `nil` re-derives from the axes.
      @rule_char : Char? = nil

      def initialize(@orientation = @orientation, char : Char? = nil, line_size : Dim | Int32 | String? = nil,
                     medium : (Border::Medium | Symbol)? = nil,
                     stroke : (Border::Stroke | Symbol)? = nil,
                     ratio : (Float64 | Symbol)? = nil, **box)
        super **box

        # `line_size` is the line's *length* (`width` when horizontal, `height`
        # when vertical), defaulting to `100%`. Only apply the default when
        # unset, so a `width:`/`height:` passed through `**box` isn't clobbered.
        if line_size
          self.line_size = line_size
        elsif (@orientation.horizontal? ? @width : @height).nil?
          self.line_size = "100%"
        end

        case medium
        in Border::Medium then @medium = medium
        in Symbol         then @medium = Border::Medium.parse medium.to_s
        in Nil
        end
        case stroke
        in Border::Stroke then @stroke = stroke
        in Symbol         then @stroke = Border::Stroke.parse stroke.to_s
        in Nil
        end
        case ratio
        in Float64 then @ratio = ratio
        in Symbol
          @ratio = Glyphs::BLOCK_RATIOS[ratio.to_s]? ||
                   raise ArgumentError.new "Unknown line ratio #{ratio.inspect} (known: #{Glyphs::BLOCK_RATIOS.keys.join(", ")})"
        in Nil
        end
        @rule_char = char

        style.fill_char = char || rule_char
      end

      def orientation : Tput::Orientation
        @orientation
      end

      # The rule glyph the axes derive for the current orientation at the
      # widget's effective glyph tier (an explicit `char:` wins).
      def rule_char : Char
        if pinned = @rule_char
          return pinned
        end
        horizontal = !@orientation.vertical?
        case @medium
        in .block?
          block_rule_char horizontal
        in .braille?
          braille_rule_char horizontal
        in .line?, .fill?
          line_rule_char horizontal
        end
      end

      # The line-medium rule: *stroke*'s run glyph, heavy above `ratio` 1/2
      # (`Double` has no heavier spelling). *stroke* defaults to the
      # widget's own; the braille fallback passes its degraded one.
      private def line_rule_char(horizontal : Bool, stroke : Border::Stroke = @stroke) : Char
        heavy = @ratio > 0.5 && !stroke.double?
        role =
          case stroke
          in .double? then horizontal ? Glyphs::Role::BorderDoubleH : Glyphs::Role::BorderDoubleV
          in .dashed?
            if heavy
              horizontal ? Glyphs::Role::BorderHeavyDashedH : Glyphs::Role::BorderHeavyDashedV
            else
              horizontal ? Glyphs::Role::BorderDashedH : Glyphs::Role::BorderDashedV
            end
          in .dotted?
            if heavy
              horizontal ? Glyphs::Role::BorderHeavyDottedH : Glyphs::Role::BorderHeavyDottedV
            else
              horizontal ? Glyphs::Role::BorderDottedH : Glyphs::Role::BorderDottedV
            end
          in .solid?
            if heavy
              horizontal ? Glyphs::Role::BorderHeavyH : Glyphs::Role::BorderHeavyV
            else
              horizontal ? Glyphs::Role::LineHorizontal : Glyphs::Role::LineVertical
            end
          end
        glyph role
      end

      # The block-medium rule: a ramp step at `ratio`'s aspect-compensated
      # thickness — a horizontal rule sits on its row's baseline (the
      # lower-anchored ramp), a vertical one against the left cell edge.
      # Dashes have no block sub-cell rendition; they round down to solid
      # (a `Line` has no per-cell render pass of its own).
      private def block_rule_char(horizontal : Bool) : Char
        w8, v8 = Glyphs.block_eighths(@ratio)
        if horizontal
          Glyphs.chars(Glyphs::SeqRole::BorderRampLower, glyph_tier)[v8 - 1]
        else
          Glyphs.chars(Glyphs::SeqRole::BorderRampLeft, glyph_tier)[w8 - 1]
        end
      end

      # The braille rule: centered dot-rows for a horizontal rule (the
      # braille grid can center horizontals — `Glyphs::BRAILLE_RULE_ROWS`),
      # left-anchored dot-columns for a vertical one; the sparse strokes
      # give dotted/dashed dots. Below the Extended tier braille degrades
      # to the dotted/dashed line families, as for borders.
      private def braille_rule_char(horizontal : Bool) : Char
        unless glyph_tier.extended?
          degraded = @stroke.dashed? ? Border::Stroke::Dashed : Border::Stroke::Dotted
          return line_rule_char horizontal, degraded
        end
        mask =
          case @stroke
          in .dotted?
            horizontal ? Glyphs::BRAILLE_RULE_DOTTED_H : Glyphs::BRAILLE_RULE_DOTTED_V
          in .dashed?
            horizontal ? Glyphs::BRAILLE_RULE_DOTTED_H : Glyphs::BRAILLE_RULE_DASHED_V
          in .solid?, .double?
            w2, v4 = Glyphs.braille_steps(@ratio)
            if @stroke.double?
              w2 = 2
              v4 = Math.max(v4, 2)
            end
            horizontal ? Glyphs::BRAILLE_RULE_ROWS[v4 - 1] : Glyphs::BRAILLE_COLS_LEFT[w2 - 1]
          end
        Glyphs.braille mask
      end

      # Changing orientation re-resolves the fill glyph (an explicit
      # `char:` is kept; the axes re-derive otherwise) and swaps which axis
      # (`width`/`height`) carries the line's length, then repaints.
      def orientation=(v : Tput::Orientation) : Tput::Orientation
        return v if v == @orientation
        old_width = @width
        old_height = @height
        @orientation = v
        style.fill_char = rule_char
        # Swap the axes wholesale: the length moves onto the new axis and the
        # thickness (usually `nil`, i.e. shrink-to-fit to one cell) onto the
        # other. Merely copying the length would leave the old axis pinned at
        # the old length, turning the line into a full-area slab of glyphs.
        self.width = old_height
        self.height = old_width
        request_render
        @orientation
      end

      # Beyond any border (handled by `super`), a *horizontal* line emits a run
      # of line-drawing characters across its row(s), so those rows must
      # participate in docking. A *vertical* line emits only `│` down a single
      # column and needs no stop of its own — it's docked whenever a horizontal
      # line/border registers the crossing row.
      def register_dock_stops(coords)
        super

        if @orientation.horizontal?
          # A Line rendering into a compositing plane registers on the *plane*
          # stops, so overlay line art joins other overlay art but not the base
          # content beneath it. Skip negative rows, matching `Docking.dock`.
          scr = window
          stops = scr.compositing_layers? ? scr._plane_dock_stops : scr._dock_stops
          (coords.yi..coords.yl - 1).each do |y|
            stops[y] = true if y >= 0
          end
        end
      end

      # The line's *length* along its `#orientation` — i.e. `#width` when
      # horizontal, `#height` when vertical — in the user-set form (`Int32`,
      # a `Dim`, a `"50%"`-style String, or `nil` when unset). `#awidth`/
      # `#aheight` give the resolved cell count.
      def line_size : Dim | Int32 | String?
        @orientation.vertical? ? @height : @width
      end

      def line_size=(size : Dim | Int32 | String) : Dim | Int32 | String
        case @orientation
        when Tput::Orientation::Horizontal
          self.width = size
        when Tput::Orientation::Vertical
          self.height = size
        else
          # Failsafe case; prevents nothing rendering at all.
          self.width = size
          self.height = size
        end
        size
      end
    end
  end
end
