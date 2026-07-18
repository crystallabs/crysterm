module Crysterm
  # The complete style of a widget.
  class Style
    include Colorizable

    # Foreground color (color of font/character).
    #
    # The native color form is a `0xRRGGBB` integer (`-1` = terminal default,
    # `nil` = "no color set", so no SGR sequence is emitted and the terminal
    # default applies). The setter also accepts `"#rrggbb"`/named-color strings,
    # parsing them to the native int via `Colors.convert`.
    getter fg : Int32?

    # Background color (color of cell). See `#fg` for the accepted forms.
    getter bg : Int32?

    # SGR text-attribute booleans. The plain `property?` setters this generates
    # are re-wrapped below to track explicit assignment in `specified_mask`,
    # regardless of include order.
    include TextAttributes

    # Whether the widget is visible (CSS `visibility`). Widget-level, not an SGR
    # attribute — deliberately on `Style` itself, not `TextAttributes`, so
    # `Border` (which shares the SGR mixin) doesn't inherit a meaningless
    # `visible?`. The setter is re-wrapped below for `specified_mask`, like the
    # SGR booleans.
    property? visible : Bool = true

    # Opacity (inverse of transparency). 0 == full transparency, 1 == full opacity.
    property opacity : Float64?

    # A color the whole widget region is blended toward, by `tint_alpha`.
    # `nil` = no tint. See `#fg` for the accepted forms.
    getter tint : Int32?

    # Strength of the `tint` overlay: `0.0` = none, `1.0` = fully the tint color.
    property tint_alpha : Float64 = 0.5

    Colorizable.color_setter tint

    # Compositing layer (CSS `z-index`). When set, the widget and its subtree are
    # promoted to their own `Plane` at this z, composited over the base so
    # content from other widgets can show through; `opacity` becomes the plane's
    # opacity. `nil` = the base layer (the ordinary painter's path).
    property z_index : Int32?

    # How a `background_image` is scaled to fill the widget box.
    enum BackgroundSize
      Cover   # fill the box, preserve aspect, crop overflow (default)
      Contain # fit entirely inside the box, preserve aspect, letterbox remainder
      Stretch # stretch to fill exactly, ignoring aspect (CSS `100% 100%`)
      Auto    # natural size, no scaling (CSS default `auto`)
    end

    # CSS `background-image`: the `url(...)` path/URL of an image painted behind
    # the widget's own content. `nil` = none. Realized lazily as an internal
    # `Widget::Media` background layer, so it only has visible effect where a
    # background-capable backend is available (Kitty for true pixels under the
    # text, or the cell-grid `Glyph`/`Ansi` fallback).
    property background_image : String?

    # CSS `background-size`: how `background_image` fills the box. Defaults to
    # `Cover` rather than the strict CSS `auto`, as the more useful default for a
    # widget backdrop.
    getter background_size : BackgroundSize = BackgroundSize::Cover

    def background_size=(value : BackgroundSize) : BackgroundSize
      @specified_mask |= SPEC_BACKGROUND_SIZE
      @background_size = value
    end

    # CSS `transition`: animatable property name -> `{duration, easing}`. When an
    # animated property's value changes (e.g. on a `:hover`/`:focus` state
    # change) the new value tweens in over its duration rather than snapping.
    property transitions : Hash(String, Tuple(Time::Span, Easing))?

    # A CSS `animation` binding: which `@keyframes` to play and how. `nil` = none.
    record AnimationSpec,
      name : String,
      duration : Time::Span,
      easing : Easing = Easing::Linear,
      iterations : Int32? = nil, # nil = infinite
      alternate : Bool = false   # ping-pong direction each cycle

    # CSS `animation`: a named `@keyframes` sequence to loop.
    property animation : AnimationSpec?

    # Tracks which text-attribute booleans (and struct properties) were
    # explicitly set, vs left at default, so the CSS cascade can tell "set to
    # false" from "unset". Colors and `opacity` carry their own unset signal
    # (`nil`), so they aren't tracked here.
    #
    # Must stay a bitmask rather than a `Set(Symbol)`: the cascade `#dup`s a
    # style per state per recompute (hundreds-thousands per frame on a deep
    # tree), and a `UInt32` is copied for free by the shallow `super` dup, so
    # that path allocates nothing.
    protected property specified_mask : UInt32 = 0_u32

    # Bit per tracked property. Order is arbitrary but must stay stable within a
    # build (the mask is never persisted across builds).
    {% begin %}
      # Split by getter form so one list also drives `#fold_specified_onto`:
      # boolean attributes are read through their `?` getter, the rest through a
      # plain getter. `tracked` is their concatenation and defines the bitmask.
      {% tracked_bool = %w(bold italic underline blink reverse strike visible
           fill draw_over_border) %}
      {% tracked_value = %w(background_size fill_char border padding margin
           shadow tab_size tab_char) %}
      {% tracked = tracked_bool + tracked_value %}
      {% for prop, i in tracked %}
        SPEC_{{prop.upcase.id}} = 1_u32 << {{i}}
      {% end %}

      # The mask bit for a tracked property symbol; `0` if untracked, those
      # using a `nil` unset signal answered directly in `#specified?`.
      private def specified_bit(property : Symbol) : UInt32
        case property
        {% for prop in tracked %}
        when :{{prop.id}} then SPEC_{{prop.upcase.id}}
        {% end %}
        else 0_u32
        end
      end

      # Folds every explicitly-set *tracked* property of this style onto *other*,
      # copying each only where `specified?` reports it set, so an inline style
      # can switch a value on *or* off over a stylesheet. The assignments go
      # through *other*'s setters, stamping *other*'s `specified_mask` too. The
      # remaining, `nil`-signalled properties (`fg`/`bg`/`opacity`/`tint`/…) carry
      # no mask bit and are folded by hand in the cascade.
      def fold_specified_onto(other : Style) : Nil
        {% for prop in tracked_bool %}
          other.{{prop.id}} = {{prop.id}}? if specified?(:{{prop.id}})
        {% end %}
        {% for prop in tracked_value %}
          {% if %w(border padding margin shadow).includes?(prop) %}
            # Mutable box sub-objects must be copied, not shared by reference:
            # the longhand tiers (`border-left`, `padding-top`, …) mutate the
            # folded object in place, which would permanently corrupt the user's
            # inline `@style`. Mirrors `Style#dup`'s policy.
            other.{{prop.id}} = {{prop.id}}.dup if specified?(:{{prop.id}})
          {% else %}
            other.{{prop.id}} = {{prop.id}} if specified?(:{{prop.id}})
          {% end %}
        {% end %}
      end
    {% end %}

    # Whether *property* was explicitly set on this style.
    def specified?(property : Symbol) : Bool
      case property
      when :fg               then !@fg.nil?
      when :bg               then !@bg.nil?
      when :opacity          then !@opacity.nil?
      when :tint             then !@tint.nil?
      when :gridline_color   then !@gridline_color.nil?
      when :z_index          then !@z_index.nil?
      when :background_image then !@background_image.nil?
      when :transitions      then !@transitions.nil?
      when :animation        then !@animation.nil?
      when :glyph            then !@glyph.nil?
      when :glyph_ascii      then !@glyph_ascii.nil?
      when :glyph_unicode    then !@glyph_unicode.nil?
      when :glyph_extended   then !@glyph_extended.nil?
      when :glyph_open       then !@glyph_open.nil?
      when :glyph_close      then !@glyph_close.nil?
      when :glyphs           then !@glyphs.nil?
      else                        (@specified_mask & specified_bit(property)) != 0_u32
      end
    end

    # Re-wrap the `property?`-generated boolean setters so each explicit
    # assignment is recorded, making `bold = false` distinguishable from the
    # default `false`.
    {% for attr in %w(bold italic underline blink reverse strike visible) %}
      def {{attr.id}}=(value : Bool) : Bool
        @specified_mask |= SPEC_{{attr.upcase.id}}
        @{{attr.id}} = value
      end
    {% end %}

    # A deep-enough copy: the mutable box sub-objects (`border`/`padding`/
    # `margin`/`shadow`, mutated in place by e.g. `border-left`/`padding-top`)
    # get independent instances, so a copy can't be corrupted by later edits to
    # the original. Sub-styles like `scrollbar` are replaced, not mutated, so
    # they stay shared.
    def dup
      copy = super
      @border.try { |border| copy.border = border.dup }
      # The boxes are lazy (nil until first set/read) and read through the ivar,
      # so a style that never touched one costs no dup here. Most widgets set no
      # box geometry, and the cascade dups every recompute candidate per state.
      @padding.try { |padding| copy.padding = padding.dup }
      @margin.try { |margin| copy.margin = margin.dup }
      @shadow.try { |shadow| copy.shadow = shadow.dup }
      # The setters above stamp their bits into the copy's mask, so restore our
      # exact mask; the dup must report precisely what we explicitly set.
      copy.specified_mask = @specified_mask
      copy
    end

    # Whether this style carries a visible distinction of its own — an explicit
    # `fg`/`bg` color, or reverse-video — as opposed to being fully unstyled.
    def visibly_styled? : Bool
      specified?(:fg) || specified?(:bg) || reverse?
    end

    # A copy of this style with reverse-video forced on when it is not already
    # `#visibly_styled?`, else `self` untouched. Lets a state (selection, focus)
    # still read against an unstyled floor.
    def with_reverse_fallback : Style
      return self if visibly_styled?
      copy = dup
      copy.reverse = true
      copy
    end

    # Is any transparency defined? Testing `opacity == nil` alone isn't enough:
    # 1.0 (full opacity) also means no transparency is enabled.
    def opacity?
      @opacity.try do |a|
        return a if a != 1.0
      end
    end

    # The active tint as `{color, alpha}`, or `nil` when no tint color is set or
    # the overlay is fully transparent (`tint_alpha == 0`, a no-op).
    def tint?
      @tint.try do |c|
        return {c, @tint_alpha} if @tint_alpha != 0.0
      end
    end

    # Length in number of characters to replace TABs with
    property tab_size = 4

    # Character to replace TABs with, multiplied by tab_size
    property tab_char = " "

    # Re-wrap the TAB-expansion setters so an explicit assignment is recorded as
    # `specified`; otherwise the defaults are indistinguishable from an
    # intentional value and the cascade drops an inline-set tab width/char. Must
    # come after the `property` declarations above to override their setters.
    def tab_size=(value : Int32) : Int32
      @specified_mask |= SPEC_TAB_SIZE
      @tab_size = value
    end

    def tab_char=(value : String) : String
      @specified_mask |= SPEC_TAB_CHAR
      @tab_char = value
    end

    # Character used to fill otherwise-empty cells the widget paints: alignment
    # gaps (`#align_line`), `fill_region`/`clear_pos` backfill, a `Fill`-type
    # `Border`'s fallback char, and the artificial cursor's `none`-shape glyph.
    property fill_char : Char = ' '

    # Re-wrap the fill-character setter so an explicit assignment is recorded as
    # `specified`; otherwise the `' '` default is indistinguishable from an
    # intentional `' '` and the cascade silently drops an inline-set fill char.
    # Must come after the `property` declaration above to override its setter.
    def fill_char=(value : Char) : Char
      @specified_mask |= SPEC_FILL_CHAR
      @fill_char = value
    end

    # -- CSS `glyph` property family ------------------------------------------
    #
    # A chrome-glyph override for the site/slot this style lands on; the one
    # property is addressed at different sites via sub-controls and state pseudos
    # (`CheckBox::indicator:checked { glyph: "x" }`). All fields are
    # `nil`-signalled (unset = ask the `Glyphs` registry), so they cost no
    # `specified_mask` bits. `Glyphs::NONE_STR` (CSS `glyph: none`) means "omit"
    # on run roles and "registry default" on cell roles; the consumer decides by
    # role class.
    #
    # The fields are `String?`, not `Char?`, because a CSS glyph value can be a
    # multi-codepoint grapheme a `Char` can't hold (an emoji-presentation `⚠️` =
    # base + VS16, a regional-indicator flag, any combining sequence). A
    # cell-role consumer reduces it to a lone `Char`; a run-role consumer takes
    # it whole.

    # Universal override: use this grapheme at any tier.
    property glyph : String?

    # Per-tier longhands (CSS `glyph-ascii`/`glyph-unicode`/`glyph-extended`).
    # Resolution falls *down* tiers within this layer, then to `glyph` — never
    # across layers mid-tier.
    property glyph_ascii : String?
    property glyph_unicode : String?
    property glyph_extended : String?

    # Delimiter pair around a composed indicator marker (CSS `glyph-open`/
    # `glyph-close`), e.g. a checkbox's `[`/`]`. `Glyphs::NONE_STR` omits the
    # delimiter entirely, shrinking the marker.
    property glyph_open : String?
    property glyph_close : String?

    # A sequence override (CSS `glyphs`): the string's characters are the ordered
    # steps of the site's sequence role — spinner frames, dial pointer ring, fill
    # ramp. `nil` = unset (ask the `Glyphs` sequence registry).
    property glyphs : String?

    # The CSS-specified glyph for *tier*: the tier longhand, falling down tiers,
    # else the universal `glyph`; `nil` when this style specifies none, so the
    # consumer asks the `Glyphs` registry. May return a full multi-codepoint
    # grapheme, or `Glyphs::NONE_STR` — see the field docs above.
    @[AlwaysInline]
    def glyph_for(tier : Glyphs::Tier) : String?
      case tier
      in .extended? then @glyph_extended || @glyph_unicode || @glyph_ascii || @glyph
      in .unicode?  then @glyph_unicode || @glyph_ascii || @glyph
      in .ascii?    then @glyph_ascii || @glyph
      end
    end

    # XXX Test/document this.
    property? fill = true

    # Should something render inside/over the border?
    # Currently used for `Widget::Scrollbar` only.
    # XXX Rename, or make more general, or otherwise unify.
    property? draw_over_border : Bool = false

    # Re-wrap the `fill`/`draw_over_border` setters so an explicit assignment is
    # recorded as `specified`; otherwise the defaults are indistinguishable from
    # an intentional value and the cascade drops an inline-set one. Must come
    # after the `property?` declarations above to override their setters.
    def fill=(value : Bool) : Bool
      @specified_mask |= SPEC_FILL
      @fill = value
    end

    def draw_over_border=(value : Bool) : Bool
      @specified_mask |= SPEC_DRAW_OVER_BORDER
      @draw_over_border = value
    end

    # Each subelement below is styled individually; if undefined, it defaults to
    # the main/parent style. Keep the list sorted alphabetically.

    # Declares a nested sub-`Style` *slot*: a `setter` plus a getter that falls
    # back to *fallback* (`self` for most slots, `cell` for the alternate row)
    # when the slot was never explicitly assigned.
    private macro sub_style_accessor(name, fallback = "self")
      setter {{name.id}} : Style?

      def {{name.id}}
        @{{name.id}} || {{fallback.id}}
      end
    end

    # Style used for alternating (even) rows when a `Widget::Table` or
    # `Widget::ListTable` has `alternate_rows` enabled — equivalent to Qt's
    # `QAbstractItemView#alternatingRowColors`. Defaults to `cell` (and thus the
    # main style), so it has no visible effect until styled.
    #
    # An explicitly-assigned sub-style is the base; the CSS
    # `alternate-background-color` override (`@alternate_bg`) is composed over it
    # (or over `cell`/`self`) *lazily* at read time, so the foreground and
    # attributes always track the current cell/self style — a `color` declaration
    # applied after `alternate-background-color`, or one inherited from a parent
    # rule, still reaches alternate rows (per Qt, only the background changes).
    @alternate_row : Style?

    # Only the background override is frozen; fg/attributes compose live.
    @alternate_bg : Int32?

    # Memoized composed sub-style, guarded by the base style's identity so the
    # per-frame read stays cheap; invalidated whenever the base object or the bg
    # override changes.
    @alternate_row_composed : Style?
    @alternate_row_composed_src : Style?

    def alternate_row=(value : Style?) : Style?
      @alternate_row_composed = nil
      @alternate_row = value
    end

    def alternate_row : Style
      base = @alternate_row || cell
      bg = @alternate_bg
      return base if bg.nil?
      # Reuse the memoized composition while the base object is unchanged.
      if (c = @alternate_row_composed) && (s = @alternate_row_composed_src) && s.same?(base)
        return c
      end
      composed = base.dup
      composed.bg = bg
      @alternate_row_composed = composed
      @alternate_row_composed_src = base
      composed
    end

    # Whether a distinct alternate-row sub-style has been set (an explicit
    # sub-style or a CSS `alternate-background-color` override), as opposed to the
    # getter falling back to `cell`/`self`.
    def alternate_row?
      !@alternate_row.nil? || !@alternate_bg.nil?
    end

    # Sets the background of the alternating-row sub-style (CSS
    # `alternate-background-color`). Only the background is stored, per Qt; the
    # foreground and attributes are composed live from the current `cell`/`self`
    # style at read time (see `#alternate_row`), so a later `color` declaration or
    # inherited color still reaches alternate rows.
    def alternate_background_color=(color) : Nil
      @alternate_bg =
        case color
        when Int    then color.to_i32
        when String then Colors.convert_cached(color)
        else             nil
        end
      @alternate_row_composed = nil
    end

    # The alternate-row background color, or `nil` when no distinct alternate-row
    # background has been set (the row then follows `cell`/`self`).
    def alternate_background_color
      @alternate_bg || @alternate_row.try &.bg
    end

    # Color of a table's internal gridlines (Qt's `gridline-color`). `nil` (the
    # default) means the gridlines follow the box `border` color. When set, it
    # overrides just the gridline foreground; other border attributes are kept.
    # See `#fg` for the accepted forms.
    getter gridline_color : Int32?

    Colorizable.color_setter gridline_color

    def border=(value : Bool | BorderType | Border | Side | Symbol | Int32 | Nil)
      @specified_mask |= SPEC_BORDER
      @border = Border.from value
    end

    # Border is always a non-nil object. "No border" is a `Border` whose sides
    # are all 0, which renders nothing and expands the widget by nothing.
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
    # `self`; pushed onto the tabs only when a `TabWidget::tab` rule actually set
    # it (`tab.same?(self)` is false).
    sub_style_accessor tab

    # Style used for a widget's title chrome (Qt's `QGroupBox::title` /
    # `QDockWidget::title`). Defaults to `self`; pushed onto the title element
    # only when a `::title` rule actually set it.
    sub_style_accessor title

    # Style used for a `Widget::TabWidget` page area (Qt's `QTabWidget::pane`).
    # Defaults to `self`; pushed onto the current page only when a `::pane` rule
    # actually set it.
    sub_style_accessor pane

    # Styles for a `Widget::DockWidget`'s title-bar buttons (Qt's
    # `QDockWidget::close-button` / `::float-button`). Default to `self`; pushed
    # onto the respective button only when a matching rule set it.
    sub_style_accessor close_button

    sub_style_accessor float_button

    # Style for a drop-down affordance (Qt's `QComboBox::drop-down`; also the
    # `ToolButton` popup arrow). Defaults to `self`; carries the arrow `glyph`.
    sub_style_accessor drop_down

    # Style used for a widget's border label (`Widget#set_label`). Defaults to
    # `self` like every other sub-style; since labels are widgets, the resolved
    # sub-style is pushed onto the `@label_widget` each frame — but only when a
    # `::label` rule (or explicit assignment) actually set it, so an unstyled
    # label keeps its own plain `Style` and doesn't inherit box properties
    # (e.g. the parent's border).
    sub_style_accessor label

    def padding=(value : Bool | Padding | Side | Symbol | Int32 | Tuple(Int32, Int32) | Tuple(Int32, Int32, Int32, Int32) | Nil)
      @specified_mask |= SPEC_PADDING
      @padding = Padding.from value
    end

    # Element's inner spacing. Lazy: an untouched box stays `nil` so `#dup`
    # copies nothing for it, and is materialized on first access so the per-side
    # longhands (`padding-left`, …) can mutate it in place. Never a shared
    # singleton — each style owns its box.
    getter padding : Padding { Padding.default }

    # Element's outer spacing. Unlike `padding`/`border`, which are inner insets,
    # margin offsets and shrinks the element itself within its allotted slot.
    def margin=(value : Bool | Margin | Side | Symbol | Int32 | Tuple(Int32, Int32) | Tuple(Int32, Int32, Int32, Int32) | Nil)
      @specified_mask |= SPEC_MARGIN
      @margin = Margin.from value
    end

    # :ditto: (lazy, like `#padding`).
    getter margin : Margin { Margin.default }

    sub_style_accessor scrollbar

    # Should element drop shadow?
    def shadow=(value : Bool | Shadow | Side | Symbol | Float64 | Int32 | Nil)
      @specified_mask |= SPEC_SHADOW
      @shadow = Shadow.from value
    end

    # :ditto: (lazy, like `#padding`).
    getter shadow : Shadow { Shadow.default }

    sub_style_accessor track

    # `Widget::ScrollBar` sub-control slots, mirroring Qt's `QScrollBar`
    # sub-controls: `::sub-line`/`::add-line` stepper buttons, `::up-arrow`/
    # `::down-arrow`/`::left-arrow`/`::right-arrow` arrow glyphs, and
    # `::sub-page`/`::add-page` trough regions. Each defaults to `self`; the bar
    # resolves an unset arrow/page slot back to its button/track slot at render
    # time.
    sub_style_accessor sub_line

    sub_style_accessor add_line

    sub_style_accessor sub_page

    sub_style_accessor add_page

    sub_style_accessor up_arrow

    sub_style_accessor down_arrow

    sub_style_accessor left_arrow

    sub_style_accessor right_arrow

    # Canonical CSS *slot* → sub-`Style` accessor mapping. Every place that maps
    # a cascade slot name to a nested `Style` is generated from this one list, so
    # the slot set can't drift between methods.
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
           "drop-down"     => "drop_down",
           "label"         => "label",
           "alternate-row" => "alternate_row",
         } %}

      # Folds *inline*'s explicitly-set nested sub-styles onto this style, so an
      # inline `@style` carrying one survives recomputation even when no
      # sub-element rule matched. Must read the raw nilable ivars: the getters
      # fall back to `self`/`cell`, so they would always look "set".
      def fold_inline_sub_styles(inline : Style) : Nil
        {% for css_name, accessor in slots %}
        @{{accessor.id}} = inline.@{{accessor.id}} if inline.@{{accessor.id}}
        {% end %}
        # `alternate-background-color` is stored as a scalar override, not a
        # sub-style, so the slot loop above misses it.
        if b = inline.@alternate_bg
          @alternate_bg = b
          @alternate_row_composed = nil
        end
      end

      # The explicitly-set sub-`Style` for the cascade *slot* name, or `nil` when
      # this style never set one. Unlike the public getters (`#indicator`, etc.),
      # which fall back to `self`, this reports only what was actually assigned,
      # telling "inline set an `indicator`" apart from "no indicator, use the
      # base style".
      def raw_sub_style(slot : String) : Style?
        case slot
        {% for css_name, accessor in slots %}
        when {{css_name}} then @{{accessor.id}}
        {% end %}
        else nil
        end
      end

      # The sub-`Style` for the cascade *slot* name via its public getter, so it
      # falls back to `self`/`cell` like `#indicator` etc.; `self` for an
      # unknown/`nil` slot.
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
      @drop_down = @drop_down,
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
      opacity : Float64? = nil,
      fill_char = nil,
      draw_over_border = nil,
      z_index = nil,
      tint = nil,
      tint_alpha = nil,
      gridline_color = nil,
      background_image = nil,
      background_size = nil,
      transitions = nil,
      animation = nil,
      tab_size = nil,
      tab_char = nil,
      fill = nil,
      @glyph : String? = nil,
      @glyph_ascii : String? = nil,
      @glyph_unicode : String? = nil,
      @glyph_extended : String? = nil,
      @glyph_open : String? = nil,
      @glyph_close : String? = nil,
      @glyphs : String? = nil,
    )
      # Route fg/bg through the setters so a native `0xRRGGBB` int is normalized
      # to its `#rrggbb` string (each call type — String, Int, Nil — resolves to
      # the matching `fg=`/`bg=` overload).
      self.fg = fg
      self.bg = bg
      # Route booleans through their setters too, but only when given, so a
      # constructed value is recorded as `specified` while an omitted one stays
      # at the default (unset).
      bold.try { |v| self.bold = v }
      italic.try { |v| self.italic = v }
      underline.try { |v| self.underline = v }
      blink.try { |v| self.blink = v }
      reverse.try { |v| self.reverse = v }
      strike.try { |v| self.strike = v }
      visible.try { |v| self.visible = v }
      opacity.try { |v| self.opacity = self.class.opacity_from(v) }
      border.try { |v| self.border = Border.from(v) }
      padding.try { |v| self.padding = Padding.from(v) }
      margin.try { |v| self.margin = Margin.from(v) }
      shadow.try { |v| self.shadow = Shadow.from(v) }
      # Only record an explicitly-passed fill character as `specified`.
      fill_char.try { |v| self.fill_char = v }
      # Only record an explicitly-passed `draw_over_border` as `specified`.
      draw_over_border.try { |v| self.draw_over_border = v }
      # Tint/gridline are colors: route them through their `Colorizable`
      # setters unconditionally, exactly like `fg`/`bg` above, so an
      # `0xRRGGBB` int, a `"#rrggbb"`/named string, and `nil` each pick the
      # matching overload.
      self.tint = tint
      self.gridline_color = gridline_color
      z_index.try { |v| self.z_index = v }
      tint_alpha.try { |v| self.tint_alpha = v }
      background_image.try { |v| self.background_image = v }
      background_size.try { |v| self.background_size = v }
      transitions.try { |v| self.transitions = v }
      animation.try { |v| self.animation = v }
      tab_size.try { |v| self.tab_size = v }
      tab_char.try { |v| self.tab_char = v }
      fill.try { |v| self.fill = v }
    end

    def self.opacity_from(value : Float64?)
      value
    end
  end
end
