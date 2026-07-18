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

      def initialize(@orientation = @orientation, char : Char? = nil, line_size : Int32 | String | Nil = nil, **box)
        super **box

        # `line_size` is the line's *length* (`width` when horizontal, `height`
        # when vertical), defaulting to `100%`. Only apply the default when
        # unset, so a `width:`/`height:` passed through `**box` isn't clobbered.
        if line_size
          self.line_size = line_size
        elsif (@orientation.horizontal? ? @width : @height).nil?
          self.line_size = "100%"
        end

        char ||= glyph(@orientation == Tput::Orientation::Vertical ? Glyphs::Role::LineVertical : Glyphs::Role::LineHorizontal)

        style.fill_char = char
      end

      def orientation : Tput::Orientation
        @orientation
      end

      # Changing orientation re-resolves the fill glyph (horizontal/vertical
      # line-drawing character) and swaps which axis (`width`/`height`) carries
      # the line's length, then repaints.
      def orientation=(v : Tput::Orientation) : Tput::Orientation
        return v if v == @orientation
        old_size = line_size
        @orientation = v
        style.fill_char = glyph(v.vertical? ? Glyphs::Role::LineVertical : Glyphs::Role::LineHorizontal)
        self.line_size = old_size if old_size
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
      # a `"50%"`-style String, or `nil` when unset). `#awidth`/`#aheight` give
      # the resolved cell count.
      def line_size : Int32 | String | Nil
        @orientation.vertical? ? @height : @width
      end

      def line_size=(size : Int32 | String) : Int32 | String
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
