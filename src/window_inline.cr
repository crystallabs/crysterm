module Crysterm
  # The inline-mode / auto-grow machinery of a `Window`: everything behind
  # `alternate: false` — anchoring the surface at the terminal's cursor row in
  # the normal scrolling buffer, offsetting rendered rows, growing/shrinking
  # the region to fit content, and tearing the region down on leave. The
  # full-screen (alt-buffer) path lives in `window.cr`; `#enter`/`#leave`
  # branch into the helpers here.
  class Window
    # Whether this window takes over the whole terminal via the *alternate*
    # screen buffer (the default, full-screen mode). When `false`, the window
    # runs **inline**: it stays in the normal scrolling buffer, is bounded to its
    # `height` rows, and is anchored at the terminal's cursor row at start-up.
    # All the normal machinery (widgets, input, focus, damage/diff, layout)
    # applies; only the alt-buffer takeover and full-screen scroll region are
    # skipped, and rendered rows are offset down to `#render_row_offset`. Inline
    # mode wants an explicit `height:` (the reserved region size).
    getter? alternate : Bool = true

    # Whether this window runs inline in the normal buffer rather than taking
    # over the alternate screen — the intent-named inverse of `#alternate?`.
    def inline? : Bool
      !alternate?
    end

    # Physical terminal row the inline (`alternate: false`) surface is anchored
    # at — added to every rendered row so the whole `[0, aheight)` surface lands
    # at `[offset, offset + aheight)` on the real terminal. `0` in full-screen
    # (alt) mode, so the offset is a no-op there. On the draw hot path.
    property render_row_offset : Int32 = 0

    # Terminal cursor row an inline surface is anchored at, captured at
    # construction before the input loop starts. Settable so hosts/specs can pin
    # it when the terminal can't answer the cursor-position query.
    property anchor_row : Int32 = 0

    # Inline **auto-grow**: when `true` (only meaningful with `alternate: false`),
    # the region's height tracks its content each frame instead of staying fixed
    # — it grows downward as widgets need more rows (scrolling the terminal up
    # when it reaches the bottom) and shrinks back, erasing the rows it vacates.
    # Suits a completer/menu whose size depends on how many items are showing.
    # Content must be top-anchored (heights that don't depend on the surface
    # height); the growth is capped by `#max_height`.
    getter? auto_grow : Bool = false

    # Optional cap on an `auto_grow` region's height (in rows). `nil` = the
    # terminal height. The region never grows past this.
    property max_height : Int32? = nil

    # Physical footprint (rows) the inline region currently occupies on screen.
    # Under auto-grow this can be less than `aheight`; teardown parks the cursor
    # below the *actual* content, and a shrink erases the rows it vacates.
    @inline_visible : Int32 = 0

    # Captures the terminal's current cursor row so an inline surface can be
    # anchored there. Must run before the input loop starts (`report_cursor`
    # reads `@input` synchronously). Falls back to row 0 if the terminal doesn't
    # answer.
    private def capture_inline_anchor : Nil
      @anchor_row = TerminalCursorAnchor.new(@screen).cursor_row
    end

    # Reserves the inline region below the anchor row and sets
    # `#render_row_offset`. If the anchor sits too low for `aheight` rows to fit,
    # scrolls the terminal up by emitting newlines (pushing existing content into
    # scrollback) and moves the anchor up to compensate, so the region always
    # fits on-screen. Homes the cursor to the region's top-left.
    private def enter_inline : Nil
      anchor = @anchor_row
      term_h = tput.screen.height
      if anchor + aheight > term_h
        scroll = anchor + aheight - term_h
        # Newlines only scroll the terminal when emitted from the bottom row, so
        # `scroll_terminal_up` homes to the last row first; from the anchor row
        # nothing would enter scrollback.
        scroll_terminal_up scroll
        anchor -= scroll
      end
      anchor = 0 if anchor < 0
      @render_row_offset = anchor
      @inline_visible = aheight
      tput.cursor_pos anchor, 0
    end

    # Height an `auto_grow` region may grow to (rows): the configured
    # `#max_height`, else the terminal height, and never more than the terminal
    # can show.
    private def autogrow_max : Int32
      cap = @max_height || tput.screen.height
      {cap, tput.screen.height}.min
    end

    # Reflows an inline `auto_grow` region to fit its content. Must run once per
    # frame *before* compositing, so widgets lay out at the new height. On growth
    # past the screen bottom it scrolls the terminal up and re-anchors; on shrink
    # it erases the physical rows the region no longer occupies. A no-op when the
    # size is unchanged, so steady-state frames pay only the measurement.
    private def autogrow_reflow : Nil
      return unless !@alternate && @auto_grow

      desired = content_height.clamp(1, autogrow_max)
      cur = aheight
      if desired > cur
        # Growing past the last screen row: scroll existing content up into
        # scrollback and move the anchor up to make room.
        overflow = (render_row_offset + desired) - tput.screen.height
        if overflow > 0
          scroll_terminal_up overflow
          self.render_row_offset = Math.max(0, render_row_offset - overflow)
        end
      elsif desired < cur
        # Shrinking: clear the rows the region is giving back to the terminal
        # before the buffer forgets they were ours.
        erase_physical_rows render_row_offset + desired, render_row_offset + @inline_visible
      end

      @inline_visible = desired
      if desired != cur
        @screen.height = desired
        # Full repaint of the resized region at the (possibly new) offset.
        # `alloc`'s `tput.clear` is suppressed inline, so this does not wipe the
        # terminal.
        realloc
      end
    end

    # Desired inline height (rows) from the widget tree: the largest bottom edge
    # (`atop + aheight`) among visible top-level children, in surface
    # coordinates. Assumes top-anchored content (heights independent of the
    # surface height); at least 1.
    def content_height : Int32
      h = 1
      children.each do |c|
        next unless c.visible?
        bottom = c.atop + c.aheight
        h = bottom if bottom > h
      end
      h
    end

    # Scrolls the whole terminal up by *n* rows (pushing the top into
    # scrollback) by emitting newlines at the last row.
    private def scroll_terminal_up(n : Int32) : Nil
      return unless n > 0
      tput.cursor_pos tput.screen.height - 1, 0
      tput._print { |io| n.times { io << '\n' } }
    end

    # Erases physical rows `[from, to)` (whole lines).
    private def erase_physical_rows(from : Int32, to : Int32) : Nil
      term_h = tput.screen.height
      from.upto(to - 1) do |py|
        next if py < 0 || py >= term_h
        tput.cursor_pos py, 0
        tput._print "\e[2K"
      end
    end

    # Tears down an inline (non-alt) surface: restores keypad/mouse/cursor,
    # releases the scroll region, and parks the cursor just below the rendered
    # region so the shell prompt continues cleanly instead of overwriting the UI.
    private def leave_inline : Nil
      tput.disable_keypad
      disable_mouse if @screen.mouse_enabled?

      # An inline il/dl scroll op may have left the scroll region pinned to
      # `[offset, offset + aheight - 1]`; hand the whole terminal back.
      tput.set_scroll_region(0, tput.screen.height - 1)

      show_cursor
      # Same as in `#leave`: the artificial branch of `show_cursor` never emits
      # cnorm, so directly undo the civis `apply_cursor`'s artificial branch
      # emitted (or any other stray hide) before handing the tty back.
      show_hardware_cursor
      # Park below the region's *actual* on-screen footprint (which, under
      # auto-grow, may be smaller than `aheight`).
      tput.cursor_pos render_row_offset + @inline_visible, 0
      reset_cursor if cursor.applied?

      tput.flush
    end
  end
end
