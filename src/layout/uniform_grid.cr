require "./flow"

module Crysterm
  class Layout
    # Uniform-cell wrapping flow (WPF's `UniformGrid`; blessed's `grid` layout).
    # Like `Masonry`, flows children left-to-right with row wrapping, but every
    # child snaps to a column of the widest child's width, giving a regular
    # tiled grid rather than a packed masonry. For an explicit row/column grid
    # with spans, see `Layout::Grid`.
    #
    # NOTE: children must have an explicit `width`. A nil-width (`auto`) child's
    # `awidth` reports the *stretched* full-interior size, which would make it
    # the uniform column width and collapse the grid to a single column.
    #
    # <!-- widget-examples:capture v1 -->
    # ![UniformGrid screenshot](../../tests/layout/uniform_grid/uniform_grid.5s.apng)
    # <!-- /widget-examples:capture -->
    class UniformGrid < Flow
      @high_width = 0

      # Per-child `awidth` resolved by this frame's `#before_flow` scan, reused
      # by `#cached_awidth` at the placement fit check instead of resolving
      # `awidth` a second time for the same child. Per-arrange scratch:
      # cleared and rebuilt at the top of every `#before_flow` call, mirroring
      # how `Flow#arrange` resets its own row-cursor ivars each frame.
      @awidth_cache = {} of Widget => Int32

      # Widest child becomes the uniform column width. Layout-excluded chrome
      # (e.g. a full-width `background-image` layer) and `layout_chrome?` chrome
      # (a border label / bound scroll bar) are skipped; either would otherwise
      # inflate the column to the whole interior and collapse the grid to one
      # column. So are `#vacant?` (hidden) children — `Flow#arrange` packs as
      # though they weren't there, and a hidden wide child must not set the
      # column pitch for the visible ones.
      protected def before_flow(container : Widget) : Nil
        @awidth_cache.clear
        hw = 0
        each_occupying(container) do |el|
          w = el.awidth
          @awidth_cache[el] = w
          hw = Math.max hw, w
        end
        @high_width = hw
      end

      # Reuses the `awidth` this frame's `#before_flow` scan already resolved
      # for `el`, instead of resolving it again for the placement fit check.
      # Falls back to a fresh `el.awidth` when `el` isn't in the
      # cache — a `Flow#arrange` child that isn't `#each_occupying` (e.g. a
      # `#vacant?` one skipped before `#place_one` runs) never reaches
      # `#flow_place`, so this should be unreachable in practice, but stays
      # nil-safe rather than raising on a missing key.
      protected def cached_awidth(el : Widget) : Int32
        @awidth_cache[el]? || el.awidth
      end

      # Snap every child to the widest child's width, measured in `#before_flow`.
      protected def column_width : Int32
        @high_width
      end
    end
  end
end
