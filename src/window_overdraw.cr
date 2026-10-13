module Crysterm
  class Window
    # Overdraw tracking: what the terminal had written over it since the last
    # `Event::Rendered`.
    #
    # A widget whose pixels the terminal owns (`Widget::Media::Graphics`) paints
    # them after the frame's cells are flushed, so they land on top. A backend
    # that emits its graphic only when it changes (Kitty: a separate image layer
    # the cells do not touch in kitty itself) must still emit it again when the
    # terminal may have lost it since the last emit:
    #
    # * the frame wrote cells inside its rectangle — a terminal keeping its
    #   images in the cells (as WezTerm does) erases the picture under every
    #   character written there, and a full re-emission (`#invalidate_region` of
    #   the whole window, done when the terminal's color depth, hyperlink
    #   support or polarity is learned after the first frames, on `#show` and
    #   on `Application#activate`) writes every cell, blanks included;
    # * the surface was wiped (`tput.clear`, whose `ED 2` deletes kitty's
    #   images too, or an erase of whole rows) or scrolled (insert/delete-line
    #   ops), which no cell comparison sees.
    #
    # `#draw` records, per row, the first and last column it wrote; the wipes
    # set a flag; `#overdrawn?` answers for a rectangle during `Event::Rendered`,
    # after which the record is reset for the next frame.

    # Per surface row, the first and last column `#draw` wrote since the last
    # `Event::Rendered` (`-1` when none). Grown to the row count on demand.
    @_overdraw_lo = [] of Int32
    @_overdraw_hi = [] of Int32

    # Whether any row holds a record (so the reset is skipped on idle frames).
    @_overdraw_any = false

    # Whether the surface was wiped or scrolled since the last `Event::Rendered`.
    @_overdraw_all = false

    # Whether the terminal may have written over the window rectangle *x*, *y*,
    # *w* × *h* (cells) since the previous `Event::Rendered`: a cell inside it
    # was emitted, or the surface was cleared or scrolled. Meant for
    # `Event::Rendered` listeners that paint outside the cell buffer and skip
    # repainting when nothing changed.
    def overdrawn?(x : Int32, y : Int32, w : Int32, h : Int32) : Bool
      return true if @_overdraw_all
      return false unless @_overdraw_any
      x2 = x + w - 1
      y0 = Math.max(y, 0)
      y1 = Math.min(y + h, @_overdraw_lo.size) - 1
      y0.upto(y1) do |row|
        lo = @_overdraw_lo.unsafe_fetch(row)
        next if lo < 0
        return true if lo <= x2 && @_overdraw_hi.unsafe_fetch(row) >= x
      end
      false
    end

    # Whether the surface itself was wiped or scrolled since the previous
    # `Event::Rendered` (a clear, an erase of whole rows, insert/delete-line
    # ops), as opposed to cells written over parts of it: then `#overdrawn?`
    # is true everywhere, and what the terminal stored with the lost pictures
    # may be gone too (kitty frees an image's data on `ED 2`), so a listener
    # sends a picture whole again rather than placing it once more.
    def wiped? : Bool
      @_overdraw_all
    end

    # Records that `#draw` wrote columns *lo*..*hi* of row *y*.
    @[AlwaysInline]
    private def note_overdraw(y : Int32, lo : Int32, hi : Int32) : Nil
      if y >= @_overdraw_lo.size
        (y + 1 - @_overdraw_lo.size).times do
          @_overdraw_lo << -1
          @_overdraw_hi << -1
        end
      end
      cur = @_overdraw_lo.unsafe_fetch(y)
      @_overdraw_lo[y] = lo if cur < 0 || lo < cur
      @_overdraw_hi[y] = hi if hi > @_overdraw_hi.unsafe_fetch(y)
      @_overdraw_any = true
    end

    # Records that the whole surface may have been written over (cleared,
    # rows erased or scrolled) — for every window on the terminal: a sibling
    # sharing it lost its pictures too (kitty frees them on `ED 2`), and must
    # send them whole when it is shown again.
    protected def note_overdraw_all : Nil
      @_overdraw_all = true
      Window.instances.each do |w|
        w.note_wiped if !w.same?(self) && w.screen.same?(@screen)
      end
    end

    # Records that this window's surface was wiped by a sibling's write.
    protected def note_wiped : Nil
      @_overdraw_all = true
    end

    # Forgets the record, once `Event::Rendered` has been delivered.
    private def reset_overdraw : Nil
      @_overdraw_all = false
      return unless @_overdraw_any
      @_overdraw_any = false
      @_overdraw_lo.fill -1
      @_overdraw_hi.fill -1
    end
  end
end
