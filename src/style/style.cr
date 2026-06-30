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

    # Tint color setters (Int/String/Nil, like `fg`/`bg`); see
    # `Colorizable.color_setter`. Native `tint: 0xff0000` is stored directly, a
    # `"#rrggbb"`/named string is parsed, and `nil` clears it (no overlay).
    Colorizable.color_setter tint

    # Compositing layer (CSS `z-index`). When set, the widget (and its subtree)
    # is promoted to its own `Plane` at this z, composited over the base so it can
    # show content from *other* widgets through it; its `alpha` becomes the
    # plane's opacity. `nil` = the base layer (the ordinary painter's path).
    property z_index : Int32?

    # How a `background_image` is scaled to fill the widget box.
    enum BackgroundSize
      Cover   # fill the box, preserve aspect, crop overflow (default)
      Contain # fit entirely inside the box, preserve aspect, letterbox remainder
      Stretch # stretch to fill exactly, ignoring aspect (CSS `100% 100%`)
      Auto    # natural size, no scaling (CSS default `auto`)
    end

    # CSS `background-image`: the `url(...)` path/URL of an image painted *behind*
    # the widget's own content. `nil` = none. Realized lazily as an internal
    # `Widget::Media` background layer (see `Widget#update_background_media`); the
    # backend is chosen by `Media.resolve(Content::Background)` and so only has a
    # visible effect where a background-capable backend is available (Kitty for
    # true pixels under the text, or the cell-grid `Glyph`/`Ansi` fallback).
    property background_image : String?

    # CSS `background-size`: how `background_image` fills the box. Default `Cover`
    # (rather than the strict CSS `auto`) — the most useful default for a widget
    # backdrop. Explicit assignment is tracked so the cascade folds it.
    getter background_size : BackgroundSize = BackgroundSize::Cover

    def background_size=(value : BackgroundSize) : BackgroundSize
      @specified_mask |= SPEC_BACKGROUND_SIZE
      @background_size = value
    end

    # CSS `transition`: animatable property name -> `{duration, easing}`. When an
    # animated property's value changes (e.g. on a `:hover`/`:focus` state change)
    # the new value is tweened in over its duration rather than snapping. Set by
    # the CSS layer; consumed generically by `Widget#apply_style_transitions`.
    property transitions : Hash(String, Tuple(Time::Span, Easing))?

    # A CSS `animation` binding: which `@keyframes` to play and how. `nil` = none.
    record AnimationSpec,
      name : String,
      duration : Time::Span,
      easing : Easing = Easing::Linear,
      iterations : Int32? = nil, # nil = infinite
      alternate : Bool = false   # ping-pong direction each cycle

    # CSS `animation`: a named `@keyframes` sequence to loop. Set by the CSS layer;
    # driven generically by `Widget#ensure_css_animation`.
    property animation : AnimationSpec?

    # Tracks which text-attribute booleans (and the struct properties) were
    # *explicitly* set (vs left at their default), so the CSS cascade can tell
    # "set to false" from "unset" — needed for inline-style folding and
    # inheritance. Colors and `alpha` carry their own unset signal (`nil`), so
    # they are not tracked here.
    #
    # Stored as a bitmask rather than a `Set(Symbol)`: the cascade resets every
    # recomputed widget with a `#dup` per state per cascade (hundreds–thousands
    # per frame on a deep tree), and a `Set` made each `#dup` allocate a fresh
    # heap object. A `UInt32` is copied for free by the shallow `super` dup, so
    # the reset path allocates nothing here, and the per-property checks become
    # bit tests instead of hashed-set lookups.
    protected property specified_mask : UInt32 = 0_u32

    # Bit per tracked property. Order is arbitrary but must stay stable within a
    # build (the mask is never persisted across builds).
    {% begin %}
      {% tracked = %w(bold italic underline blink reverse strike visible
           background_size fill_char percent_char foreground_char
           background_char border padding margin shadow
           tab_size tab_char fill draw_over_border) %}
      {% for prop, i in tracked %}
        SPEC_{{prop.upcase.id}} = 1_u32 << {{i}}
      {% end %}

      # The mask bit for a tracked property symbol (`0` if untracked — those use
      # a `nil` unset signal and are answered directly in `#specified?`).
      private def specified_bit(property : Symbol) : UInt32
        case property
        {% for prop in tracked %}
        when :{{prop.id}} then SPEC_{{prop.upcase.id}}
        {% end %}
        else 0_u32
        end
      end
    {% end %}

    # Whether *property* was explicitly set on this style.
    def specified?(property : Symbol) : Bool
      case property
      when :fg               then !@fg.nil?
      when :bg               then !@bg.nil?
      when :alpha            then !@alpha.nil?
      when :tint             then !@tint.nil?
      when :gridline_color   then !@gridline_color.nil?
      when :z_index          then !@z_index.nil?
      when :background_image then !@background_image.nil?
      when :transition       then !@transitions.nil?
      when :animation        then !@animation.nil?
      else                        (@specified_mask & specified_bit(property)) != 0_u32
      end
    end

    # Re-wrap the `property?`-generated boolean setters so each explicit
    # assignment is recorded (`bold = false` becomes distinguishable from the
    # default `false`).
    {% for attr in %w(bold italic underline blink reverse strike visible) %}
      def {{attr.id}}=(value : Bool) : Bool
        @specified_mask |= SPEC_{{attr.upcase.id}}
        @{{attr.id}} = value
      end
    {% end %}

    # A plain shallow `dup` would share the *mutable* sub-objects
    # (`border`/`padding`/`shadow` are mutated in place by e.g.
    # `border-left`/`padding-top`). Give the copy independent ones so a dup — in
    # particular a cascade base snapshot — can't be corrupted by later in-place
    # edits. (Sub-*styles* like `scrollbar` are replaced, not mutated, so they
    # stay shared here. The `specified_mask` is a value field, copied for free by
    # `super`.)
    def dup
      copy = super
      @border.try { |border| copy.border = border.dup }
      copy.padding = @padding.dup
      copy.margin = @margin.dup
      copy.shadow = @shadow.dup
      # The `border=`/`padding=`/`margin=`/`shadow=` setters above stamp their
      # bits into the copy's mask; restore our exact mask so the dup reports
      # precisely what *we* explicitly set, no more (a single value assignment,
      # no allocation).
      copy.specified_mask = @specified_mask
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

    # Re-wrap the `property`-generated setters for TAB expansion so an explicit
    # assignment is recorded as `specified` (must come *after* the `property`
    # declarations above so it overrides their plain setters). Otherwise the
    # `tab_size = 4`/`tab_char = " "` defaults are indistinguishable from an
    # intentional value, and the CSS cascade (`fold_inline`) can't carry an
    # inline-set tab width/char once a stylesheet is active (`tab-size` is itself
    # a CSS property, so inline must fold at the inline tier, beating author).
    def tab_size=(value : Int32) : Int32
      @specified_mask |= SPEC_TAB_SIZE
      @tab_size = value
    end

    def tab_char=(value : String) : String
      @specified_mask |= SPEC_TAB_CHAR
      @tab_char = value
    end

    # Generic fill char (WIP)
    property fill_char : Char = ' '

    # Percent char (WIP)
    property percent_char : Char = ' '

    # Foreground char (WIP)
    property foreground_char : Char = ' '

    # Background char (WIP)
    property background_char : Char = ' '

    # Re-wrap the `property`-generated setters for the per-glyph fill characters
    # so an explicit assignment is recorded as `specified` (must come *after* the
    # `property` declarations above so it overrides their plain setters).
    # Otherwise these `Char = ' '` defaults are indistinguishable from an
    # intentional `' '`, and the CSS cascade (`fold_inline`) can't tell an
    # inline-set `fill_char` from the default — so e.g. `Widget::BigText`'s
    # `fill_char: '▒'` would be silently dropped once CSS is active.
    {% for attr in %w(fill_char percent_char foreground_char background_char) %}
      def {{attr.id}}=(value : Char) : Char
        @specified_mask |= SPEC_{{attr.upcase.id}}
        @{{attr.id}} = value
      end
    {% end %}

    # XXX Test/document this.
    property? fill = true

    # Should something render inside/over the border?
    # Currently used for `Widget::Scrollbar` only.
    # XXX Rename, or make more general, or otherwise unify.
    property? draw_over_border : Bool = false

    # Re-wrap the `property?`-generated setters for `fill`/`draw_over_border` so an
    # explicit assignment is recorded as `specified` (must come *after* the
    # `property?` declarations above so it overrides their plain setters).
    # Otherwise these defaults are indistinguishable from an intentional value, and
    # the CSS cascade (`fold_inline`) can't carry an inline-set value once a
    # stylesheet is active.
    def fill=(value : Bool) : Bool
      @specified_mask |= SPEC_FILL
      @fill = value
    end

    def draw_over_border=(value : Bool) : Bool
      @specified_mask |= SPEC_DRAW_OVER_BORDER
      @draw_over_border = value
    end

    # Each of the following subelements are separate and can be styled individually.
    # If any of them is not defined, it defaults to main/parent style.
    # Names of subelements could be improved over time to be more clear.

    # Keep the list sorted alphabetically.

    # Declares a nested sub-`Style` *slot*: a `setter` plus a getter that falls
    # back to *fallback* (`self` for most slots, `cell` for the alternate row)
    # when the slot was never explicitly assigned. Every sub-style below shares
    # this exact `@slot || fallback` shape; see the canonical `slots` table for
    # the cascade-facing name mapping.
    private macro sub_style_accessor(name, fallback = "self")
      setter {{name.id}} : Style?

      def {{name.id}}
        @{{name.id}} || {{fallback.id}}
      end
    end

    # Style used for alternating (even) rows when a `Widget::Table` or
    # `Widget::ListTable` has `alternate_rows` enabled — the equivalent of Qt's
    # `QAbstractItemView#alternatingRowColors`. Defaults to `cell` (and thus to
    # the main style), so it has no visible effect until styled.
    sub_style_accessor alternate_row, "cell"

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

    # :ditto: setters (Int/String/Nil), mirroring `tint`/`fg`/`bg`; see
    # `Colorizable.color_setter`.
    Colorizable.color_setter gridline_color

    def border=(value)
      @specified_mask |= SPEC_BORDER
      @border = Border.from value
    end

    # Border is always a non-nil object. "No border" is represented by a
    # `Border` whose sides are all 0 (see `Border#any?`), which renders nothing
    # and expands the widget by nothing — exactly like the old `nil` did.
    getter border : Border { Border.new 0 }

    sub_style_accessor cell

    sub_style_accessor header

    sub_style_accessor indicator

    sub_style_accessor item

    # Style used for the numeric/letter prefix shown before each
    # `Widget::ListBar` command (e.g. the `1` in `1:open`). Defaults to `self`.
    sub_style_accessor prefix

    # Style used for a `Widget::Menu` separator rule (Qt's `QMenu::separator`).
    # Defaults to `self`.
    sub_style_accessor separator

    # Style used for a `Widget::TabWidget` tab (Qt's `QTabBar::tab`). Defaults to
    # `self`; `TabWidget` only pushes it onto its tabs when a `TabWidget::tab` rule
    # actually set it (i.e. `tab.same?(self)` is false).
    sub_style_accessor tab

    # Style used for a widget's title chrome (Qt's `QGroupBox::title` /
    # `QDockWidget::title`). Defaults to `self`; the owning widget only pushes it
    # onto its title element when a `::title` rule actually set it.
    sub_style_accessor title

    # Style used for a `Widget::TabWidget` page area (Qt's `QTabWidget::pane`).
    # Defaults to `self`; only pushed onto the current page when a `::pane` rule
    # actually set it.
    sub_style_accessor pane

    # Styles for a `Widget::DockWidget`'s title-bar buttons (Qt's
    # `QDockWidget::close-button` / `::float-button`). Default to `self`; pushed
    # onto the respective button only when a matching `::close-button`/
    # `::float-button` rule set it.
    sub_style_accessor close_button

    sub_style_accessor float_button

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
      @specified_mask |= SPEC_PADDING
      @padding = Padding.from value
    end

    getter padding = Padding.default

    # Element's outer spacing. Unlike `padding`/`border` (inner insets), a margin
    # offsets and shrinks the element itself within its allotted slot; see
    # `Margin` and `Widget#_get_coords`.
    def margin=(value)
      @specified_mask |= SPEC_MARGIN
      @margin = Margin.from value
    end

    # :ditto:
    getter margin = Margin.default

    sub_style_accessor scrollbar

    # Should element drop shadow?
    def shadow=(value)
      @specified_mask |= SPEC_SHADOW
      @shadow = Shadow.from value
    end

    # :ditto:
    getter shadow = Shadow.default

    sub_style_accessor track

    # `Widget::ScrollBar` sub-control slots, mirroring Qt's `QScrollBar`
    # sub-controls (`::sub-line`/`::add-line` stepper buttons, `::up-arrow`/
    # `::down-arrow`/`::left-arrow`/`::right-arrow` arrow glyphs, and
    # `::sub-page`/`::add-page`, the trough regions before/after the handle).
    # Each defaults to `self`; the bar resolves an unset arrow/page slot back to
    # its button/track slot at render time (see `ScrollBar#render`).
    sub_style_accessor sub_line

    sub_style_accessor add_line

    sub_style_accessor sub_page

    sub_style_accessor add_page

    sub_style_accessor up_arrow

    sub_style_accessor down_arrow

    sub_style_accessor left_arrow

    sub_style_accessor right_arrow

    # Canonical CSS *slot* → sub-`Style` accessor mapping. Every place that maps a
    # cascade slot name to a nested `Style` is generated from this single list, so
    # the slot set can't drift between the methods (the previous five hand-kept
    # copies had already diverged — `alternate-row` was missing from the cascade's
    # getter/setter, silently dropping its rules). Maps each CSS pseudo-element
    # name to the underlying accessor (`#scrollbar`, `#sub_line`, …); keep it
    # sorted by accessor for readability.
    {% begin %}
      {% slots = {
           "scrollbar"     => "scrollbar",
           "track"         => "track",
           "sub-line"      => "sub_line",
           "add-line"      => "add_line",
           "sub-page"      => "sub_page",
           "add-page"      => "add_page",
           "up-arrow"      => "up_arrow",
           "down-arrow"    => "down_arrow",
           "left-arrow"    => "left_arrow",
           "right-arrow"   => "right_arrow",
           "cell"          => "cell",
           "header"        => "header",
           "item"          => "item",
           "indicator"     => "indicator",
           "prefix"        => "prefix",
           "separator"     => "separator",
           "tab"           => "tab",
           "title"         => "title",
           "pane"          => "pane",
           "close-button"  => "close_button",
           "float-button"  => "float_button",
           "label"         => "label",
           "alternate-row" => "alternate_row",
         } %}

      # Folds *inline*'s explicitly-set nested sub-styles (`header`/`cell`/
      # `alternate`/`bar`/…) onto this style. Used by the CSS cascade so an inline
      # `@style` that carries a sub-style — e.g. `Style.new(alternate_row: ...)` on a
      # `Widget::Table` — survives recomputation even when no `Widget::slot`
      # sub-element rule matched. Reads the raw nilable ivars (an instance may
      # touch another instance's privates), so only sub-styles the caller actually
      # set are carried (the getters fall back to `self`/`cell`, which would
      # otherwise always look "set").
      def fold_inline_sub_styles(inline : Style) : Nil
        {% for css_name, accessor in slots %}
        @{{accessor.id}} = inline.@{{accessor.id}} if inline.@{{accessor.id}}
        {% end %}
      end

      # The *explicitly-set* sub-`Style` for the cascade *slot* name, or `nil` when
      # this style never set one. Unlike the public getters (`#indicator`, etc.),
      # which fall back to `self`, this reports only what was actually assigned — so
      # the cascade can tell "inline set an `indicator`" apart from "no indicator,
      # use the base style". Used to re-fold an inline-only sub-style at the inline
      # cascade tier so it outranks lower-tier (default/author) sub-element rules,
      # mirroring how the main style honors inline via `fold_inline`.
      def raw_sub_style(slot : String) : Style?
        case slot
        {% for css_name, accessor in slots %}
        when {{css_name}} then @{{accessor.id}}
        {% end %}
        else nil
        end
      end

      # The sub-`Style` for the cascade *slot* name via its public getter (so it
      # falls back to `self`/`cell` like `#indicator` etc.), or `self` for an
      # unknown/`nil` slot. The cascade applies declarations onto a dup of this.
      def sub_style(slot : String?) : Style
        case slot
        {% for css_name, accessor in slots %}
        when {{css_name}} then {{accessor.id}}
        {% end %}
        else self
        end
      end

      # Assigns *sub* to the cascade *slot* name; a no-op for an unknown/`nil` slot.
      def set_sub_style(slot : String?, sub : Style) : Nil
        case slot
        {% for css_name, accessor in slots %}
        when {{css_name}} then self.{{accessor.id}} = sub
        {% end %}
        end
      end
    {% end %}

    def initialize(
      *,
      border = nil,
      padding = nil,
      margin = nil,
      shadow = nil,
      @scrollbar = @scrollbar,
      @track = @track,
      @sub_line = @sub_line,
      @add_line = @add_line,
      @sub_page = @sub_page,
      @add_page = @add_page,
      @up_arrow = @up_arrow,
      @down_arrow = @down_arrow,
      @left_arrow = @left_arrow,
      @right_arrow = @right_arrow,
      @alternate_row = @alternate_row,
      @indicator = @indicator,
      @item = @item,
      @prefix = @prefix,
      @separator = @separator,
      @tab = @tab,
      @title = @title,
      @pane = @pane,
      @close_button = @close_button,
      @float_button = @float_button,
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
      fill_char = nil,
      percent_char = nil,
      foreground_char = nil,
      background_char = nil,
      draw_over_border = nil,
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
      # Only record an explicitly-passed fill character as `specified` (an
      # omitted one keeps the unspecified `' '` default).
      fill_char.try { |v| self.fill_char = v }
      percent_char.try { |v| self.percent_char = v }
      foreground_char.try { |v| self.foreground_char = v }
      background_char.try { |v| self.background_char = v }
      # Only record an explicitly-passed `draw_over_border` as `specified` (an
      # omitted one keeps the unspecified `false` default).
      draw_over_border.try { |v| self.draw_over_border = v }
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
