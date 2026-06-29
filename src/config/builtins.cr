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

module Crysterm
  # Forced colour-depth policy, derived from the standard colour-convention
  # environment variables. A single value resolved from *several* env vars (see
  # `.color_force_from_env`) and exposed as the one `screen.color_force` option,
  # rather than one option per variable. `resolve_color_depth` turns it into a
  # concrete count with the terminal-detected count in hand; `Min16` / `Min256`
  # never *lower* the detected depth.
  enum ColorForce
    None      # no env directive: use the detected count
    Mono      # force monochrome (count 1)
    Min16     # force colour on, at least 16
    Min256    # force colour on, at least 256
    Truecolor # force full 24-bit colour
  end

  # Resolve the colour-force policy from the colour-convention env vars in their
  # historical precedence: `NO_COLOR` (present/non-empty), then `CLICOLOR=0`,
  # then `FORCE_COLOR`'s level, then a non-zero `CLICOLOR_FORCE`. Read once to
  # seed the `screen.color_force` option default (so a config file / CLI flag
  # still outranks it, and the per-frame path reads one resolved enum).
  def self.color_force_from_env : ColorForce
    # https://no-color.org : NO_COLOR present and non-empty disables color.
    return ColorForce::Mono if ENV["NO_COLOR"]?.presence
    # https://bixense.com/clicolors : CLICOLOR=0 disables; CLICOLOR_FORCE!=0 forces.
    return ColorForce::Mono if ENV["CLICOLOR"]? == "0"
    # FORCE_COLOR selects a depth: 0/false off, 1/true 16, 2 256, 3 truecolor.
    if v = ENV["FORCE_COLOR"]?
      case v
      when "0", "false" then return ColorForce::Mono
      when "2"          then return ColorForce::Min256
      when "3"          then return ColorForce::Truecolor
      else                   return ColorForce::Min16
      end
    end
    return ColorForce::Min16 if (v = ENV["CLICOLOR_FORCE"]?) && v != "0"
    ColorForce::None
  end
end

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
  # The standard `SHELL` / `TERM` / `HOME` (and the CRYSTERM_* knobs below) reach
  # Crysterm as the *default* of these options — read once from the environment at
  # registration. Sourcing the env var in the default (rather than binding `env:`
  # to the real variable) keeps a config file or CLI flag outranking the OS
  # variable, so there is no env-over-config surprise. Each option still gets its
  # own derived CRYSTERM_* env/CLI surface for explicit overrides.
  option "input.shell", (ENV["SHELL"]? || "sh"),
    description: "Shell launched by Widget::Terminal (defaults from $SHELL)"
  option "terminal.term", (ENV["TERM"]? || "xterm"),
    description: "TERM name advertised to programs run inside Widget::Terminal (defaults from $TERM)"
  option "terminal.fallback_term", "xterm",
    description: "Terminfo entry used when $TERM is missing or unusable (e.g. headless/CI)"
  option "terminal.window_helper", ENV["CRYSTERM_WINDOW_HELPER"]?, parse: ENV_STRING,
    description: "Internal: when set (by Terminal.spawn_window on the child command), the rendezvous socket path that makes this process run as a detached-window helper and exit. Not meant to be set by hand"
  option "filemanager.home", (ENV["HOME"]? || "/"),
    description: "Starting directory for Widget::FileManager (defaults from $HOME)"

  # -- Headless capture (Crysterm's own CRYSTERM_* knobs) -------------------
  # Read once at registration as the option default (so config/CLI still win).
  # When set, each names a file the screen captures itself into on first render,
  # then exits the interactive loop — see `Screen#capture_from_env`. Presence
  # paths (empty/unset = off), read via `#presence` at the call site.
  option "screen.shot", ENV["CRYSTERM_SHOT"]?, parse: ENV_STRING,
    description: "When set, path to write a single still PNG of the first rendered frame to, then exit (headless self-capture)"
  option "screen.dump", ENV["CRYSTERM_DUMP"]?, parse: ENV_STRING,
    description: "When set, path to write a textual `#dump` golden of the first rendered frame to, then exit"
  option "screen.anim", ENV["CRYSTERM_ANIM"]?, parse: ENV_STRING,
    description: "When set, path to write an animated PNG (APNG) capture to, then exit; tuned by screen.anim_secs / screen.anim_fps"
  option "screen.anim_secs", (ENV["CRYSTERM_ANIM_SECS"]?.try(&.to_f?) || 5.0),
    description: "Duration in seconds of a screen.anim (CRYSTERM_ANIM) capture"
  option "screen.anim_fps", (ENV["CRYSTERM_ANIM_FPS"]?.try(&.to_i?) || 10),
    description: "Frame rate of a screen.anim (CRYSTERM_ANIM) capture"

  # -- Observed environment variables (standard names from the OS / other tools)
  # Mirror externally-defined variables into the registry so they appear in
  # dumps/docs and can be overridden like any other option. Each is read once at
  # registration as its option default (config/CLI still outrank it) and modeled
  # as a presence/value `String?`, so callers read `Config.environment_*` instead
  # of the raw variable.
  option "screen.color_force", Crysterm.color_force_from_env,
    description: "Forced colour-depth policy resolved at startup from the standard colour-convention env vars NO_COLOR / CLICOLOR / FORCE_COLOR / CLICOLOR_FORCE (precedence in that order). Override directly to force none|mono|min16|min256|truecolor regardless of the environment"
  option "environment.w3mimgdisplay", ENV["W3MIMGDISPLAY_ENV"]?, parse: ENV_STRING,
    description: "Explicit path to the w3mimgdisplay helper used by the Media::Overlay backend (tried before the built-in candidate paths)"
  option "environment.tmux", ENV["TMUX"]?, parse: ENV_STRING,
    description: "Set by tmux when running inside it; presence makes Widget::Terminal open a new tmux window instead of a new session"
  option "environment.terminal", ENV["TERMINAL"]?, parse: ENV_STRING,
    description: "Preferred terminal-emulator command, tried first when auto-selecting a launcher for a detached window"
  option "environment.xdg_runtime_dir", ENV["XDG_RUNTIME_DIR"]?, parse: ENV_STRING,
    description: "Per-user runtime directory used for the window-handshake socket (falls back to the system temp dir when unset)"

  # -- Remote control --------------------------------------------------------
  option "remote.enabled", ENV["CRYSTERM_REMOTE"]?, parse: ENV_STRING,
    description: "When present and non-empty, allows the -Dremote HTTP bridge to start at runtime (overridable in code via Crysterm::Remote.enabled=)"
end
