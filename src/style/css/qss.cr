module Crysterm
  module CSS
    # Translates Qt Style Sheet (`.qss`) source into Crysterm CSS, so Qt themes
    # can be loaded directly. Used by `Window#load_stylesheet` /
    # `Stylesheet.from_file` whenever the file name ends in `.qss`.
    #
    # Two selector rewrites, in order:
    #
    #   1. Strip the `Q` prefix from every Qt *type selector* (`QPushButton` ->
    #      `PushButton`); Crysterm's widget classes carry no `Q`.
    #   2. Rename names Crysterm spells differently via `RENAMES`
    #      (`PushButton` -> `Button`, `TextEdit` -> `PlainTextEdit`, ...).
    #
    # The rewrites are plain text substitutions applied over the *whole* source
    # (not just the selector portions), so in principle a property value that
    # happens to spell a `Q`+CamelCase token, a Qt `:state` word, a `::name`, or
    # `palette(...)` would be rewritten too. In practice this is harmless: the
    # patterns (`Q` + upper-case letter, whole-token Qt state keywords, `::`
    # pseudo-elements, `palette()`) don't occur in real Qt property values, and
    # `palette()` in a value is exactly what we *do* want to rewrite. The
    # rewritten text then goes to the ordinary CSS parser, which tolerates
    # unrecognized properties/pseudo-elements — an unmapped selector just
    # matches nothing.
    module Qss
      # Q-stripped Qt selector => Crysterm widget class name.
      #
      # Identical names (`CheckBox`, `ComboBox`, `GroupBox`, `MenuBar`, `Slider`,
      # `Widget`, `LineEdit`, `PlainTextEdit`, ...) need no entry: step 1's
      # `Q`-strip already lands them.
      #
      # The Qt abstract bases (`QAbstractButton`, `QAbstractItemView`,
      # `QAbstractScrollArea`, `QAbstractSpinBox`, `QDialog`) also need no entry:
      # Crysterm has matching classes in the same place in the hierarchy, so the
      # `Q`-stripped name matches the whole family natively.
      #
      # Qt selectors with no Crysterm analog (`ColumnView`, `ColumnViewGrip`,
      # `PrevNextCalButton`, `TableCornerButton`) are intentionally absent —
      # they pass through `Q`-stripped and just match nothing.
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
        # Qt's rich `TextEdit` folds onto our plain editor (no rich-text widget
        # yet); `LineEdit`/`PlainTextEdit` are identical and need no entry.
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

      # Qt `palette(role)` → Crysterm theme custom property `var(--role)`. Maps
      # Qt's `QPalette` color roles onto the eight theme roles (and shades)
      # published by `CSS::Theme` (see `theme.cr` `ROLES`/`emit_variables`). A
      # role with no entry is left as-is.
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
      # `::chunk` reuses the `Indicator` slot). The identity pseudos
      # (`::indicator`, `::item`) are NOT here — `Stylesheet` lowers any
      # `::slot` to its capitalized descendant node natively (see
      # `lower_sub_elements`) for every stylesheet, so qss inherits them for
      # free. Only non-identity Qt aliases need a rewrite here, before the
      # native pass, so e.g. `::chunk` becomes `Indicator` rather than the
      # non-existent `Chunk` node. Unmapped `::name` pass through to the native
      # lowering (widget-exposed slots match; the rest match nothing).
      #
      # `::section` is intentionally absent: `QHeaderView` already renames to the
      # `Header` node (see `RENAMES`), so `::section` would double it to
      # `Header Header`; the header is reached via the type rename directly.
      SUB_ELEMENTS = {
        "chunk"  => "Indicator", # QProgressBar::chunk → the filled indicator
        "handle" => "Indicator", # QSlider::handle    → the slider indicator
        "groove" => "Track",     # QSlider/QScrollBar::groove → the track
      }

      # Matches a Qt `::pseudo-element` token.
      SUB_ELEMENT = /::([a-z][a-z-]*)/

      # Genuinely Qt-specific state pseudo-classes, mapped to Crysterm syntax.
      # Standard-CSS states (`:checked`/`:indeterminate`/`:enabled`) are NOT
      # here — `Stylesheet` lowers them natively (see `ATTR_PSEUDOS`) for every
      # stylesheet. What remains is Qt vocabulary: `:on`/`:off`/`:unchecked`
      # become the complementary boolean attributes; `:pressed` approximates to
      # `:active`; the non-standard `:horizontal`/`:vertical`/`:editable` map
      # to the orientation/editable attributes.
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
