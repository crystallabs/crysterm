require "./macros"

require "./screen_attributes"
require "./screen_cursor"
require "./screen_input"
require "./screen_mouse_device"
require "./screen_osc"

module Crysterm
  # How a `Screen` built without explicit IO chooses between a real terminal and
  # a headless (in-memory) connection. See `Crysterm.headless?`.
  enum Headless
    Auto # Decide automatically: headless iff the app is non-interactive (output is not a TTY)
    Yes  # Always headless, even on a real terminal
    No   # Always use the real terminal, even when non-interactive
  end

  # Explicit output color-depth override, independent of what the terminal
  # advertises. Drives color reduction at output time.
  enum ColorDepth
    Auto      # Terminal detection (+ the NO_COLOR / FORCE_COLOR / CLICOLOR env vars)
    None      # Monochrome: emit no color (styles like bold still apply)
    Basic     # 8 ANSI colors
    Ansi      # 16 ANSI colors (8 normal + 8 bright)
    Xterm256  # 256-color palette
    TrueColor # 24-bit RGB

    # The terminal color-count this depth maps to in `Screen#colors` terms.
    # `Auto` has no fixed count and returns `nil`.
    def to_count : Int32?
      case self
      in Auto      then nil
      in None      then 1
      in Basic     then 8
      in Ansi      then 16
      in Xterm256  then 256
      in TrueColor then 0x1000000
      end
    end
  end

  # The physical terminal/device — the `QScreen` analogue of the Qt object
  # model. Owns everything binding Crysterm to a concrete tty: the IO fds, the
  # `Tput` control-sequence generator, the statically-derived `DrawCaps`, the
  # device cell size (`width`/`height`), the output color depth and SGR
  # encoding, and the terminal's pixel cell geometry.
  #
  # A `Window` (the surface) *has-a* `Screen` and delegates to it. Splitting the
  # device out lets one app drive multiple ttys, and powers detach/reattach: a
  # `Window` survives while its `Screen` is rebuilt.
  class Screen
    # Input IO.
    #
    # NOTE: never `STDIN.dup` — the `initialize(@input = @input)` default is
    # evaluated on *every* `Screen.new`, and a dup'd IO aliases the same fd with
    # `close_on_finalize=true`, so a discarded alias closes the shared STDIN fd
    # on GC. Use the std stream directly.
    property input : IO = Screen.default_input

    # Output IO. See the note on `input` re: not using `STDOUT.dup`.
    property output : IO = Screen.default_output

    # Error IO (could redirect error output to a particular widget). See the
    # note on `input` re: not using `STDERR.dup`.
    property error : IO = Screen.default_error

    # Default input/output/error IO for a `Screen` (or `Direct`) built without
    # explicit streams: the real std stream when interactive, else a fresh
    # per-call `IO::Memory` so a headless connection has its own buffer and
    # headless input reads never consume rendered output.
    def self.default_input : IO
      Crysterm.headless? ? IO::Memory.new : STDIN
    end

    # :ditto:
    def self.default_output : IO
      Crysterm.headless? ? IO::Memory.new : STDOUT
    end

    # :ditto:
    def self.default_error : IO
      Crysterm.headless? ? IO::Memory.new : STDERR
    end

    # Force Unicode (UTF-8) even if terminfo auto-detection did not find support for it?
    property? force_unicode : Bool = Config.screen_force_unicode

    # Which set of chrome glyphs widgets pick from the `Glyphs` registry
    # (`ascii` / `unicode` / `extended`). A proactive *choice* of characters —
    # the reactive draw-time ACS/`ascii_fallback` reduction still applies on
    # terminals that can't render the chosen set. Left at its `screen.glyphs`
    # default, a device on a real tty auto-upgrades to `extended` on a
    # modern-font terminal; an explicit config value or `#glyph_tier=` pins the
    # tier and disables auto-detection.
    getter glyph_tier : Glyphs::Tier = Config.screen_glyphs

    # Whether the tier was chosen explicitly — from env/file/CLI/runtime rather
    # than the registered default. Pins `glyph_tier` against `#auto_glyph_tier`.
    getter? glyph_tier_explicit : Bool = !Config["screen.glyphs"].source.default?

    # Explicitly chooses the glyph tier, pinning it against auto-detection.
    def glyph_tier=(value : Glyphs::Tier)
      @glyph_tier_explicit = true
      @glyph_tier = value
    end

    # User option: enable grapheme/full-Unicode-aware rendering — text is
    # measured and laid out by terminal **column width** (`Crysterm::Unicode`)
    # rather than one column per codepoint, grapheme clusters stay intact, and
    # wide characters occupy two cells.
    @full_unicode : Bool = Config.screen_full_unicode

    # :ditto:
    def full_unicode=(@full_unicode : Bool)
    end

    # Whether grapheme/column-width-aware rendering is *in effect*: the
    # `full_unicode` option is on AND the terminal can render Unicode. The
    # single gate consulted by the content engine, renderer, and drawer.
    def full_unicode? : Bool
      @full_unicode && tput.features.unicode?
    end

    # The raw `full_unicode` *option* as requested, before the `#full_unicode?`
    # terminal-capability gate applies. Used when copying options to a new device.
    def full_unicode_requested? : Bool
      @full_unicode
    end

    # Device width, in cells.
    property width = 1

    # Device height, in cells.
    property height = 1

    # Whether `width` / `height` were each given explicitly to the constructor.
    # A pinned axis must not be overwritten by the size probed from the terminal.
    # Kept per-axis so an **inline** window can pin its `height` (its reserved
    # region size) while its `width` still tracks the terminal.
    getter? explicit_width = false

    # :ditto:
    getter? explicit_height = false

    # Whether either axis is pinned (device size doesn't fully follow the
    # terminal).
    def explicit_size? : Bool
      @explicit_width || @explicit_height
    end

    # Terminal cell size in pixels, detected once at startup (`0` = terminal
    # reported none). Set by `#detect_cell_geometry`; drives the CSS cell
    # aspect ratio and is a source for pixel-addressed graphics.
    property cell_pixel_width = 0
    property cell_pixel_height = 0

    # Instance of `Tput`, used for generating term control sequences.
    getter tput : ::Tput

    # Per-terminal draw capabilities, derived once per `@tput` via
    # `#compute_draw_caps` rather than re-queried every frame. Includes the
    # static, parameter-free sequence bytes (`smacs`/`rmacs`/`el`) the drawer
    # writes straight into the frame buffer.
    record DrawCaps,
      has_bce : Bool,
      parm_right_cursor : Bool,
      alt_charset : Bool,
      broken_acs : Bool,
      term_unicode : Bool,
      u8 : Int32?,
      ncolors : Int32,
      acscr : Hash(Char, Char),
      smacs : Bytes,
      rmacs : Bytes,
      el : Bytes,
      # Cursor-bracket sequences (`sc`/`rc`/`civis`/`cnorm`, with
      # DECSC/DECRC/DECTCEM ANSI fallbacks) used to wrap each painted frame in
      # save+hide … restore+show, so the hardware cursor doesn't streak across
      # the multi-write redraw. Captured once: going through `tput.save_cursor`/…
      # per frame re-`dup`s the capability and costs ~48-80 B of garbage a frame.
      save_cursor : Bytes,
      restore_cursor : Bytes,
      hide_cursor : Bytes,
      show_cursor : Bytes,
      # Whether tput verified the terminal's `cup`/`cuf`/… are byte-for-byte
      # standard ANSI. When true, hot-path cursor moves are emitted as direct
      # inline ANSI; when false they route through tput for a non-conforming
      # terminal.
      ansi_cursor : Bool

    # The per-terminal draw capabilities. Must be recomputed wherever `@tput` is
    # created or re-probed, so it is never derived per frame.
    getter draw_caps : DrawCaps

    # The `Application` this device is registered with — the dispatcher the
    # input read fiber routes parsed events to. The fiber falls back to
    # `Application.global` while nil.
    property application : Application? = nil

    def initialize(
      @input = @input,
      @output = @output,
      @error = @error,
      @force_unicode = @force_unicode,
      @full_unicode = @full_unicode,
      width : Int32? = nil,
      height : Int32? = nil,
      terminfo : Bool | Unibilium = true,
    )
      terminfo = case terminfo
                 in true
                   begin
                     Unibilium.from_env
                   rescue Unibilium::Error
                     # No usable terminfo for $TERM (e.g. unset, as on CI
                     # runners); fall back so a Screen is still constructible.
                     Unibilium.from_terminal Config.terminal_fallback_term
                   end
                 in false, nil
                   nil
                 in Unibilium
                   terminfo.as Unibilium
                 end

      # Control sequences must reach the terminal promptly. A caller-supplied
      # output (e.g. a second terminal via `File.open`) is fully buffered by
      # default, leaving the screen blank; force sync however it was obtained.
      if (output = @output).responds_to?(:sync=)
        output.sync = true
      end

      # `probe: false`: the live round-trip puts the tty into raw mode while it
      # waits, so it is deferred to `#probe!` (after registration) where an
      # interrupt gets cleaned up. `compute_draw_caps` reads only
      # terminfo-static capabilities, so deferring is safe.
      @tput = ::Tput.new(
        terminfo: terminfo,
        input: @input,
        output: @output,
        force_unicode: @force_unicode,
        use_buffer: false,
        probe: false,
      )
      @draw_caps = compute_draw_caps

      # Resolve the automatic glyph tier from the env-detected identity;
      # re-resolved once XTVERSION hardens it. No-op when a tier was pinned.
      auto_glyph_tier

      width.try { |w| @explicit_width = true; @width = w }
      height.try { |h| @explicit_height = true; @height = h }
    end

    # Returns current device width. Local operation (size is pushed to us).
    def awidth
      @width
    end

    # Returns current device height. Local operation (size is pushed to us).
    def aheight
      @height
    end

    # Runs the deferred live terminal probe that the constructor skipped. No-op
    # on a non-tty.
    #
    # The probe can upgrade capabilities the constructor could only guess at
    # from env/terminfo — most notably confirming 24-bit truecolor via a DECRQSS
    # SGR readback. `@draw_caps` snapshots the color depth, so it MUST be
    # recomputed afterward or rendering keeps downsampling to the stale
    # pre-probe depth.
    def probe! : Nil
      return unless ::Superconf.tput_probe
      @tput.probe!
      @draw_caps = compute_draw_caps
      # The probe's XTVERSION reply refines the emulator identity — confirming
      # or revoking an env-detected modern-font terminal — so re-resolve the
      # glyph tier in both directions.
      auto_glyph_tier
    end

    # Applies `Glyphs.detected_tier` (upgrade to `extended` on a
    # Unicode-capable kitty/WezTerm/Ghostty/iTerm2, else the `unicode` default)
    # while no tier was pinned explicitly. Only on a real tty: a
    # headless/redirected device isn't rendered by the emulator the environment
    # describes, and its output must not depend on where the process was
    # launched from.
    private def auto_glyph_tier : Nil
      return if @glyph_tier_explicit || !@output.tty?
      @glyph_tier = Glyphs.detected_tier(@tput)
    end

    # Reads the terminal size into `width`/`height` from this device's own `tput`
    # (which sized itself from its own output fd). Skipped when the size was
    # pinned explicitly at construction (headless / fixed-size).
    def adopt_terminal_size : Nil
      @width = tput.screen.width unless @explicit_width
      @height = tput.screen.height unless @explicit_height
    end

    # Applies a new size from a resize event, honoring the explicit-size pin.
    def resize(width : Int32, height : Int32) : Nil
      @width = width unless @explicit_width
      @height = height unless @explicit_height
    end

    # Builds and returns a **fresh** device for a new connection (a new IO
    # pair). Reuses this device's read-only terminfo and carries its options
    # across, so only the tty changes; the new device sizes itself from the new
    # terminal.
    #
    # Returns a *new* `Screen` rather than mutating this one: the previous
    # connection's input fiber stays bound to the **old** device (its now-closed
    # fd), so it can never steal input on the new tty or restore cooked mode on
    # it. Once the window swaps to the returned device, the old one is discarded.
    def reconnected(input : IO, output : IO) : Screen
      s = Screen.new(
        input: input,
        output: output,
        error: @error,
        force_unicode: @force_unicode,
        full_unicode: @full_unicode,
        # Carry the explicit-size pins across: a pinned axis (an inline window's
        # reserved `height`, a test's fixed size) must keep its value on the new
        # device. An unpinned axis passes `nil` and is sized from the new
        # terminal below.
        width: (@explicit_width ? @width : nil),
        height: (@explicit_height ? @height : nil),
        # Reuse the existing read-only terminfo; `false` on the rare chance
        # this device was built without one.
        terminfo: tput.terminfo || false,
      )
      # Take the size straight from the new terminal. `reset_screen_size`
      # ioctls the fd, which raises on a non-tty (pipe/file/memory) — tolerate
      # that for headless/redirected use.
      begin
        s.tput.reset_screen_size
      rescue
      end
      # Adopt honoring the pins carried above (a direct `s.width = ...`
      # assignment would overwrite a pinned axis).
      s.adopt_terminal_size
      # Carry a runtime `glyph_tier=` pin across too: the new device derives
      # `@glyph_tier_explicit` from config alone, so without this a runtime pin
      # is lost and the reattach's `probe!` re-runs auto-detection over it.
      s.glyph_tier = @glyph_tier if glyph_tier_explicit?
      s
    end

    # Derives the draw capabilities from the current terminal. The shim is
    # always present (terminfo always resolves, with a fallback term), so
    # `not_nil!` cannot fail.
    private def compute_draw_caps : DrawCaps
      s = tput.shim.not_nil! # ameba:disable Lint/NotNil
      DrawCaps.new(
        has_bce: !!(tput.has? &.back_color_erase?),
        parm_right_cursor: !s.parm_right_cursor?.nil?,
        alt_charset: !s.enter_alt_charset_mode?.nil?,
        broken_acs: tput.features.broken_acs?,
        term_unicode: tput.features.unicode?,
        u8: tput.terminfo.try(&.extensions.get_num?("U8")),
        ncolors: colors,
        acscr: tput.features.acscr,
        smacs: (s.smacs? || Bytes.empty).dup,
        rmacs: (s.rmacs? || Bytes.empty).dup,
        el: (s.el? || Bytes.empty).dup,
        # The ANSI fallbacks are exactly what tput's own `save_cursor`/… emit
        # when a terminal lacks the capability, so the bytes match either way.
        save_cursor: (s.sc? || "\e7".to_slice).dup,
        restore_cursor: (s.rc? || "\e8".to_slice).dup,
        hide_cursor: (s.civis? || "\e[?25l".to_slice).dup,
        show_cursor: (s.cnorm? || "\e[?25h".to_slice).dup,
        ansi_cursor: tput.features.ansi_cursor?,
      )
    end

    # Best-effort budget for each terminal cell-size query. A responsive
    # terminal answers in well under a millisecond; this only bounds the wait
    # when it stays silent, kept small to never stall startup.
    CELL_QUERY_TIMEOUT = 150.milliseconds

    # Detects the terminal's cell size in pixels at startup and feeds the
    # derived aspect ratio to the CSS layer. Prefers the `TIOCGWINSZ` ioctl (no
    # round-trip); falls back to querying via XTWINOPS when the kernel carries
    # no pixel size (common under tmux/screen/ssh). MUST run before the input
    # listen loop spawns — the fallback is a synchronous read that would race it.
    # Leaves the CSS default untouched when the terminal reports nothing.
    def detect_cell_geometry : Nil
      cp = Widget::Media::Graphics.terminal_cell_pixels(self) || query_cell_pixels
      apply_cell_pixels(cp[0], cp[1]) if cp
    end

    # Re-reads the terminal's cell pixel size on resize, catching font/zoom
    # changes arriving as `SIGWINCH`. Uses the `TIOCGWINSZ` ioctl *only*: the
    # input listen loop is active by now, so the escape-sequence fallback would
    # race it and must never run here.
    def refresh_cell_geometry : Nil
      if cp = Widget::Media::Graphics.terminal_cell_pixels(self)
        apply_cell_pixels(cp[0], cp[1])
      end
    end

    # Stores a cell pixel size and feeds the derived aspect ratio (height ÷
    # width, clamped to a sane band so a bogus report can't wreck layout) to
    # the CSS layer — unless `css.cell_aspect_ratio` pins it. No-op for a
    # non-positive size.
    def apply_cell_pixels(width : Int32, height : Int32) : Nil
      return unless width > 0 && height > 0
      @cell_pixel_width = width
      @cell_pixel_height = height
      # Keep SGR-Pixels (DEC 1016) mouse decoding in step with a font/zoom
      # change: the parser divides pixel reports by this cached cell size, so a
      # stale value mis-maps every pixel event to the wrong cell. Only refresh
      # when pixel mode is already active (non-nil).
      tput.mouse_cell_pixels = {width, height} if tput.mouse_cell_pixels
      # Feed the measured cell *width* into the CSS `px` anchor so an absolute
      # `px` length maps through the terminal's real geometry rather than the
      # hardcoded `1 cell ≈ 10px` default — unless `css.px_per_cell` pins it.
      CSS::Length.divisors["px"] = width.to_f unless CSS::Length.px_per_cell_configured?
      return if CSS::Length.cell_aspect_ratio_configured?
      CSS::Length.cell_aspect_ratio = (height.to_f / width.to_f).clamp(1.0, 4.0)
    end

    # Cell pixel size `{width, height}` queried from the terminal itself, for
    # when the ioctl reported nothing. Asks via XTWINOPS 16 (cell size in
    # pixels); if unanswered, derives it from text-area size in pixels (op 14)
    # divided by the device's known size in cells. `nil` if neither answers (or
    # on a non-tty — the query no-ops instantly, so tests/pipes don't block).
    private def query_cell_pixels : {Int32, Int32}?
      if cp = tput.get_cell_size_pixels(CELL_QUERY_TIMEOUT)
        return {cp[1], cp[0]} # XTWINOPS reports {height, width}; return {width, height}
      end
      if @width > 0 && @height > 0 && (px = tput.get_text_area_size_pixels(CELL_QUERY_TIMEOUT))
        return {px[1] // @width, px[0] // @height} # {width_px ÷ cols, height_px ÷ rows}
      end
      nil
    end
  end
end
