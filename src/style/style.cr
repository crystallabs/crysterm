module Crysterm
  # Class for the complete style of a widget.
  class Style
    include Colorizable

    # These (and possibly others) can't default to any color since that would generate
    # color-setting sequences in the terminal. It's better to have them nilable, in which
    # case no sequences get generated and term's default is used. That's also how Blessed
    # does it.

    # Foreground color (color of font/character).
    #
    # Crysterm's native color form is a `0xRRGGBB` integer (`-1` = terminal
    # default, `nil` = "no color set", so no SGR sequence is emitted). The
    # numeric form is canonical and is stored as-is; for backwards compatibility
    # the setter still accepts `"#rrggbb"`/named-color strings, parsing them to
    # the native int via `Colors.convert`.
    getter fg : Int32?

    # Background color (color of cell). See `#fg` for the accepted forms.
    getter bg : Int32?

    # Color setters (`fg=`/`bg=`, accepting Int/String/Nil) come from
    # `Colorizable`.

    # Bold?
    property? bold : Bool = false

    # Italic?
    property? italic : Bool = false

    # Unedline?
    property? underline : Bool = false

    # Blink?
    property? blink : Bool = false

    # Reverse video?
    property? reverse : Bool = false

    # Strikethrough?
    property? strike : Bool = false

    # Visible?
    property? visible : Bool = true

    # Alpha (inverse of transparency). Alpha 0 == full transparency, 1 == full opacity.
    property alpha : Float64?

    # Tint: a color the whole widget region is blended *toward* (a color overlay),
    # by `tint_alpha`. `nil` = no tint. Native `0xRRGGBB`; the setter also accepts
    # `"#rrggbb"`/named-color strings (like `fg`/`bg`). Animate `tint_alpha` (or
    # swap the color) for a tinting fade — see `Widget#tint_to`.
    getter tint : Int32?

    # Strength of the `tint` overlay: `0.0` = none, `1.0` = fully the tint color.
    property tint_alpha : Float64 = 0.5

    # Native numeric tint color (e.g. `tint: 0xff0000`); stored directly.
    def tint=(color : Int)
      @tint = color.to_i32
    end

    # Backwards-compat: a `"#rrggbb"`/named color string, parsed to the native int.
    def tint=(color : String)
      @tint = Colors.convert(color).to_i32
    end

    # Clearing the tint leaves it unset (no overlay applied).
    def tint=(color : Nil)
      @tint = nil
    end

    # Compositing layer (CSS `z-index`). When set, the widget (and its subtree)
    # is promoted to its own `Plane` at this z, composited over the base so it can
    # show content from *other* widgets through it; its `alpha` becomes the
    # plane's opacity. `nil` = the base layer (the ordinary painter's path).
    property z_index : Int32?

    # CSS `transition`: animatable property name -> `{duration, easing}`. When an
    # animated property's value changes (e.g. on a `:hover`/`:focus` state change)
    # the new value is tweened in over its duration rather than snapping. Set by
    # the CSS layer; consumed generically by `Widget#apply_style_transitions`.
    property transitions : Hash(String, Tuple(Time::Span, Animation::Easing))?

    # A CSS `animation` binding: which `@keyframes` to play and how. `nil` = none.
    record AnimationSpec,
      name : String,
      duration : Time::Span,
      easing : Animation::Easing = Animation::Easing::Linear,
      iterations : Int32? = nil, # nil = infinite
      alternate : Bool = false   # ping-pong direction each cycle

    # CSS `animation`: a named `@keyframes` sequence to loop. Set by the CSS layer;
    # driven generically by `Widget#ensure_css_animation`.
    property animation : AnimationSpec?

    # Tracks which text-attribute booleans were *explicitly* set (vs left at
    # their default), so the CSS cascade can tell "set to false" from "unset" —
    # needed for inline-style folding and inheritance. Colors and `alpha` carry
    # their own unset signal (`nil`), so they are not tracked here.
    protected property specified = Set(Symbol).new

    # Whether *property* was explicitly set on this style.
    def specified?(property : Symbol) : Bool
      case property
      when :fg             then !@fg.nil?
      when :bg             then !@bg.nil?
      when :alpha          then !@alpha.nil?
      when :tint           then !@tint.nil?
      when :gridline_color then !@gridline_color.nil?
      when :z_index        then !@z_index.nil?
      when :transition     then !@transitions.nil?
      when :animation      then !@animation.nil?
      else                      @specified.includes?(property)
      end
    end

    # Re-wrap the `property?`-generated boolean setters so each explicit
    # assignment is recorded (`bold = false` becomes distinguishable from the
    # default `false`).
    {% for attr in %w(bold italic underline blink reverse strike visible) %}
      def {{attr.id}}=(value : Bool) : Bool
        @specified << :{{attr.id}}
        @{{attr.id}} = value
      end
    {% end %}

    # A plain shallow `dup` would share the `specified` set and the
    # *mutable* sub-objects (`border`/`padding`/`shadow` are mutated in place by
    # e.g. `border-left`/`padding-top`). Give the copy independent ones so a
    # dup — in particular a cascade base snapshot — can't be corrupted by later
    # in-place edits. (Sub-*styles* like `scrollbar` are replaced, not mutated,
    # so they stay shared here.)
    def dup
      copy = super
      # Give the copy its *own* `specified` set first (so the in-place sub-object
      # copies below can't mutate ours through the shared reference `super` left).
      copy.specified = @specified.dup
      @border.try { |border| copy.border = border.dup }
      copy.padding = @padding.dup
      copy.margin = @margin.dup
      copy.shadow = @shadow.dup
      # Those `border=`/`padding=`/`margin=`/`shadow=` setters also stamp
      # `:border`/`:padding`/`:margin`/`:shadow` into the copy's set; drop any we
      # didn't actually specify (cheap deletes — no second `Set` allocation), so
      # the dup reports exactly what *we* explicitly set, no more.
      copy.specified.delete(:border) unless @specified.includes?(:border)
      copy.specified.delete(:padding) unless @specified.includes?(:padding)
      copy.specified.delete(:margin) unless @specified.includes?(:margin)
      copy.specified.delete(:shadow) unless @specified.includes?(:shadow)
      copy
    end

    # Is any transparency defined?
    #
    # This function is needed because it is not possible to test just for `alpha == nil`.
    # A value of 1.0 (full opacity) also effectively means that no transparency is enabled.
    def alpha?
      @alpha.try do |a|
        return a if a != 1.0
      end
    end

    # The active tint as `{color, alpha}`, or `nil` when no tint color is set or
    # the overlay is fully transparent (`tint_alpha == 0`, i.e. a no-op). Mirrors
    # `#alpha?`: a one-call "is there anything to apply" check for the renderer.
    def tint?
      @tint.try do |c|
        return {c, @tint_alpha} if @tint_alpha != 0.0
      end
    end

    # Length in number of characters to replace TABs with
    property tab_size = 4

    # Character to replace TABs with, multiplied by tab_size
    property tab_char = " "

    # Generic fill char (WIP)
    property fill_char : Char = ' '

    # Percent char (WIP)
    property percent_char : Char = ' '

    # Foreground char (WIP)
    property foreground_char : Char = ' '

    # Background char (WIP)
    property background_char : Char = ' '

    # XXX Test/document this.
    property? fill = true

    # Should something render inside/over the border?
    # Currently used for `Widget::Scrollbar` only.
    # XXX Rename, or make more general, or otherwise unify.
    property? draw_over_border : Bool = false

    # Each of the following subelements are separate and can be styled individually.
    # If any of them is not defined, it defaults to main/parent style.
    # Names of subelements could be improved over time to be more clear.

    # Keep the list sorted alphabetically.

    # Style used for alternating (even) rows when a `Widget::Table` or
    # `Widget::ListTable` has `alternate_rows` enabled — the equivalent of Qt's
    # `QAbstractItemView#alternatingRowColors`. Defaults to `cell` (and thus to
    # the main style), so it has no visible effect until styled.
    setter alternate_row : Style?

    def alternate_row
      @alternate_row || cell
    end

    # Whether a distinct alternate-row sub-style has been set (via
    # `alternate-background-color`, `#alternate_row=`, or `#alternate_background=`),
    # as opposed to the getter falling back to `cell`/`self`.
    def alternate_row?
      !@alternate_row.nil?
    end

    # Sets the background of the alternating-row sub-style (CSS
    # `alternate-background-color`). Works on a *dup* and reassigns, rather than
    # mutating `#alternate_row` in place: until set, `@alternate_row` is `nil` and
    # the getter falls back to `cell`/`self`, and a `dup`'d `Style` shares its
    # sub-styles with the original (see `#dup`) — so an in-place edit would leak
    # into the shared fallback. Only the background is touched, matching Qt's
    # `alternate-background-color`; the foreground is left to fall through.
    def alternate_background=(color) : Nil
      alt = (@alternate_row || Style.new).dup
      alt.bg = color
      @alternate_row = alt
    end

    # Color of a table's internal gridlines (Qt's `gridline-color`). `nil` (the
    # default) means the gridlines follow the box `border` color, as before. When
    # set, it overrides just the gridline foreground; the rest of the border
    # attributes are kept (see `Widget::Table#draw_borders`). Stored as a native
    # `0xRRGGBB` int; the setter also accepts `"#rrggbb"`/named-color strings,
    # mirroring `tint`/`fg`/`bg`.
    getter gridline_color : Int32?

    # :ditto:
    def gridline_color=(color : Int)
      @gridline_color = color.to_i32
    end

    # :ditto:
    def gridline_color=(color : String)
      @gridline_color = Colors.convert(color).to_i32
    end

    # :ditto:
    def gridline_color=(color : Nil)
      @gridline_color = nil
    end

    def border=(value)
      @specified << :border
      @border = Border.from value
    end

    # Border is always a non-nil object. "No border" is represented by a
    # `Border` whose sides are all 0 (see `Border#any?`), which renders nothing
    # and expands the widget by nothing — exactly like the old `nil` did.
    getter border : Border { Border.new 0 }

    setter cell : Style?

    def cell
      @cell || self
    end

    setter header : Style?

    def header
      @header || self
    end

    setter indicator : Style?

    def indicator
      @indicator || self
    end

    setter item : Style?

    def item
      @item || self
    end

    # Style used for the numeric/letter prefix shown before each
    # `Widget::ListBar` command (e.g. the `1` in `1:open`). Defaults to `self`.
    setter prefix : Style?

    def prefix
      @prefix || self
    end

    # Style used for a `Widget::Menu` separator rule (Qt's `QMenu::separator`).
    # Defaults to `self`.
    setter separator : Style?

    def separator
      @separator || self
    end

    # Label value is used only when internally instantiating labels on widgets,
    # to be able to set their: `style: self.style.label`. Since labels are
    # widgets, everything after that is done by looking up `@_label.style....`.
    property label : Style { Style.new }

    # property label : Style? { Style.default.label.not_nil! }
    # property label : Style { self }
    # TODO I am still not sure which of the above options is best.
    # When a decision is made, the same should be applied to all other fields
    # in this class for which it applies.
    # Namely, in the current version, if a user does not specify style, a new
    # one is generated. This requires users to style both the main widget and
    # the label (and all other sub-features) separately.
    # On the other hand, if we use the other (currently commented) implementation,
    # it conveniently defaults to self, so it achieves more results out of the
    # box. However, in many cases, you actually don't want the same style as for
    # self! (For example, if self has border: true, you probably don't want
    # border: true on the label as well!

    def padding=(value)
      @specified << :padding
      @padding = Padding.from value
    end

    getter padding = Padding.default

    # Element's outer spacing. Unlike `padding`/`border` (inner insets), a margin
    # offsets and shrinks the element itself within its allotted slot; see
    # `Margin` and `Widget#_get_coords`.
    def margin=(value)
      @specified << :margin
      @margin = Margin.from value
    end

    # :ditto:
    getter margin = Margin.default

    setter scrollbar : Style?

    def scrollbar
      @scrollbar || self
    end

    # Should element drop shadow?
    def shadow=(value)
      @specified << :shadow
      @shadow = Shadow.from value
    end

    # :ditto:
    getter shadow = Shadow.default

    setter track : Style?

    def track
      @track || self
    end

    # Folds *inline*'s explicitly-set nested sub-styles (`header`/`cell`/
    # `alternate`/`bar`/…) onto this style. Used by the CSS cascade so an inline
    # `@style` that carries a sub-style — e.g. `Style.new(alternate_row: ...)` on a
    # `Widget::Table` — survives recomputation even when no `Widget::slot`
    # sub-element rule matched. Reads the raw nilable ivars (an instance may
    # touch another instance's privates), so only sub-styles the caller actually
    # set are carried (the getters above fall back to `self`/`cell`, which would
    # otherwise always look "set").
    def fold_inline_sub_styles(inline : Style) : Nil
      @alternate_row = inline.@alternate_row if inline.@alternate_row
      @cell = inline.@cell if inline.@cell
      @header = inline.@header if inline.@header
      @indicator = inline.@indicator if inline.@indicator
      @item = inline.@item if inline.@item
      @prefix = inline.@prefix if inline.@prefix
      @separator = inline.@separator if inline.@separator
      @scrollbar = inline.@scrollbar if inline.@scrollbar
      @track = inline.@track if inline.@track
    end

    def initialize(
      *,
      border = nil,
      padding = nil,
      margin = nil,
      shadow = nil,
      @scrollbar = @scrollbar,
      @track = @track,
      @alternate_row = @alternate_row,
      @indicator = @indicator,
      @item = @item,
      @prefix = @prefix,
      @separator = @separator,
      @header = @header,
      @cell = @cell,
      @label = @label,
      fg = nil,
      bg = nil,
      bold = nil,
      italic = nil,
      underline = nil,
      blink = nil,
      reverse = nil,
      strike = nil,
      visible = nil,
      alpha = nil,
      @fill_char = @fill_char,
      @percent_char = @percent_char,
      @foreground_char = @foreground_char,
      @background_char = @background_char,
      @draw_over_border = @draw_over_border,
    )
      # Route fg/bg through the setters so a native `0xRRGGBB` int is normalized
      # to its `#rrggbb` string (the param is unrestricted, so each call type —
      # String, Int, or Nil — resolves to the matching `fg=`/`bg=` overload).
      self.fg = fg
      self.bg = bg
      # Route booleans through their setters too, but only when given, so a
      # constructed value is recorded as `specified` while an omitted one keeps
      # the property default (and stays "unset").
      bold.try { |v| self.bold = v }
      italic.try { |v| self.italic = v }
      underline.try { |v| self.underline = v }
      blink.try { |v| self.blink = v }
      reverse.try { |v| self.reverse = v }
      strike.try { |v| self.strike = v }
      visible.try { |v| self.visible = v }
      alpha.try { |v| self.alpha = self.class.alpha_from(v) }
      border.try { |v| self.border = Border.from(v) }
      padding.try { |v| self.padding = Padding.from(v) }
      margin.try { |v| self.margin = Margin.from(v) }
      shadow.try { |v| self.shadow = Shadow.from(v) }
    end

    def self.alpha_from(value : Float64 | Bool?)
      case value
      in Float
        value
      in true
        0.5
      in false
        1.0
      in nil
        nil
      end
    end
  end
end
