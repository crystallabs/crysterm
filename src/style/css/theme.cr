module Crysterm
  module CSS
    # A color theme expressed in the Motif/CDE spirit: the author picks a small
    # set of **primary** colors and the rest of the palette is *derived* from
    # them, so a whole consistent look falls out of a handful of inputs.
    #
    # Concretely there are **8 primaries** (one per semantic role) and, for each,
    # **5 derived shades** — `base`, `light` (top-shadow/highlight), `dark`
    # (bottom-shadow), `select` (selection tint) and `fg` (a readable foreground
    # on that color). That is the classic Motif "8 colors, 40 derived" palette
    # (48 entries total), reused here for terminal widgets.
    #
    # A `Theme` renders to a `Stylesheet` (`#to_css` / `#stylesheet`) that is
    # installed as the CSS *default* stylesheet (`CSS.default_stylesheet`), so
    # every widget is styled by CSS out of the box; author stylesheets layer on
    # top and override it.
    #
    # Three ready-made themes are provided:
    #
    # * `Theme.dark` / `Theme.light` — fixed, hand-picked palettes.
    # * `Theme.from_terminal` — the "no theme" mode: it reads the terminal's own
    #   default background/foreground and 16-color palette (probed by `tput`) and
    #   *derives a matching theme*, so the app blends into the user's terminal
    #   colors instead of imposing its own.
    struct Theme
      # The eight semantic roles. Each is one primary color from which five
      # shades are derived; their names become the CSS custom-property prefixes
      # (`--surface`, `--surface-light`, ... `--accent-fg`, ...).
      ROLES = %w[surface text accent muted success warning danger info]

      getter name : String

      # Whether this is a dark theme (light text on dark surfaces). Drives the
      # direction of a few derivations and the readable-foreground choice.
      getter? dark : Bool

      # The eight primaries, keyed by role name (see `ROLES`).
      getter primaries : Hash(String, Int32)

      # Whether to actually paint the base surface background / base text color.
      # The terminal theme leaves these off when it couldn't detect the
      # terminal's real colors, so the terminal's own background shows through
      # (`-1`/default) rather than guessing.
      getter? paint_surface : Bool
      getter? paint_text : Bool

      def initialize(@name, @dark, @primaries, @paint_surface = true, @paint_text = true)
      end

      # Built-in dark theme (Catppuccin-Mocha-flavored).
      def self.dark : Theme
        new "dark", true, {
          "surface" => 0x1e1e2e,
          "text"    => 0xcdd6f4,
          "accent"  => 0x89b4fa,
          "muted"   => 0x585b70,
          "success" => 0xa6e3a1,
          "warning" => 0xf9e2af,
          "danger"  => 0xf38ba8,
          "info"    => 0x94e2d5,
        }
      end

      # Built-in light theme (Catppuccin-Latte-flavored).
      def self.light : Theme
        new "light", false, {
          "surface" => 0xeff1f5,
          "text"    => 0x4c4f69,
          "accent"  => 0x1e66f5,
          "muted"   => 0xacb0be,
          "success" => 0x40a02b,
          "warning" => 0xdf8e1d,
          "danger"  => 0xd20f39,
          "info"    => 0x179299,
        }
      end

      # The "no theme" theme: derive a palette from the *terminal's own* probed
      # colors. *bg*/*fg* are the terminal default background/foreground and
      # *palette* its 16 ANSI colors (any may be `nil` if the terminal didn't
      # answer the probe); missing values fall back to the built-in dark theme,
      # and an undetected surface/text is left as the terminal default so the
      # native background shows through.
      def self.from_terminal(bg : Int32?, fg : Int32?, palette : Array(Int32?)) : Theme
        # Decide polarity from the detected background (default: dark).
        is_dark = bg ? Colors.luminance(bg) < 0.5 : true
        base = is_dark ? dark : light

        ansi = ->(i : Int32) { palette[i]? }
        prim = base.primaries.dup
        prim["surface"] = bg if bg
        prim["text"] = fg if fg
        prim["danger"] = ansi.call(1) || prim["danger"]
        prim["success"] = ansi.call(2) || prim["success"]
        prim["warning"] = ansi.call(3) || prim["warning"]
        prim["accent"] = ansi.call(4) || prim["accent"]
        prim["info"] = ansi.call(6) || prim["info"]
        prim["muted"] = ansi.call(8) || prim["muted"]

        new "terminal", is_dark, prim, paint_surface: !bg.nil?, paint_text: !fg.nil?
      end

      # --- derivation --------------------------------------------------------

      # The five shades derived from a primary *base*: `{base, light, dark,
      # select, fg}`. `light`/`dark` step the lightness; `select` is a subtle
      # highlight relative to the surface direction; `fg` is whichever of a near-
      # black / near-white reads best on *base*.
      def shades(role : String) : NamedTuple(base: Int32, light: Int32, dark: Int32, select: Int32, fg: Int32)
        base = @primaries[role]
        {
          base:   base,
          light:  Colors.lighten(base, 0.10),
          dark:   Colors.darken(base, 0.10),
          select: dark? ? Colors.lighten(base, 0.06) : Colors.darken(base, 0.06),
          fg:     Colors.readable_on(base, 0x101010, 0xf5f5f5),
        }
      end

      # --- stylesheet generation --------------------------------------------

      # The full default-stylesheet CSS text for this theme: the 48 palette
      # custom properties followed by the widget rules that consume them.
      def to_css : String
        String.build do |io|
          emit_variables io
          # Base surface/text first, then the specific widget rules. Order
          # matters: crysterm type selectors all carry equal specificity
          # (`.Button` and its base `.Input` are both one class), so ties break
          # on source order — generic types and normal states must precede
          # specific subclasses and their `:focus`/`:hover` rules for the
          # subclass/state to win.
          emit_surface_rules io
          io << WIDGET_RULES
        end
      end

      # Parses `#to_css` into a `Stylesheet` ready to install as the default.
      def stylesheet : Stylesheet
        Stylesheet.parse to_css
      end

      # Emits the `--role[-shade]: #rrggbb;` custom properties (carried on a
      # `Screen` block; the parser collects custom properties globally, so no
      # actual `Screen` rule is produced).
      private def emit_variables(io : IO) : Nil
        io << "Screen {\n"
        ROLES.each do |role|
          s = shades(role)
          io << "  --" << role << ": " << Colors.hex(s[:base]) << ";\n"
          io << "  --" << role << "-light: " << Colors.hex(s[:light]) << ";\n"
          io << "  --" << role << "-dark: " << Colors.hex(s[:dark]) << ";\n"
          io << "  --" << role << "-select: " << Colors.hex(s[:select]) << ";\n"
          io << "  --" << role << "-fg: " << Colors.hex(s[:fg]) << ";\n"
        end
        io << "}\n"
      end

      # The base surface/text rules, emitted only when this theme paints them
      # (the terminal theme may leave them to the terminal's own default).
      private def emit_surface_rules(io : IO) : Nil
        io << "\nBox { background-color: var(--surface); }\n" if paint_surface?
        io << "Widget { color: var(--text); }\n" if paint_text?
      end

      # The structural widget rules, identical across themes — only the variable
      # *values* differ. Kept as a single CSS string so the look is auditable in
      # one place. Each rule is overridable by an author stylesheet (these are
      # tier-0 defaults).
      WIDGET_RULES = <<-CSS

      /* Editable fields (Button is an Input subclass, so this comes first and
         the Button rules below win the equal-specificity tie via source order). */
      Input, TextBox, TextArea, SpinBox, DoubleSpinBox, ComboBox { background-color: var(--surface-dark); color: var(--text); }
      Input:focus, TextBox:focus, TextArea:focus, SpinBox:focus, DoubleSpinBox:focus, ComboBox:focus { background-color: var(--surface-light); }

      /* Buttons (after Input so they win the tie) */
      Button { background-color: var(--muted-dark); color: var(--text); }
      Button:hover { background-color: var(--muted); }
      Button:focus { background-color: var(--accent); color: var(--accent-fg); }
      Button:disabled { color: var(--muted-light); }

      /* Framed containers */
      GroupBox { border: solid; border-color: var(--muted); }
      /* Overlays sit on their own compositing planes (z-index) so they layer
         correctly over content, with a slight translucency for a modern look —
         all via the general compositor, no overlay-specific code. */
      Menu { border: solid; border-color: var(--muted); background-color: var(--surface-light); z-index: 10; opacity: 0.96; }
      .popup { border: solid; border-color: var(--muted); background-color: var(--surface-light); z-index: 10; opacity: 0.96; }

      /* Scrollbars and progress indicators. The scrollbar is a real widget
         (.scrollbar) on a thin translucent plane so content shows faintly through. */
      .scrollbar { color: var(--muted); z-index: 5; opacity: 0.82; }
      Track { color: var(--surface-dark); }
      ProgressBar Bar, Slider Bar, Dial Bar { color: var(--accent); }

      /* Tables */
      Header { background-color: var(--muted-dark); color: var(--text); font-weight: bold; }

      /* Bars and chrome */
      MenuBar, ToolBar { background-color: var(--muted-dark); color: var(--text); }
      StatusBar { background-color: var(--muted-dark); color: var(--text); }
      ListBar Prefix { color: var(--info); }

      /* Tooltips */
      ToolTip { background-color: var(--warning); color: var(--warning-fg); z-index: 10; opacity: 0.96; }

      /* Migrated chrome looks (see widgets that drop their hardcoded styles) */
      .titlebar, .titlebutton { background-color: var(--accent); color: var(--accent-fg); }
      .divider { background-color: var(--muted); }
      .search { background-color: var(--accent); color: var(--accent-fg); }

      /* Selection highlight — `Box` is the base of (almost) every visible
         widget, so this matches broadly at the same specificity as the base
         surface rule and, coming last, wins the selected state. Widgets that
         paint their selected row from `styles.selected` (List, Menu, ...) pick
         this up too. */
      Box:selected { background-color: var(--accent); color: var(--accent-fg); }
      CSS
    end

    # The currently active theme, or `nil` when styling is not theme-driven
    # (CSS then comes purely from an author stylesheet, if any).
    @@active_theme : Theme? = nil

    def self.theme : Theme?
      @@active_theme
    end

    # Installs *theme* as the active theme: its generated stylesheet becomes the
    # CSS *default* (user-agent) stylesheet, so every screen is styled by it out
    # of the box. Passing `nil` clears the theme and empties the default
    # stylesheet (back to "no theme"). Setting this — or a non-empty
    # `default_stylesheet` — before the first `Screen` is created suppresses the
    # automatic config-driven theme.
    def self.theme=(theme : Theme?) : Theme?
      @@active_theme = theme
      self.default_stylesheet = theme ? theme.stylesheet : Stylesheet.new
      theme
    end

    # Whether the one-time config-driven theme resolution has already happened.
    @@theme_resolved = false

    # Resolves and installs the theme named by `Config.colors_theme` the first
    # time a screen is created, unless the app already chose a theme (or set a
    # non-empty default stylesheet). *screen* supplies the terminal probe data
    # the `"terminal"`/`"auto"` theme derives from.
    def self.ensure_theme(screen) : Nil
      return if @@theme_resolved
      @@theme_resolved = true
      return if @@active_theme || !default_stylesheet.rules.empty?
      if theme = resolve_config_theme(screen)
        self.theme = theme
      end
    end

    # Maps the `colors.theme` config value to a `Theme` (`nil` for "no theme").
    def self.resolve_config_theme(screen) : Theme?
      case Crysterm::Config.colors_theme.to_s.downcase
      when "none", "off", "" then nil
      when "dark"            then Theme.dark
      when "light"           then Theme.light
      else                        screen.terminal_theme # "terminal" / "auto" / unknown
      end
    end
  end
end
