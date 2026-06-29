module Crysterm
  module CSS
    # Translates Qt Style Sheet (`.qss`) source into Crysterm CSS, so Qt themes
    # can be loaded directly. Used by the loading path (`Window#load_stylesheet`
    # / `Stylesheet.from_file`) whenever the file name ends in `.qss`.
    #
    # Two selector rewrites are applied, in order:
    #
    #   1. The `Q` prefix is stripped from every Qt *type selector*
    #      (`QPushButton` -> `PushButton`); Crysterm's widget classes carry no
    #      `Q`.
    #   2. Names Crysterm spells differently are renamed via `RENAMES`
    #      (`PushButton` -> `Button`, `TextEdit` -> `PlainTextEdit`, ...).
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
      # `Widget`, `LineEdit`, `PlainTextEdit`, ...) need no entry: step 1's
      # `Q`-strip already lands them.
      #
      # The Qt *abstract* bases — `QAbstractButton`, `QAbstractItemView`,
      # `QAbstractScrollArea`, `QAbstractSpinBox`, and `QDialog` — also need no
      # entry: Crysterm now has matching `AbstractButton`/`AbstractItemView`/
      # `AbstractScrollArea`/`AbstractSpinBox`/`Dialog` classes in the same place
      # in the hierarchy, so the `Q`-stripped name matches the whole family
      # natively (e.g. `QAbstractButton` styles every button). They used to be
      # faked here by aliasing onto one concrete subclass, which missed the
      # siblings; the real classes do better.
      #
      # Qt selectors with no Crysterm analog (`ColumnView`, `ColumnViewGrip`,
      # `PrevNextCalButton`, `TableCornerButton`) are intentionally absent — they
      # pass through `Q`-stripped and just match nothing.
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

      # *Qt-vocabulary* sub-control pseudo-elements (`::name`) whose Crysterm slot
      # is spelled differently → the slot's capitalized descendant node (e.g.
      # `::chunk` reuses the `Indicator` slot). The *identity* pseudos
      # (`::indicator`, `::item`) are NOT here — `Stylesheet` lowers any `::slot`
      # to its capitalized descendant node natively (see its `lower_sub_elements`)
      # for every stylesheet, so qss inherits them for free. Only the non-identity
      # Qt aliases need a rewrite here, *before* the native pass, so e.g. `::chunk`
      # becomes `Indicator` rather than the non-existent `Chunk` node. Unmapped
      # `::name` pass through to the native lowering: those a widget exposes as a
      # slot (e.g. `Widget::ScrollBar`'s `::add-page`/`::sub-line`/`::up-arrow`,
      # see `sub_elements.cr`) match its capitalized node; the rest (`::tab`, …)
      # match nothing.
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

      # *Genuinely Qt-specific* state pseudo-classes, mapped to Crysterm syntax.
      # Standard-CSS states (`:checked`/`:indeterminate`/`:enabled`) are NOT here —
      # they're lowered natively by `Stylesheet` (see its `ATTR_PSEUDOS`) for every
      # stylesheet, so qss inherits them for free. What remains is Qt vocabulary:
      # `:on`/`:off` (Qt's checkable spelling) and `:unchecked` become the
      # complementary boolean attributes; `:pressed` approximates to `:active`;
      # the non-standard `:horizontal`/`:vertical`/`:editable` map to the
      # orientation/editable attributes. States Crysterm already handles
      # (`:hover`, `:focus`, `:disabled`, `:selected`) are deliberately absent.
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
      # tokens (the trailing lookahead stops `:on` matching inside `:only-one`,
      # etc.). Other `:pseudo` tokens are left for the parser to handle or ignore.
      STATE_PSEUDO = /:(unchecked|pressed|on|off|horizontal|vertical|editable|flat|default)(?![\w-])/

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
