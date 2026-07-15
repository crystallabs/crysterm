module Crysterm
  module CSS
    # Translates Qt Style Sheet (`.qss`) source into Crysterm CSS, so Qt themes
    # can be loaded directly. Applied whenever a stylesheet file name ends in
    # `.qss`.
    #
    # Two selector rewrites, in order:
    #
    #   1. Strip the `Q` prefix from every Qt *type selector* (`QPushButton` ->
    #      `PushButton`); Crysterm's widget classes carry no `Q`.
    #   2. Rename names Crysterm spells differently via `RENAMES`
    #      (`PushButton` -> `Button`, `TextEdit` -> `PlainTextEdit`, ...).
    #
    # The rewrites are plain text substitutions over the *whole* source, not
    # just the selector portions; the patterns don't occur in real Qt property
    # values. The result goes to the ordinary CSS parser, which tolerates
    # unrecognized properties/pseudo-elements — an unmapped selector just
    # matches nothing.
    module Qss
      # Q-stripped Qt selector => Crysterm widget class name.
      #
      # Names Crysterm spells identically (`CheckBox`, `Slider`, `LineEdit`,
      # ...) and the Qt abstract bases (`QAbstractButton`, `QAbstractItemView`,
      # ...) need no entry — the `Q`-strip already lands them. Qt selectors with
      # no Crysterm analog (`ColumnView`, `PrevNextCalButton`, ...) are
      # intentionally absent and match nothing.
      RENAMES = {
        "AbstractView"      => "List", # QAbstractItemView's older alias; no Crysterm class
        "ScrollArea"        => "ScrollableBox",
        "CalendarWidget"    => "Calendar",
        "CommandLinkButton" => "Button",
        "PushButton"        => "Button",
        "MessageBox"        => "Message",
        "Frame"             => "Box",
        "GraphicsView"      => "Canvas",
        "HeaderView"        => "Header",
        "ListView"          => "List",
        # Qt's rich `TextEdit` folds onto the plain editor (no rich-text widget).
        "TextEdit"    => "PlainTextEdit",
        "TextBrowser" => "ScrollableText",
        "TabBar"      => "TabWidget",
        "TableView"   => "Table",
        "TableWidget" => "Table",
        "TreeView"    => "Tree",
      }

      # Matches a Qt type-selector token: `Q` + a CamelCase identifier. `\b`
      # keeps it from biting into another identifier; `Qt` never matches since
      # the next char must be upper-case.
      SELECTOR = /\bQ([A-Z][A-Za-z0-9_]*)/

      # Qt `palette(role)` → Crysterm theme custom property `var(--role)`,
      # mapping Qt's `QPalette` color roles onto the theme roles published by
      # `CSS::Theme`. A role with no entry is left as-is.
      PALETTE_ROLES = {
        "window"           => "surface",
        "windowtext"       => "text",
        "window-text"      => "text",
        "base"             => "surface-dark",
        "alternatebase"    => "surface-light",
        "alternate-base"   => "surface-light",
        "text"             => "text",
        "button"           => "muted-dark",
        "buttontext"       => "text",
        "button-text"      => "text",
        "brighttext"       => "text",
        "bright-text"      => "text",
        "light"            => "surface-light",
        "midlight"         => "surface-light",
        "mid"              => "muted",
        "dark"             => "muted-dark",
        "shadow"           => "muted-dark",
        "highlight"        => "accent",
        "highlightedtext"  => "accent-fg",
        "highlighted-text" => "accent-fg",
        "link"             => "info",
        "linkvisited"      => "info-dark",
        "link-visited"     => "info-dark",
        "tooltipbase"      => "warning",
        "tooltip-base"     => "warning",
        "tooltiptext"      => "warning-fg",
        "tooltip-text"     => "warning-fg",
        "placeholdertext"  => "muted-light",
        "placeholder-text" => "muted-light",
      }

      # Matches a Qt `palette(role)` color function.
      PALETTE = /palette\(\s*([a-z-]+)\s*\)/i

      # Qt-vocabulary sub-control pseudo-elements (`::name`) whose Crysterm slot
      # is spelled differently → the slot's capitalized descendant node (e.g.
      # `::chunk` reuses the `Indicator` slot). Only non-identity Qt aliases
      # belong here: `Stylesheet` natively lowers any `::slot` to its
      # capitalized descendant node, so the identity pseudos (`::indicator`,
      # `::item`) come free and unmapped names pass through to that lowering.
      #
      # `::section` is intentionally absent: `QHeaderView` already renames to
      # the `Header` node, so `::section` would double it to `Header Header`.
      SUB_ELEMENTS = {
        "chunk"  => "Indicator", # QProgressBar::chunk → the filled indicator
        "handle" => "Indicator", # QSlider::handle    → the slider indicator
        "groove" => "Track",     # QSlider/QScrollBar::groove → the track
      }

      # Matches a Qt `::pseudo-element` token.
      SUB_ELEMENT = /::([a-z][a-z-]*)/

      # Genuinely Qt-specific state pseudo-classes, mapped to Crysterm syntax:
      # `:on`/`:off`/`:unchecked` become the complementary boolean attributes,
      # `:pressed` approximates to `:active`, and the non-standard
      # `:horizontal`/`:vertical`/`:editable` map to attributes. Standard-CSS
      # states (`:checked`/`:indeterminate`/`:enabled`) are lowered natively by
      # `Stylesheet` instead.
      STATE_PSEUDOS = {
        "on"         => "[checked]",
        "unchecked"  => "[unchecked]",
        "off"        => "[unchecked]",
        "pressed"    => ":active",
        "horizontal" => "[horizontal]", # ScrollBar/Slider/ProgressBar/Splitter orientation
        "vertical"   => "[vertical]",
        "editable"   => "[editable]", # ComboBox
        "flat"       => "[flat]",     # Button/GroupBox frameless look
        "default"    => "[default]",  # the dialog's default Button
      }

      # Matches exactly the Qt state pseudo-classes in `STATE_PSEUDOS` as whole
      # tokens (the trailing lookahead stops `:on` matching inside `:only-one`).
      # Other `:pseudo` tokens are left for the parser.
      STATE_PSEUDO = /:(unchecked|pressed|on|off|horizontal|vertical|editable|flat|default)(?![\w-])/

      # Rewrites *source* (a `.qss` file's contents) into Crysterm CSS:
      # `Q`-prefixed type selectors are renamed, Qt `::sub-control`
      # pseudo-elements become descendant sub-element selectors, and
      # `palette(role)` functions become `var(--role)`.
      def self.to_css(source : String) : String
        source = source.gsub(SELECTOR) { RENAMES.fetch($1, $1) }
        source = source.gsub(SUB_ELEMENT) do |match|
          SUB_ELEMENTS[$1]?.try { |slot| " #{slot}" } || match
        end
        source = source.gsub(STATE_PSEUDO) { STATE_PSEUDOS[$1] }
        source.gsub(PALETTE) do |match|
          PALETTE_ROLES[$1.downcase]?.try { |role| "var(--#{role})" } || match
        end
      end
    end
  end
end
