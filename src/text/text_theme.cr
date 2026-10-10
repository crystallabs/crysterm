module Crysterm
  # Colors the interchange importers give semantic elements that have no
  # terminal-native appearance of their own — a heading or code span has to
  # become *some* color on a cell grid. Two built-in palettes, `.dark` and
  # `.light`, read well on dark and on light surfaces; `.for_colors` picks and
  # adapts one to a widget's actual background, which is how a `TextEdit`
  # follows the active CSS theme/stylesheet (see `Widget::TextEdit#theme`).
  # Exporters must never read the theme: they key on the semantic properties
  # (`heading_level`, `TextCharFormat#code?`, `anchor_href`) instead, so a
  # retheme cannot break round-trips.
  record TextTheme,
    heading_color : Int32 = 0x86B5FF,
    code_color : Int32 = 0xE0A85C,
    code_bg : Int32 = 0x202833,
    quote_color : Int32 = 0x86C58A,
    link_color : Int32 = 0x4FB6E6,
    rule_color : Int32 = 0x404A57,
    muted_color : Int32 = 0x808A96 do
    # The palette for dark surfaces — also the all-defaults instance
    # (`.default`), so an untouched document colors as it always has.
    class_getter dark : TextTheme = new

    # :ditto:
    def self.default : TextTheme
      dark
    end

    # The palette for light surfaces.
    class_getter light : TextTheme = new(
      heading_color: 0x1F5FBF,
      code_color: 0xA3400A,
      code_bg: 0xE2E4E8,
      quote_color: 0x2E8540,
      link_color: 0x0B6FA4,
      rule_color: 0xB5BBC4,
      muted_color: 0x6B7480,
    )

    # Lightness steps `.for_colors` moves a known background by to set code
    # blocks apart from it: a touch lighter on a dark surface, darker on a
    # light one.
    CODE_BG_LIFT_DARK  = 0.07
    CODE_BG_LIFT_LIGHT = 0.06

    # The palette matching a surface: `.light` when *bg* is a light color,
    # `.dark` otherwise, with `code_bg` derived from *bg* itself so code blocks
    # sit on the surface they are read on rather than on a palette constant.
    # *bg* is a `0xRRGGBB` color, or `nil`/`-1` for the terminal default, in
    # which case *dark* (the terminal's probed darkness; dark by default) picks
    # the palette and its own `code_bg` stands.
    def self.for_colors(bg : Int32?, dark : Bool = true) : TextTheme
      if bg.nil? || bg < 0
        return dark ? self.dark : self.light
      end
      if Colors.luminance(bg) < 0.5
        self.dark.copy_with(code_bg: Colors.lighten(bg, CODE_BG_LIFT_DARK))
      else
        self.light.copy_with(code_bg: Colors.darken(bg, CODE_BG_LIFT_LIGHT))
      end
    end

    # Every color of this theme, in a fixed order, so two themes can be
    # matched color for color (see `TextDocument#theme=`).
    def colors : Array(Int32)
      [@heading_color, @code_color, @code_bg, @quote_color, @link_color, @rule_color, @muted_color]
    end
  end
end
