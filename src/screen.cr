require "./macros"

require "./screen_attributes"
require "./screen_input"
require "./screen_mouse_device"

module Crysterm
  # How a `Screen` built without explicit IO chooses between a real terminal and
  # a headless (in-memory) connection. See `Crysterm.headless?`.
  enum Headless
    Auto # Decide automatically: headless iff the app is non-interactive (output is not a TTY)
    Yes  # Always headless, even on a real terminal
    No   # Always use the real terminal, even when non-interactive
  end

  # Explicit output color-depth override, independent of what the terminal
  # advertises. `Auto` (the default) keeps terminal detection but still honors
  # the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` environment conventions;
  # the rest pin a fixed depth. Drives color reduction at output time — see
  # `Screen#colors` / `Screen.resolve_color_depth`.
  enum ColorDepth
    Auto      # Terminal detection (+ the NO_COLOR / FORCE_COLOR / CLICOLOR env vars)
    None      # Monochrome: emit no color (styles like bold still apply)
    Basic     # 8 ANSI colors
    Ansi      # 16 ANSI colors (8 normal + 8 bright)
    Xterm256  # 256-color palette
    TrueColor # 24-bit RGB

    # The terminal color-count this depth maps to in `Screen#colors` terms
    # (1 = monochrome, then 8 / 16 / 256 / 0x1000000). `Auto` has no fixed count
    # and returns `nil` (the caller falls back to detection + env).
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

  # The physical terminal / device — the `QScreen` analogue of the Qt object
  # model (see QT-OBJECT-MODEL-PLAN.md). It owns everything that binds Crysterm
  # to a concrete tty: the IO fds, the `Tput` control-sequence generator, the
  # statically-derived `DrawCaps`, the device cell size (`width`/`height`), the
  # output color depth and SGR encoding, and the terminal's pixel cell geometry.
  #
  # A `Window` (the surface — formerly `Screen`) *has-a* `Screen` and delegates
  # all of these to it. Splitting the device out is what lets one app drive
  # multiple ttys and is the same seam that powers detach/reattach (a `Window`
  # surviving while its `Screen` is rebuilt — see `window_connection.cr`).
  #
  # The SGR/color encoding methods live in `screen_attributes.cr`.
  class Screen
    # Input IO.
    #
    # NOTE: not `STDIN.dup` — because of the `initialize(@input = @input)`
    # default, the initializer here is evaluated on *every* `Screen.new`, even
    # when an `input:` is passed explicitly. `Object#dup` shallow-copies the IO
    # and aliases the same fd with `close_on_finalize=true`, so each discarded
    # alias closes the shared STDIN fd when it is garbage-collected. With more
    # than one `Screen` per process that corrupts the standard streams (hangs or
    # "File not open" errors). Use the std stream directly (a single, never-
    # collected global); this matches the same fix in `Tput#initialize`.
    # When the app runs non-interactively (see `Crysterm.headless?`), an
    # `IO::Memory` is substituted so a `Screen` built without explicit IO drives
    # a headless connection instead of the real STDIN/STDOUT/STDERR. A caller-
    # supplied `input:`/`output:`/`error:` always wins. Each default is its own
    # buffer so headless input reads never consume rendered output.
    property input : IO = Crysterm.headless? ? IO::Memory.new : STDIN

    # Output IO. See the note on `input` re: not using `STDOUT.dup`.
    property output : IO = Crysterm.headless? ? IO::Memory.new : STDOUT

    # Error IO. (Could be used for redirecting error output to a particular
    # widget.) See the note on `input` re: not using `STDERR.dup`.
    property error : IO = Crysterm.headless? ? IO::Memory.new : STDERR

    # Force Unicode (UTF-8) even if terminfo auto-detection did not find support for it?
    property? force_unicode : Bool = Config.screen_force_unicode

    # User option: enable grapheme / full-Unicode-aware rendering — text is
    # measured and laid out by terminal **column width** (`Crysterm::Unicode`)
    # rather than one column per codepoint, grapheme clusters are kept intact,
    # and wide characters occupy two cells. Set via `full_unicode=`.
    @full_unicode : Bool = Config.screen_full_unicode

    # :ditto:
    def full_unicode=(@full_unicode : Bool)
    end

    # Whether grapheme / column-width-aware rendering is *in effect*: the
    # `full_unicode` option is on AND the terminal can render Unicode. This is
    # the single gate consulted by the content engine, renderer, and drawer.
    def full_unicode? : Bool
      @full_unicode && tput.features.unicode?
    end

    # The raw `full_unicode` *option* as requested, before the terminal-capability
    # gate `#full_unicode?` applies. Used when copying options to a new device.
    def full_unicode_requested : Bool
      @full_unicode
    end

    # Device width, in cells.
    property width = 1

    # Device height, in cells.
    property height = 1

    # Whether `width`/`height` were given explicitly to the constructor. When set,
    # the device must not overwrite them with the size probed from the terminal
    # (which, for a headless device whose output is an `IO::Memory`, falls back to
    # the *real* controlling terminal — see `Tput#get_screen_size`). This keeps a
    # fixed-size `Screen` fixed, as tests and off-screen rendering rely on.
    getter? explicit_size = false

    # Terminal cell size in pixels, detected once at startup (`0` = the terminal
    # reported none). Set by `#detect_cell_geometry`; drives the CSS cell aspect
    # ratio and is a ready source for pixel-addressed graphics.
    property cell_pixel_width = 0
    property cell_pixel_height = 0

    # Instance of `Tput`, used for generating term control sequences.
    getter tput : ::Tput

    # Per-terminal draw capabilities, derived once per `@tput` via
    # `#compute_draw_caps` instead of being re-queried every frame. Includes the
    # static, parameter-free sequence bytes (`smacs`/`rmacs`/`el`) the drawer
    # writes straight into the frame buffer, and the `ansi_cursor` flag gating
    # inline-ANSI hot-path cursor moves.
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
      # Whether tput verified the terminal's `cup`/`cuf`/… are byte-for-byte
      # standard ANSI (`Tput::Features#ansi_cursor?`). When true, the hot-path
      # cursor moves below are emitted as direct inline ANSI; when false they
      # route through tput (via `divert`) so a non-conforming terminal still gets
      # correct sequences. Constant for the terminal, so it is read once here.
      ansi_cursor : Bool

    # The per-terminal draw capabilities (`DrawCaps`). Assigned `= compute_draw_caps`
    # wherever `@tput` is created — here and on reconnect — so it is always
    # present and never derived per frame. (The reconnect reuses the same
    # terminfo, so the values are in fact identical across it, but it is
    # re-derived there anyway so it stays correct even if that ever changes.)
    getter draw_caps : DrawCaps

    # The `Application` this device is registered with — the dispatcher the input
    # read fiber routes parsed events up to (`Application#route_input`). Set by
    # `Application#add` when an owning `Window` is registered; the fiber falls
    # back to `Application.global` while it is still nil. See `#listen_keys`
    # (`screen_input.cr`).
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
                     # No usable terminfo for the environment's $TERM (e.g. TERM
                     # unset, as on CI runners). Fall back to a widely-available
                     # `xterm` entry so a Screen can still be constructed
                     # headlessly instead of crashing.
                     Unibilium.from_terminal Config.terminal_fallback_term
                   end
                 in false, nil
                   nil
                 in Unibilium
                   terminfo.as Unibilium
                 end

      # Control sequences are written to `@output` and must reach the terminal
      # promptly, without sitting in a write buffer. `STDOUT` connected to a
      # terminal is already `sync`, but a caller-supplied output (e.g. a second
      # terminal opened via `File.open`) is fully buffered by default, which
      # would leave the screen blank. Force sync so rendering works regardless
      # of how the output was obtained.
      if (output = @output).responds_to?(:sync=)
        output.sync = true
      end

      # `probe: false`: do NOT run the live terminal round-trip here, inside the
      # constructor. That probe puts the tty into raw mode while it waits; the
      # owning `Window` defers it to `#probe!` (after it is registered) so an
      # interrupt during it is cleaned up. `compute_draw_caps` reads only
      # terminfo-static capabilities, not the live-probe results, so deferring
      # is safe.
      @tput = ::Tput.new(
        terminfo: terminfo,
        input: @input,
        output: @output,
        force_unicode: @force_unicode,
        use_buffer: false,
        probe: false,
      )
      # Derive the terminal's static draw capabilities once, here. They are
      # re-derived wherever `@tput` is rebuilt (see `#rebuild_connection`).
      @draw_caps = compute_draw_caps

      # An explicitly-sized device keeps its size; the terminal-probed size (in
      # `#adopt_terminal_size`) must not replace it.
      if width || height
        @explicit_size = true
        width.try { |w| @width = w }
        height.try { |h| @height = h }
      end
    end

    # Returns current device width. Local operation (the size is pushed to us).
    def awidth
      @width
    end

    # Returns current device height. Local operation (the size is pushed to us).
    def aheight
      @height
    end

    # Runs the deferred live terminal probe that `Tput.new` skipped (see
    # `probe: false`). Gated on the same config flag `Tput.new` itself uses, and
    # `probe!` no-ops on a non-tty.
    def probe! : Nil
      @tput.probe! if ::Superconf.tput_probe
    end

    # Reads the terminal size into `width`/`height` from this device's own `tput`
    # (which sized itself from its own output fd). Skipped when the size was
    # pinned explicitly at construction (headless / fixed-size).
    def adopt_terminal_size : Nil
      return if @explicit_size
      @width = tput.screen.width
      @height = tput.screen.height
    end

    # Applies a new size from a resize event, honoring the explicit-size pin.
    def set_size(width : Int32, height : Int32) : Nil
      return if @explicit_size
      @width = width
      @height = height
    end

    # Rebuilds `tput` (and the derived `draw_caps`) on a new connection — a fresh
    # IO pair — reusing the existing read-only terminfo. Used by reattach
    # (`Window#connect`). `probe: false` is essential: on reattach the new tty has
    # no responder yet, so a live round-trip would block forever.
    def rebuild_connection(input : IO, output : IO) : Nil
      @input = input
      @output = output
      if output.responds_to?(:sync=)
        output.sync = true
      end
      @tput = ::Tput.new(
        terminfo: tput.terminfo,
        input: input,
        output: output,
        force_unicode: @force_unicode,
        use_buffer: false,
        probe: false,
      )
      @draw_caps = compute_draw_caps
      # `reset_screen_size` ioctls the fd, which raises on a non-tty (pipe/file/
      # memory) — tolerate that for headless/redirected use.
      begin
        tput.reset_screen_size
      rescue
      end
      @width = tput.screen.width
      @height = tput.screen.height
    end

    # Derives the draw capabilities from the current terminal. The shim is always
    # present (terminfo always resolves, with a fallback term), so `not_nil!`
    # cannot fail.
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
        ansi_cursor: tput.features.ansi_cursor?,
      )
    end

    # Best-effort budget for each terminal cell-size query. A responsive terminal
    # answers in well under a millisecond; this only bounds the wait when it stays
    # silent, so it is kept small to never stall startup.
    CELL_QUERY_TIMEOUT = 150.milliseconds

    # Detects the terminal's cell size in pixels at startup and feeds the derived
    # aspect ratio to the CSS layer (see `#apply_cell_pixels`). Prefers the
    # `TIOCGWINSZ` ioctl (no terminal round-trip); when the kernel carries no
    # pixel size (common under tmux/screen/ssh), falls back to querying the
    # terminal via XTWINOPS — done before the input listen loop spawns, per
    # `Tput::Response`'s synchronous-read rule. Leaves the CSS default untouched
    # when the terminal reports nothing.
    def detect_cell_geometry : Nil
      cp = Widget::Media::Graphics.terminal_cell_pixels(self) || query_cell_pixels
      apply_cell_pixels(cp[0], cp[1]) if cp
    end

    # Re-reads the terminal's cell pixel size on resize, via the `TIOCGWINSZ`
    # ioctl *only* — the escape-sequence fallback must never run here, since the
    # input listen loop is active and a synchronous query would race it. Catches
    # font/zoom changes that arrive as `SIGWINCH`. (The in-band resize path takes
    # the size straight from the report.)
    def refresh_cell_geometry : Nil
      if cp = Widget::Media::Graphics.terminal_cell_pixels(self)
        apply_cell_pixels(cp[0], cp[1])
      end
    end

    # Stores a cell pixel size and feeds the derived aspect ratio (cell height ÷
    # width, clamped to a sane band so a bogus report can't wreck layout) to the
    # CSS layer — unless `css.cell_aspect_ratio` pins it. No-op for a non-positive
    # size, so a terminal that reports no pixels leaves the prior values intact.
    # Shared by startup detection, the resize ioctl refresh, and the in-band
    # resize report (the latter calls this directly via the owning window).
    def apply_cell_pixels(width : Int32, height : Int32) : Nil
      return unless width > 0 && height > 0
      @cell_pixel_width = width
      @cell_pixel_height = height
      return if CSS::Length.cell_aspect_ratio_configured?
      CSS::Length.cell_aspect_ratio = (height.to_f / width.to_f).clamp(1.0, 4.0)
    end

    # Cell pixel size `{width, height}` queried from the terminal itself, for when
    # the ioctl reported nothing. Asks via XTWINOPS 16 (cell size in pixels); if
    # that goes unanswered, derives it from the text-area size in pixels (op 14)
    # divided by the device's known size in cells. `nil` if the terminal answers
    # neither (or isn't a tty — `query` then no-ops instantly, so tests/pipes
    # don't block).
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
