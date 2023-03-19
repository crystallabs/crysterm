require "./radioset"

module Crysterm
  class Widget
    # Layout
    class Layout < Widget
      include EventHandler

      @layout : LayoutType

      def initialize(@layout = LayoutType::Inline, **element)
        el = element

        if (!el["width"]? && (!el["left"]? && !el["right"]?)) ||
           (!el["height"]? && (!el["top"]? && !el["bottom"]?))
          raise "Layout must have width and height"
        else
          super **el
        end
      end

      def rendered?(el)
        return false unless l = el.lpos
        ((l.xl - l.xi) > 0) && ((l.yl - l.yi) > 0)
      end

      # Get last coordinates of a child element
      def get_last(i)
        i.downto 1 do
          i -= 1
          return @children[i] if rendered?(@children[i])
        end
        nil
      end

      def get_last_coords(i)
        if l = get_last i
          return l.lpos
        end
        nil
      end

      def _render_coords
        coords = _get_coords true
        children = @children.dup
        @children.clear
        _render
        @children += children
        coords
      end

      def renderer(c)
        # Coordinates of the layout element itself
        width = c.xl - c.xi
        height = c.yl - c.yi
        xi = c.xi
        yi = c.yi

        # Current row offset in cells (which row are we on?)
        row_offset = 0
        # Index of first child in the row
        row_index = 0
        last_row_index = 0

        high_width = 0

        # Figure out highest child element
        if @layout == LayoutType::Grid
          high_width = @children.reduce(0) { |o, el|
            Math.max o, el.awidth
          }
        end

        ->(el : Widget, i : Int32) {
          # Make our children resizable. If they don't have a height, for
          # example, calculate it for them.
          el.resizable = true

          # Find the previous rendered child's coordinates
          last = get_last i

          # If there is no previously rendered element, we are on the first child.
          if !last
            el.left = 0
            el.top = 0
          else
            # Otherwise, figure out where to place this child. We'll start by
            # setting it's `left`/`x` coordinate to right after the previous
            # rendered element. This child will end up directly to the right of it.
            llp = last.lpos.not_nil!
            el.left = llp.xl - xi

            # Make sure the position matches the highest width element
            if (@layout == LayoutType::Grid)
              # D O:
              # Compensate with width:
              # el.width = el.awidth + (highWidth - el.awidth)
              # Compensate with position:
              el.left = el.left.as(Int) + high_width - (llp.xl - llp.xi)
            end

            # If our child does not overlap the right side of the Layout, set it's
            # `top`/`y` to the current `row_offset` (the coordinate for the current
            # row).
            if el.left.as(Int) + el.awidth <= width
              el.top = row_offset
            else
              # Otherwise we need to start a new row and calculate a new
              # `row_offset` and `row_index` (the index of the child on the current
              # row).
              row_offset += @children[row_index...i].reduce(0) { |o, el2|
                if !rendered?(el2)
                  o
                else
                  elp = el2.lpos.not_nil!
                  Math.max o, elp.yl - elp.yi
                end
              }
              last_row_index = row_index
              row_index = i
              el.left = 0
              el.top = row_offset
            end
          end

          # Make sure the elements on lower rows gravitate up as much as possible
          if (@layout == LayoutType::Inline)
            above = nil
            abovea = Int32::MAX
            j = last_row_index
            while j < row_index
              l = @children[j]
              if (!rendered?(l))
                j += 1
                next
              end
              abs = (el.left.as(Int) - (l.lpos.not_nil!.xi - xi)).abs
              # D O:
              # if (abs < abovea && (l.lpos.xl - l.lpos.xi) <= el.awidth)
              if (abs < abovea)
                above = l
                abovea = abs
              end

              j += 1
            end
            if above
              el.top = above.lpos.not_nil!.yl - yi
            end
          end

          # If our child overflows the Layout, return @overflow which contains
          # instruction what to do.
          if (el.top.as(Int) + el.height.as(Int) > height)
            return @overflow
          end
        }
      end

      def render
        _emit Crysterm::Event::PreRender

        coords = _render_coords
        if (!coords)
          @lpos = nil
          return
        end

        if (coords.xl - coords.xi <= 0)
          coords.xl = Math.max(coords.xl, coords.xi)
          return
        end

        if (coords.yl - coords.yi <= 0)
          coords.yl = Math.max(coords.yl, coords.yi)
          return
        end

        @lpos = coords

        @style.border.try &.adjust(coords)

        if @padding.any?
          coords.xi += @padding.left
          coords.xl -= @padding.right
          coords.yi += @padding.top
          coords.yl -= @padding.bottom
        end

        iterator = renderer(coords)

        @style.border.try &.adjust(coords, -1)

        if @padding.any?
          coords.xi -= @padding.left
          coords.xl += @padding.right
          coords.yi -= @padding.top
          coords.yl += @padding.bottom
        end

        @children.each_with_index do |el, i|
          if (el.screen._ci != -1)
            el.index = el.screen._ci
            el.screen._ci += 1
          end

          rendered = iterator.call(el, i)
          case rendered
          when Overflow::SkipWidget
            el.lpos = nil
            next
          when Overflow::StopRendering
            el.lpos = nil
            break
          when Overflow::MoveWidget
            raise Exception.new "Not implemented yet"
          end

          # D O:
          # if (el.screen._rendering)
          #   el._rendering = true;
          # end
          el.render
          # D O:
          # if (el.screen._rendering)
          #   el._rendering = false;
          # end
        end

        _emit Crysterm::Event::Rendered # , coords # XXX add param to the event

        coords
      end
    end
  end
end
