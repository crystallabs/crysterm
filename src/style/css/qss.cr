module Crysterm
  module CSS
    # Translates Qt Style Sheet (`.qss`) source into Crysterm CSS, so Qt themes
    # can be loaded directly. Used by the loading path (`Screen#load_stylesheet`
    # / `Stylesheet.from_file`) whenever the file name ends in `.qss`.
    #
    # Two selector rewrites are applied, in order:
    #
    #   1. The `Q` prefix is stripped from every Qt *type selector*
    #      (`QPushButton` -> `PushButton`); Crysterm's widget classes carry no
    #      `Q`.
    #   2. Names Crysterm spells differently are renamed via `RENAMES`
    #      (`PushButton` -> `Button`, `LineEdit` -> `TextBox`, ...).
    #
    # Only type-selector tokens (a `Q` immediately followed by an upper-case
    # letter) are touched; property names/values, ids, classes and `:state`
    # pseudo-classes are left untouched. The rewritten text is then handed to the
    # ordinary CSS parser, which is already tolerant of anything it doesn't
    # recognise — unknown Qt properties (e.g. `subcontrol-origin`) and
    # pseudo-elements (e.g. `::indicator`) are skipped, never fatal — so an
    # unmapped selector simply matches nothing.
    module Qss
      # Q-stripped Qt selector => Crysterm widget class name.
      #
      # Identical names (`CheckBox`, `ComboBox`, `GroupBox`, `MenuBar`, `Slider`,
      # `Widget`, ...) need no entry: step 1's `Q`-strip already lands them.
      # Qt selectors with no Crysterm analog (`ColumnView`, `ColumnViewGrip`,
      # `PrevNextCalButton`, `TableCornerButton`) and ambiguous ones with no
      # single target (`Dialog`) are intentionally absent — they pass through
      # `Q`-stripped and just match nothing.
      RENAMES = {
        "AbstractButton"     => "Button",
        "AbstractItemView"   => "List",
        "AbstractView"       => "List",
        "AbstractScrollArea" => "ScrollableBox",
        "ScrollArea"         => "ScrollableBox",
        "AbstractSpinBox"    => "SpinBox",
        "CalendarWidget"     => "Calendar",
        "CommandLinkButton"  => "Button",
        "PushButton"         => "Button",
        "MessageBox"         => "Message",
        "Frame"              => "Box",
        "GraphicsView"       => "Canvas",
        "HeaderView"         => "Header",
        "LineEdit"           => "TextBox",
        "ListView"           => "List",
        "PlainTextEdit"      => "TextArea",
        "TextEdit"           => "TextArea",
        "TextBrowser"        => "ScrollableText",
        "TabBar"             => "TabWidget",
        "TableView"          => "Table",
        "TableWidget"        => "Table",
        "TreeView"           => "Tree",
      }

      # Matches a Qt type-selector token: `Q` + a CamelCase identifier. The
      # leading `\b` keeps it from biting into the middle of another identifier
      # (and `Qt`, `Q` + lower-case, never matches since the next char must be
      # upper-case).
      SELECTOR = /\bQ([A-Z][A-Za-z0-9_]*)/

      # Qt `palette(role)` → Crysterm theme custom property `var(--role)`. Maps
      # Qt's `QPalette` color roles onto the eight theme roles (and their shades)
      # published by `CSS::Theme` (see `theme.cr` `ROLES`/`emit_variables`). A
      # role with no entry is left as-is (the parser then ignores it).
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

      # Qt sub-control pseudo-elements (`::name`) → Crysterm sub-element slot.
      # Crysterm matches a slot by its *capitalized* name as a descendant node
      # (e.g. `ProgressBar Indicator`, see `html.cr`/`sub_elements.cr`), not by
      # `::`-syntax, so each mapping rewrites `::name` to ` Name`. Only Qt parts
      # backed by a slot a widget actually renders are mapped — `::chunk` and
      # `::handle` reuse the `Indicator` slot, `::groove` the base `Track`.
      # Unmapped `::name` (`::tab`, `::down-arrow`, …) are left verbatim and
      # simply match nothing.
      #
      # `::section` is intentionally absent: `QHeaderView` already renames to the
      # `Header` node (see `RENAMES`), so `::section` would double it to
      # `Header Header`; the header is reached via the type rename directly.
      SUB_ELEMENTS = {
        "indicator" => "Indicator", # CheckBox/RadioButton/ProgressBar/Slider/Dial
        "item"      => "Item",      # List
        "chunk"     => "Indicator", # QProgressBar::chunk → the filled indicator
        "handle"    => "Indicator", # QSlider::handle    → the slider indicator
        "groove"    => "Track",     # QSlider/QScrollBar::groove → the track
      }

      # Matches a Qt `::pseudo-element` token.
      SUB_ELEMENT = /::([a-z][a-z-]*)/

      # Qt state pseudo-classes that Crysterm can express, mapped to its own
      # syntax. Checkable state becomes complementary boolean *attributes*
      # (Button/CheckBox `css_attributes`) because an attribute selector inside
      # `:not()` doesn't compile; `:enabled` becomes `:not(:disabled)` (the parser
      # lowers `:disabled` to a `.state-disabled` class, which *is* legal inside
      # `:not()`); `:pressed` approximates to `:active` (Crysterm's pressed-ish
      # `Selected` state). States Crysterm already handles (`:hover`, `:focus`,
      # `:disabled`, `:selected`) are deliberately absent — left untouched.
      STATE_PSEUDOS = {
        "checked"       => "[checked]",
        "on"            => "[checked]",
        "unchecked"     => "[unchecked]",
        "off"           => "[unchecked]",
        "indeterminate" => "[indeterminate]",
        "enabled"       => ":not(:disabled)",
        "pressed"       => ":active",
        "horizontal"    => "[horizontal]", # ScrollBar/Slider/ProgressBar/Splitter orientation
        "vertical"      => "[vertical]",
        "editable"      => "[editable]", # ComboBox
      }

      # Matches exactly the Qt state pseudo-classes in `STATE_PSEUDOS` as whole
      # tokens (the trailing lookahead stops `:on` matching inside `:only-one`,
      # etc.). Other `:pseudo` tokens are left for the parser to handle or ignore.
      STATE_PSEUDO = /:(checked|unchecked|indeterminate|enabled|pressed|on|off|horizontal|vertical|editable)(?![\w-])/

      # Rewrites *source* (the contents of a `.qss` file) into Crysterm CSS:
      # `Q`-prefixed type selectors are renamed, Qt `::sub-control` pseudo-elements
      # become descendant sub-element selectors, and `palette(role)` functions
      # become `var(--role)` against the active theme's custom properties.
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
