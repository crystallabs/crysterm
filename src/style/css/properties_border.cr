module Crysterm
  module CSS
    # The `border*` property family of `Properties`, reopened here: the
    # `apply_border` dispatch `Properties.apply` hands every `border*`
    # declaration to, plus its helpers — the per-side/shorthand appliers,
    # the width/type/char resolvers and `parse_border`. The shared parsing
    # helpers these lean on (`with_color`, `with_cell_char`, `parse_char`,
    # `trbl_indices`, ...) live in `properties.cr`.
    module Properties
      # Applies any `border*` property. Per-side colors and widths are honored
      # individually (`border-top-color`/`border-left-width` & co.); the border
      # *type* is a single whole-border value. The `border-color` shorthand
      # recolors every side, so it also clears any per-side color override.
      #
      private def self.apply_border(style : Style, property : String, value : String) : Nil
        border = style.border
        # `currentColor` in a border color is the element's text color (`color`
        # / `Style#fg`), per CSS — not the border's own existing color. Threaded
        # as the basis into every border-color resolution below; unused for a
        # concrete value (hex/named/`rgb()`/…).
        el_color = style.fg
        case property
        when "border"
          style.border = parse_border(value, el_color)
        when "border-width"
          apply_border_width border, value
        when "border-color"
          apply_border_color border, value, el_color
        when "border-top-color"    then apply_side_color border, Side::Top, value, el_color
        when "border-right-color"  then apply_side_color border, Side::Right, value, el_color
        when "border-bottom-color" then apply_side_color border, Side::Bottom, value, el_color
        when "border-left-color"   then apply_side_color border, Side::Left, value, el_color
        when "border-style"
          apply_border_style border, value, {Side::Left, Side::Top, Side::Right, Side::Bottom}
        when "border-top"          then apply_border_side border, Side::Top, value, el_color
        when "border-right"        then apply_border_side border, Side::Right, value, el_color
        when "border-bottom"       then apply_border_side border, Side::Bottom, value, el_color
        when "border-left"         then apply_border_side border, Side::Left, value, el_color
        when "border-top-width"    then border_cells?(value, vertical: true).try { |c| border.top = c }
        when "border-right-width"  then border_cells?(value).try { |c| border.right = c }
        when "border-bottom-width" then border_cells?(value, vertical: true).try { |c| border.bottom = c }
        when "border-left-width"   then border_cells?(value).try { |c| border.left = c }
        when "border-top-style"    then apply_border_style border, value, {Side::Top}
        when "border-right-style"  then apply_border_style border, value, {Side::Right}
        when "border-bottom-style" then apply_border_style border, value, {Side::Bottom}
        when "border-left-style"   then apply_border_style border, value, {Side::Left}
        when "border-radius"       then apply_border_radius border, value
        when "border-ratio"        then apply_border_ratio border, value
        when "border-chars"        then apply_border_chars border, value
        when .ends_with?("-char")  then apply_border_char_longhand border, property, value
        else
          # Unknown border-* property: ignore.
        end
      end

      # `border-<position>-char` longhand → the position it names. The whole
      # family is pure data, so one table beats a `when` arm per position.
      BORDER_CHAR_POSITIONS = {
        "top-left"     => Border::CharPosition::TopLeft,
        "top-right"    => Border::CharPosition::TopRight,
        "bottom-left"  => Border::CharPosition::BottomLeft,
        "bottom-right" => Border::CharPosition::BottomRight,
        "top"          => Border::CharPosition::Top,
        "right"        => Border::CharPosition::Right,
        "bottom"       => Border::CharPosition::Bottom,
        "left"         => Border::CharPosition::Left,
        "horizontal"   => Border::CharPosition::Horizontal,
        "vertical"     => Border::CharPosition::Vertical,
        "corner"       => Border::CharPosition::Corner,
      }

      # Applies a `border-<position>-char` longhand, looking *property*'s middle
      # segment up in `BORDER_CHAR_POSITIONS` (`border-top-left-char` → the
      # 8 chars between the `border-` prefix and the `-char` suffix). An
      # unknown position is an unknown property: ignored.
      private def self.apply_border_char_longhand(border : Border, property : String, value : String) : Nil
        position = BORDER_CHAR_POSITIONS[property["border-".size..-("-char".size + 1)]]?
        apply_border_char border, position, value if position
      end

      # The CSS `border-radius` shorthand, mapped honestly onto the cell grid:
      # a terminal can't render partial curves, so any positive radius turns a
      # light `Solid` border's corners into the arc family
      # (`BorderType::Rounded`, `╭╮╰╯`), and an explicit zero turns a
      # `Rounded` border back to square corners. Other families (`Double`/
      # `Dashed`/`Dotted`/`Fill`) are left alone — the author picked a stronger
      # corner statement than "slightly rounded". Qt themes' ubiquitous
      # `border-radius: 4px` thus rounds frames for free. Order note: the
      # `border` shorthand *replaces* the whole `Border`, so declare the
      # radius after it (as Qt themes conventionally do); an unparseable or
      # blank value is dropped.
      private def self.apply_border_radius(border : Border, value : String) : Nil
        v = value.strip
        return if v.empty?
        # First numeric component of the (possibly multi-value, unit-suffixed)
        # shorthand: `4px`, `0.5em 1em`, `50%` — any positive number rounds.
        return unless m = v.match(/-?\d+(?:\.\d+)?/)
        return unless r = m[0].to_f?
        if r > 0
          border.type = BorderType::Rounded if border.type.solid?
        else
          border.type = BorderType::Solid if border.type.rounded?
        end
      end

      # A `border-<position>-char` longhand: sets one border char override.
      # `none` clears the override back to the type's normal
      # glyph source (registry family / `fill_char`); an unparseable value —
      # or one that isn't exactly one column (a border cell must be) — is
      # dropped, per CSS's invalid-declaration rule.
      private def self.apply_border_char(border : Border, position : Border::CharPosition, value : String) : Nil
        with_cell_char(value) { |c| border.set_char position, c }
      end

      # The `border-chars` shorthand: six chars in
      # `tl tr bl br h v` order (`border-chars: "╭" "╮" "╰" "╯" "─" "│"`),
      # three for the `corner h v` groups, or one for everything. Each token
      # follows `apply_border_char`'s rules (`none` clears a position); a
      # declaration with an unparseable/wide token or another count is
      # dropped whole.
      private def self.apply_border_chars(border : Border, value : String) : Nil
        return if value.blank?
        tokens = Selectors.split_top_level(value)
        chars = tokens.map { |token| parse_char(token) }
        return if chars.any?(Nil)
        resolved = chars.map { |c| c == Glyphs::NONE ? nil : c }
        return if resolved.any? { |c| c && Unicode.width(c) != 1 }
        case resolved.size
        when 6
          border.set_char Border::CharPosition::TopLeft, resolved[0]
          border.set_char Border::CharPosition::TopRight, resolved[1]
          border.set_char Border::CharPosition::BottomLeft, resolved[2]
          border.set_char Border::CharPosition::BottomRight, resolved[3]
          border.set_char Border::CharPosition::Horizontal, resolved[4]
          border.set_char Border::CharPosition::Vertical, resolved[5]
        when 3 # corner group, horizontal runs, vertical runs
          border.set_char Border::CharPosition::Corner, resolved[0]
          border.set_char Border::CharPosition::Horizontal, resolved[1]
          border.set_char Border::CharPosition::Vertical, resolved[2]
        when 1 # one char everywhere
          border.set_char Border::CharPosition::Corner, resolved[0]
          border.set_char Border::CharPosition::Horizontal, resolved[0]
          border.set_char Border::CharPosition::Vertical, resolved[0]
        end
      end

      # Coerces a resolved color (`Int32`, a named/hex `String`, or `nil`) to the
      # native `0xRRGGBB` int the per-side `border-*-color` slots store (the
      # whole-border `border-color` keeps the string form via `Colorizable`).
      private def self.coerce_color_int(resolved : Int32 | String?) : Int32?
        Colors.to_native resolved
      end

      # Whether a resolved per-side border color is valid to store, shared by
      # every border-color path (the multi-token `border-color` shorthand, the
      # `border-<side>-color` longhand, and the `border-<side>` shorthand's color
      # fallback). Valid: a `currentColor` marker (*cur*, its slot resolves at
      # render time), a concrete `Int32` (including `transparent`'s genuine `-1`),
      # or a named/hex `String` that `Colors.convert_cached` recognizes. Invalid:
      # a non-`currentColor` `nil` (a malformed color function, or `inherit`/
      # `initial`/`unset`) or an unknown color name (the `-1` sentinel) — the
      # caller drops the token/declaration, per CSS, rather than storing a bogus
      # color that paints the side terminal-default or clobbers a prior color.
      private def self.valid_side_color?(resolved : Int32 | String?, cur : Bool) : Bool
        return true if cur
        case resolved
        when Int32  then true
        when String then Colors.known?(resolved)
        else             false
        end
      end

      # Applies the `border-color` shorthand: 1-4 colors in CSS TRBL order
      # (`border-color: <top> <right> <bottom> <left>`), with the standard CSS
      # fill-ins (1 value → whole border; 2 → vertical/horizontal; 3 → top/
      # horizontal/bottom). A single color recolors the whole border and clears
      # any per-side override (`border-top-color` & co.) — the renderer reads
      # `top_fg = @top_fg || @fg`, so a stale `@top_fg` would otherwise shadow the
      # new whole-border `@fg`. Two-to-four colors set the per-side
      # `top_fg`/`right_fg`/… slots directly, the analog of the multi-value
      # `border-width` shorthand (`apply_border_width`).
      #
      # Tokens are split with `Selectors.split_top_level` so a color function's internal
      # spaces/commas (`rgb(255, 0, 0)`) stay one token (a plain split would break
      # them apart and resolve to the `-1` "unknown" sentinel, dropping all
      # colors). A blank value or one with more than four colors is dropped.
      private def self.apply_border_color(border : Border, value : String, el_color : Int32?) : Nil
        return if value.blank?
        tokens = Selectors.split_top_level(value)
        if tokens.size == 1
          # Whole-border recolor: keep the resolved form (`Int32`/`String`) via
          # `Colorizable`, and clear any per-side override so it can't shadow it.
          # A `currentColor` keyword additionally sets the render-time marker
          # (see `Border#side_fg`) — and a concrete color clears it.
          cur = current_color_token?(value.strip)
          with_color(value, el_color) do |c|
            border.fg = c
            border.top_fg = border.right_fg = border.bottom_fg = border.left_fg = nil
            border.fg_current_color = cur
            border.clear_side_current_colors
          end
          return
        end
        return unless i = trbl_indices(tokens.size) # 0 (blank) / >4 colors: drop it
        # Resolve each token to the native per-side int form (`currentColor`
        # against the element's text color, like the per-side longhands) before
        # assigning any of them: an invalid token — `nil` (a malformed color
        # function, or `inherit`/`initial`/`unset`, neither of which is a valid
        # per-side token in a value list) or a `String` that fails
        # `Colors.convert_cached` (an unknown color name, the `-1` sentinel) —
        # makes the whole declaration invalid and must not touch the border, the
        # same drop-the-invalid-declaration rule `with_color` and `parse_border`
        # already implement. A genuine `transparent` resolves to the `Int32` -1
        # sentinel and stays valid, distinguishable from the unknown-name case.
        c = tokens.map { |token| ColorValue.resolve(token, el_color) }
        # A `currentColor` token is valid even when no text color is known yet
        # (its slot resolves at render time via the marker), so exempt it from
        # the nil check.
        curs = tokens.map { |token| current_color_token? token }
        return if c.each_with_index.any? { |r, j| !valid_side_color?(r, curs[j]) }
        c = c.map { |r| coerce_color_int(r) }
        border.top_fg = c[i[:top]]
        border.right_fg = c[i[:right]]
        border.bottom_fg = c[i[:bottom]]
        border.left_fg = c[i[:left]]
        border.top_fg_current_color = curs[i[:top]]
        border.right_fg_current_color = curs[i[:right]]
        border.bottom_fg_current_color = curs[i[:bottom]]
        border.left_fg_current_color = curs[i[:left]]
      end

      # Whether *token* is the CSS `currentColor` keyword (case-insensitive).
      private def self.current_color_token?(token : String) : Bool
        Case.fold_keyword(token) == "currentcolor"
      end

      # Maps a CSS `border-style` keyword to a `BorderType`, or `nil` if the
      # token isn't a style keyword (a width, color, or `none`). `solid`/`line`
      # both mean the light line border; `bg`/`background` the fill-char border;
      # `dashed`/`dotted`/`double` their respective glyph sets; `rounded` (or
      # `round` — no standard CSS spelling exists) the arc-corner family.
      private def self.border_type_keyword(token : String) : BorderType?
        case Case.fold_keyword(token)
        when "solid", "line"                      then BorderType::Solid
        when "dashed"                             then BorderType::Dashed
        when "dotted"                             then BorderType::Dotted
        when "double"                             then BorderType::Double
        when "rounded", "round"                   then BorderType::Rounded
        when "outer", "block"                     then BorderType::Outer
        when "inner"                              then BorderType::Inner
        when "bg", "background"                   then BorderType::Fill
        when "inset", "outset", "groove", "ridge" then BorderType::Solid
        end
      end

      # Maps the four CSS 3D `border-style` keywords to a `Border::Relief`; the
      # flat styles (and any non-style token) yield `nil`. Paired with
      # `border_type_keyword` above, which resolves all four to a `Solid` line —
      # the relief is carried by the per-side shading, not by a different glyph
      # set. A flat style keyword clears any relief a previous rule set, so
      # `border-style: solid` really is flat.
      private def self.border_relief_keyword(token : String) : Border::Relief?
        case Case.fold_keyword(token)
        when "inset"  then Border::Relief::Inset
        when "outset" then Border::Relief::Outset
        when "groove" then Border::Relief::Groove
        when "ridge"  then Border::Relief::Ridge
        when "solid", "line", "dashed", "dotted",
             "double", "rounded", "round",
             "outer", "block", "inner",
             "bg", "background" then Border::Relief::None
        end
      end

      # The `border-ratio` property (a crysterm extension, no CSS analog): a
      # block-family border's ink thickness as a fraction of the cell width —
      # a number in (0, 1] (`0.375`), a percentage (`50%`), or a named preset
      # (`thin`/`quarter`/`half`/`full`, see `Glyphs::BLOCK_RATIOS`). An
      # out-of-range or unparseable value is an invalid declaration and is
      # dropped, per CSS.
      private def self.apply_border_ratio(border : Border, value : String) : Nil
        v = value.strip
        return if v.empty?
        if preset = Glyphs::BLOCK_RATIOS[Case.fold_keyword(v)]?
          border.ratio = preset
          return
        end
        f = v.ends_with?("%") ? v.rchop.to_f?.try { |p| p / 100 } : v.to_f?
        return unless f
        border.ratio = f if 0 < f <= 1
      end

      # Whether *token* is a CSS `border-style` keyword that means "draw no
      # border". CSS distinguishes `none` from `hidden` only for border-collapse
      # conflict resolution in tables, which has no analog here, so both simply
      # zero the side.
      private def self.border_none_keyword?(token : String) : Bool
        k = Case.fold_keyword(token)
        k == "none" || k == "hidden"
      end

      # A single-side `border-<side>` shorthand: a width sets that side, a style
      # keyword sets the border type (or hides the side with `none`), and any
      # other token is the color for that side — routed to the per-side
      # `border-<side>-color` slot (`top_fg`/`left_fg`/…), not the whole-border
      # `fg`. So `border-left: solid red` colors only the left edge, matching CSS.
      # *el_color* is the element's text color, the basis for `currentColor`
      # (see `apply_border`).
      private def self.apply_border_side(border : Border, side : Side, value : String, el_color : Int32?) : Nil
        vertical = side.top? || side.bottom?
        # A width token (if any) is authoritative for the side; a bare style
        # keyword only ensures visibility when no width was given. A width is
        # honored at its rounded cell count (`0.04em`/`1px` → 0, `1.5em` → 2), so
        # a sub-cell hairline collapses to no border instead of being forced to a
        # full-cell box by an accompanying `solid`. (Unlike the `border-width`
        # longhand, a shorthand width is not clamped up.)
        explicit_width = nil
        type_seen = false
        # Split on top-level whitespace only, so a color function's internal
        # spaces/commas (`rgb(30, 30, 46)`) stay one token — same tokenizing as
        # `parse_border`/`apply_border_color`. A plain `value.split` would break a
        # multi-token color into fragments that each resolve to the `-1` "unknown"
        # sentinel, mis-setting the per-side color.
        Selectors.split_top_level(value).each do |token|
          if border_none_keyword?(token)
            explicit_width = 0
          elsif type = border_type_keyword(token)
            border.type = type
            # A style keyword also settles the relief: the 3D ones switch it on,
            # the flat ones clear whatever a previous rule left.
            border_relief_keyword(token).try { |r| border.relief = r }
            type_seen = true
          elsif nw = named_width(token)
            # Named width (`thin`/`medium`/`thick`) before the color fallback, so
            # `border-left: thin solid red` sets a 1-cell edge, not a bogus color.
            explicit_width = nw
          elsif w = border_cells?(token, vertical)
            # Same resolver as the `border-<side>-width` longhand, so the two
            # spellings can't disagree: a sub-cell hairline resolves to no
            # border, as does an explicit `0` or a negative (a `-1`, a calc()
            # below zero — invalid CSS, and stored it would outset the content
            # rect past the widget box).
            explicit_width = w
          else
            # Only store a valid color; an unknown name (`-1` sentinel) or a
            # malformed-function/unset `nil` leaves the existing per-side color
            # and marker untouched, per CSS (mirrors the multi-token shorthand).
            cur = current_color_token?(token)
            resolved = ColorValue.resolve(token, el_color)
            store_side_color border, side, resolved, cur if valid_side_color?(resolved, cur)
          end
        end
        if explicit_width
          set_side border, side, explicit_width
        elsif type_seen
          ensure_side border, side
        end
      end

      # A `border-<side>-color` longhand: resolves *value* (dropping a blank or
      # malformed color, per `with_color`) and routes it to that side's per-side
      # color slot via `set_side_color` — the same per-side dispatch the
      # `border-<side>` shorthand uses, rather than four inline copies.
      private def self.apply_side_color(border : Border, side : Side, value : String, el_color : Int32?) : Nil
        cur = current_color_token?(value.strip)
        with_color(value, el_color) do |c|
          # `with_color` already drops a blank/malformed-function value; also
          # reject an unknown color name (`-1` sentinel) here, keeping the side's
          # prior color, while a genuine `transparent` (`Int32` -1) stays valid.
          next unless valid_side_color?(c, cur)
          store_side_color border, side, c, cur
        end
      end

      # Stores an already-validated per-side border color plus its `currentColor`
      # marker — the two-line tail shared by the `border-<side>` shorthand and the
      # `border-<side>-color` longhand.
      private def self.store_side_color(border : Border, side : Side, resolved, cur) : Nil
        set_side_color border, side, resolved
        border.set_current_color side, cur
      end

      # Sets the per-side border color (`top_fg`/`right_fg`/`bottom_fg`/`left_fg`)
      # for the `border-<side>` shorthand and the `border-<side>-color` longhand
      # (via `apply_side_color`), coercing the resolved color to the native int
      # form those slots store.
      private def self.set_side_color(border : Border, side : Side, resolved : Int32 | String?) : Nil
        border.set_color side, coerce_color_int(resolved)
      end

      # Applies the `border-width` shorthand: 1-4 cell widths in CSS TRBL order
      # (`border-width: <top> <right> <bottom> <left>`), with the standard CSS
      # fill-ins (1 value → all sides; 2 → vertical/horizontal; 3 → top/horizontal/
      # bottom). Each side resolves through `border_cells` (same per-axis scaling
      # as `border-top-width`/`border-bottom-width`), and a sub-cell width clamps
      # up to 1 so a declared border stays visible — e.g. `border-width: 0 0 1px 0`
      # gives a 1-cell bottom edge only.
      #
      # A blank value or one with more than four widths is invalid CSS and
      # dropped, leaving the border unchanged (mirrors `parse_sides`).
      private def self.apply_border_width(border : Border, value : String) : Nil
        # Split on top-level whitespace only, so a `calc(...)` width whose
        # internal `+`/`-` carry required spaces (`calc(2em + 1px)`) stays one
        # token — same tokenizing as the `border-color`/`border-<side>` shorthands.
        tokens = Selectors.split_top_level(value)
        # Every token must be a real length or named width. A token that isn't
        # (a typo'd named width like `thinn`, or a partially-collapsed `var()`)
        # resolves `nil` via `border_cells?` — drop the whole declaration per CSS
        # rather than zeroing the affected sides and hiding edges a lower-priority
        # rule set. (nil-ness is axis-independent, so one axis suffices.) A blank
        # value yields no tokens and falls through to the `trbl_indices(0)` drop.
        return if tokens.any? { |token| border_cells?(token).nil? }
        # A cell is taller than wide, so horizontal (left/right) and vertical
        # (top/bottom) axes resolve absolute units differently — resolve each
        # token on both axes and pick the right one per side.
        h = tokens.map { |token| border_cells(token) }
        v = tokens.map { |token| border_cells(token, vertical: true) }
        # 0 (blank/invalid) or >4 widths: invalid declaration, drop it. Top/bottom
        # read the vertical-axis cells, left/right the horizontal-axis cells.
        return unless i = trbl_indices(tokens.size)
        border.top = v[i[:top]]
        border.right = h[i[:right]]
        border.bottom = v[i[:bottom]]
        border.left = h[i[:left]]
      end

      # Applies a `border-style` keyword to the given *sides*: `none` hides them,
      # any line/fill keyword (`solid`/`line`/`dashed`/`dotted`/`double`/`bg`)
      # sets the type and enables the sides.
      private def self.apply_border_style(border : Border, value : String, sides : Tuple) : Nil
        # CSS `border-style` accepts 1–4 space-separated keywords (TRBL). `Border#type`
        # is whole-border (no per-side type), so honor the *first* token rather
        # than folding the whole multi-value string and matching nothing.
        first = value.strip.split.first?
        return unless first
        if border_none_keyword?(first)
          sides.each { |side| set_side border, side, 0 }
        elsif type = border_type_keyword(first)
          border.type = type
          border_relief_keyword(first).try { |r| border.relief = r }
          sides.each { |side| ensure_side border, side }
        end
      end

      private def self.set_side(border : Border, side : Side, width : Int32) : Nil
        border.set_width side, width
      end

      # Ensures a side has at least width 1 (so a `solid` style makes it visible).
      private def self.ensure_side(border : Border, side : Side) : Nil
        set_side border, side, 1 if border.width_of(side) == 0
      end

      # Maps a CSS named border width (`thin`/`medium`/`thick`) to a cell count,
      # or `nil` for any other token. Per CSS `thin < medium < thick`; in the
      # terminal cell model `thin`/`medium` both round to a single-cell line and
      # `thick` to two. Checked before the length/color parsing in the `border`
      # shorthand and the width resolvers, so these keywords aren't mistaken for
      # a color (`border: thin solid red` would otherwise set the border color to
      # the unknown-name `-1` sentinel or, in the shorthand, drop the width to 0).
      private def self.named_width(token : String) : Int32?
        case Case.fold_keyword(token.strip)
        when "thin", "medium" then 1
        when "thick"          then 2
        end
      end

      # The single border-width resolver: every spelling — the `border` and
      # `border-<side>` shorthands, the `border-width` shorthand and the four
      # `border-<side>-width` longhands — goes through it, so they cannot
      # disagree about what a given length means.
      #
      # A width rounds honestly to whole cells, and a positive *sub*-cell
      # hairline therefore resolves to **no border**. That is deliberate: a cell
      # grid has no way to draw thinner than one cell, and one cell is
      # proportionally enormous next to the ~20px-tall widget a desktop QSS theme
      # was written for. Clamping `1px` up boxes every label and button in a Qt
      # theme and breaks the layout; dropping it renders the hairline as the
      # nothing a terminal can honestly show. Widths that survive are the ones
      # stated in cell-scale terms: a bare count, `thin`/`medium`/`thick`, or a
      # length that genuinely reaches a cell.
      #
      # A border width is almost always a bare number or one unit'd length, so
      # resolve the fractional cells in one pass (`to_cells_f`). Only a rare
      # `calc()` border falls back to `to_cells`.
      private def self.border_cells(value : String, vertical : Bool = false) : Int32
        border_cells?(value, vertical) || 0
      end

      # Nilable variant of `border_cells`: returns `nil` when the value is not a
      # length or named width *at all* (a blank/collapsed `var(--x)` or a typo
      # like `thinn`), so a caller can drop the invalid declaration rather than
      # hard-resetting the side to 0 — matching every sibling longhand
      # (`padding-left`, `tab-size`, `border-top-style`). A genuine `0`, negative,
      # or sub-cell length still resolves to a real cell count (all three: 0).
      private def self.border_cells?(value : String, vertical : Bool = false) : Int32?
        if nw = named_width(value)
          return nw
        end
        if frac = Length.to_cells_f(value, vertical)
          cells = Length.to_cell_count(frac)
          return cells > 0 ? cells : 0 # sub-cell hairline / 0 / negative → no border
        end
        c = Length.to_cells(value, vertical) # a `calc()` border still resolves here
        return unless c                      # nothing parsed → invalid declaration, dropped by caller
        c > 0 ? c : 0
      end

      # Parses a `border` shorthand. Recognizes a width (cells), a style keyword
      # (`solid`/`line` -> line border, `bg` -> background border, `none` -> no
      # border), and otherwise treats a token as a color — resolved through
      # `ColorValue` exactly like the `border-color` longhand, so `currentColor`
      # and color functions (`rgb()`/`hsl()`/gradients) work here too. Tokens are
      # split with `Selectors.split_top_level` so a function's internal spaces/commas
      # (`rgb(255, 0, 0)`) stay one token.
      private def self.parse_border(value : String, el_color : Int32? = nil) : Border
        return Border.new(0) if border_none_keyword?(value.strip)
        border = Border.new # default: line border, 1 cell on each side
        # A `none`/`hidden` style keyword wins over any width in the same
        # shorthand whatever the order (`border: hidden 2px red` draws nothing,
        # exactly like `border: 2px hidden red`), so it is applied after the
        # token loop rather than inside it.
        hidden = false
        Selectors.split_top_level(value).each do |token|
          if border_none_keyword?(token)
            hidden = true
          elsif type = border_type_keyword(token)
            border.type = type
            border_relief_keyword(token).try { |r| border.relief = r }
          elsif nw = named_width(token)
            # A named width (`thin`/`medium`/`thick`) sizes all four sides; must
            # be checked before the color fallback so it isn't treated as an
            # unknown color name.
            border.left = border.right = border.top = border.bottom = nw
          elsif w = border_cells?(token)
            # One width for all four sides, through the same resolver as the
            # `border-width` longhands (top/bottom scale absolute units
            # differently), so a QSS theme's ubiquitous `border: 1px solid`
            # means the same thing here as spelled any other way: a sub-cell
            # hairline, and therefore no border.
            border.left = border.right = w
            border.top = border.bottom = border_cells?(token, vertical: true) || w
          else
            # Whole-border color: keep the resolved form (`Int32`/`String`) via
            # `Colorizable`. A `nil` (`inherit`/`initial`/`currentColor` with no
            # text color) is dropped so it doesn't clobber the color with "unset".
            # A named/hex string that `Colors.convert` can't recognize collapses
            # to the `-1` sentinel (a stray keyword — e.g. a misspelled width);
            # drop it too rather than storing a bogus border color. `transparent`
            # resolves to a genuine `Int32` `-1` and is kept.
            cur = current_color_token?(token)
            resolved = ColorValue.resolve(token, el_color)
            border.fg = resolved if valid_side_color?(resolved, cur)
            # `currentColor` re-resolves against the element's final text color
            # at render time (see `Border#side_fg`), even when none is known yet.
            border.fg_current_color = true if cur
          end
        end
        border.left = border.right = border.top = border.bottom = 0 if hidden
        border
      end
    end
  end
end
