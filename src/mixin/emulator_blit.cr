module Crysterm
  module Mixin
    # Shared grid→window blit for widgets that embed a `TerminalEmulator`
    # (`Widget::Terminal`, `Widget::LogFd` in `:ansi` mode): copies the
    # emulator's visible grid onto the window cells covering the includer's
    # content area, with ancestor clipping, wide-glyph (continuation-cell)
    # handling and an optional cursor overlay.
    #
    # Written against the includer's widget surface (`content_edges`, `aleft`/
    # `ileft`, `window`), so it must be included into a `Widget` subclass.
    module EmulatorBlit
      # Copies *em*'s visible grid into `window.cell_rows` over the content area
      # described by *coords*.
      #
      # `cursor_x`/`cursor_y` are window-absolute coordinates of the cell to
      # overlay the cursor on; the block maps that cell's `{attr, char}` to its
      # cursor-styled replacement. Callers must pass coordinates only when the
      # cursor is visible and inside the (possibly clipped) viewport — pass the
      # `-1, -1` sentinel (or use the block-less overload) to skip the overlay
      # entirely; `y`/`x` never go negative, so the sentinel can never match.
      private def blit_emulator_grid(em : TerminalEmulator, coords, cursor_x : Int32, cursor_y : Int32, & : Int64, Char -> {Int64, Char}) : Nil
        lines = window.cell_rows

        xi, xl, yi, yl = content_edges coords

        # When an ancestor clips this widget, `coords` moves `coords.xi`/`coords.yi`
        # inward to the clip edge and folds the clipped-top row count into
        # `coords.base`. Rows must map through `coords.base` and columns through
        # the unclipped content origin — the true position of emulator column 0,
        # since horizontal clipping has no `base` — or a partially clipped
        # grid shows its top-left corner instead of the correct region.
        origin_x = aleft + ileft

        disp = em.ydisp
        full_unicode = window.full_unicode_effective?

        y = Math.max yi, 0
        while y < yl
          line = lines[y]?
          break unless line
          src = em.lines[disp + coords.base + (y - yi)]?
          break unless src

          cursor_col = (y == cursor_y) ? cursor_x : -1

          x = Math.max xi, 0
          while x < xl
            cell = line[x]?
            break unless cell
            scell = src[x - origin_x]?
            break unless scell

            attr = scell.attr
            ch = scell.char
            # The emulator parks a NUL in the trailing half of a wide glyph;
            # render it blank. In full-unicode mode the wide-glyph branch below
            # claims the following cell as a real continuation, skipping this.
            ch = ' ' if ch == TerminalEmulator::CONTINUATION

            if x == cursor_col
              attr, ch = yield attr, ch
            end

            # Both wide-glyph branches below need the glyph's column count and
            # the following window cell; derive each once per cell. Folding
            # `full_unicode` into `cw` (a window without full-unicode support
            # treats every cell as one column) reproduces the plain
            # `full_unicode && Unicode.width(ch) == 2` guards exactly, while
            # sparing every interior cell a second `Unicode.width` walk and a
            # second bounds-checked row lookup. Safe to hoist `nxt` above the
            # write below: that write targets `line[x]`, never `line[x + 1]`.
            cw = full_unicode ? ::Crysterm::Unicode.width(ch) : 1
            nxt = line[x + 1]?

            # A wide (2-column) glyph whose continuation cell cannot be claimed —
            # past the content region or absent from the window row — is blanked
            # to a space, upholding the invariant "a width-2 cell is always
            # followed by an in-region continuation" that the flush code relies on
            # (mirrors the end-of-line safeguard in `widget_rendering.cr`).
            # Without it a bare wide lead — e.g. one stranded in the last column
            # by a column-shrink resize — would over-claim and paint across the
            # widget's edge into the neighbouring cell. Must stay the exact
            # complement of the continuation-claim block below.
            if cw == 2 && (x + 1 >= xl || nxt.nil?)
              ch = ' '
              # Load-bearing: the blanked lead is now one column wide, so the
              # claim block below must not also consume the next column.
              cw = 1
            end

            if cell != {attr, ch}
              cell.attr = attr
              cell.char = ch
              line.mark_dirty x
            end

            # Wide glyph: claim the following window cell as its continuation so
            # the window grid stays 1 cell == 1 terminal column. This holds even
            # when the cursor sits on the lead half — `attr` already carries the
            # cursor styling — so both columns are still consumed.
            if cw == 2 && nxt && x + 1 < xl
              nxt_attr = attr
              # With the cursor on the TRAILING half of a wide glyph, `x += 2`
              # would skip its column and leave it invisible; carry the cursor
              # styling onto the continuation cell instead.
              if x + 1 == cursor_col
                nxt_attr, _ = yield attr, ' '
              end
              nxt.attr = nxt_attr
              nxt.continuation!
              line.mark_dirty x + 1
              x += 2
              next
            end

            x += 1
          end

          y += 1
        end
      end

      # Cursor-less blit (for non-interactive grids, or when the cursor is
      # hidden/scrolled out of view): the sentinel column can never match, so
      # the identity block is never invoked.
      private def blit_emulator_grid(em : TerminalEmulator, coords) : Nil
        blit_emulator_grid(em, coords, -1, -1) { |attr, ch| {attr, ch} }
      end
    end
  end
end
