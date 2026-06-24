module Crysterm
  # An independent, screen-sized cell buffer with a z-order — the unit a widget
  # (and its subtree) renders into once it is promoted to a *layer* (via CSS
  # `z-index`, or `style.z_index`). After the base buffer is painted by the
  # normal painter's algorithm, each plane is composited over it bottom-to-top,
  # honoring the per-cell `Attr::Alpha` modes (Step 4) and the plane's own
  # `opacity`. That composite pass is what lets an *opaque* overlay show other
  # widgets' content through it — something the single-buffer painter can't do.
  #
  # Planes are opt-in: a UI that declares no z-index allocates none and the
  # render path is unchanged.
  class Plane
    # A cleared cell carries both channels' alpha as `Transparent` and a space,
    # so an untouched cell contributes nothing (the base shows through). A
    # widget's normal render overwrites the cells it actually paints (`Opaque`).
    CLEAR_ATTR = Attr.with_alpha(Screen::DEFAULT_ATTR, Attr::Alpha::Transparent, Attr::Alpha::Transparent)

    getter z : Int32

    # How strongly the whole plane contributes over the base (`0.0`..`1.0`); set
    # from the layer root's `opacity`. At `1.0` the per-cell modes alone decide.
    property opacity : Float64 = 1.0

    # The plane's own cell buffer (kept the same size as the screen).
    getter cells : Array(Screen::Row)

    def initialize(@z : Int32, width : Int32, height : Int32)
      @cells = Array(Screen::Row).new
      resize width, height
    end

    def width : Int32
      @cells[0]?.try(&.size) || 0
    end

    def height : Int32
      @cells.size
    end

    # (Re)builds the buffer to *width*×*height* when the screen size changes.
    def resize(width : Int32, height : Int32) : Nil
      return if width == self.width && height == self.height
      @cells = Array(Screen::Row).new(height) do
        row = Screen::Row.new width
        width.times { row.push CLEAR_ATTR, ' ' }
        row
      end
    end

    # Resets every cell to the transparent sentinel — called once per frame,
    # before the layer's widgets render into this plane.
    def clear : Nil
      @cells.each do |row|
        row.clear_to CLEAR_ATTR, ' '
        row.dirty = false
      end
    end

    # Folds this plane over *base* in place. Each painted cell is composited per
    # its `Attr::Alpha` modes (`Colors.composite`), then — when `opacity < 1` —
    # scaled toward the base so the whole layer reads as translucent. Untouched
    # (transparent-sentinel) cells are skipped, so the base shows through.
    #
    # `xi`/`xl`/`yi`/`yl` clip the fold to a half-open sub-rectangle (defaults
    # cover the whole plane). Damage tracking's Phase 4 selective plane frame
    # uses this to re-fold the plane over only the region of the base it just
    # rebuilt — re-folding over a carried-over (already-folded) base would
    # saturate, so the caller rebuilds the base in this exact rectangle first.
    def composite_onto(base : Array(Screen::Row), xi : Int32 = 0, xl : Int32 = Int32::MAX, yi : Int32 = 0, yl : Int32 = Int32::MAX) : Nil
      op = @opacity
      # The plane's opacity is constant for the whole composite, so decide once
      # — not per cell — whether a painted cell is taken straight from the fold
      # or blended toward the base. Replaces a per-cell `op >= 1.0` float compare
      # with a per-cell read of this local bool.
      opaque = op >= 1.0
      rows = {@cells.size, base.size}.min
      y = yi < 0 ? 0 : yi
      rows = yl if yl < rows
      while y < rows
        pr = @cells.unsafe_fetch(y)
        # A plane row that no widget painted into this frame is entirely the
        # transparent sentinel — `#clear` marked it `dirty = false`, and the
        # render path sets `dirty = true` on any row it writes — so it composites
        # to nothing and the whole row scan can be skipped. The base buffer is
        # rebuilt every frame (`Screen#_render` clears it), so there is never a
        # stale overlay left behind on a now-transparent row. For a small overlay
        # on a large terminal this collapses the full O(width×height) scan to just
        # the rows the layer actually touched.
        unless pr.dirty
          y += 1
          next
        end
        br = base.unsafe_fetch(y)
        pa = pr.attrs; pc = pr.chars
        ba = br.attrs; bc = br.chars
        cols = {pa.size, ba.size}.min
        cols = xl if xl < cols
        # Whether this plane row carries any grapheme-cluster overlay. When it
        # does not (the overwhelmingly common all-single-codepoint row), the
        # per-cell `grapheme_at?` hash probe below is pointless and skipped — the
        # base cell's own overlay (if a base-layer paint left one) is still
        # cleared so an opaque plane cell never inherits a stale cluster.
        pr_has_g = pr.has_graphemes?
        changed = false
        x = xi < 0 ? 0 : xi
        while x < cols
          patt = pa.unsafe_fetch(x)
          ch = pc.unsafe_fetch(x)
          unless patt == CLEAR_ATTR && ch == ' ' # skip unpainted (transparent) cells
            under = ba.unsafe_fetch(x)
            folded = Colors.composite(patt, under)
            result = opaque ? folded : Colors.blend(folded, under, op)
            if under != result || bc.unsafe_fetch(x) != ch
              ba[x] = result
              bc[x] = ch
              if pr_has_g && (g = pr.grapheme_at?(x))
                br.set_grapheme x, g
              else
                br.delete_grapheme x
              end
              changed = true
            end
          end
          x += 1
        end
        br.dirty = true if changed
        y += 1
      end
    end
  end
end
