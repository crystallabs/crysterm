module Crysterm
  # The colors a view paints a rich-text document's semantic parts in —
  # headings, code (and its background), links, quote bars, rules, muted
  # text and the five GFM alert kinds — resolved from a widget's `Style`: the
  # `::heading`/`::code`/`::link`/`::quote`/`::rule`/`::muted` and
  # `::note`/`::tip`/`::important`/`::warning`/`::caution` content slots
  # (`Style#heading` and friends), which the default theme fills from its
  # palette roles and any stylesheet may override (`TextEdit::code { color:
  # … }`). The document itself carries only the semantics
  # (`TextBlockFormat#heading_level`, `#code_language`, `#quote_level`,
  # `#alert_kind`, `#horizontal_rule?`; `TextCharFormat#code?`, `#rule?`,
  # `#dim?`, `#anchor_href`), so a restyle recolors on the next frame and a
  # document shared by two views paints in each view's colors. Exporters
  # never see a color they did not store.
  #
  # A slot without a `color` leaves its part `nil` — drawn in the widget's
  # own foreground. The code background is the `code` slot's
  # `background-color`; `transparent` there means none (code sits on the
  # plain surface); unset, it is a shade of the widget's actual surface
  # (`.code_bg_for`): a touch lighter on a dark surface, darker on a light
  # one, so code blocks sit on whatever background a stylesheet gave the
  # widget rather than on a constant.
  record ContentPalette,
    heading : Int32? = nil,
    code : Int32? = nil,
    code_bg : Int32? = nil,
    link : Int32? = nil,
    quote : Int32? = nil,
    rule : Int32? = nil,
    muted : Int32? = nil,
    note : Int32? = nil,
    tip : Int32? = nil,
    important : Int32? = nil,
    warning : Int32? = nil,
    caution : Int32? = nil do
    # Lightness steps `.code_bg_for` moves the surface by.
    CODE_BG_LIFT_DARK  = 0.07
    CODE_BG_LIFT_LIGHT = 0.06

    # The accent of a GFM alert *kind* (its bar and title chip), `nil` when
    # the kind's slot sets no color.
    def alert(kind : TextBlockFormat::AlertKind) : Int32?
      case kind
      in .note?      then @note
      in .tip?       then @tip
      in .important? then @important
      in .warning?   then @warning
      in .caution?   then @caution
      end
    end

    # The palette *style*'s content slots resolve to. *bg* is the widget's
    # resolved background (`0xRRGGBB`; `nil`/`-1` for the terminal default),
    # which the code background is derived from when the `code` slot sets
    # none.
    #
    # A slot the cascade materialized starts as a copy of the widget style,
    # so a slot color equal to the widget's own is read as "not set" — the
    # same reading `Widget::Menu` gives its separator — which is also what
    # it would paint as. (On a terminal-default surface this leaves `code {
    # background-color: transparent }` indistinguishable from unset, since
    # both are the `-1` default; the derived shade then stands.)
    def self.from_style(style : Style, bg : Int32? = style.bg) : ContentPalette
      code = style.code?
      code_bg =
        case c = own(code, style, fg: false)
        when nil then code_bg_for(bg)
        when -1  then nil # `transparent`: no shade
        else          c
        end
      new(
        heading: own(style.heading?, style, fg: true),
        code: own(code, style, fg: true),
        code_bg: code_bg,
        link: own(style.link?, style, fg: true),
        quote: own(style.quote?, style, fg: true),
        rule: own(style.rule?, style, fg: true),
        muted: own(style.muted?, style, fg: true),
        note: own(style.note?, style, fg: true),
        tip: own(style.tip?, style, fg: true),
        important: own(style.important?, style, fg: true),
        warning: own(style.warning?, style, fg: true),
        caution: own(style.caution?, style, fg: true),
      )
    end

    # *slot*'s fg (or bg) when it differs from *base*'s, else `nil`.
    private def self.own(slot : Style?, base : Style, *, fg : Bool) : Int32?
      return unless slot
      c = fg ? slot.fg : slot.bg
      c == (fg ? base.fg : base.bg) ? nil : c
    end

    # A code background set off from the surface *bg*: lighter on a dark
    # surface, darker on a light one. An unknown (terminal default) surface
    # is taken to be the active CSS theme's `surface` primary — the color the
    # theme believes it is drawing on, light for a light theme — falling back
    # to the configured neutral default (`Colors.default_bg_rgb`).
    def self.code_bg_for(bg : Int32?) : Int32
      surface = (bg.nil? || bg < 0) ? (CSS.theme.try(&.primaries["surface"]?) || Colors.default_bg_rgb) : bg
      if Colors.luminance(surface) < 0.5
        Colors.lighten(surface, CODE_BG_LIFT_DARK)
      else
        Colors.darken(surface, CODE_BG_LIFT_LIGHT)
      end
    end

    # Per-view memo of `.from_style`: the palette is re-resolved only when the
    # style object, its `attr_revision`, the resolved background, the active
    # theme, or any content slot (by identity and revision) changed since the
    # last `#fetch`. Holds the `Style` references it keyed on, so a recycled
    # object address can never false-hit (as `Style::AttrMemo` does).
    #
    # A mutable struct: hold it in an ivar and call `#fetch` on that lvalue
    # directly; reading it through a copying accessor would memoize nothing.
    struct Memo
      @src : Style?
      @revision : Int64 = 0_i64
      @bg : Int32? = nil
      # `CSS.default_stylesheet_generation` at the last resolution: it bumps
      # on every theme/default-sheet swap, which moves the surface an
      # unknown-background shade is derived from.
      @generation : Int32 = -1
      @slots = StaticArray(Style?, 11).new(nil)
      @slot_revisions = StaticArray(Int64, 11).new(0_i64)
      @palette = ContentPalette.new

      # The palette for *style* over the resolved background *bg* (see
      # `.from_style`).
      def fetch(style : Style, bg : Int32?) : ContentPalette
        slots = {style.heading?, style.code?, style.link?, style.quote?, style.rule?, style.muted?,
                 style.note?, style.tip?, style.important?, style.warning?, style.caution?}
        generation = CSS.default_stylesheet_generation
        if (src = @src) && src.same?(style) && @revision == style.attr_revision && @bg == bg &&
           @generation == generation && slots_unchanged?(slots)
          return @palette
        end
        @src = style
        @revision = style.attr_revision
        @bg = bg
        @generation = generation
        slots.each_with_index do |slot, i|
          @slots[i] = slot
          @slot_revisions[i] = slot ? slot.attr_revision : 0_i64
        end
        @palette = ContentPalette.from_style(style, bg)
      end

      private def slots_unchanged?(slots) : Bool
        slots.each_with_index do |slot, i|
          cached = @slots[i]
          if slot
            return false unless cached && cached.same?(slot) && @slot_revisions[i] == slot.attr_revision
          else
            return false unless cached.nil?
          end
        end
        true
      end
    end
  end
end
