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

      # Rewrites *source* (the contents of a `.qss` file) into Crysterm CSS:
      # `Q`-prefixed type selectors are renamed, and `palette(role)` functions
      # become `var(--role)` against the active theme's custom properties.
      def self.to_css(source : String) : String
        source = source.gsub(SELECTOR) { RENAMES.fetch($1, $1) }
        source.gsub(PALETTE) do |match|
          PALETTE_ROLES[$1.downcase]?.try { |role| "var(--#{role})" } || match
        end
      end
    end
  end
end
