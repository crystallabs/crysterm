require "./box"

# `SpinBox`, `TextBox`, `Button` and `DialogButtonBox` are referenced only in
# method bodies (resolved after the whole `widget/**` glob is required), so they
# need no explicit `require` here — and requiring `textbox` directly would fail,
# since it relies on the glob to have loaded its `TextArea` parent first.

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
    #   * an editable **Hex** field plus editable **R/G/B** and **H/S/V** spin
    #     boxes (type or wheel to set a component precisely).
    #   * a **Basic colors** palette and a row of **Custom colors** slots — the
    #     "＋" button stores the current color into the next slot; clicking a
    #     filled slot recalls it.
    #   * an **Ok / Cancel** `DialogButtonBox`.
    #
    # On Ok it emits `Event::Action` (carrying the chosen `"#rrggbb"` hex) and
    # `Event::Accepted`; on Cancel/Escape it emits `Event::Rejected`. The
    # convenience `#pick` form also delivers the hex (or `nil` when cancelled) to
    # a block, restoring the previously-focused widget.
    #
    # ```
    # dialog = Widget::ColorDialog.new parent: screen, top: "center", left: "center",
    #   width: 56, height: 20, style: Style.new(border: true)
    # dialog.pick { |hex| theme.accent = hex if hex }
    # ```
    class ColorDialog < Box
      # Inner-area layout (cells, relative to the content origin).
      FIELD_X  =  0
      FIELD_Y  =  0
      FIELD_W  = 24
      FIELD_H  = 10
      HUE_X    = FIELD_X + FIELD_W + 1 # 25
      HUE_Y    = 0
      HUE_W    = 2
      HUE_H    = FIELD_H
      INFO_X   = HUE_X + HUE_W + 2 # 29
      SPIN_X   = INFO_X + 2        # value column for the labeled spin boxes
      SPIN_W   = 13
      PAL_Y    = FIELD_H + 1 # 11
      CUST_Y   = PAL_Y + 2   # 13
      BTN_Y    = CUST_Y + 2  # 15
      CUSTOM_N = 8           # number of custom-color slots

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
      @hexbox : TextBox?
      @rspin : SpinBox?
      @gspin : SpinBox?
      @bspin : SpinBox?
      @hspin : SpinBox?
      @sspin : SpinBox?
      @vspin : SpinBox?
      @custom_slots = [] of Box
      @custom_colors = [] of String?
      @custom_index = 0

      @callback : Proc(String?, Nil)?
      @ev_keys : Crysterm::Event::KeyPress::Wrapper?
      # Guards the editor<->state feedback loop while we push state into the
      # spin boxes / hex field (their `value=` would otherwise re-enter here).
      @syncing = false

      def initialize(colors : Array(String)? = nil, **box)
        @colors = colors || DEFAULT_COLORS
        @custom_colors = Array(String?).new(CUSTOM_N, nil)

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
        screen.save_focus
        show
        front!
        focus
        @ev_keys ||= screen.on(Crysterm::Event::KeyPress) { |e| on_key e }
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
        @preview = Box.new parent: self, top: 0, left: INFO_X, width: SPIN_W + 2, height: 2,
          style: Style.new(border: true)

        Box.new parent: self, top: 2, left: INFO_X, width: 3, height: 1, content: "Hex"
        @hexbox = hb = TextBox.new parent: self, top: 2, left: SPIN_X + 1, width: SPIN_W - 1, height: 1,
          style: Style.new(fg: "white", bg: "#303030")
        hb.on(Crysterm::Event::Submit) { |e| set_color e.value }

        @rspin = labeled_spin "R", 3, 0, 255
        @gspin = labeled_spin "G", 4, 0, 255
        @bspin = labeled_spin "B", 5, 0, 255
        @hspin = labeled_spin "H", 6, 0, 360
        @sspin = labeled_spin "S", 7, 0, 100
        @vspin = labeled_spin "V", 8, 0, 100

        # R/G/B edits drive the state directly; H/S/V edits go through HSV.
        {@rspin, @gspin, @bspin}.each do |sp|
          next unless sp
          sp.on(Crysterm::Event::ValueChange) { apply_rgb_spins }
        end
        {@hspin, @sspin, @vspin}.each do |sp|
          next unless sp
          sp.on(Crysterm::Event::ValueChange) { apply_hsv_spins }
        end

        # Basic palette: one click sets the color.
        x = 0
        @colors.each do |name|
          sw = Box.new parent: self, top: PAL_Y, left: x, width: 3, height: 1,
            style: Style.new(bg: name)
          sw.on(Crysterm::Event::Click) { set_color name; request_render }
          x += 3
        end

        # Custom colors: "＋" stores the current color; each slot recalls its own.
        add = Button.new parent: self, top: CUST_Y, left: 0, width: 3, height: 1,
          content: "＋", align: :center, focus_on_click: false,
          style: Style.new(fg: "white", bg: "#404040")
        add.on(Crysterm::Event::Press) { store_custom }
        cx = 4
        CUSTOM_N.times do |i|
          slot = Box.new parent: self, top: CUST_Y, left: cx, width: 3, height: 1,
            style: Style.new(bg: "#202020")
          slot.on(Crysterm::Event::Click) do
            @custom_colors[i]?.try { |c| set_color c; request_render }
          end
          @custom_slots << slot
          cx += 3
        end

        bb = DialogButtonBox.new parent: self, top: BTN_Y, left: 0,
          buttons: DialogButtonBox::StandardButton::Ok | DialogButtonBox::StandardButton::Cancel
        bb.on(Crysterm::Event::Accepted) { accept }
        bb.on(Crysterm::Event::Rejected) { cancel }
      end

      # A `"<label> [spin]"` row at *row*, returning the spin box.
      private def labeled_spin(label : String, row : Int32, min : Int32, max : Int32) : SpinBox
        Box.new parent: self, top: row, left: INFO_X, width: 2, height: 1, content: label
        SpinBox.new parent: self, top: row, left: SPIN_X, width: SPIN_W, height: 1,
          minimum: min, maximum: max, value: min,
          style: Style.new(fg: "white", bg: "#303030")
      end

      # --------------------------------------------------------- state set

      private def apply_rgb_spins : Nil
        return if @syncing
        set_rgb (@rspin.try(&.value) || 0), (@gspin.try(&.value) || 0), (@bspin.try(&.value) || 0)
      end

      private def apply_hsv_spins : Nil
        return if @syncing
        h = (@hspin.try(&.value) || 0).to_f
        s = (@sspin.try(&.value) || 0) / 100.0
        v = (@vspin.try(&.value) || 0) / 100.0
        set_hsv h, s, v
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
          slot.style.bg = hex
        end
        @custom_index = (@custom_index + 1) % CUSTOM_N
        request_render
      end

      # Pushes the HSV state into every editor + the preview.
      private def refresh_ui : Nil
        @syncing = true
        hex = current_color
        r, g, b = hsv_to_rgb @hue, @saturation, @value_v
        if pv = @preview
          pv.style.bg = hex
        end
        if sp = @rspin
          sp.value = r
        end
        if sp = @gspin
          sp.value = g
        end
        if sp = @bspin
          sp.value = b
        end
        if sp = @hspin
          sp.value = @hue.round.to_i
        end
        if sp = @sspin
          sp.value = (@saturation * 100).round.to_i
        end
        if sp = @vspin
          sp.value = (@value_v * 100).round.to_i
        end
        if hb = @hexbox
          hb.value = hex
        end
        @syncing = false
        request_render
      end

      private def finish(color : String?) : Nil
        hide
        @ev_keys.try { |w| screen?.try &.off Crysterm::Event::KeyPress, w }
        @ev_keys = nil
        screen?.try &.restore_focus
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

      # Whether one of the text/number editors currently holds focus (so the
      # modal Enter/Escape shouldn't steal those keys from it).
      private def editing_focused? : Bool
        f = screen?.try &.focused
        return false unless f
        f == @hexbox || f == @rspin || f == @gspin || f == @bspin ||
          f == @hspin || f == @sspin || f == @vspin
      end

      private def on_key(e : Crysterm::Event::KeyPress) : Nil
        return if editing_focused?
        case e.key
        when Tput::Key::Enter  then accept; e.accept
        when Tput::Key::Escape then cancel; e.accept
        end
        request_render if e.accepted?
      end

      private def on_mouse(e : Crysterm::Event::Mouse) : Nil
        return unless @lpos
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
          end
        end
        request_render if e.accepted?
      end

      # ----------------------------------------------------------- drawing

      def render
        ret = super
        return ret unless ret && screen?
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

      # Writes one cell directly into the screen buffer (cf. `Slider#render`).
      # When *marked*, the glyph is drawn in a contrasting fg over the swatch.
      private def put_cell(x : Int32, y : Int32, ch : Char, bg : Int32, marked : Bool) : Nil
        fg = marked ? (luminance(bg) > 0.5 ? 0x000000 : 0xffffff) : bg
        attr = sattr style, fg, bg
        screen.lines[y]?.try do |line|
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

      # HSV (h 0..360, s/v 0..1) → RGB (each 0..255).
      private def hsv_to_rgb(h : Float64, s : Float64, v : Float64) : {Int32, Int32, Int32}
        h = h % 360.0
        h += 360.0 if h < 0
        c = v * s
        x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs)
        m = v - c
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

      # RGB (each 0..255) → HSV (h 0..360, s/v 0..1).
      private def rgb_to_hsv(r : Int32, g : Int32, b : Int32) : {Float64, Float64, Float64}
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
        s = max == 0.0 ? 0.0 : delta / max
        {h, s, max}
      end
    end
  end
end
