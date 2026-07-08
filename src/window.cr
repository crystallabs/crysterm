require "./macros"
require "./widget"

require "./mixin/children"

require "./screen"

require "./window_resize"
require "./window_interaction"
require "./window_mouse"
require "./window_drag"

require "./window_children"
require "./window_cursor"
require "./window_rendering"
require "./window_damage"
require "./window_drawing"
require "./window_focus"
require "./window_rows"
require "./window_capture"
require "./window_connection"

module Crysterm
  # The surface — the `QWindow` / top-level `QWidget` analogue (see
  # QT-OBJECT-MODEL-PLAN.md). Owns the cell buffer, widget-tree root, focus,
  # damage, rendering, and its geometry within its `Screen`. *Has-a* `Screen`
  # (the physical tty/device) and delegates device concerns — IO, `Tput`, color
  # depth, draw caps, device cell size — to it. (The surface/device split lets
  # one app drive multiple ttys.)
  class Window
    include EventHandler
    include Mixin::Name
    include Mixin::Pos
    include Mixin::Children
    include Mixin::Instances

    # The physical terminal/device backing this surface (the `QScreen`); see
    # `Screen`.
    getter screen : Screen

    # Moves this surface onto a different physical device (`QWindow::setScreen()`).
    # Keeps the widget tree and cell content; re-enters the new terminal and
    # fully repaints. Notifies the owning `Application` so it emits
    # `ScreenRemoved`/`ScreenAdded`. No-op if already on *new_screen*.
    def screen=(new_screen : Screen) : Screen
      return new_screen if new_screen.same? @screen
      old = @screen

      # Capture whether input was being listened on the old device *before* any
      # teardown, so it can be restored on the new device — mirroring
      # `#connect`. The old-device teardown below is gated on this being its
      # last window, but the new device must start listening regardless (even
      # when a sibling window keeps the old device alive), or the moved window
      # goes deaf on a fresh destination device.
      was_listening = @screen.listening?

      # Whether the new device is genuinely new — not already backing another
      # registered window. Computed *before* the swap, while `#screens` still
      # reflects this window on `old`; afterwards this window already points at
      # `new_screen`, so `screens.includes?(new_screen)` would always be true.
      # Gates `ScreenAdded` the way `Application#add` does, so moving a window
      # onto a device a sibling already uses doesn't fire a duplicate.
      new_device = application.try { |app| !app.screens.includes?(new_screen) }

      # Before swapping, tear down the old device's terminal when this was its
      # last live window — otherwise it's stranded in the alternate buffer with
      # raw mode + mouse reporting on and its input fiber still running, and no
      # later path restores it (`at_exit -> destroy -> disconnect` only touches
      # the current device). A sibling window still on the old device keeps it.
      # Mirrors `#disconnect`'s last-user logic.
      unless other_live_window_on_device?
        restore_terminal
        @screen.stop_keys
      end

      @screen = new_screen
      # Re-enter + repaint invalidates descendants' memoized device.
      enter
      realloc
      application.try do |app|
        # Back-link the new device to the dispatcher (mirrors `Application#add`)
        # so its input read fiber routes here.
        new_screen.application = app
        app.emit ::Crysterm::Event::ScreenRemoved, old unless app.screens.includes? old
        app.emit ::Crysterm::Event::ScreenAdded, new_screen if new_device
      end
      # Restore input listening on the new device if the window was listening
      # before the move (mirrors `#connect`).
      listen if was_listening
      render
      new_screen
    end

    # Device concerns delegated to this window's `Screen`. `width`/`height` are
    # the device size — a `Window` is full-screen, so its surface size *is*
    # its screen's size.
    delegate input, output, error,
      tput, draw_caps, colors, truecolor?,
      force_unicode?, full_unicode?,
      glyph_tier,
      width, height, awidth, aheight,
      cell_pixel_width, cell_pixel_height,
      attr2code, code2attr, to: @screen

    # Device-side input-mode toggles (live on `Screen`, in `screen_input.cr`).
    # `#listen` enables them; `#restore_terminal` disables whatever was enabled.
    delegate enable_keyboard_protocol, disable_keyboard_protocol,
      enable_bracketed_paste, disable_bracketed_paste,
      enable_in_band_resize, disable_in_band_resize,
      enable_color_scheme_notifications, disable_color_scheme_notifications,
      _listened_keyboard?, _listened_paste?,
      _listened_in_band_resize?, _listened_color_scheme?,
      to: @screen

    # Device-side mouse transport (lives on `Screen`, in `screen_mouse_device.cr`).
    # The surface hit-test (`#dispatch_mouse`) and `#disable_mouse` wrapper stay
    # here; everything else delegates.
    delegate enable_mouse, listen_mouse, _listened_mouse?,
      set_mouse_cursor_shape, mouse_cursor_shape?,
      to: @screen

    # `delegate` can't forward assignment, so forward this gate explicitly.
    def mouse_cursor_shape=(value : Bool)
      @screen.mouse_cursor_shape = value
    end

    # Device-side hardware-cursor control (lives on `Screen`, in
    # `screen_cursor.cr`): raw `tput` shape/color/show-hide/reset primitives and
    # capability probes. The artificial cursor and hardware-vs-artificial
    # decision read surface state, so they stay in `window_cursor.cr` and drive
    # the hardware path through these delegations.
    delegate hardware_cursor_styling?, hardware_cursor_color?,
      set_hardware_cursor_shape, set_hardware_cursor_color,
      reset_hardware_cursor_color, show_hardware_cursor, hide_hardware_cursor,
      reset_hardware_cursor,
      to: @screen

    # Device-side OSC escape-sequence transport (lives on `Screen`, in
    # `screen_osc.cr`): OSC-52 clipboard, OSC 7 cwd, OSC 9;4 progress. Reached
    # by `Application#clipboard` and drag interop through the surface.
    delegate copy, request_clipboard, copy_to_clipboard, report_cwd, progress,
      to: @screen

    # Setters forwarded explicitly (`delegate` doesn't accept assignment forms).
    def width=(value : Int32)
      @screen.width = value
    end

    def height=(value : Int32)
      @screen.height = value
    end

    def full_unicode=(value : Bool)
      @screen.full_unicode = value
    end

    def glyph_tier=(value : Glyphs::Tier)
      @screen.glyph_tier = value
    end

    def input=(value : IO)
      @screen.input = value
    end

    def output=(value : IO)
      @screen.output = value
    end

    def error=(value : IO)
      @screen.error = value
    end

    # :nodoc: Flag indicating whether at least one `Screen` has called `#bind`.
    # Possibly removable; appears only in this file.
    # @@_bound = false
    # XXX Disabled to check if it's needed.

    # Screen title, if/when applicable
    getter title : String? = nil

    # :ditto:
    def title=(@title : String?)
      @title.try { |t| self.tput.title = t }
    end

    # Disabled, unused atm
    # # XXX Rename to e.g. `hovered_widget`, or remove (single-widget hover looks
    # # application-specific).
    # # Element being hovered over. Set only if mouse events are enabled.
    # @hover : Widget? = nil

    # Rendering performance figures are not drawn by the window itself.
    # Add a `Widget::Fps` to display them; it reads the per-frame measurements
    # exposed by `window_rendering.cr` (`#render_rate`, `#draw_rate`,
    # `#frame_rate`, `#throughput`, `#bytes_written`).

    # Optimization flags for rendering/drawing.
    # XXX TODO: decide default flags dynamically.
    # ameba:disable Lint/UselessAssign
    Crystallabs::Helpers::Enums.enum_property optimization : OptimizationFlag = Config.render_optimization

    # `awidth`/`aheight` (the current device size) are delegated to `@screen`.

    # The absolute ones are all 0 because `Screen`s are always full screen.

    # Disabled, unused. Uncomment when relevant.
    # getter aleft = 0
    # getter atop = 0
    # getter aright = 0
    # getter abottom = 0

    # What to do with "overflowing" (too large) widgets. `Overflow::Ignore`
    # (default) renders only the parts in view.
    Crystallabs::Helpers::Enums.enum_property overflow : Overflow = Config.window_overflow

    # Whether this window takes over the whole terminal via the *alternate*
    # screen buffer (the default, full-screen mode). When `false`, the window
    # runs **inline**: it stays in the normal scrolling buffer, is bounded to its
    # `height` rows, and is anchored at the terminal's cursor row at start-up.
    # All the normal machinery (widgets, input, focus, damage/diff, layout)
    # applies; only the alt-buffer takeover and full-screen scroll region are
    # skipped, and rendered rows are offset down to `#render_row_offset`. Inline
    # mode wants an explicit `height:` (the reserved region size).
    getter? alternate : Bool = true

    # Physical terminal row the inline (`alternate: false`) surface is anchored
    # at — added to every rendered row so the whole `[0, aheight)` surface lands
    # at `[offset, offset + aheight)` on the real terminal. `0` in full-screen
    # (alt) mode, so the offset is a no-op there. Read on the draw hot path
    # (`window_drawing.cr`).
    property render_row_offset : Int32 = 0

    # Terminal cursor row captured at construction (via `report_cursor`, before
    # the input loop starts), used to anchor an inline surface in `#enter`.
    # Settable so hosts/specs can pin the anchor when the terminal can't answer
    # the cursor-position query (headless, non-tty).
    property anchor_row : Int32 = 0

    # Inline **auto-grow**: when `true` (only meaningful with `alternate: false`),
    # the region's height tracks its content each frame instead of staying fixed
    # — it grows downward as widgets need more rows (scrolling the terminal up
    # when it reaches the bottom) and shrinks back, erasing the rows it vacates.
    # Suits a completer/menu whose size depends on how many items are showing.
    # Content must be top-anchored (heights that don't depend on the surface
    # height); the growth is capped by `#max_height`.
    getter? auto_grow : Bool = false

    # Optional cap on an `auto_grow` region's height (in rows). `nil` = the
    # terminal height. The region never grows past this.
    property max_height : Int32? = nil

    # Physical footprint (rows) the inline region currently occupies on screen —
    # tracked by `#autogrow_reflow` so `#leave_inline` parks the cursor just
    # below the *actual* content, and so a shrink knows which rows to erase.
    @inline_visible : Int32 = 0

    def initialize(
      input : IO? = nil,
      output : IO? = nil,
      error : IO? = nil,
      @title = @title,
      width : Int32? = nil,
      height : Int32? = nil,
      @dock_borders = @dock_borders,
      @dock_contrast = @dock_contrast,
      @always_propagate = @always_propagate,
      @propagate_keys = @propagate_keys,
      @default_quit_keys = @default_quit_keys,
      @tab_navigation = @tab_navigation,
      @cursor = @cursor,
      optimization : OptimizationFlag | Shorthands = @optimization,
      padding = nil,
      @alternate : Bool = true,
      @auto_grow : Bool = false,
      @max_height : Int32? = nil,
      force_unicode : Bool = Config.screen_force_unicode,
      full_unicode : Bool = Config.screen_full_unicode,
      @resize_interval = @resize_interval,

      terminfo : Bool | Unibilium = true,

      # An already-built device may be passed directly (e.g. by `Application` or
      # a reattach). When omitted, one is built from the IO/terminfo args — the
      # "one app, one full-screen window on the default tty" convenience.
      screen : Screen? = nil,

      # Not needed for now; also avoids coupling to terminal specifics.
      # @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
      # @use_buffer = false,
    )
      # An auto-grow inline region starts one row tall and is pinned (so the
      # device won't adopt the terminal height); the first render grows it to
      # fit — starting minimal means growth only ever *adds* rows, never erases
      # real terminal content on the first frame. `max_height` caps the growth.
      height = 1 if @auto_grow

      # Build (or adopt) the physical device — owns IO, `Tput`, `draw_caps`,
      # color depth, and cell size, all delegated back to this window.
      @screen = screen || Screen.new(
        input: input || (Crysterm.headless? ? IO::Memory.new : STDIN),
        output: output || (Crysterm.headless? ? IO::Memory.new : STDOUT),
        error: error || (Crysterm.headless? ? IO::Memory.new : STDERR),
        force_unicode: force_unicode,
        full_unicode: full_unicode,
        width: width,
        height: height,
        terminfo: terminfo,
      )

      self.optimization = optimization
      padding.try { |pad| @padding = Padding.from(pad) }
      title.try { |t| self.title = t }

      @_resize_loop_fiber = spawn(name: "resize_loop") { resize_loop }

      handle ::Crysterm::Event::Attach
      handle ::Crysterm::Event::Detach
      handle ::Crysterm::Event::Destroy
      handle ::Crysterm::Event::Resize

      emit ::Crysterm::Event::Attach, self

      bind

      # Now that the screen is in `@@instances`, run the live terminal probe
      # that `Tput.new` skipped. It round-trips query sequences in raw mode; if
      # Ctrl+C interrupts it, `at_exit` -> `#restore_terminal` cooks the tty back
      # since this screen is now in the list. Runs before `_listen_keys` to
      # avoid racing the input fiber for reply bytes. Gated on the same config
      # flag `Tput.new` uses; `probe!` no-ops on a non-tty.
      @screen.probe!

      # ensure tput.zero_based = true, use_buffer=true
      # set resizeTimeout

      # Tput is accessed via tput

      # No longer calling super; not a Widget subclass any more.

      # _unicode is tput.features.unicode
      # full_unicode? is option full_unicode? + _unicode

      # Events:
      # addhander,

      # TODO These events are not for specific widgets, but for the whole
      # program. Enable and rework them like the example below when needed.

      # on(Crysterm::Event::Focus) do
      #  emit Crysterm::Event::Focus
      # end

      # on(Crysterm::Event::Blur) do
      #  emit Crysterm::Event::Blur
      # end

      # on(Crysterm::Event::Warning) do |e|
      # emit e
      # end

      # Inline (non-alt) mode anchors its region at the terminal's current
      # cursor row. `report_cursor` reads `@input` synchronously and must not
      # race the input listen loop, so capture the anchor *before* `_listen_keys`
      # spawns that fiber. `#enter` consumes `@anchor_row`.
      capture_inline_anchor unless @alternate

      # XXX Why here instead of in enter/leave?
      _listen_keys

      # The default quit keys (`q` / Ctrl-Q) are now an app-global hotkey
      # handled by `Application#route_input` (gated on `default_quit_keys?`),
      # not a per-window `Event::KeyPress` handler installed here.

      enter # Full-screen (alt) or inline, per `@alternate`.
      post_enter

      # Install the configured CSS theme after `enter`/`post_enter` so the
      # terminal probe (background/palette) the `"terminal"` theme reads can
      # complete. `restyle` marks the tree dirty so the first render applies it.
      CSS.ensure_theme self
      # Apply the configured startup stylesheet over the theme, unless the app
      # already set one in code.
      apply_config_stylesheet
      # Seed CSS unit→cell divisors and cell aspect ratio before the first
      # restyle resolves unit'd geometry: config first (can pin the ratio),
      # then the terminal's measured cell size (won't override a pinned ratio).
      CSS::Length.apply_config
      @screen.detect_cell_geometry
      restyle

      # The loop doesn't render until the first `#render`, so spawning here is fine.
      spawn render_loop
    end

    # The terminal cell-size detection now lives on the device `Screen`
    # (`#detect_cell_geometry` / `#refresh_cell_geometry`).

    def on_attach(e)
      # Adopt the size from this window's device. Skipped when the size was
      # pinned explicitly at construction (headless / fixed-size).
      @screen.adopt_terminal_size

      # Push resize events to screens (push, not pull, keeps components loosely
      # coupled).
      @_resize_handler = subscribe_global_resize
    end

    def on_detach(e)
      @_resize_handler.try { |handler| GlobalEvents.off ::Crysterm::Event::Resize, handler }

      # NOTE Per-screen teardown only — does NOT cascade-destroy other
      # `Screen.instances`; each screen has an independent lifecycle. Whole-app
      # shutdown is handled by `at_exit` (in `crysterm.cr`) and
      # `Screen.exec_all`'s shared quit. Terminal-mode restore happens in
      # `#disconnect`, which `#destroy` calls.
    end

    # Destroys current `Display`.
    def on_destroy(e)
      on_detach(e)
    end

    def on_resize(e)
      # A pinned axis ignores the terminal's reported size; only unpinned axes
      # follow it (an inline window pins height, tracks width — see
      # `Screen#explicit_height?` / `#explicit_width?`).
      e.size.try { |size|
        @screen.set_size(size.width, size.height)
      }

      # Keep an inline region on-screen if the terminal shrank: clamp the anchor
      # so `offset + aheight` still fits. A precise re-anchor would need a fresh
      # `report_cursor`, which can't run while the input loop is live, so this is
      # best-effort — never let the region render off the bottom.
      unless @alternate
        max_off = tput.screen.height - aheight
        self.render_row_offset = render_row_offset.clamp(0, max_off < 0 ? 0 : max_off)
      end

      realloc
      render

      # For children (`Widget`s).
      # e.size = nil
      emit_descendants e
    end

    # The `Application` this window is being driven by, if any. Set when the
    # window is run via `Application#exec` (or added to an app). Lets `#exec`
    # find its app, and the window reach app-level services (clipboard, quit).
    property application : Application? = nil

    # Renders this window and runs the main loop. The loop itself lives on
    # `Application#exec` (the `QApplication::exec()` analogue); this delegates
    # to the current application (creating one if none exists) so a
    # single-window program stays the one-liner `Window.new(...).exec`.
    def exec : Nil
      (application || Application.global).exec self
    end

    # When any of `CRYSTERM_SHOT` / `CRYSTERM_DUMP` / `CRYSTERM_ANIM` is set, each
    # names a file to write the current screen to — a still PNG, a text `#dump`
    # golden, and/or an APNG (with `CRYSTERM_ANIM_SECS` / `CRYSTERM_ANIM_FPS`
    # tuning duration/rate). Renders one frame, writes the requested artifacts,
    # and returns `true` so `exec` skips the interactive loop; returns `false`
    # when no capture var is set. Makes every Crysterm program self-capturable
    # headlessly.
    #
    # :nodoc: (public so `Application#exec` can consult it)
    def capture_from_env : Bool
      shot = Config.window_shot.presence
      dump_dest = Config.window_dump.presence
      anim = Config.window_anim.presence
      return false unless shot || dump_dest || anim

      _render

      capture path: shot if shot
      dump path: dump_dest if dump_dest
      if anim
        secs = Config.window_anim_secs
        fps = Config.window_anim_fps
        capture path: anim, format: "apng", duration: secs.seconds, fps: fps, loops: 0
      end

      true
    end

    def enter
      if !@cursor._set
        apply_cursor
      end

      {% if flag? :windows %}
        `cls`
      {% end %}

      # Full-screen mode takes over the terminal via the alternate buffer and
      # owns the whole screen; inline mode stays in the normal buffer and only
      # reserves/anchors its own `height`-row region (see `#enter_inline`).
      tput.alternate_buffer if @alternate
      tput.enable_keypad
      tput.set_scroll_region(0, aheight - 1) if @alternate
      hide_cursor
      if @alternate
        tput.cursor_pos 0, 0
      else
        enter_inline
      end
      tput.enable_acs

      alloc
    end

    # Captures the terminal's current cursor row so an inline surface can be
    # anchored there, via the shared `CursorAnchor` abstraction (real-terminal
    # host). Runs at construction *before* the input loop starts
    # (`report_cursor` reads `@input` synchronously — see the call site); the
    # anchor falls back to row 0 if the terminal doesn't answer (non-tty,
    # headless).
    private def capture_inline_anchor : Nil
      @anchor_row = TerminalCursorAnchor.new(@screen).cursor_row
    end

    # Reserves the inline region below the anchor row and sets
    # `#render_row_offset`. If the anchor sits too low for `aheight` rows to fit,
    # scrolls the terminal up by emitting newlines (pushing existing content into
    # scrollback) and moves the anchor up to compensate, so the region always
    # fits on-screen. Homes the cursor to the region's top-left.
    private def enter_inline : Nil
      anchor = @anchor_row
      term_h = tput.screen.height
      if anchor + aheight > term_h
        scroll = anchor + aheight - term_h
        # Newlines only scroll the terminal when emitted from the bottom row;
        # from the anchor row they would just walk the cursor down and nothing
        # would enter scrollback, leaving the region painted over un-scrolled
        # content. `scroll_terminal_up` homes to the last row first.
        scroll_terminal_up scroll
        anchor -= scroll
      end
      anchor = 0 if anchor < 0
      @render_row_offset = anchor
      # Initial on-screen footprint equals the reserved height; `autogrow_reflow`
      # updates it as the region grows/shrinks.
      @inline_visible = aheight
      tput.cursor_pos anchor, 0
    end

    # Height an `auto_grow` region may grow to (rows): the configured
    # `#max_height`, else the terminal height, and never more than the terminal
    # can show.
    private def autogrow_max : Int32
      cap = @max_height || tput.screen.height
      {cap, tput.screen.height}.min
    end

    # Reflows an inline `auto_grow` region to fit its content, run once per frame
    # *before* compositing (so widgets lay out at the new height). Grows/shrinks
    # the surface to `#content_height`: on growth past the screen bottom it
    # scrolls the terminal up and re-anchors; on shrink it erases the physical
    # rows the region no longer occupies. A no-op when the size is unchanged, so
    # steady-state frames pay only the measurement.
    private def autogrow_reflow : Nil
      return unless !@alternate && @auto_grow

      desired = content_height.clamp(1, autogrow_max)
      cur = aheight
      if desired > cur
        # Growing past the last screen row: scroll existing content up into
        # scrollback and move the anchor up to make room.
        overflow = (render_row_offset + desired) - tput.screen.height
        if overflow > 0
          scroll_terminal_up overflow
          self.render_row_offset = Math.max(0, render_row_offset - overflow)
        end
      elsif desired < cur
        # Shrinking: clear the rows the region is giving back to the terminal
        # before the buffer forgets they were ours.
        erase_physical_rows render_row_offset + desired, render_row_offset + @inline_visible
      end

      @inline_visible = desired
      if desired != cur
        @screen.height = desired
        # Dirty rebuild → full repaint of the resized region at the (possibly
        # new) offset. `alloc`'s `tput.clear` is suppressed inline, so this does
        # not wipe the terminal.
        realloc
      end
    end

    # Desired inline height (rows) from the widget tree: the largest bottom edge
    # (`atop + aheight`) among visible top-level children, in surface
    # coordinates. Assumes top-anchored content (heights independent of the
    # surface height); at least 1.
    def content_height : Int32
      h = 1
      children.each do |c|
        next unless c.visible?
        bottom = c.atop + c.aheight
        h = bottom if bottom > h
      end
      h
    end

    # Scrolls the whole terminal up by *n* rows (pushing the top into
    # scrollback) by emitting newlines at the last row. Used by `auto_grow` when
    # the region reaches the bottom of the screen.
    private def scroll_terminal_up(n : Int32) : Nil
      return unless n > 0
      tput.cursor_pos tput.screen.height - 1, 0
      tput._print { |io| n.times { io << '\n' } }
    end

    # Erases physical rows `[from, to)` (whole lines), used when an `auto_grow`
    # region shrinks and hands rows back to the terminal.
    private def erase_physical_rows(from : Int32, to : Int32) : Nil
      term_h = tput.screen.height
      from.upto(to - 1) do |py|
        next if py < 0 || py >= term_h
        tput.cursor_pos py, 0
        tput._print "\e[2K"
      end
    end

    # Allocates screen buffers (a new pending/staging buffer and a new output buffer).
    #
    # `dirty` means lines must be redrawn: re-creates the cell grid from
    # scratch rather than adjusting the size of the existing one.
    def alloc(dirty = false)
      # dirty=true re-creates rows/cols from scratch; otherwise we just apply
      # the size difference (enlarge/shrink the existing arrays).
      #
      # NOTE dirty=true is mostly used during resize to empty all cells,
      # because `clear_last_rendered_pos` seems to not clear the correct area
      # on resize (it sees the resized values by the time it runs) — possibly
      # masking an underlying bug rather than being the real fix. Revisit if
      # further resize-related issues show up.
      old_height = @lines.size
      new_height = aheight

      old_width = @lines[0]?.try(&.size) || 0
      new_width = awidth

      if !dirty
        do_clear = false
      else
        do_clear = true
        # Reset BOTH buffers: resetting only `@lines` left `@olines` at its old
        # size while `add_row` below pushes to both, so `@olines` grew
        # unbounded across resizes and its rows no longer lined up with
        # `@lines`, corrupting the frame diff in `draw`.
        @lines = Array(Row).new aheight
        @olines = Array(Row).new aheight
        old_height = 0
        old_width = 0
      end

      # If nr. of columns has changed, adjust width in existing rows
      if old_width != new_width
        do_clear = true

        Math.min(old_height, new_height).times do |i|
          adjust_width @lines[i], old_width, new_width, dirty
          adjust_width @olines[i], old_width, new_width, dirty
          @lines[i].dirty = dirty
          @olines[i].dirty = dirty
        end
      end

      # If nr. of rows has changed, add or remove rows as appropriate. New rows
      # have their columns created from scratch.
      if (diff = new_height - old_height) != 0
        do_clear = true
        if diff > 0
          diff.times do
            add_row dirty
          end
        elsif diff < 0
          (diff * -1).times do
            remove_row
          end
        end
      end

      # A full-screen clear is only correct when we own the whole screen. An
      # inline window must never wipe the terminal on (re)alloc — but it must
      # erase its own region: `@olines` was just reset to blanks, so any cell
      # whose new content is blank compares equal and is skipped by the frame
      # diff — whatever the terminal physically shows there (pre-resize glyphs,
      # rewrapped text) would persist. Vacated autogrow rows are erased
      # separately in `#autogrow_reflow`.
      if do_clear
        if @alternate
          tput.clear
        else
          erase_physical_rows render_row_offset, render_row_offset + aheight
        end
      end
    end

    @[AlwaysInline]
    private def add_row(dirty)
      push_row @lines, dirty
      push_row @olines, dirty
    end

    # Appends one fresh, width-adjusted row to *buf*, marked `dirty`. Used by
    # `add_row` to grow `@lines` and `@olines` in lock-step.
    @[AlwaysInline]
    private def push_row(buf, dirty)
      col = Row.new awidth
      adjust_width col, 0, awidth, dirty
      buf.push col
      buf[-1].dirty = dirty
    end

    @[AlwaysInline]
    private def remove_row
      @lines.pop
      @olines.pop
    end

    @[AlwaysInline]
    private def adjust_width(line, old_width, new_width, dirty)
      diff = new_width - old_width
      if diff > 0
        diff.times do
          line.push
        end
      elsif diff < 0
        (diff * -1).times do
          line.pop
        end
      end
    end

    # Reallocates screen buffers and clear the screen.
    def realloc
      alloc dirty: true
    end

    def leave
      # Inline mode never entered the alt buffer; tear its region down instead.
      return leave_inline unless @alternate

      # (Full-screen path.) Assumes `enter` activated alt mode.
      return unless tput.is_alt

      tput.disable_keypad

      if (tput.scroll_top != 0) || (tput.scroll_bottom != aheight - 1)
        tput.set_scroll_region(0, tput.screen.height - 1)
      end

      # XXX For some reason if alloc/clear() is before this line, it doesn't
      # work on linux console.
      show_cursor
      alloc

      # `leave` owns disabling the mouse on the alt-screen teardown path:
      # `#disable_mouse` clears the device's `_listened_mouse` flag, so a
      # subsequent `restore_terminal` doesn't redundantly disable again. On the
      # non-alt path this method early-returns above, leaving the flag set so
      # `restore_terminal` disables the mouse itself.
      disable_mouse if @screen._listened_mouse?

      tput.normal_buffer
      if cursor._set
        cursor_reset
      end

      tput.flush

      # :-)
      {% if flag? :windows %}
        `cls`
      {% end %}
    end

    # Tears down an inline (non-alt) surface: restores keypad/mouse/cursor,
    # releases any scroll region the inline il/dl path left constrained to our
    # rows, and parks the cursor just below the rendered region so the shell
    # prompt continues cleanly on the next line rather than overwriting the UI.
    private def leave_inline : Nil
      tput.disable_keypad
      disable_mouse if @screen._listened_mouse?

      # An inline il/dl scroll op may have left the scroll region pinned to
      # `[offset, offset + aheight - 1]`; hand the whole terminal back.
      tput.set_scroll_region(0, tput.screen.height - 1)

      show_cursor
      # Park below the region's *actual* on-screen footprint (which, under
      # auto-grow, may be smaller than `aheight`).
      tput.cursor_pos render_row_offset + @inline_visible, 0
      cursor_reset if cursor._set

      tput.flush
    end

    def post_enter
      # Debug helpers/setup, such as:
      # if (this.options.debug) {
      #  this.debugLog = new Log({
      #    screen: this,
      #    parent: this,
      #    hidden: true,
      #    draggable: true,
      #    left: 'center',
      #    top: 'center',
      #    width: '30%',
      #    height: '30%',
      #    border: 'line',
      #    label: ' {bold}Debug Log{/bold} ',
      #    tags: true,
      #    keys: true,
      #    vi: true,
      #    mouse: true,
      #    scrollbar: {
      #      ch: ' ',
      #      track: {
      #        bg: 'yellow'
      #      },
      #      style: {
      #        reverse: true
      #      }
      #    }
      #  });

      #  this.debugLog.toggle = function() {
      #    if (self.debugLog.hidden) {
      #      self.saveFocus();
      #      self.debugLog.show();
      #      self.debugLog.setFront();
      #      self.debugLog.focus();
      #    } else {
      #      self.debugLog.hide();
      #      self.restoreFocus();
      #    }
      #    self.render();
      #  };

      #  this.debugLog.key(['q', 'escape'], self.debugLog.toggle);
      #  this.key('f12', self.debugLog.toggle);
      # }

      # if (this.options.warnings) {
      #  this.on('warning', function(text) {
      #    var warning = new Box({
      #      screen: self,
      #      parent: self,
      #      left: 'center',
      #      top: 'center',
      #      width: 'shrink',
      #      padding: 1,
      #      height: 'shrink',
      #      align: 'center',
      #      valign: 'middle',
      #      border: 'line',
      #      label: ' {red-fg}{bold}WARNING{/} ',
      #      content: '{bold}' + text + '{/bold}',
      #      tags: true
      #    });
      #    self.render();
      #    var timeout = setTimeout(function() {
      #      warning.destroy();
      #      self.render();
      #    }, 1500);
      #    if (timeout.unref) {
      #      timeout.unref();
      #    }
      #  });
      # }
    end

    # Destroys self and removes it from the global list of `Screen`s. Also
    # removes all global events relevant to the object. If no screens remain,
    # the app is reset to its initial state.
    def destroy
      return if @destroyed
      @destroyed = true

      # Signal the render fiber to exit, then wake it so it notices.
      @render_stop = true
      schedule_render

      # Same for the resize fiber (finding 12): flag it, then poke the channel
      # so it wakes and exits instead of looping forever on `receive`, pinning
      # this destroyed window and possibly resizing it after teardown.
      @resize_stop = true
      schedule_resize

      # Stop the stylesheet hot-reload monitor thread, if one is running.
      unwatch_stylesheet

      # XXX Needs a small fix before enabling — probably destroyal order needs
      # to be bottom-up instead of top-down.
      # @children.each &.destroy

      # Tear down the terminal connection (restores the terminal, stops the
      # input fiber, closes owned IO and any spawned window). For the
      # launching screen this is the old `leave` plus line-discipline restore;
      # for screens bound to spawned windows it also closes the window.
      disconnect

      # Drop this surface from its `Application`'s registry so input is no
      # longer routed to it and it stops counting as an `active_window` (the
      # app emits `ScreenRemoved` if its device is now unused). The global
      # `Window.instances` teardown registry is cleared separately by `super`
      # below; see the registry note on `Application`.
      application.try &.remove self

      # XXX Blessed does this here (undoes the setup from initialize):
      #    process.removeListener('uncaughtException', Screen._exceptionHandler);
      #    process.removeListener('SIGTERM', Screen._sigtermHandler);
      #    process.removeListener('SIGINT', Screen._sigintHandler);
      #    process.removeListener('SIGQUIT', Screen._sigquitHandler);
      #    process.removeListener('exit', Screen._exitHandler);
      #  this.destroyed = true;
      #  this.emit('destroy');
      #  this._destroy();

      super
    end

    # Rebuilds this screen on a different terminal type and returns the **new**
    # screen, carrying every top-level widget across. Crysterm loads terminfo
    # once per `Screen`, so changing the terminal at runtime (Blessed's
    # `screen.terminal = '...'`) means a *new* `Screen` with the same widgets.
    # Constructs a new screen on *term*'s terminfo (copying this screen's
    # salient options, but not its IO — the new screen opens fresh, since
    # `#destroy` closes this one's), reparents every widget onto it, destroys
    # this screen, and returns the new one. Re-`render`/`exec` the returned
    # screen.
    #
    # ```
    # screen = screen.switch_terminal "vt100"
    # ```
    def switch_terminal(term : String) : Window
      reparent_onto Window.new(
        terminfo: Unibilium.from_terminal(term),
        title: @title,
        width: width, height: height,
        dock_borders: @dock_borders, dock_contrast: @dock_contrast,
        always_propagate: @always_propagate, propagate_keys: @propagate_keys,
        default_quit_keys: @default_quit_keys, tab_navigation: @tab_navigation,
        optimization: @optimization,
        force_unicode: force_unicode?, full_unicode: @screen.full_unicode_requested,
        resize_interval: @resize_interval,
      )
    end

    # Moves every top-level widget from this screen onto *other*, destroys this
    # screen, and returns *other*. The migration half of `#switch_terminal`;
    # also usable on its own to move a whole UI between two existing screens.
    def reparent_onto(other : Window) : Window
      children.dup.each do |child|
        remove child
        other.append child
      end
      destroy
      other
    end

    # Unused
    # def sigtstp(callback)
    #  display.sigtstp {
    #    alloc
    #    render
    #    display.lrestore_cursor :pause, true
    #    callback.call if callback
    #  }
    # end

    # For compatibility with widgets; as a side-effect, screens can have
    # padding. A widget at position (0,0) is positioned after padding.
    # (`Padding.default` is empty; `Padding.new` would default to 1 cell.)
    property padding = Padding.default

    # Space taken by decorations on the left, subtracted from widget total width
    def ileft
      @padding.left
    end

    # Space taken by decorations on top, subtracted from widget total height
    def itop
      @padding.top
    end

    # Space taken by decorations on the right, subtracted from widget total width
    def iright
      @padding.right
    end

    # Space taken by decorations on bottom, subtracted from widget total height
    def ibottom
      @padding.bottom
    end

    # Returns current screen width.
    def iwidth
      p = @padding
      p.left + p.right
    end

    # Returns current screen height.
    def iheight
      p = @padding
      p.top + p.bottom
    end
  end
end
