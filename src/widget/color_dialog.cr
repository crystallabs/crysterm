require "./dialog"

# `SpinBox`, `LineEdit`, `Button` and `DialogButtonBox` are referenced only in
# method bodies (resolved after the whole `widget/**` glob is required), so they
# need no explicit `require` here — requiring `lineedit` directly would fail
# since it relies on the glob having loaded its `PlainTextEdit` parent first.

module Crysterm
  class Widget
    # Rich modal color picker, modeled after Qt's `QColorDialog` / the KDE color
    # dialog.
    #
    # All editors stay in sync on one HSV state:
    #
    #   * a 2-D **saturation/value field** — a gradient of the current hue;
    #     click or drag anywhere in it to set saturation (X) and value (Y); the
    #     wheel nudges the value.
    #   * a vertical **hue bar** — the full spectrum; click/drag/wheel sets hue.
    #   * a **live preview** swatch.
    #   * editable **R/G/B**, **H/S/V** and **H/S/L** spin-box columns (type or
    #     wheel to set a component precisely) plus an editable **Hex** field; an
    #     edit to any field updates all the others and the preview immediately.
    #   * a **Basic colors** palette and a row of **Custom colors** slots — the
    #     "+" button stores the current color into the next slot; clicking a
    #     filled slot recalls it.
    #   * a **Pick** button — an eyedropper: after pressing it, the next click
    #     anywhere on the window reads the color under the pointer into the next
    #     custom slot (and makes it current).
    #   * an **Ok / Cancel** `DialogButtonBox`.
    #
    # The dialog is a **movable window**: drag its border (or any empty interior
    # area) to reposition it; the gradient field and hue bar keep their own
    # click/drag behavior.
    #
    # On Ok it emits `Event::Action` (carrying the chosen `"#rrggbb"` hex) and
    # `Event::Accepted`; on Cancel/Escape it emits `Event::Rejected`. The
    # convenience `#pick` form also delivers the hex (or `nil` when cancelled) to
    # a block, restoring the previously-focused widget.
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
      # Right-hand editor rows. A blank row separates the preview from the
      # columns, and another separates the columns from the Hex field.
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
      # Guards the editor<->state feedback loop while we push state into the
      # spin boxes / hex field (their `value=` would otherwise re-enter here).
      @syncing = false

      # Window-move (drag the border/empty area to reposition the dialog). While
      # a move is in flight, a window-level listener owns the pointer so the drag
      # keeps tracking even off the dialog.
      # A `Subscription` (not a bare wrapper) so teardown removes from the exact
      # window it subscribed on, even if the dialog detached meanwhile.
      @ev_move = Crysterm::Subscription.new
      @move_dx = 0
      @move_dy = 0

      # Window color pick ("eyedropper"): after the "Pick" button, the next click
      # anywhere reads the color under it into a custom slot. Same captured-target
      # `Subscription` as `@ev_move` — `#end_pick` and `#release_window_state`
      # both tear it down, and each formerly used `window?`, which could differ
      # from the `scr` it subscribed on.
      @ev_pick = Crysterm::Subscription.new
      @picking = false

      def initialize(colors : Array(String)? = nil, **box)
        @colors = colors || DEFAULT_COLORS
        # One custom slot per basic color, minus its first cell (taken by the
        # "＋" button) — so the custom row lines up with the palette above (e.g.
        # 16 colors -> "＋" plus 15 slots).
        @custom_colors = Array(String?).new(Math.max(@colors.size - 1, 1), nil)

        super **box

        build_children
        # Clicks/drags/wheel over the gradient field and hue bar (the child
        # widgets handle their own mouse input).
        on(Crysterm::Event::Mouse) { |e| on_mouse e }
        refresh_ui
      end

      # ------------------------------------------------------------------ API

      # The current color as a `"#rrggbb"` hex string.
      def current_color : String
        r, g, b = hsv_to_rgb @hue, @saturation, @value_v
        "#%02x%02x%02x" % {r, g, b}
      end

      # Sets the current color from a name or `"#rrggbb"` spec, updating every
      # editor. Invalid specs are ignored.
      def set_color(spec : String) : Nil
        rgb = Colors.convert(spec).to_i32
        set_rgb (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff
      rescue
        # Ignore unparseable color specs (e.g. half-typed hex).
      end

      # Shows the dialog and runs *block* with the chosen hex (or `nil` on
      # cancel). Saves and later restores focus, and installs the modal Enter
      # (accept) / Escape (cancel) handler.
      def pick(&block : String? -> Nil) : Nil
        @callback = block
        window.save_focus
        show
        front!
        focus
        # The `Dialog` base owns the window-level Enter/Escape accelerator.
        install_dialog_keys
        request_render
      end

      # Confirms the current color (Ok / Enter).
      def accept : Nil
        finish current_color
      end

      # Dismisses without choosing (Cancel / Escape).
      def cancel : Nil
        finish nil
      end

      # ------------------------------------------------------- construction

      private def build_children
        # The right-hand editor area's width matches the row of basic colors
        # below it, so the preview and editor columns line up with the palette.
        info_w = Math.max(@colors.size * COLOR_W - INFO_X, COLOR_W)

        # A solid swatch (no border, so the color fills it) that tracks the
        # current color live — see `refresh_ui`.
        @preview = Box.new parent: self, top: PREVIEW_Y, left: INFO_X, width: info_w,
          height: PREVIEW_H, style: Style.new(bg: "black")

        # Column headers, laid out by an `HBox` so they sit over the three editor
        # columns below (same width/gap => same column fences).
        headers = Box.new parent: self, top: HEAD_Y, left: INFO_X, width: info_w, height: 1,
          layout: Layout::HBox.new(gap: 1)
        {"RGB", "HSV", "HSL"}.each do |name|
          Box.new parent: headers, height: 1, align: :left, content: name
        end

        # Three side-by-side editor columns — RGB, HSV, HSL — each a small
        # `Form` (label column + field) so the toolkit places the label/field
        # rows. The `HBox` shares the width evenly between the columns.
        cols = Box.new parent: self, top: COLS_Y, left: INFO_X, width: info_w, height: COLS_H,
          layout: Layout::HBox.new(gap: 1)

        # Every field applies immediately like the Hex field, keeping all color
        # spaces in sync (`refresh_ui`). R/G/B edits drive the state directly;
        # H/S/V and H/S/L go through their color space. The apply path is wired
        # per field inside `column_spin` (live on keystroke / Enter / wheel).
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

        # Hex field at the bottom, spanning the full width (a `Form` "Hex  […]").
        # The editors are *chrome*: no hardcoded color, so they follow the
        # terminal default/theme (only the swatches/preview/gradient below use
        # functional color).
        hexrow = Box.new parent: self, top: HEX_Y, left: INFO_X, width: info_w, height: 1,
          layout: Layout::Form.new(label_width: 4, gap: 0)
        Box.new parent: hexrow, height: 1, content: "Hex"
        @hexbox = hb = LineEdit.new parent: hexrow, height: 1
        # Apply live on every keystroke (`TextChange`) and on Enter (`Submit`);
        # strip the cosmetic leading space first. Invalid/half-typed specs are
        # ignored by `set_color`.
        hb.on(Crysterm::Event::Submit) { |e| set_color e.value.strip }
        hb.on(Crysterm::Event::TextChange) do |e|
          next if @syncing
          set_color e.value.strip
        end

        # Basic palette: one click sets the color. A centered marker (drawn by
        # `mark_palette_selection`) shows which entry, if any, is current.
        x = 0
        @colors.each do |name|
          sw = Box.new parent: self, top: PAL_Y, left: x, width: COLOR_W, height: 1,
            align: :center, style: Style.new(bg: name)
          sw.on(Crysterm::Event::Click) { set_color name; request_render }
          @palette_swatches << sw
          x += COLOR_W
        end

        # Custom colors: "+" stores the current color; each slot recalls its own.
        # Use an ASCII "+" (one cell), not the fullwidth "＋" (two cells) — the
        # content layout treats it as a single cell, so a wide glyph would push
        # everything after it one column right and overrun the row's right edge.
        add = Button.new parent: self, top: CUST_Y, left: 0, width: COLOR_W, height: 1,
          content: "+", align: :center, focus_on_click: false
        add.on(Crysterm::Event::Press) { store_custom }
        # Slots sit flush against the "＋" button (no gap). Empty ones carry a "·"
        # placeholder so they read as slots before anything is stored. Painted
        # color is folded onto the slot's *inline* style (`#paint_swatch`) so it
        # survives a re-cascade — otherwise a reopened picker shows
        # occupied-but-blank slots (state agrees via `@custom_colors`, but the
        # cascade wiped the computed `style.bg`).
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
            @custom_colors[i]?.try { |col| set_color col; request_render }
          end
          @custom_slots << slot
          cx += COLOR_W
        end

        bb = DialogButtonBox.new parent: self, top: BTN_Y, left: 0,
          buttons: DialogButtonBox::StandardButton::Ok | DialogButtonBox::StandardButton::Cancel
        bb.on(Crysterm::Event::Accepted) { accept }
        bb.on(Crysterm::Event::Rejected) { cancel }

        # Eyedropper: arm a window-wide color pick (see `begin_pick`).
        pick = Button.new parent: self, top: BTN_Y, left: 20, width: 8, height: 1,
          content: "Pick", align: :center, focus_on_click: false
        pick.tool_tip = "Pick a color from anywhere on the window"
        pick.on(Crysterm::Event::Press) { begin_pick }
      end

      # A `Form`-based editor column (a 1-cell label column + its field), shared
      # by the RGB/HSV/HSL columns.
      private def column_box(parent : Widget) : Box
        Box.new parent: parent, height: COLS_H, layout: Layout::Form.new(label_width: 1, gap: 1)
      end

      # Appends a `"<label> [field]"` row to a `column_box`, returning the editable
      # `LineEdit` field. Behaves like the Hex field: applies live on keystroke
      # (`TextChange`) and on Enter (`Submit`). The mouse wheel nudges this one
      # component by ±1 (clamped to `min..max`) and re-applies the same way.
      private def column_spin(col : Widget, label : String, min : Int32, max : Int32, &apply : -> Nil) : LineEdit
        Box.new parent: col, height: 1, content: label
        le = LineEdit.new parent: col, height: 1
        le.on(Crysterm::Event::Submit) { apply.call }
        le.on(Crysterm::Event::TextChange) do
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

      # Folds a functional background color onto *box*'s inline style so it shows
      # now and survives the next cascade (cf. `Widget#set_visible`). Mutating
      # only the computed `style.bg` would be rebuilt away on the next restyle.
      private def paint_swatch(box : Box, hex : String) : Nil
        box.style.bg = hex
        box.persist_inline_style(&.bg = hex)
      end

      # --------------------------------------------------------- state set

      # Reads an editable component field as an integer, clamped into `min..max`.
      # The field is free text, so a blank/half-typed value reads as the minimum
      # of the range (0 for every component here).
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
        r, g, b = hsl_to_rgb h, s, l
        set_rgb r, g, b
      end

      private def set_rgb(r : Int32, g : Int32, b : Int32) : Nil
        @hue, @saturation, @value_v = rgb_to_hsv r, g, b
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
        r, g, b = hsv_to_rgb @hue, @saturation, @value_v
        # Fold onto the preview's inline style so the swatch survives a
        # re-cascade (same reason `#paint_swatch` exists for the custom slots).
        if pv = @preview
          paint_swatch pv, hex
        end
        sync_field @rspin, r.to_s
        sync_field @gspin, g.to_s
        sync_field @bspin, b.to_s
        sync_field @hspin, @hue.round.to_i.to_s
        sync_field @sspin, (@saturation * 100).round.to_i.to_s
        sync_field @vspin, (@value_v * 100).round.to_i.to_s
        lh, ls, ll = rgb_to_hsl r, g, b
        sync_field @lhspin, lh.round.to_i.to_s
        sync_field @lsspin, (ls * 100).round.to_i.to_s
        sync_field @llspin, (ll * 100).round.to_i.to_s
        # The Hex field carries a cosmetic leading space before the "#".
        sync_field @hexbox, " #{hex}"
        mark_palette_selection r, g, b
        @syncing = false
        request_render
      end

      # Pushes *value* into editor field *le*, unless it is `nil` or currently
      # focused — never clobbers a field the user is mid-typing into, since the
      # live `TextChange` handler already drove the change that got us here.
      private def sync_field(le : LineEdit?, value : String) : Nil
        le.value = value if le && !le.focused?
      end

      # Shows a centered marker on the basic-palette swatch (if any) whose color
      # equals the current one, so the selection is visible there too — like the
      # "<" on the hue bar.
      private def mark_palette_selection(r : Int32, g : Int32, b : Int32) : Nil
        cur = (r << 16) | (g << 8) | b
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

      # Releases every window-level resource `#pick`/`#begin_pick` installed —
      # the accelerator, the eyedropper `Event::Mouse` listener, the modal grab
      # and the saved focus. Shared by `#finish` (the Ok/Cancel/Escape path) and
      # `#destroy` (host tears the dialog down without either), so neither leaks
      # a handler onto the window or leaves it modally grabbed to a dead widget.
      private def release_window_state : Nil
        if @picking
          @picking = false
          @ev_pick.off
          window?.try &.ungrab self
        end
        uninstall_dialog_keys
        window?.try &.restore_focus
      end

      # Released outside the accept/cancel path: drop the listeners, grab and
      # saved focus, and discard the callback so a stray later key can't fire it
      # on the destroyed dialog.
      def destroy
        # Drop any in-flight window move / eyedropper before releasing.
        end_move
        release_window_state
        @callback = nil
        super
      end

      private def finish(color : String?) : Nil
        hide
        # Drop any in-flight window move / eyedropper before closing.
        end_move
        release_window_state
        if color
          emit Crysterm::Event::Action, color
          emit Crysterm::Event::Accepted
        else
          emit Crysterm::Event::Rejected
        end
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

      # The `Dialog` accelerator stands down while a spin/hex field is focused, so
      # a field's own Enter/Escape isn't stolen to accept/cancel the dialog.
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

        if e.action.wheel_up?
          in_hue ? set_hsv(@hue + 10, @saturation, @value_v) : set_hsv(@hue, @saturation, @value_v + 0.05)
          e.accept
        elsif e.action.wheel_down?
          in_hue ? set_hsv(@hue - 10, @saturation, @value_v) : set_hsv(@hue, @saturation, @value_v - 0.05)
          e.accept
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

      # Begins a window move: capture the grab offset and take over the pointer
      # at the window level so the drag keeps tracking even off the dialog.
      private def begin_move(x : Int32, y : Int32) : Nil
        @move_dx = x - aleft
        @move_dy = y - atop
        return if @ev_move.active?
        w = window? || return
        @ev_move.on(w, Crysterm::Event::Mouse) do |e|
          if e.action.move?
            self.left = (e.x - @move_dx).clamp(0, drag_max_left)
            self.top = (e.y - @move_dy).clamp(0, drag_max_top)
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
      # A modal grab keeps that click from also activating whatever is beneath
      # it, while the window-level `Event::Mouse` (emitted before hit-testing)
      # still delivers the coordinates here.
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
          set_color hex
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
        draw_field
        draw_hue
        ret
      end

      private def draw_field : Nil
        ox = aleft + ileft
        oy = atop + itop
        cur_sx = ox + FIELD_X + (@saturation * (FIELD_W - 1)).round.to_i
        cur_sy = oy + FIELD_Y + ((1.0 - @value_v) * (FIELD_H - 1)).round.to_i

        (0...FIELD_H).each do |row|
          v = 1.0 - row / (FIELD_H - 1).to_f
          y = oy + FIELD_Y + row
          (0...FIELD_W).each do |col|
            s = col / (FIELD_W - 1).to_f
            r, g, b = hsv_to_rgb @hue, s, v
            x = ox + FIELD_X + col
            marker = (x == cur_sx && y == cur_sy)
            put_cell x, y, (marker ? '+' : ' '), (r << 16) | (g << 8) | b, marker
          end
        end
      end

      private def draw_hue : Nil
        ox = aleft + ileft
        oy = atop + itop
        cur_hy = oy + HUE_Y + (@hue / 360.0 * (HUE_H - 1)).round.to_i

        (0...HUE_H).each do |row|
          h = row / (HUE_H - 1).to_f * 360.0
          r, g, b = hsv_to_rgb h, 1.0, 1.0
          y = oy + HUE_Y + row
          (0...HUE_W).each do |col|
            x = ox + HUE_X + col
            marker = (y == cur_hy && col == HUE_W - 1)
            put_cell x, y, (marker ? '<' : ' '), (r << 16) | (g << 8) | b, marker
          end
        end
      end

      # Writes one cell directly into the window buffer (cf. `Slider#render`).
      # When *marked*, the glyph is drawn in a contrasting fg over the swatch.
      private def put_cell(x : Int32, y : Int32, ch : Char, bg : Int32, marked : Bool) : Nil
        fg = marked ? (luminance(bg) > 0.5 ? 0x000000 : 0xffffff) : bg
        attr = sattr style, fg, bg
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

      # Maps a hue angle to its RGB sextant, scaled by chroma *c* and offset *m*
      # — the shared tail of `hsv_to_rgb`/`hsl_to_rgb` (which differ only in how
      # they derive *c*/*m* from value vs lightness).
      private def hue_chroma_to_rgb(h : Float64, c : Float64, m : Float64) : {Int32, Int32, Int32}
        h = h % 360.0
        h += 360.0 if h < 0
        x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs)
        r1, g1, b1 =
          case h
          when .< 60.0  then {c, x, 0.0}
          when .< 120.0 then {x, c, 0.0}
          when .< 180.0 then {0.0, c, x}
          when .< 240.0 then {0.0, x, c}
          when .< 300.0 then {x, 0.0, c}
          else               {c, 0.0, x}
          end
        {((r1 + m) * 255).round.to_i, ((g1 + m) * 255).round.to_i, ((b1 + m) * 255).round.to_i}
      end

      # Normalized channels and the common hue angle (0..360) — shared head of
      # `rgb_to_hsv`/`rgb_to_hsl` (which finish with their own saturation and
      # third axis, value vs lightness). Returns `{hue, max, min, delta}`.
      private def rgb_components(r : Int32, g : Int32, b : Int32) : {Float64, Float64, Float64, Float64}
        rf = r / 255.0
        gf = g / 255.0
        bf = b / 255.0
        max = {rf, gf, bf}.max
        min = {rf, gf, bf}.min
        delta = max - min

        h =
          if delta == 0.0
            0.0
          elsif max == rf
            60.0 * (((gf - bf) / delta) % 6.0)
          elsif max == gf
            60.0 * (((bf - rf) / delta) + 2.0)
          else
            60.0 * (((rf - gf) / delta) + 4.0)
          end
        h += 360.0 if h < 0
        {h, max, min, delta}
      end

      # HSV (h 0..360, s/v 0..1) → RGB (each 0..255).
      private def hsv_to_rgb(h : Float64, s : Float64, v : Float64) : {Int32, Int32, Int32}
        c = v * s
        hue_chroma_to_rgb h, c, v - c
      end

      # RGB (each 0..255) → HSV (h 0..360, s/v 0..1).
      private def rgb_to_hsv(r : Int32, g : Int32, b : Int32) : {Float64, Float64, Float64}
        h, max, _, delta = rgb_components r, g, b
        s = max == 0.0 ? 0.0 : delta / max
        {h, s, max}
      end

      # HSL (h 0..360, s/l 0..1) → RGB (each 0..255). Shares HSV's hue but uses
      # lightness (mid-point) and its own saturation.
      private def hsl_to_rgb(h : Float64, s : Float64, l : Float64) : {Int32, Int32, Int32}
        c = (1.0 - (2.0 * l - 1.0).abs) * s
        hue_chroma_to_rgb h, c, l - c / 2.0
      end

      # RGB (each 0..255) → HSL (h 0..360, s/l 0..1).
      private def rgb_to_hsl(r : Int32, g : Int32, b : Int32) : {Float64, Float64, Float64}
        h, max, min, delta = rgb_components r, g, b
        l = (max + min) / 2.0
        denom = 1.0 - (2.0 * l - 1.0).abs
        s = denom == 0.0 ? 0.0 : delta / denom
        {h, s, l}
      end
    end
  end
end
