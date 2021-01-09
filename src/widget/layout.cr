require "./radioset"

module Crysterm
  module Widget
    # Layout
    class Layout < Element
      include EventHandler

      @type = :layout
      @layout : String
      @renderer : Proc(Element, Int32)?

      def initialize(@layout=LayoutType::Inline, @renderer=nil, **el)
        if (!el["width"]? && (!el["left"]? && !el["right"])) ||
           (!el["height"]? && (!el["top"]? && !el["bottom"]))
          raise "Layout must have width and height"
        end

        super **element
      end

      def rendered?(el)
        return false unless l = el.lpos
        ((l.xl - l.xi) > 0) && ((l.yl - l.yi) > 0)
      end

      # Get last coordinates of a child element
      def get_last(i)
        i -= 1
        i.downto 1 do
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
            Math.max o, el.width
          }
        end

        ->(el : Element, i : Int32) {
          # Make our children shrinkable. If they don't have a height, for
          # example, calculate it for them.
          el.shrink = true

          # Find the previous rendered child's coordinates
          last = get_last i

          # If there is no previously rendered element, we are on the first child.
          if (!last)
            el.position.left = 0
            el.position.top = 0
          else
            # Otherwise, figure out where to place this child. We'll start by
            # setting it's `left`/`x` coordinate to right after the previous
            # rendered element. This child will end up directly to the right of it.
            llp = last.lpos.not_nil!
            el.position.left = llp.xl - xi

            # Make sure the position matches the highest width element
            if (@layout == LayoutType::Grid)
              # Compensate with width:
              # el.position.width = el.width + (highWidth - el.width)
              # Compensate with position:
              el.position.left = el.position.left.as(Int) + high_width - (llp.xl - llp.xi)
            end

            # If our child does not overlap the right side of the Layout, set it's
            # `top`/`y` to the current `rowOffset` (the coordinate for the current
            # row).
            if (el.position.left.as(Int) + el.width <= width)
              el.position.top = row_offset
            else
              # Otherwise we need to start a new row and calculate a new
              # `rowOffset` and `rowIndex` (the index of the child on the current
              # row).
              row_offset += @children[row_index...i].reduce(0) { |o, el|
                if (!rendered?(el))
                  o
                else
                  elp = el.lpos.not_nil!
                  Math.max o, elp.yl - elp.yi
                end
              }
              last_row_index = row_index
              row_index = i
              el.position.left = 0
              el.position.top = row_offset
            end
          end

          # Make sure the elements on lower rows graviatate up as much as possible
          if (@layout == LayoutType::Inline)
            above = nil
            abovea = Int32::MAX
            (last_row_index...row_index).each do |j|
              l = @children[j]
              if (!rendered?(l))
                next
              end
              abs = (el.position.left.as(Int) - (l.lpos.not_nil!.xi - xi)).abs
              # D O:
              # if (abs < abovea && (l.lpos.xl - l.lpos.xi) <= el.width)
              if (abs < abovea)
                above = l
                abovea = abs
              end
            end
            if (above)
              el.position.top = above.lpos.not_nil!.yl - yi
            end
          end

          # If our child overflows the Layout, do not render it!
          # Disable this feature for now.
          if (el.position.top.as(Int) + el.height > height)
            # Returning false tells blessed to ignore this child.
            # return false
          end
        }
      end

      def render
        _emit PreRenderEvent

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

        if (@border)
          coords.xi+=1
          coords.xl-=1
          coords.yi+=1
          coords.yl-=1
        end

        if (tpadding)
          coords.xi += @padding.left
          coords.xl -= @padding.right
          coords.yi += @padding.top
          coords.yl -= @padding.bottom
        end

        iterator = renderer(coords)

        if (@border)
          coords.xi-=1
          coords.xl+=1
          coords.yi-=1
          coords.yl+=1
        end

        if (tpadding)
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
          if (rendered == false)
            el.lpos = nil
            return
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

        _emit RenderEvent #, coords

        coords
      end
    end
  end
end
