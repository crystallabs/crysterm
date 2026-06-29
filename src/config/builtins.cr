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
  # Parser for a `String?`-valued option (a presence/value environment mirror):
  # the built-in casts cover `String` but not the `String | Nil` union, so these
  # options pass this proc explicitly. A present value is taken verbatim;
  # absence is represented by the `nil` default, never produced here.
  ENV_STRING = ->(s : String) { s.as(String?) }

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
  option "render.synchronized_output", true,
    description: "Bracket each painted frame in a DEC 2026 synchronized update (\\e[?2026h … \\e[?2026l) so the terminal presents it atomically (no flicker/tearing on a multi-write redraw). Harmless and ignored on terminals that don't support it; set false to opt out globally"
  option "render.reduced_motion", false,
    description: "Honor a reduced-motion preference: collapse duration-based animations (CSS transitions, fades, tweens) straight to their final state instead of animating. Decorative looping effects and media playback keep running"

  # -- Cursor ----------------------------------------------------------------
  option "cursor.glyph", '▮',
    description: "Default character drawn for the artificial (software) cursor"

  # -- Mouse -----------------------------------------------------------------
  option "mouse.cursor_shape", false,
    description: "Allow widgets to change the GUI mouse-pointer shape (xterm's OSC 22) while the pointer hovers them — e.g. a hand over a clickable widget, reset to the terminal default on leave. Off by default: it is best-effort (only xterm-class terminals honor OSC 22; most others ignore it) and changes a window the application doesn't otherwise own"

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
  option "colors.depth", Crysterm::ColorDepth::Auto,
    description: "Force the output color depth (auto|none|basic|ansi|xterm256|truecolor). 'auto' uses terminal detection and honors the NO_COLOR / FORCE_COLOR / CLICOLOR[_FORCE] environment variables; the rest pin a fixed depth ('none' = monochrome, with styles like bold still applied)"

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
  option "media.ansi_art_detail", true,
    description: "When decoding ANSI/textmode art (.ans), rasterize each cell at 2x4 sub-cell resolution so the Glyph backend can resolve sub-cell shapes (sharper outlines). Set false to rasterize one averaged colour per cell (softer, but cleaner under the Ansi backend and at 1:1)"
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

  # -- Input -----------------------------------------------------------------
  option "input.readline_keys", true,
    description: "Enable emacs/readline-style editing keys in text inputs: Ctrl-A/Ctrl-E (line start/end), word-wise Ctrl/Alt-Left/Right (+ Alt-B/Alt-F), Ctrl-W (kill word back), Ctrl-U/Ctrl-K (kill to line start/end), Alt-D (kill word forward), and Ctrl-Y (yank from the kill ring). When off, these keys are left unhandled so the application can bind them"

  # -- External programs / environment --------------------------------------
  # These options *are* the channel through which the standard `SHELL` / `TERM` /
  # `HOME` variables reach Crysterm: `env:` binds each to its real OS variable, so
  # the value now flows through the env source (which outranks a config file and
  # the literal default) rather than being baked into the default. The trade-off
  # is that the derived `CRYSTERM_INPUT_SHELL` / `CRYSTERM_TERMINAL_TERM` /
  # `CRYSTERM_FILEMANAGER_HOME` names no longer exist — the real var is the name.
  option "input.shell", "sh", env: "SHELL",
    description: "Shell launched by Widget::Terminal (defaults from $SHELL)"
  option "terminal.term", "xterm", env: "TERM",
    description: "TERM name advertised to programs run inside Widget::Terminal (defaults from $TERM)"
  option "terminal.fallback_term", "xterm",
    description: "Terminfo entry used when $TERM is missing or unusable (e.g. headless/CI)"
  option "terminal.window_helper", nil.as(String?), env: "CRYSTERM_WINDOW_HELPER", parse: ENV_STRING,
    description: "Internal: when set (by Terminal.spawn_window on the child command), the rendezvous socket path that makes this process run as a detached-window helper and exit. Not meant to be set by hand"
  option "filemanager.home", "/", env: "HOME",
    description: "Starting directory for Widget::FileManager (defaults from $HOME)"

  # -- Headless capture (Crysterm's own CRYSTERM_* knobs) -------------------
  # When set, each names a file the screen captures itself into on first render,
  # then exits the interactive loop — see `Screen#capture_from_env`. Presence
  # paths (empty/unset = off), so they are `String?` read via `#presence`.
  option "screen.shot", nil.as(String?), env: "CRYSTERM_SHOT", parse: ENV_STRING,
    description: "When set, path to write a single still PNG of the first rendered frame to, then exit (headless self-capture)"
  option "screen.dump", nil.as(String?), env: "CRYSTERM_DUMP", parse: ENV_STRING,
    description: "When set, path to write a textual `#dump` golden of the first rendered frame to, then exit"
  option "screen.anim", nil.as(String?), env: "CRYSTERM_ANIM", parse: ENV_STRING,
    description: "When set, path to write an animated PNG (APNG) capture to, then exit; tuned by screen.anim_secs / screen.anim_fps"
  option "screen.anim_secs", 5.0, env: "CRYSTERM_ANIM_SECS",
    description: "Duration in seconds of a screen.anim (CRYSTERM_ANIM) capture"
  option "screen.anim_fps", 10, env: "CRYSTERM_ANIM_FPS",
    description: "Frame rate of a screen.anim (CRYSTERM_ANIM) capture"

  # -- Observed environment variables (standard names from the OS / other tools)
  # Mirror externally-defined variables into the registry so they appear in
  # dumps/docs and can be overridden like any other option. Each is bound to its
  # real name via `env:` and modeled as a presence/value `String?` (empty/unset =
  # absent), so callers read `Config.environment_*` instead of the raw variable.
  option "environment.no_color", nil.as(String?), env: "NO_COLOR", parse: ENV_STRING,
    description: "https://no-color.org : when present and non-empty, disables color (monochrome output)"
  option "environment.clicolor", nil.as(String?), env: "CLICOLOR", parse: ENV_STRING,
    description: "https://bixense.com/clicolors : when set to 0, disables color (monochrome output)"
  option "environment.force_color", nil.as(String?), env: "FORCE_COLOR", parse: ENV_STRING,
    description: "Forces a color depth: 0/false off (monochrome), 1/true at least 16, 2 at least 256, 3 truecolor"
  option "environment.clicolor_force", nil.as(String?), env: "CLICOLOR_FORCE", parse: ENV_STRING,
    description: "https://bixense.com/clicolors : when set and non-zero, forces color on (at least 16)"
  option "environment.w3mimgdisplay", nil.as(String?), env: "W3MIMGDISPLAY_ENV", parse: ENV_STRING,
    description: "Explicit path to the w3mimgdisplay helper used by the Media::Overlay backend (tried before the built-in candidate paths)"
  option "environment.tmux", nil.as(String?), env: "TMUX", parse: ENV_STRING,
    description: "Set by tmux when running inside it; presence makes Widget::Terminal open a new tmux window instead of a new session"
  option "environment.terminal", nil.as(String?), env: "TERMINAL", parse: ENV_STRING,
    description: "Preferred terminal-emulator command, tried first when auto-selecting a launcher for a detached window"
  option "environment.xdg_runtime_dir", nil.as(String?), env: "XDG_RUNTIME_DIR", parse: ENV_STRING,
    description: "Per-user runtime directory used for the window-handshake socket (falls back to the system temp dir when unset)"

  # -- Remote control --------------------------------------------------------
  option "remote.enabled", nil.as(String?), env: "CRYSTERM_REMOTE", parse: ENV_STRING,
    description: "When present and non-empty, allows the -Dremote HTTP bridge to start at runtime (overridable in code via Crysterm::Remote.enabled=)"
end
