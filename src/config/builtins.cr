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
#
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
  option "screen.default_quit_keys", true,
    description: "Install a default quit handler (q / Ctrl-Q destroy the screen and exit) in the Screen constructor"
  option "screen.send_focus", false,
    description: "Emit focus events once the mouse is enabled"
  option "screen.grab_keys", false,
    description: "Route all keypresses to a single grabbing widget"
  option "screen.dock_borders", false,
    description: "Join adjacent widget borders instead of overlapping them"
  option "screen.headless", Crysterm::Headless::Auto,
    description: "Default a Screen built without explicit IO to a headless (in-memory) connection instead of the real terminal (auto|yes|no): 'auto' decides from whether the app runs interactively (output is a TTY), 'yes' forces headless, 'no' forces a real terminal"
  option "screen.force_unicode", false,
    description: "Assume UTF-8 even if terminal auto-detection didn't find it"
  option "screen.full_unicode", false,
    description: "Grapheme / column-width-aware rendering (when the terminal supports Unicode)"
  option "screen.overflow", Crysterm::Overflow::Ignore,
    description: "Policy for widgets larger than their container (ignore|hidden|shrink_widget|skip_widget|stop_rendering|move_widget)"

  # -- Rendering -------------------------------------------------------------
  option "render.frame_interval", 1/60,
    description: "Minimum delay between frames in seconds (the FPS cap)",
    validate: ->(s : Float64) { s > 0 }
  option "render.fps_window", 30,
    description: "Number of frames averaged by a Widget::Fps overlay's rolling averages",
    validate: ->(n : Int32) { n > 0 }
  option "render.optimization", Crysterm::OptimizationFlag::DamageTracking,
    description: "Render/draw optimization flags (fast_csr|smart_csr|bce|damage_tracking, comma-separated)"
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
  option "colors.theme", Crysterm::CSS::Theme::Choice::Terminal,
    description: "Default CSS theme installed on each Screen (dark|light|terminal|none). 'terminal' derives a palette from the terminal's own probed colors; 'none' disables the built-in theme (CSS then comes only from an author stylesheet)"
  option "colors.stylesheet", "",
    description: "Author CSS applied to each Screen at startup (over the theme), unless the app already set one in code. Either a path to a .css file (read from disk; ~ is expanded and @import resolves relative to it) or inline CSS text (any value containing '{'). Empty = none"
  option "colors.default_fg", 0xc0c0c0,
    description: "Neutral RGB substituted for a 'default' foreground when it must be blended",
    validate: ->(c : Int32) { 0 <= c <= 0xFFFFFF }
  option "colors.default_bg", 0x000000,
    description: "Neutral RGB substituted for a 'default' background when it must be blended",
    validate: ->(c : Int32) { 0 <= c <= 0xFFFFFF }

  # -- CSS units -------------------------------------------------------------
  option "css.px_per_cell", 10.0,
    description: "Pixels per terminal cell when converting CSS `px` lengths to cells (cells = round(px / this); e.g. 200px → 20 cells at 10). A shortcut that seeds the `px` entry of css.unit_divisors; leave at the default to keep the built-in table (or a programmatic Length.divisors tweak) untouched",
    validate: ->(f : Float64) { f > 0 }
  option "css.unit_divisors", "",
    description: "Override CSS unit→cell divisors as a comma map, e.g. 'px=10,pt=7.5,em=1,cm=none' (cells = round(value / divisor); 'none' drops the unit). Merged over the built-in table and applied before css.px_per_cell; empty = leave the table as-is"
  option "css.cell_aspect_ratio", 2.0,
    description: "Terminal cell height ÷ width, used so a vertical absolute CSS length (px/pt/pc/cm/mm/in) spans fewer cells than the same horizontal one (a 200px×200px box renders square). Leave at the default to auto-detect from the terminal's reported pixel size (falling back to 2.0); set explicitly to override detection",
    validate: ->(f : Float64) { f > 0 }

  # -- Images ----------------------------------------------------------------
  option "media.backend", Crysterm::Widget::Media::Backend::Auto,
    description: "Default Widget::Media backend (auto|ansi|glyph|overlay|ueberzug|sixel|regis|kitty|iterm|tek); 'auto' picks the best one the terminal supports"
  option "media.unsupported", Crysterm::Widget::Media::Unsupported::Ignore,
    description: "What a Widget::Media backend does when asked for a feature it can't do (error|ignore)"
  option "media.exclude", "",
    description: "Backends excluded from automatic selection (comma/space separated: kitty,iterm,sixel,glyph,ansi,…); the 'best' is then chosen from the rest"
  option "video.fps", 15.0,
    description: "Maximum frame rate Widget::Video samples a video at",
    validate: ->(f : Float64) { f > 0 }
  option "video.max_size", 240,
    description: "Long-edge pixel size Widget::Video decodes video frames at (terminal boxes are small; smaller = faster, less memory)",
    validate: ->(n : Int32) { n > 0 }
  option "video.max_frames", 600,
    description: "Safety cap on frames Widget::Video decodes eagerly into memory (Tier-1 decoder); longer videos are truncated to this many frames",
    validate: ->(n : Int32) { n > 0 }
  option "media.video_decode", Crysterm::Widget::Media::VideoDecode::Auto,
    description: "Video decode strategy (auto|eager|stream): 'eager' loads all frames into memory (best for short loops), 'stream' decodes on demand at constant memory (best for long videos), 'auto' streams when the estimated frame count exceeds video.max_frames"
  option "media.double_buffer", true,
    description: "Present each animation frame atomically on in-band graphics backends (sixel/regis/kitty/iterm) via synchronized output; Kitty additionally swaps alternating image ids — eliminates tearing and the mid-update blank/flash"

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
