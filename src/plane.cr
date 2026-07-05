module Crysterm
  # An independent, window-sized cell buffer with a z-order — the unit a widget
  # (and its subtree) renders into once promoted to a *layer* (via CSS
  # `z-index`, or `style.z_index`). After the base buffer is painted by the
  # normal painter, each plane is composited over it bottom-to-top, honoring
  # the per-cell `Attr::Alpha` modes and the plane's own `opacity`. This is
  # what lets an "opaque" overlay show other widgets' content through it.
  #
  # Planes are opt-in: a UI with no z-index allocates none and the render path
  # is unchanged.
  class Plane
    # A cleared cell carries both channels' alpha as `Transparent` and a space,
    # so an untouched cell contributes nothing. A widget's render overwrites
    # cells it actually paints (`Opaque`).
    CLEAR_ATTR = Attr.with_alpha(Window::DEFAULT_ATTR, Attr::Alpha::Transparent, Attr::Alpha::Transparent)

    getter z : Int32

    # How strongly the whole plane contributes over the base (`0.0`..`1.0`); set
    # from the layer root's `opacity`. At `1.0` the per-cell modes alone decide.
    property opacity : Float64 = 1.0

    # The plane's own cell buffer (kept the same size as the window).
    getter cells : Array(Window::Row)

    def initialize(@z : Int32, width : Int32, height : Int32)
      @cells = Array(Window::Row).new
      resize width, height
    end

    def width : Int32
      @cells[0]?.try(&.size) || 0
    end

    def height : Int32
      @cells.size
    end

    # (Re)builds the buffer to *width*×*height* when the window size changes.
    def resize(width : Int32, height : Int32) : Nil
      return if width == self.width && height == self.height
      @cells = Array(Window::Row).new(height) do
        row = Window::Row.new width
        width.times { row.push CLEAR_ATTR, ' ' }
        row
      end
    end

    # Resets every cell to the transparent sentinel — called once per frame,
    # before the layer's widgets render into this plane.
    def clear : Nil
      @cells.each do |row|
        next unless row.dirty # untouched since last clear ⇒ already the sentinel
        row.clear_to CLEAR_ATTR, ' '
        row.dirty = false
      end
    end

    # Folds this plane over *base* in place. Each painted cell is composited per
    # its `Attr::Alpha` modes (`Colors.composite`), then — when `opacity < 1` —
    # scaled toward the base so the whole layer reads as translucent. Untouched
    # (transparent-sentinel) cells are skipped.
    #
    # `xi`/`xl`/`yi`/`yl` clip the fold to a half-open sub-rectangle (default:
    # whole plane). Damage tracking uses this to re-fold only the region of the
    # base it just rebuilt — re-folding over an already-folded base would
    # saturate, so the caller rebuilds the base in this rectangle first.
    def composite_onto(base : Array(Window::Row), xi : Int32 = 0, xl : Int32 = Int32::MAX, yi : Int32 = 0, yl : Int32 = Int32::MAX) : Nil
      op = @opacity
      # Opacity is constant for the whole composite, so decide once whether a
      # cell is taken straight from the fold or blended toward the base.
      opaque = op >= 1.0
      rows = {@cells.size, base.size}.min
      y = yi < 0 ? 0 : yi
      rows = yl if yl < rows
      while y < rows
        pr = @cells.unsafe_fetch(y)
        # A plane row no widget painted this frame is entirely the transparent
        # sentinel (`#clear` set `dirty = false`; the render path sets it true
        # on any row it writes), so the scan can skip it. The base is rebuilt
        # every frame, so no stale overlay is ever left on a transparent row.
        # This collapses the O(width×height) scan to just the touched rows.
        unless pr.dirty
          y += 1
          next
        end
        br = base.unsafe_fetch(y)
        pa = pr.attrs; pc = pr.chars
        ba = br.attrs; bc = br.chars
        cols = {pa.size, ba.size}.min
        cols = xl if xl < cols
        # Whether this row carries any grapheme-cluster overlay. When not (the
        # common all-single-codepoint case), the per-cell `grapheme_at?` probe
        # below is skipped; the base cell's overlay is still cleared so an
        # opaque plane cell never inherits a stale cluster.
        pr_has_g = pr.has_graphemes?
        # Same gate for the BASE row's overlay: with none, the per-cell
        # `br.grapheme_at?` probe and `delete_grapheme` are skipped. Installing
        # an overlay below flips the flag; installs happen at already-visited
        # columns, so probes at the current `x` stay exact.
        br_has_g = br.has_graphemes?
        x = xi < 0 ? 0 : xi
        while x < cols
          patt = pa.unsafe_fetch(x)
          ch = pc.unsafe_fetch(x)
          unless patt == CLEAR_ATTR && ch == ' ' # skip unpainted (transparent) cells
            under = ba.unsafe_fetch(x)
            folded = Colors.composite(patt, under)
            result = opaque ? folded : Colors.blend(folded, under, op)
            # The base `char` array stores only a cluster's BASE codepoint, so the
            # attr/char compare above is blind to grapheme-overlay differences
            # (e.g. base "e" under an overlay painting "é" with identical style).
            # Include the overlay in the change test so the accent is installed,
            # and so a stale cluster under a matching base cell is cleared.
            pg = pr_has_g ? pr.grapheme_at?(x) : nil
            bg = br_has_g ? br.grapheme_at?(x) : nil
            if under != result || bc.unsafe_fetch(x) != ch || bg != pg
              ba[x] = result
              bc[x] = ch
              if pg
                br.set_grapheme x, pg
                br_has_g = true
              elsif br_has_g
                br.delete_grapheme x
              end
              # Narrow the dirty range to the changed columns (a plain
              # `dirty = true` widened it to full width, defeating draw's
              # scan-bounding for plane frames).
              br.mark_dirty x
            end
          end
          x += 1
        end
        y += 1
      end
    end
  end
end
