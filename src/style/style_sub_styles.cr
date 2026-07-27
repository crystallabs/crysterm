module Crysterm
  # The nested sub-`Style` slots of `Style` (split out of style.cr): the
  # `sub_style_accessor` slot declarations, the composed alternate-row
  # machinery, and the canonical slot-name mapping the CSS cascade addresses
  # them by.
  class Style
    # Each subelement below is styled individually; if undefined, it defaults to
    # the main/parent style. Keep the list sorted alphabetically.

    # Declares a nested sub-`Style` *slot*: a `setter` plus a getter that falls
    # back to *fallback* (`self` for most slots, `cell` for the alternate row)
    # when the slot was never explicitly assigned.
    private macro sub_style_accessor(name, fallback = "self")
      setter {{ name.id }} : Style?

      def {{ name.id }}
        @{{ name.id }} || {{ fallback.id }}
      end
    end

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

    sub_style_accessor scrollbar

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

    # Memoized composed sub-style, guarded by the base style's identity *and*
    # its `#attr_fingerprint` so the per-frame read stays cheap; invalidated
    # whenever the base object, its attribute values (in-place mutation), or
    # the bg override changes.
    @alternate_row_composed : Style?
    @alternate_row_composed_src : Style?
    @alternate_row_composed_fp : AttrFingerprint?

    def alternate_row=(value : Style?) : Style?
      @alternate_row_composed = nil
      @alternate_row = value
    end

    def alternate_row : Style
      base = @alternate_row || cell
      bg = @alternate_bg
      return base if bg.nil?
      # Reuse the memoized composition while the base object is unchanged —
      # both by identity and by value, so an in-place `base.fg = ...` between
      # frames recomposes instead of returning the stale frozen copy.
      composed, @alternate_row_composed_src, @alternate_row_composed, @alternate_row_composed_fp =
        Style.memo_derive(base, @alternate_row_composed_src, @alternate_row_composed,
          @alternate_row_composed_fp) do |s|
          copy = s.dup
          copy.bg = bg
          copy
        end
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
      @alternate_bg = Colors.to_native color
      @alternate_row_composed = nil
    end

    # The alternate-row background color, or `nil` when no distinct alternate-row
    # background has been set (the row then follows `cell`/`self`).
    def alternate_background_color
      @alternate_bg || @alternate_row.try &.bg
    end

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
        @{{ accessor.id }} = inline.@{{ accessor.id }} if inline.@{{ accessor.id }}
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
        when {{ css_name }} then @{{ accessor.id }}
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
        when {{ css_name }} then {{ accessor.id }}
        {% end %}
        else self
        end
      end

      # Assigns *sub* to the cascade *slot* name; a no-op for an unknown/`nil` slot.
      def set_sub_style(slot : String?, sub : Style) : Nil
        case slot
        {% for css_name, accessor in slots %}
        when {{ css_name }} then self.{{ accessor.id }} = sub
        {% end %}
        end
      end
    {% end %}
  end
end
