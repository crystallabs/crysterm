# Single source of truth for Crysterm's own tunables, registered into the shared
# `Superconf` registry. Each `option` mints a config key + env var + CLI flag +
# typed accessor (`Superconf.<key with dots as underscores>`, reachable as
# `Crysterm::Config.<...>` via the alias), and shows up in `Config.dump`
# alongside options registered by tput. These are only *declarations*: until an
# app loads env/args/file, every option holds the default below.
#
# Apps append their own options the same way, anywhere after `require "crysterm"`:
#
# ```
# module Superconf
#   option "myapp.theme", "dark", description: "UI theme"
# end
# Crysterm::Config.myapp_theme # => "dark"
# ```
module Superconf
  # -- Screen ----------------------------------------------------------------
  option "screen.resize_interval", 0.2.seconds,
    description: "Debounce before redrawing after the last terminal-resize event",
    validate: ->(t : Time::Span) { t >= Time::Span.zero }
  option "screen.tab_navigation", true,
    description: "Tab / Shift+Tab move keyboard focus between focusable widgets"
  option "screen.propagate_keys", true,
    description: "Propagate unhandled keypresses up the widget tree"
  option "screen.send_focus", false,
    description: "Emit focus events once the mouse is enabled"
  option "screen.grab_keys", false,
    description: "Route all keypresses to a single grabbing widget"
  option "screen.dock_borders", false,
    description: "Join adjacent widget borders instead of overlapping them"
  option "screen.show_avg", true,
    description: "Include 30-frame averages in the FPS overlay"
  option "screen.force_unicode", false,
    description: "Assume UTF-8 even if terminal auto-detection didn't find it"
  option "screen.full_unicode", false,
    description: "Grapheme / column-width-aware rendering (when the terminal supports Unicode)"
  option "screen.overflow", Crysterm::Overflow::Ignore,
    description: "Policy for widgets larger than their container (ignore|hidden|shrink_widget|skip_widget|stop_rendering|move_widget)"

  # -- Rendering -------------------------------------------------------------
  option "render.frame_interval", 1/29,
    description: "Minimum delay between frames in seconds (the FPS cap)",
    validate: ->(s : Float64) { s > 0 }
  option "render.fps_window", 30,
    description: "Number of frames averaged for the FPS overlay",
    validate: ->(n : Int32) { n > 0 }
  option "render.optimization", Crysterm::OptimizationFlag::None,
    description: "Render/draw optimization flags (fast_csr|smart_csr|bce, comma-separated)"
  option "render.dock_contrast", Crysterm::DockContrast::Blend,
    description: "What to do when docked borders have differing colors (ignore|dont_dock|blend)"
  option "render.csr_threshold", 40,
    description: "FastCSR optimization activates when a widget is within this many columns of a screen edge",
    validate: ->(n : Int32) { n > 0 }

  # -- Cursor ----------------------------------------------------------------
  option "cursor.glyph", '▮',
    description: "Default character drawn for the artificial (software) cursor"

  # -- Focus -----------------------------------------------------------------
  option "focus.history_size", 10,
    description: "How many previously-focused widgets to remember for focus_pop",
    validate: ->(n : Int32) { n >= 1 }

  # -- Colors ----------------------------------------------------------------
  option "colors.default_fg", 0xc0c0c0,
    description: "Neutral RGB substituted for a 'default' foreground when it must be blended",
    validate: ->(c : Int32) { 0 <= c <= 0xFFFFFF }
  option "colors.default_bg", 0x000000,
    description: "Neutral RGB substituted for a 'default' background when it must be blended",
    validate: ->(c : Int32) { 0 <= c <= 0xFFFFFF }

  # -- Images ----------------------------------------------------------------
  option "image.backend", "ansi",
    description: "Default Widget::Image backend (auto|ansi|glyph|overlay|sixel|regis|kitty|tek); 'auto' detects from the terminal"

  # -- Widget defaults -------------------------------------------------------
  option "message.display_time", 3.seconds,
    description: "Default time Widget::Message stays on screen before dismissing",
    validate: ->(t : Time::Span) { t > Time::Span.zero }
  option "loading.interval", 0.2.seconds,
    description: "Default Widget::Loading spinner frame interval",
    validate: ->(t : Time::Span) { t > Time::Span.zero }

  # -- External programs / environment --------------------------------------
  option "input.shell", (ENV["SHELL"]? || "sh"),
    description: "Shell launched by Widget::Terminal"
  option "terminal.term", (ENV["TERM"]? || "xterm"),
    description: "TERM name advertised to programs run inside Widget::Terminal"
  option "terminal.fallback_term", "xterm",
    description: "Terminfo entry used when $TERM is missing or unusable (e.g. headless/CI)"
  option "filemanager.home", (ENV["HOME"]? || "/"),
    description: "Starting directory for Widget::FileManager"
end
