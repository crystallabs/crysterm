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

    # Inverse?
    property? inverse : Bool = false

    # Visible?
    property? visible : Bool = true

    # Alpha (inverse of transparency). Alpha 0 == full transparency, 1 == full opacity.
    property alpha : Float64?

    # Tracks which text-attribute booleans were *explicitly* set (vs left at
    # their default), so the CSS cascade can tell "set to false" from "unset" —
    # needed for inline-style folding and inheritance. Colors and `alpha` carry
    # their own unset signal (`nil`), so they are not tracked here.
    protected property specified = Set(Symbol).new

    # Whether *property* was explicitly set on this style.
    def specified?(property : Symbol) : Bool
      case property
      when :fg    then !@fg.nil?
      when :bg    then !@bg.nil?
      when :alpha then !@alpha.nil?
      else             @specified.includes?(property)
      end
    end

    # Re-wrap the `property?`-generated boolean setters so each explicit
    # assignment is recorded (`bold = false` becomes distinguishable from the
    # default `false`).
    {% for attr in %w(bold italic underline blink inverse visible) %}
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
      copy.shadow = @shadow.dup
      # Those `border=`/`padding=`/`shadow=` setters also stamp
      # `:border`/`:padding`/`:shadow` into the copy's set; drop any we didn't
      # actually specify (cheap deletes — no second `Set` allocation), so the dup
      # reports exactly what *we* explicitly set, no more.
      copy.specified.delete(:border) unless @specified.includes?(:border)
      copy.specified.delete(:padding) unless @specified.includes?(:padding)
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

    # Length in number of characters to replace TABs with
    property tab_size = 4

    # Character to replace TABs with, multiplied by tab_size
    property tab_char = " "

    # Generic char (WIP)
    property char : Char = ' '

    # Percent char (WIP)
    property pchar : Char = ' '

    # Foreground char (WIP)
    property fchar : Char = ' '

    # Background char (WIP)
    property bchar : Char = ' '

    # XXX Test/document this.
    property? fill = true

    # Should something render inside/over the border?
    # Currently used for `Widget::Scrollbar` only.
    # XXX Rename, or make more general, or otherwise unify.
    property? ignore_border : Bool = false

    # Each of the following subelements are separate and can be styled individually.
    # If any of them is not defined, it defaults to main/parent style.
    # Names of subelements could be improved over time to be more clear.

    # Keep the list sorted alphabetically.

    # Style used for alternating (even) rows when a `Widget::Table` or
    # `Widget::ListTable` has `alternate_rows` enabled — the equivalent of Qt's
    # `QAbstractItemView#alternatingRowColors`. Defaults to `cell` (and thus to
    # the main style), so it has no visible effect until styled.
    setter alternate : Style?

    def alternate
      @alternate || cell
    end

    setter bar : Style?

    def bar
      @bar || self
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

    def initialize(
      *,
      border = nil,
      padding = nil,
      shadow = nil,
      @scrollbar = @scrollbar,
      @track = @track,
      @alternate = @alternate,
      @bar = @bar,
      @item = @item,
      @prefix = @prefix,
      @header = @header,
      @cell = @cell,
      @label = @label,
      fg = nil,
      bg = nil,
      bold = nil,
      italic = nil,
      underline = nil,
      blink = nil,
      inverse = nil,
      visible = nil,
      alpha = nil,
      @char = @char,
      @pchar = @pchar,
      @fchar = @fchar,
      @bchar = @bchar,
      @ignore_border = @ignore_border,
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
      inverse.try { |v| self.inverse = v }
      visible.try { |v| self.visible = v }
      alpha.try { |v| self.alpha = self.class.alpha_from(v) }
      border.try { |v| self.border = Border.from(v) }
      padding.try { |v| self.padding = Padding.from(v) }
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
