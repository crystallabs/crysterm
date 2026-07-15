require "./dialog"

# `SpinBox`, `LineEdit`, `Button` and `DialogButtonBox` resolve through the
# `widget/**` glob; requiring `lineedit` here would fail before the glob has
# loaded its `PlainTextEdit` parent.

module Crysterm
  class Widget
    # Rich modal color picker, modeled after Qt's `QColorDialog`.
    #
    # All editors stay in sync on one HSV state:
    #
    #   * a 2-D **saturation/value field** — a gradient of the current hue;
    #     click or drag to set saturation (X) and value (Y), wheel to nudge value.
    #   * a vertical **hue bar** — click/drag/wheel sets hue.
    #   * a **live preview** swatch.
    #   * editable **R/G/B**, **H/S/V** and **H/S/L** spin-box columns plus an
    #     editable **Hex** field; an edit to any updates all the others.
    #   * a **Basic colors** palette and a row of **Custom colors** slots — the
    #     "+" button stores the current color into the next slot; clicking a
    #     filled slot recalls it.
    #   * a **Pick** button — an eyedropper: the next click anywhere on the
    #     window reads the color under the pointer into the next custom slot.
    #   * an **Ok / Cancel** `DialogButtonBox`.
    #
    # Drag the border, or any empty interior area, to move the dialog.
    #
    # On Ok it emits `Event::Action` (the chosen `"#rrggbb"` hex) and
    # `Event::Accepted`; on Cancel/Escape it emits `Event::Rejected`. Either way
    # it closes through `Dialog#done`. `#pick` delivers the hex (or `nil` when
    # cancelled) to a block, restoring the previously-focused widget.
    #
    # ```
    # dialog = Widget::ColorDialog.new parent: window, top: "center", left: "center",
    #   width: 56, height: 20, style: Style.new(border: true)
    # dialog.pick { |hex| theme.accent = hex if hex }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ColorDialog screenshot](../../tests/widget/color_dialog/color_dialog.5s.apng)
    # <!-- /widget-examples:capture -->
    class ColorDialog < Dialog
      # Inner-area layout (cells, relative to the content origin).
      FIELD_X =  0
      FIELD_Y =  0
      FIELD_W = 24
      FIELD_H = 10
      HUE_X   = FIELD_X + FIELD_W + 1 # 25
      HUE_Y   = 0
      HUE_W   = 2
      HUE_H   = FIELD_H
      INFO_X  = HUE_X + HUE_W + 2 # 29 — origin of the right-hand editor column
      COLOR_W = 3                 # cell width of one palette/custom swatch
      # Right-hand editor rows.
      PREVIEW_Y = 0
      PREVIEW_H = 2
      HEAD_Y    = 3 # column headers ("RGB"/"HSV"/"HSL")
      COLS_Y    = 4 # the three label/field columns (3 rows each)
      COLS_H    = 3
      HEX_Y     = 8           # full-width Hex field, below the columns
      PAL_Y     = FIELD_H + 1 # 11
      CUST_Y    = PAL_Y + 2   # 13
      BTN_Y     = CUST_Y + 2  # 15

      # The "Basic colors" palette (named colors that always resolve as specs).
      DEFAULT_COLORS = %w[
        black red green yellow blue magenta cyan white
        gray brightred brightgreen brightyellow
        brightblue brightmagenta brightcyan brightwhite
      ]

      # The basic palette, in display order.
      getter colors : Array(String)

      # Current color as HSV: hue 0..360, saturation/value 0..1.
      getter hue : Float64 = 0.0
      getter saturation : Float64 = 1.0
      getter value_v : Float64 = 1.0

      @preview : Box?
      @hexbox : LineEdit?
      @rspin : LineEdit?
      @gspin : LineEdit?
      @bspin : LineEdit?
      @hspin : LineEdit?
      @sspin : LineEdit?
      @vspin : LineEdit?
      @lhspin : LineEdit?
      @lsspin : LineEdit?
      @llspin : LineEdit?
      @palette_swatches = [] of Box
      @custom_slots = [] of Box
      # Stored custom-slot colors (`nil` for an empty slot), in slot order.
      getter custom_colors = [] of String?
      @custom_index = 0

      @callback : Proc(String?, Nil)?
      # Guards the editor↔state feedback loop while state is pushed into the
      # fields (their `value=` would otherwise re-enter here).
      @syncing = false

      # Window-move drag. A window-level listener owns the pointer while a move
      # is in flight, so the drag keeps tracking off the dialog. A
      # `Subscription` captures the window it subscribed on, so teardown reaches
      # it even after the dialog detached.
      @ev_move = Crysterm::Subscription.new
      @move_dx = 0
      @move_dy = 0

      # Eyedropper: after the "Pick" button, the next click anywhere reads the
      # color under it into a custom slot. Window-captured like `@ev_move`.
      @ev_pick = Crysterm::Subscription.new
      @picking = false

      # Per-frame draw caches. The field's cell backgrounds depend only on
      # `@hue` (plus the folded style flags), the hue bar's on nothing, so the
      # packed attrs are cached instead of deriving 260 cells per frame. The
      # marker cell is still drawn per frame, keeping output byte-identical.
      @field_attrs = [] of Int64
      @field_attrs_hue : Float64? = nil # `@hue` the field cache was built for
      @field_attrs_flags : Int64? = nil # style flags folded into that cache
      @hue_attrs = [] of Int64
      @hue_attrs_flags : Int64? = nil # style flags folded into the hue cache

      def initialize(colors : Array(String)? = nil, **box)
        @colors = colors || DEFAULT_COLORS
        # One custom slot per basic color, minus the cell taken by the "+"
        # button, so the custom row lines up with the palette above.
        @custom_colors = Array(String?).new(Math.max(@colors.size - 1, 1), nil)

        super **box

        build_children
        on(Crysterm::Event::Mouse) { |e| on_mouse e }
        refresh_ui
      end

      # ------------------------------------------------------------------ API

      # The current color as a `"#rrggbb"` hex string.
      def current_color : String
        r, g, b = Colors.rgb_channels(Colors.hsv_i(@hue, @saturation, @value_v))
        "#%02x%02x%02x" % {r, g, b}
      end

      # Sets the current color from a name or `"#rrggbb"` spec, updating every
      # editor. Invalid specs are ignored (Qt's `setCurrentColor`).
      def current_color=(spec : String) : String
        begin
          rgb = Colors.convert(spec).to_i32
          set_rgb (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff
        rescue
          # Ignore unparseable color specs (e.g. half-typed hex).
        end
        spec
      end

      # Shows the dialog and runs *block* with the chosen hex (or `nil` on
      # cancel). Saves and later restores focus, and installs the modal Enter
      # (accept) / Escape (reject) accelerator.
      def pick(&block : String? -> Nil) : Nil
        @callback = block
        window.save_focus
        @result = Code::Rejected.to_i
        show
        front!
        focus
        install_dialog_keys
        request_render
      end

      # Confirms the current color (Ok / Enter).
      def accept : Nil
        finish current_color
      end

      # Dismisses without choosing (Cancel / Escape).
      def reject : Nil
        finish nil
      end

      # ------------------------------------------------------- construction

      private def build_children
        # The right-hand editor area's width matches the row of basic colors
        # below it, so the preview and editor columns line up with the palette.
        info_w = Math.max(@colors.size * COLOR_W - INFO_X, COLOR_W)

        # Live preview swatch: no border, so the color fills it.
        @preview = Box.new parent: self, top: PREVIEW_Y, left: INFO_X, width: info_w,
          height: PREVIEW_H, style: Style.new(bg: "black")

        # Column headers: same width/gap as the editor columns below, so an
        # `HBox` lands them on the same column fences.
        headers = Box.new parent: self, top: HEAD_Y, left: INFO_X, width: info_w, height: 1,
          layout: Layout::HBox.new(gap: 1)
        {"RGB", "HSV", "HSL"}.each do |name|
          Box.new parent: headers, height: 1, align: :left, content: name
        end

        # Three side-by-side editor columns — RGB, HSV, HSL — each a small
        # `Form` (label column + field), shared evenly by the `HBox`.
        cols = Box.new parent: self, top: COLS_Y, left: INFO_X, width: info_w, height: COLS_H,
          layout: Layout::HBox.new(gap: 1)

        rgbcol = column_box cols
        @rspin = column_spin(rgbcol, "R", 0, 255) { apply_rgb_spins }
        @gspin = column_spin(rgbcol, "G", 0, 255) { apply_rgb_spins }
        @bspin = column_spin(rgbcol, "B", 0, 255) { apply_rgb_spins }

        hsvcol = column_box cols
        @hspin = column_spin(hsvcol, "H", 0, 360) { apply_hsv_spins }
        @sspin = column_spin(hsvcol, "S", 0, 100) { apply_hsv_spins }
        @vspin = column_spin(hsvcol, "V", 0, 100) { apply_hsv_spins }

        hslcol = column_box cols
        @lhspin = column_spin(hslcol, "H", 0, 360) { apply_hsl_spins }
        @lsspin = column_spin(hslcol, "S", 0, 100) { apply_hsl_spins }
        @llspin = column_spin(hslcol, "L", 0, 100) { apply_hsl_spins }

        # Full-width Hex field at the bottom. The editors are *chrome*: no
        # hardcoded color, so they follow the terminal default/theme (only the
        # swatches/preview/gradient use functional color).
        hexrow = Box.new parent: self, top: HEX_Y, left: INFO_X, width: info_w, height: 1,
          layout: Layout::Form.new(label_width: 4, column_gap: 0)
        Box.new parent: hexrow, height: 1, content: "Hex"
        @hexbox = hb = LineEdit.new parent: hexrow, height: 1
        # Applies live on every keystroke and on Enter; the cosmetic leading
        # space is stripped, and `current_color=` ignores half-typed specs.
        hb.on(Crysterm::Event::Submit) { |e| self.current_color = e.value.strip }
        hb.on(Crysterm::Event::TextChanged) do |e|
          next if @syncing
          self.current_color = e.value.strip
        end

        # Basic palette: one click sets the color; a centered marker shows which
        # entry, if any, is current.
        x = 0
        @colors.each do |name|
          sw = Box.new parent: self, top: PAL_Y, left: x, width: COLOR_W, height: 1,
            align: :center, style: Style.new(bg: name)
          sw.on(Crysterm::Event::Click) { self.current_color = name; request_render }
          @palette_swatches << sw
          x += COLOR_W
        end

        # Custom colors: "+" stores the current color; each slot recalls its own.
        # The mark must be an ASCII "+", not the fullwidth "＋": the content
        # layout counts it as one cell, so a wide glyph would shift the whole
        # row one column right and overrun its right edge.
        add = Button.new parent: self, top: CUST_Y, left: 0, width: COLOR_W, height: 1,
          content: "+", align: :center, focus_on_click: false
        add.on(Crysterm::Event::Press) { store_custom }
        # Slots sit flush against the "+" button. Empty ones carry a "·"
        # placeholder so they read as slots before anything is stored.
        cx = COLOR_W
        @custom_colors.each_with_index do |stored, i|
          slot = Box.new parent: self, top: CUST_Y, left: cx, width: COLOR_W, height: 1,
            align: :center, content: "·", style: Style.new
          # Restore any color already stored in this slot (e.g. on reopen).
          if c = stored
            slot.content = ""
            paint_swatch slot, c
          end
          slot.on(Crysterm::Event::Click) do
            @custom_colors[i]?.try { |col| self.current_color = col; request_render }
          end
          @custom_slots << slot
          cx += COLOR_W
        end

        bb = DialogButtonBox.new parent: self, top: BTN_Y, left: 0,
          buttons: DialogButtonBox::StandardButton::Ok | DialogButtonBox::StandardButton::Cancel
        bb.on(Crysterm::Event::Accepted) { accept }
        bb.on(Crysterm::Event::Rejected) { reject }

        pick = Button.new parent: self, top: BTN_Y, left: 20, width: 8, height: 1,
          content: "Pick", align: :center, focus_on_click: false
        pick.tool_tip = "Pick a color from anywhere on the window"
        pick.on(Crysterm::Event::Press) { begin_pick }
      end

      # A `Form`-based editor column: a 1-cell label column plus its field.
      private def column_box(parent : Widget) : Box
        Box.new parent: parent, height: COLS_H, layout: Layout::Form.new(label_width: 1, column_gap: 1)
      end

      # Appends a `"<label> [field]"` row to a `column_box`, returning the
      # editable `LineEdit` field. Applies live on keystroke and on Enter; the
      # wheel nudges the component by ±1, clamped to `min..max`.
      private def column_spin(col : Widget, label : String, min : Int32, max : Int32, &apply : -> Nil) : LineEdit
        Box.new parent: col, height: 1, content: label
        le = LineEdit.new parent: col, height: 1
        le.on(Crysterm::Event::Submit) { apply.call }
        le.on(Crysterm::Event::TextChanged) do
          next if @syncing
          apply.call
        end
        le.on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up? || e.action.wheel_down?
            cur = (le.value.strip.to_i? || 0) + (e.action.wheel_up? ? 1 : -1)
            le.value = cur.clamp(min, max).to_s
            apply.call
            e.accept
            request_render
          end
        end
        le
      end

      # Folds a functional background color onto *box*'s inline style, so it
      # survives the next cascade; the computed `style.bg` alone would be
      # rebuilt away on the next restyle, leaving the swatch blank.
      private def paint_swatch(box : Box, hex : String) : Nil
        box.style.bg = hex
        box.persist_inline_style(&.bg = hex)
      end

      # --------------------------------------------------------- state set

      # Reads an editable component field as an integer, clamped into `min..max`.
      # The field is free text, so a blank/half-typed value reads as 0.
      private def field_int(le : LineEdit?, min : Int32, max : Int32) : Int32
        (le.try(&.value).try(&.strip).try(&.to_i?) || 0).clamp(min, max)
      end

      private def apply_rgb_spins : Nil
        return if @syncing
        set_rgb field_int(@rspin, 0, 255), field_int(@gspin, 0, 255), field_int(@bspin, 0, 255)
      end

      private def apply_hsv_spins : Nil
        return if @syncing
        h = field_int(@hspin, 0, 360).to_f
        s = field_int(@sspin, 0, 100) / 100.0
        v = field_int(@vspin, 0, 100) / 100.0
        set_hsv h, s, v
      end

      private def apply_hsl_spins : Nil
        return if @syncing
        h = field_int(@lhspin, 0, 360).to_f
        s = field_int(@lsspin, 0, 100) / 100.0
        l = field_int(@llspin, 0, 100) / 100.0
        r, g, b = Colors.rgb_channels(Colors.hsl_to_rgb(h, s, l))
        set_rgb r, g, b
      end

      private def set_rgb(r : Int32, g : Int32, b : Int32) : Nil
        @hue, @saturation, @value_v = Colors.rgb_to_hsv(Colors.rgb(r, g, b))
        refresh_ui
      end

      private def set_hsv(h : Float64, s : Float64, v : Float64) : Nil
        @hue = h.clamp(0.0, 360.0)
        @saturation = s.clamp(0.0, 1.0)
        @value_v = v.clamp(0.0, 1.0)
        refresh_ui
      end

      # Stores the current color into the next custom slot (cycling).
      private def store_custom : Nil
        hex = current_color
        @custom_colors[@custom_index] = hex
        if slot = @custom_slots[@custom_index]?
          slot.content = "" # drop the empty-slot placeholder
          paint_swatch slot, hex
        end
        @custom_index = (@custom_index + 1) % @custom_colors.size
        request_render
      end

      # Pushes the current color into every editor (RGB/HSV/HSL/Hex) + the preview.
      private def refresh_ui : Nil
        @syncing = true
        hex = current_color
        r, g, b = Colors.rgb_channels(Colors.hsv_i(@hue, @saturation, @value_v))
        if pv = @preview
          paint_swatch pv, hex
        end
        sync_field @rspin, r.to_s
        sync_field @gspin, g.to_s
        sync_field @bspin, b.to_s
        sync_field @hspin, @hue.round.to_i.to_s
        sync_field @sspin, (@saturation * 100).round.to_i.to_s
        sync_field @vspin, (@value_v * 100).round.to_i.to_s
        lh, ls, ll = Colors.rgb_to_hsl(Colors.rgb(r, g, b))
        sync_field @lhspin, lh.round.to_i.to_s
        sync_field @lsspin, (ls * 100).round.to_i.to_s
        sync_field @llspin, (ll * 100).round.to_i.to_s
        # The Hex field carries a cosmetic leading space before the "#".
        sync_field @hexbox, " #{hex}"
        mark_palette_selection r, g, b
        @syncing = false
        request_render
      end

      # Pushes *value* into editor field *le*, never clobbering a focused field
      # the user is mid-typing into (its own live handler drove this change).
      private def sync_field(le : LineEdit?, value : String) : Nil
        le.value = value if le && !le.focused?
      end

      # Shows a centered marker on the basic-palette swatch, if any, whose color
      # equals the current one.
      private def mark_palette_selection(r : Int32, g : Int32, b : Int32) : Nil
        cur = Colors.rgb(r, g, b)
        @palette_swatches.each_with_index do |sw, i|
          name = @colors[i]?
          next unless name
          selected =
            begin
              (Colors.convert_cached(name) & 0xffffff) == cur
            rescue
              false
            end
          if selected
            sw.style.fg = luminance(cur) > 0.5 ? "black" : "white"
            sw.content = "<"
          else
            sw.content = ""
          end
        end
      end

      # Releases every window-level resource the dialog installed: the
      # accelerator, the eyedropper listener, the modal grab and the saved
      # focus. Every close path must run this, or the window is left with a
      # stale handler or a modal grab held by a dead widget.
      private def release_window_state : Nil
        if @picking
          @picking = false
          @ev_pick.off
          window?.try &.ungrab self
        end
        uninstall_dialog_keys
        window?.try &.restore_focus
      end

      # Teardown outside the accept/cancel path. Discards the callback too, so a
      # stray later key can't fire it on the destroyed dialog.
      def destroy
        end_move
        release_window_state
        @callback = nil
        super
      end

      private def finish(color : String?) : Nil
        hide
        end_move
        release_window_state
        # The chosen value goes out before the outcome, so an `Action` handler
        # sees the color while `Accepted` is still pending.
        emit Crysterm::Event::Action, color if color
        done(color ? Code::Accepted : Code::Rejected)
        cb = @callback
        @callback = nil
        cb.try &.call color
        request_render
      end

      # ------------------------------------------------------------- input

      # Whether a text/number editor currently holds focus (so the modal
      # Enter/Escape shouldn't steal those keys from it).
      private def editing_focused? : Bool
        f = window?.try &.focused
        return false unless f
        f == @hexbox || f == @rspin || f == @gspin || f == @bspin ||
          f == @hspin || f == @sspin || f == @vspin ||
          f == @lhspin || f == @lsspin || f == @llspin
      end

      # The accelerator stands down while a spin/hex field is focused, so a
      # field's own Enter/Escape isn't stolen to accept/cancel the dialog.
      protected def dialog_keys_active?(e : Crysterm::Event::KeyPress) : Bool
        !editing_focused?
      end

      private def on_mouse(e : Crysterm::Event::Mouse) : Nil
        return unless @lpos
        # While a window move or pick is in flight, a window-level listener owns
        # the pointer — don't also treat motion as field/hue input.
        return if @ev_move.active? || @picking
        ox = aleft + ileft
        oy = atop + itop

        in_field = e.x >= ox + FIELD_X && e.x < ox + FIELD_X + FIELD_W &&
                   e.y >= oy + FIELD_Y && e.y < oy + FIELD_Y + FIELD_H
        in_hue = e.x >= ox + HUE_X && e.x < ox + HUE_X + HUE_W &&
                 e.y >= oy + HUE_Y && e.y < oy + HUE_Y + HUE_H

        # The wheel is gated like the press branch: a notch outside the hue strip
        # and 2-D field must fall through unaccepted, so an ancestor scroll can
        # act instead of the color silently changing.
        if e.action.wheel_up?
          if in_hue
            set_hsv(@hue + 10, @saturation, @value_v)
            e.accept
          elsif in_field
            set_hsv(@hue, @saturation, @value_v + 0.05)
            e.accept
          end
        elsif e.action.wheel_down?
          if in_hue
            set_hsv(@hue - 10, @saturation, @value_v)
            e.accept
          elsif in_field
            set_hsv(@hue, @saturation, @value_v - 0.05)
            e.accept
          end
        elsif e.action.down? || (e.action.move? && !e.button.none?)
          if in_field
            s = (e.x - (ox + FIELD_X)) / (FIELD_W - 1).to_f
            v = 1.0 - (e.y - (oy + FIELD_Y)) / (FIELD_H - 1).to_f
            set_hsv @hue, s, v
            e.accept
          elsif in_hue
            h = (e.y - (oy + HUE_Y)) / (HUE_H - 1).to_f * 360.0
            set_hsv h, @saturation, @value_v
            e.accept
          elsif e.action.down?
            # A press on the border or any empty interior area starts moving the
            # whole window.
            begin_move e.x, e.y
            e.accept
          end
        end
        request_render if e.accepted?
      end

      # ----------------------------------------------------- window move

      # Begins a window move: captures the grab offset and takes over the pointer
      # at the window level, so the drag keeps tracking off the dialog.
      private def begin_move(x : Int32, y : Int32) : Nil
        @move_dx = x - aleft(with_margin: false)
        @move_dy = y - atop(with_margin: false)
        return if @ev_move.active?
        w = window? || return
        @ev_move.on(w, Crysterm::Event::Mouse) do |e|
          if e.action.move?
            # `drag_origin` maps the absolute pointer onto parent-content-relative
            # `left`/`top`; `drag_max_left`/`drag_max_top` clamp it in-bounds.
            ox, oy = drag_origin
            self.left = (e.x - @move_dx - ox).clamp(0, drag_max_left)
            self.top = (e.y - @move_dy - oy).clamp(0, drag_max_top)
            e.accept
            request_render
          elsif e.action.up?
            end_move
          end
        end
      end

      private def end_move : Nil
        @ev_move.off
      end

      # ------------------------------------------------- window color pick

      # Arms the eyedropper: the next click anywhere reads the color under it.
      # The modal grab keeps that click from also activating whatever is beneath
      # it; the window-level `Event::Mouse`, emitted before hit-testing, still
      # delivers the coordinates here.
      private def begin_pick : Nil
        return if @picking
        scr = window? || return
        @picking = true
        scr.grab self
        @ev_pick.on(scr, Crysterm::Event::Mouse) do |e|
          next unless e.action.down?
          e.accept
          end_pick e.x, e.y
        end
        request_render
      end

      private def end_pick(x : Int32, y : Int32) : Nil
        return unless @picking
        @picking = false
        @ev_pick.off
        window?.try &.ungrab self
        if hex = screen_color_at x, y
          self.current_color = hex
          store_custom
        end
        request_render
      end

      # The rendered color at window cell *x*,*y* as `"#rrggbb"` — its
      # background, or its foreground when the background is the terminal
      # default; `nil` when neither carries a concrete color.
      private def screen_color_at(x : Int32, y : Int32) : String?
        scr = window? || return nil
        line = scr.lines[y]? || return nil
        cell = line[x]? || return nil
        {Crysterm::Attr.bg(cell.attr), Crysterm::Attr.fg(cell.attr)}.each do |field|
          next if Crysterm::Attr.default? field
          rgb = Crysterm::Attr.unpack_color field
          return "#%06x" % rgb if rgb >= 0
        end
        nil
      end

      # ----------------------------------------------------------- drawing

      def render
        ret = super
        return ret unless ret && window?
        # Style flags are invariant across every cell of the field and hue bar
        # (only fg/bg vary), so they are derived once and folded into the cache.
        flags = Attr.flags sattr(style)
        # The overlays paint at raw absolute coords, so they take the clipped
        # geometry: otherwise they wrap (negative indices) or escape the clip.
        draw_field flags, ret
        draw_hue flags, ret
        ret
      end

      # The field's packed cell attrs, keyed on `{@hue, flags}`: a cell's
      # background is a pure function of the hue and its grid position, so the
      # array only changes when the key does. Rebuilt lazily on a mismatch.
      private def field_attrs(flags : Int64) : Array(Int64)
        if @field_attrs_hue != @hue || @field_attrs_flags != flags
          @field_attrs_hue = @hue
          @field_attrs_flags = flags
          attrs = @field_attrs
          attrs.clear
          (0...FIELD_H).each do |row|
            v = 1.0 - row / (FIELD_H - 1).to_f
            (0...FIELD_W).each do |col|
              s = col / (FIELD_W - 1).to_f
              bg = Colors.hsv_i(@hue, s, v)
              # Unmarked cell: fg == bg.
              attrs << Attr.pack(flags, Attr.pack_color(bg), Attr.pack_color(bg))
            end
          end
        end
        @field_attrs
      end

      # The hue bar's packed cell attrs, keyed on `flags` alone: the bar's colors
      # never change, so this is built once.
      private def hue_attrs(flags : Int64) : Array(Int64)
        if @hue_attrs_flags != flags
          @hue_attrs_flags = flags
          attrs = @hue_attrs
          attrs.clear
          (0...HUE_H).each do |row|
            h = row / (HUE_H - 1).to_f * 360.0
            bg = Colors.hsv_i(h, 1.0, 1.0)
            (0...HUE_W).each do
              attrs << Attr.pack(flags, Attr.pack_color(bg), Attr.pack_color(bg))
            end
          end
        end
        @hue_attrs
      end

      private def draw_field(flags : Int64, clip : RenderedGeometry) : Nil
        ox = aleft + ileft
        oy = atop + itop
        cur_sx = ox + FIELD_X + (@saturation * (FIELD_W - 1)).round.to_i
        cur_sy = oy + FIELD_Y + ((1.0 - @value_v) * (FIELD_H - 1)).round.to_i
        attrs = field_attrs flags

        (0...FIELD_H).each do |row|
          y = oy + FIELD_Y + row
          (0...FIELD_W).each do |col|
            x = ox + FIELD_X + col
            if x == cur_sx && y == cur_sy
              # The lone marker cell needs a contrasting fg; recompute just this
              # one bg (its position tracks saturation/value, not `@hue`).
              v = 1.0 - row / (FIELD_H - 1).to_f
              s = col / (FIELD_W - 1).to_f
              put_cell x, y, '+', Colors.hsv_i(@hue, s, v), true, clip
            else
              put_cell_attr x, y, ' ', attrs[row * FIELD_W + col], clip
            end
          end
        end
      end

      private def draw_hue(flags : Int64, clip : RenderedGeometry) : Nil
        ox = aleft + ileft
        oy = atop + itop
        cur_hy = oy + HUE_Y + (@hue / 360.0 * (HUE_H - 1)).round.to_i
        attrs = hue_attrs flags

        (0...HUE_H).each do |row|
          y = oy + HUE_Y + row
          (0...HUE_W).each do |col|
            x = ox + HUE_X + col
            if y == cur_hy && col == HUE_W - 1
              # Marker: recompute just this row's bg for the contrasting fg.
              h = row / (HUE_H - 1).to_f * 360.0
              put_cell x, y, '<', Colors.hsv_i(h, 1.0, 1.0), true, clip
            else
              put_cell_attr x, y, ' ', attrs[row * HUE_W + col], clip
            end
          end
        end
      end

      # Writes one cell directly into the window buffer. When *marked*, the glyph
      # is drawn in a contrasting fg over the swatch.
      private def put_cell(x : Int32, y : Int32, ch : Char, bg : Int32, marked : Bool, clip : RenderedGeometry) : Nil
        fg = marked ? (luminance(bg) > 0.5 ? 0x000000 : 0xffffff) : bg
        put_cell_attr x, y, ch, sattr(style, fg, bg), clip
      end

      # Writes one cell with an already-packed attr, bypassing per-cell
      # `Colors.hsv_i`/`sattr`. Cells outside the clip (a partially offscreen or
      # parent-clipped dialog) must be dropped: a negative index would wrap to
      # the far side of the screen buffer.
      private def put_cell_attr(x : Int32, y : Int32, ch : Char, attr : Int64, clip : RenderedGeometry) : Nil
        return if x < clip.xi || x >= clip.xl || y < clip.yi || y >= clip.yl
        return if x < 0 || y < 0
        window.lines[y]?.try do |line|
          line[x]?.try do |cell|
            cell.char = ch
            cell.attr = attr
          end
          line.dirty = true
        end
      end

      # ---------------------------------------------------- color helpers

      private def luminance(rgb : Int32) : Float64
        r = ((rgb >> 16) & 0xff) / 255.0
        g = ((rgb >> 8) & 0xff) / 255.0
        b = (rgb & 0xff) / 255.0
        0.299 * r + 0.587 * g + 0.114 * b
      end
    end
  end
end
