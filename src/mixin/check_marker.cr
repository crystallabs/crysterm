module Crysterm
  module Mixin
    # Shared rendering and interaction for the marker-style checkable controls —
    # `[x] label`, `(*) label`. Provides the marker-only click hit-test, the
    # activate-key toggle, focus/blur cursor placement over the marker, and the
    # `<open><glyph><close> text` line builder. The glyph set, tri-state and
    # group exclusivity stay per-widget.
    #
    # The including type must derive `Widget::AbstractButton`.
    module CheckMarker
      # `repaint_property` (below) is a body-level macro call, so `Macros` must be
      # in scope here — unlike the `handle` calls, which resolve through the
      # including `Widget` because they sit inside method bodies. Harmless
      # re-include: every includer is already a `Widget`, which includes `Macros`.
      include ::Crysterm::Macros

      # The label drawn after the marker glyph. A marker control renders the
      # composed `<open><mark><close> text` line as its `#content`, so it cannot
      # let `AbstractButton#text` read/write `#content` the way the push buttons
      # do — it keeps the label in its own ivar and `#marker_line` re-composes.
      @text : String = ""

      # :ditto:
      def text : String
        @text
      end

      # :ditto: — a change only needs a repaint; `#render` re-composes the marker
      # line from `@text`.
      repaint_property text, String

      # Sets the checkable base state (`#checkable?`, `#checked?`), the initial
      # `#text` from an explicit `content:`, and wires marker input via
      # `#setup_check_marker`. Call from `initialize`, after `super`; the
      # including widget handles its own extra constructor args around it.
      private def setup_marker_control(checked, content) : Nil
        @checkable = true # a marker control is inherently checkable
        @checked = checked

        # An explicit `content:` is the label for a marker control. `text:` is
        # the preferred spelling and is already applied by the base
        # `initialize`; the two are mutually exclusive at any one call site.
        content.try do |c|
          @text = c
        end

        setup_check_marker
      end

      # Wires the activate keys, focus/blur cursor handling, and the marker-click
      # hit-test. Call from `initialize`, after `super`.
      private def setup_check_marker : Nil
        # `KeyPress` is already wired by the base `initialize`; only the
        # marker-specific handlers are added here.
        handle Crysterm::Event::FocusIn
        handle Crysterm::Event::FocusOut

        # Toggle only when the `[ ]`/`( )` marker itself is clicked, not the text
        # label. Uses `Mouse` (not `Click`) since only it carries coordinates;
        # the marker is the composed-marker cells at the start of the first
        # content row (`@_marker_width` — measured, since CSS can reshape it).
        on(Crysterm::Event::Mouse) do |e|
          next unless e.action.down?
          # Compute the marker cell from the *painted* position (`@lpos`), not
          # the layout coords: inside a scrolled container the two differ by the
          # scroll base, and mouse dispatch hit-tests against `@lpos`.
          next unless origin = painted_content_origin?
          marker_start = origin[0]
          # Row check needed because `Mouse` fires for clicks anywhere in the
          # widget's rect — without it, a taller control (border/explicit
          # height) would toggle on any row at the marker's column.
          marker_row = origin[1]
          if e.y == marker_row && e.x >= marker_start && e.x < marker_start + @_marker_width
            toggle
            request_render
            e.accept
          end
        end
      end

      # Cached last-built line and the inputs it was built from: `marker_line`
      # runs every frame, but the line changes only when a marker piece (check
      # state, CSS glyph, registry/tier retheme) or the label text does, so the
      # `String.build` is memoized against the resolved inputs.
      @_selectable_content : String?
      @_selectable_key : Tuple(String?, String?, String?, Int32, String)?

      # Cells the composed marker occupies and the mark cell's offset within it
      # — the input geometry for the marker click hit-test and the focus cursor.
      # Defaults match the classic 3-cell `[x]`.
      @_marker_width : Int32 = 3
      @_mark_offset : Int32 = 1

      # Builds the composed `<open?><mark?><close?> text` line for a marker
      # control: each piece resolves CSS-first (the widget's `::indicator`
      # sub-style — `glyph-open`/`glyph-close`/the `glyph` family) and falls back
      # to its registry role; a `none` piece is omitted outright, shrinking the
      # marker. The marker is padded (text side) to the max width over
      # *state_roles* — every mark this control can show — so toggling never
      # jitters the label. Memoized: no allocation on repeated identical renders.
      private def marker_line(open_role : Glyphs::Role, close_role : Glyphs::Role,
                              mark_role : Glyphs::Role, *state_roles : Glyphs::Role) : String
        ind = style.raw_sub_style("indicator")
        tier = glyph_tier
        open = marker_piece(ind.try(&.glyph_open), open_role, tier)
        close = marker_piece(ind.try(&.glyph_close), close_role, tier)
        mark = marker_piece(ind.try(&.glyph_for(tier)), mark_role, tier)

        # Stable width: max over every state's mark. The CSS mark (if any) is
        # known only for the *current* state — other states are estimated from
        # the registry, so a state-conditional rule (`::indicator:checked`)
        # that changes the mark's *width* re-measures on toggle.
        base = char_cells(open) + char_cells(close)
        width = base + char_cells(mark)
        state_roles.each do |role|
          w = base + Unicode.width(Glyphs[role, tier])
          width = w if w > width
        end

        key = {open, close, mark, width, @text}
        content = @_selectable_content
        if @_selectable_key != key || content.nil?
          @_selectable_key = key
          @_marker_width = width
          @_mark_offset = char_cells(open)
          pad = width - (base + char_cells(mark))
          content = String.build do |s|
            open.try { |c| s << c }
            mark.try { |c| s << c }
            close.try { |c| s << c }
            pad.times { s << ' ' }
            # The marker-label gap belongs to the marker; a fully `none`-d
            # marker (width 0) leaves the bare label.
            s << ' ' unless width == 0
            s << @text
          end
          @_selectable_content = content
        end
        content
      end

      # One marker piece: the CSS-specified grapheme when present (`none` omits
      # the piece — returns `nil`), else the registry role's glyph. A CSS
      # override may be a multi-codepoint grapheme (an emoji-presentation mark)
      # and is kept whole; the registry fallback stays the narrow single-`Char`
      # default, so the wide form is opt-in via CSS, never forced.
      private def marker_piece(css : String?, role : Glyphs::Role, tier : Glyphs::Tier) : String?
        if s = css
          return if s == Glyphs::NONE_STR
          return s
        end
        Glyphs[role, tier].to_s
      end

      # Columns a piece occupies: 0 when omitted, else its terminal width (a
      # run role may legitimately be 2 cells wide — an emoji indicator).
      private def char_cells(s : String?) : Int32
        s ? Unicode.width(s) : 0
      end

      # The marker controls toggle, rather than push, on activation.
      protected def activate
        toggle
        request_render
      end

      protected def on_focusin(e : ::Crysterm::Event::FocusIn)
        return unless lpos = @lpos
        window?.try do |s|
          s.tput.lsave_cursor hash
          # `+ render_row_offset` keeps the marker cursor in the rendered region
          # for an inline window (no-op at offset 0). The mark cell sits
          # `@_mark_offset` columns in (0 when the open delimiter is `none`-d away).
          s.tput.cursor_pos lpos.yi + itop + s.render_row_offset, lpos.xi + @_mark_offset + ileft
        end
      end

      protected def on_focusout(e : ::Crysterm::Event::FocusOut)
        window?.try do |s|
          s.tput.lrestore_cursor hash, true
        end
      end
    end
  end
end
