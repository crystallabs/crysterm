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
  # The surface — the `QWindow` / top-level `QWidget` analogue. Owns the cell
  # buffer, widget-tree root, focus, damage, rendering, and its geometry within
  # its `Screen`. *Has-a* `Screen` (the physical tty/device) and delegates
  # device concerns — IO, `Tput`, color depth, draw caps, device cell size — to
  # it, so one app can drive multiple ttys.
  class Window
    include EventHandler
    include Mixin::Name
    include Mixin::Pos
    include Mixin::Children
    include Mixin::Instances

    # The physical terminal/device backing this surface (the `QScreen`).
    getter screen : Screen

    # Moves this surface onto a different physical device (`QWindow::setScreen()`).
    # Keeps the widget tree and cell content; re-enters the new terminal and
    # fully repaints. Notifies the owning `Application` so it emits
    # `ScreenRemoved`/`ScreenAdded`. No-op if already on *new_screen*.
    def screen=(new_screen : Screen) : Screen
      return new_screen if new_screen.same? @screen
      old = @screen

      # Sampled before any teardown, to be restored on the new device below.
      was_listening = @screen.listening?

      # Whether the new device is genuinely new — not already backing another
      # registered window. Must be computed *before* the swap, while `#screens`
      # still reflects this window on `old`.
      new_device = application.try { |app| !app.screens.includes?(new_screen) }

      # Tear down the old device's terminal when this was its last live window;
      # no later path would restore it. Mirrors `#disconnect`'s split: a sibling
      # window keeps the device alive, but the departing window's pinned
      # hardware cursor (shape/blink/color) and title must be handed back to it
      # rather than outliving this window on the shared terminal.
      if other_live_window_on_device?
        reassert_sibling_terminal_state
        stale_window = nil
      else
        restore_terminal
        # The old device dies with this migration; its owned fds (spawned-window
        # IO) would otherwise leak — nothing else ever closes them.
        if @owns_io
          input.close rescue nil
          output.close rescue nil
        end
        @screen.stop_input
        # The old device dies with this migration; release any claim it holds
        # on the process-global CSS geometry anchor so the NEW device's
        # `detect_cell_geometry` below can take over.
        @screen.release_cell_geometry_anchor
        stale_window = @window
      end
      # The spawned emulator window and the IO ownership belong to the OLD
      # device. Carried across, the stale emulator's eventual close would fire
      # `on_window_closed`, pass its `@window == win` guard, and disconnect
      # this window from its NEW, healthy device — with `@owns_io` still true,
      # even closing the new device's fds. Clear both BEFORE closing the stale
      # window, so its EOF-woken watcher fails the guard. (`#connect`
      # re-asserts ownership after this swap for IO it does own.)
      @window = nil
      @owns_io = false
      # Closing the rendezvous socket also ends the watcher fiber via EOF.
      # `nil` on the sibling path: the emulator still serves the siblings.
      stale_window.try &.close

      @screen = new_screen
      # A freshly-built device is still at its 1×1 construction default and
      # unprobed; size and probe it before rendering. Pinned axes are honored.
      new_screen.adopt_terminal_size
      new_screen.probe
      # Pixel mouse (DEC 1016) and CSS `px` lengths read the cell geometry, and
      # a fresh `Screen` starts at 0. Must run before `start_input` below: the
      # fallback query is a synchronous read that would race the input fiber.
      new_screen.detect_cell_geometry
      # An inline surface re-anchors at the NEW terminal's cursor row. Safe
      # here for the same no-input-fiber-yet reason.
      capture_inline_anchor unless @alternate
      # Re-enter + repaint invalidates descendants' memoized device.
      enter
      realloc
      # Re-assert per-window terminal state on the new device: `enter` skips
      # `apply_cursor` for an already-applied cursor, and nothing else pushes
      # the stored title here — without this a migration loses both until the
      # next `activate`.
      reassert_terminal_state
      application.try do |app|
        # Back-link the new device to the dispatcher so its input read fiber
        # routes here.
        new_screen.application = app
        app.emit ::Crysterm::Event::ScreenRemoved, old unless app.screens.includes? old
        app.emit ::Crysterm::Event::ScreenAdded, new_screen if new_device
      end
      start_input if was_listening
      render
      new_screen
    end

    # Device concerns delegated to this window's `Screen`. `width`/`height` are
    # the device size — a `Window` is full-screen, so its surface size *is*
    # its screen's size.
    delegate input, output, error,
      tput, draw_caps, colors, color_count, truecolor?,
      force_unicode?, full_unicode?, full_unicode_effective?,
      glyph_tier,
      width, height,
      cell_pixel_width, cell_pixel_height,
      sgr_to_attr, attr_to_sgr, to: @screen

    # `Screen#awidth`/`#aheight` were verbatim duplicates of `#width`/`#height`
    # and were removed there; kept here (returning the screen's `width`/
    # `height`) since these are widely used across the render/geometry hot path.
    def awidth : Int32
      width
    end

    # :ditto:
    def aheight : Int32
      height
    end

    # Device-side input-mode toggles. `#start_input` enables them;
    # `#restore_terminal` disables whatever was enabled.
    delegate enable_keyboard_protocol, disable_keyboard_protocol,
      enable_bracketed_paste, disable_bracketed_paste,
      enable_in_band_resize, disable_in_band_resize,
      enable_color_scheme_notifications, disable_color_scheme_notifications,
      keyboard_protocol_enabled?, bracketed_paste_enabled?,
      in_band_resize_enabled?, color_scheme_notifications_enabled?,
      to: @screen

    # Device-side mouse transport. The surface hit-test and the
    # `#disable_mouse` wrapper stay here; everything else delegates.
    delegate mouse_enabled?, mouse_cursor_shaping?,
      to: @screen

    # Explicit forwarder (not `delegate`): the splat-forwarding delegate def
    # loses the enum restriction, so `enable_mouse(pixels: :on)` symbol
    # autocasting would not compile through it. Also passes this window's
    # `#send_focus?` so focus-in/out reporting (DEC 1004) follows the property.
    def enable_mouse(pixels : PixelMouse = :auto)
      @screen.enable_mouse(pixels: pixels, focus: send_focus?)
    end

    # `delegate` can't forward assignment, so forward these explicitly.
    def mouse_cursor_shape=(shape : ::Tput::MouseCursorShape?)
      @screen.mouse_cursor_shape = shape
    end

    def mouse_cursor_shaping=(value : Bool)
      @screen.mouse_cursor_shaping = value
    end

    # Device-side hardware-cursor control: raw `tput` shape/color/show-hide/
    # reset primitives and capability probes. The artificial cursor and the
    # hardware-vs-artificial decision read surface state, so they stay on the
    # surface and drive the hardware path through these.
    delegate hardware_cursor_styling?, hardware_cursor_color?,
      apply_hardware_cursor_shape,
      reset_hardware_cursor_color, show_hardware_cursor, hide_hardware_cursor,
      reset_hardware_cursor,
      to: @screen

    # `delegate` can't forward assignment, so forward this setter explicitly.
    def hardware_cursor_color=(color : Int32)
      @screen.hardware_cursor_color = color
    end

    # Device-side OSC escape-sequence transport: OSC-52 clipboard, OSC 7 cwd,
    # OSC 9;4 progress.
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

    # Screen title, if/when applicable
    getter title : String? = nil

    # :ditto:
    def title=(@title : String?)
      # The title is per-window terminal state: store it always, but write the
      # OSC 0 escape only while connected AND device-active — a background
      # window on a shared device must not retitle the terminal showing its
      # sibling, and a disconnected window's owned fds are closed (the write
      # would raise). `Application#activate`, `#connect` and the sibling
      # hand-back re-assert the stored title via `#reassert_terminal_state`.
      return unless @connected && device_active_window?
      if t = @title
        tput.title = t
      else
        # An explicit `nil` clears the terminal's title; terminals then show
        # their own default.
        tput.title = ""
      end
    end

    # Re-asserts this window's per-window terminal state — the hardware cursor
    # (DECSCUSR / OSC 12) and the OSC 0 title — on its device. The shared
    # re-assert used whenever this window (re)takes a terminal: on
    # `Application#activate`, on `#connect`'s reattach, on `#screen=`'s device
    # migration, and when a departing sibling hands the device back
    # (`#reassert_sibling_terminal_state`). Writes via `tput` directly, so it
    # emits even before the caller's activation bookkeeping settles.
    def reassert_terminal_state : Nil
      apply_cursor
      @title.try { |t| tput.title = t }
    end

    # Rendering performance figures are not drawn by the window itself; add a
    # `Widget::Fps` to display them.

    # Optimization flags for rendering/drawing.
    # XXX TODO: decide default flags dynamically.
    Crystallabs::Helpers::Enums.enum_property optimization : OptimizationFlag = Config.render_optimization

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
    # (alt) mode, so the offset is a no-op there. On the draw hot path.
    property render_row_offset : Int32 = 0

    # Terminal cursor row an inline surface is anchored at, captured at
    # construction before the input loop starts. Settable so hosts/specs can pin
    # it when the terminal can't answer the cursor-position query.
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

    # Physical footprint (rows) the inline region currently occupies on screen.
    # Under auto-grow this can be less than `aheight`; teardown parks the cursor
    # below the *actual* content, and a shrink erases the rows it vacates.
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
      @always_propagated_keys = @always_propagated_keys,
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

      # `false` defers the live terminal probe (and the cell-geometry query it
      # gates) to the caller — `#switch_terminal` builds its replacement on a
      # tty whose previous reader could still swallow the reply bytes.
      probe : Bool = true,

      terminfo : Bool | Unibilium = true,

      # An already-built device may be passed directly (e.g. by `Application` or
      # a reattach). When omitted, one is built from the IO/terminfo args — the
      # "one app, one full-screen window on the default tty" convenience.
      screen : Screen? = nil,

      # Not needed for now; also avoids coupling to terminal specifics.
      # @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
      # @use_buffer = false,
    )
      # An auto-grow region starts one row tall and pinned, so the first render
      # only ever *adds* rows and never erases real terminal content.
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

      handle ::Crysterm::Event::Attached
      handle ::Crysterm::Event::Detached
      handle ::Crysterm::Event::Destroy
      handle ::Crysterm::Event::Resize

      emit ::Crysterm::Event::Attached, self

      register_instance

      # Must run after `register_instance` (an interrupted probe needs this screen registered
      # for `at_exit` to cook the tty back) and before `_listen_keys` (the probe
      # round-trips queries in raw mode and would race the input fiber for reply
      # bytes). No-op on a non-tty.
      @screen.probe if probe

      # `report_cursor` reads `@input` synchronously, so the anchor must be
      # captured before `_listen_keys` spawns the input fiber.
      capture_inline_anchor unless @alternate

      # XXX Why here instead of in enter/leave?
      _listen_keys

      enter # Full-screen (alt) or inline, per `@alternate`.
      post_enter

      # After `enter`/`post_enter`, so the terminal background/palette probe the
      # `"terminal"` theme reads can complete.
      CSS.ensure_theme self
      # Apply the configured startup stylesheet over the theme, unless the app
      # already set one in code.
      apply_config_stylesheet
      # Seed CSS unit→cell divisors and cell aspect ratio before the first
      # restyle resolves unit'd geometry: config first (can pin the ratio),
      # then the terminal's measured cell size (won't override a pinned ratio).
      CSS::Length.apply_config
      # Deferred along with the probe: the fallback cell-size query is a
      # synchronous read the tty's previous reader could swallow.
      @screen.detect_cell_geometry if probe
      restyle

      # The loop doesn't render until the first `#render`, so spawning here is fine.
      @_render_loop_fiber = spawn render_loop
    end

    def on_attached(e)
      # Adopt the size from this window's device. Skipped when the size was
      # pinned explicitly at construction (headless / fixed-size).
      @screen.adopt_terminal_size

      # Resize events are pushed to screens, not pulled, to keep components
      # loosely coupled.
      @_resize_handler = subscribe_global_resize
    end

    def on_detached(e)
      @_resize_handler.try { |handler| GlobalEvents.off ::Crysterm::Event::Resize, handler }
      # Must be nil'd, so a later reattach resubscribes instead of keeping a
      # dangling handle.
      @_resize_handler = nil

      # NOTE Per-screen teardown only — does NOT cascade-destroy other
      # `Screen.instances`; each screen has an independent lifecycle.
    end

    # Destroys this `Window`.
    def on_destroy(e)
      on_detached(e)
    end

    def on_resize(e)
      # A pinned axis ignores the terminal's reported size; only unpinned axes
      # follow it (an inline window pins height, tracks width).
      e.size.try do |size|
        @screen.resize(size.width, size.height)
      end

      # Keep an inline region on-screen if the terminal shrank: clamp the anchor
      # so `offset + aheight` still fits. Best-effort — a precise re-anchor would
      # need a fresh `report_cursor`, which can't run while the input loop is
      # live.
      unless @alternate
        max_off = tput.screen.height - aheight
        self.render_row_offset = render_row_offset.clamp(0, max_off < 0 ? 0 : max_off)
      end

      realloc
      # On a device shared by several windows, only the device-active window
      # repaints — otherwise the last-created sibling would paint over the
      # activated one while input still routed to it. A non-active window's
      # buffers are reallocated above; it fully repaints on `activate`.
      render if device_active_window?

      # For children (`Widget`s).
      emit_descendants e
    end

    # Whether this window is the one currently shown on its device: the
    # `Application`'s most-recently added/activated window for this `Screen`.
    # True when unmanaged (no application, or not registered with it) — a lone
    # window is always its own device's active window.
    private def device_active_window? : Bool
      app = application
      return true unless app
      return true unless app.windows.includes? self
      aw = app.active_window_for(@screen)
      aw.nil? || aw.same?(self)
    end

    # The `Application` this window is being driven by, if any. Set when the
    # window is run via `Application#exec` (or added to an app).
    property application : Application? = nil

    # Renders this window and runs the main loop (the `QApplication::exec()`
    # analogue). Delegates to the current application, creating one if none
    # exists, so a single-window program stays the one-liner
    # `Window.new(...).exec`. Blocks until `#quit` (a plain `q` by default),
    # returning the status passed to it.
    def exec : Int32
      (application || Application.global).exec self
    end

    # Quits the application this window is driven by (creating/using the global
    # one when never registered) — the canonical way for a handler to end the
    # program: emits `Event::AboutToQuit`, tears every window down, and makes
    # `#exec` return *status*. See `Application#quit`.
    def quit(status : Int32 = 0) : Nil
      (application || Application.global).quit status
    end

    # Writes the current screen to the files named by `CRYSTERM_SHOT` (a still
    # PNG), `CRYSTERM_DUMP` (a text `#dump` golden), and `CRYSTERM_ANIM` (an
    # APNG, tuned by `CRYSTERM_ANIM_SECS` / `CRYSTERM_ANIM_FPS`), making every
    # Crysterm program self-capturable headlessly. Renders one frame, writes the
    # requested artifacts, and returns `true` so `exec` skips the interactive
    # loop; returns `false` when no capture var is set.
    #
    # :nodoc:
    def run_env_capture : Bool
      shot = Config.window_shot.presence
      dump_dest = Config.window_dump.presence
      anim = Config.window_anim.presence
      return false unless shot || dump_dest || anim

      repaint

      capture path: shot if shot
      dump path: dump_dest if dump_dest
      if anim
        secs = Config.window_anim_secs
        # `CRYSTERM_ANIM_FPS` parses with `.to_i?`, so `0`/negative gets
        # through; floor it so a misconfigured env var can't crash the capture.
        fps = Config.window_anim_fps
        fps = 1 if fps < 1
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
      # reserves/anchors its own `height`-row region.
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
    # anchored there. Must run before the input loop starts (`report_cursor`
    # reads `@input` synchronously). Falls back to row 0 if the terminal doesn't
    # answer.
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
        # Newlines only scroll the terminal when emitted from the bottom row, so
        # `scroll_terminal_up` homes to the last row first; from the anchor row
        # nothing would enter scrollback.
        scroll_terminal_up scroll
        anchor -= scroll
      end
      anchor = 0 if anchor < 0
      @render_row_offset = anchor
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

    # Reflows an inline `auto_grow` region to fit its content. Must run once per
    # frame *before* compositing, so widgets lay out at the new height. On growth
    # past the screen bottom it scrolls the terminal up and re-anchors; on shrink
    # it erases the physical rows the region no longer occupies. A no-op when the
    # size is unchanged, so steady-state frames pay only the measurement.
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
        # Full repaint of the resized region at the (possibly new) offset.
        # `alloc`'s `tput.clear` is suppressed inline, so this does not wipe the
        # terminal.
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
    # scrollback) by emitting newlines at the last row.
    private def scroll_terminal_up(n : Int32) : Nil
      return unless n > 0
      tput.cursor_pos tput.screen.height - 1, 0
      tput._print { |io| n.times { io << '\n' } }
    end

    # Erases physical rows `[from, to)` (whole lines).
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
      # NOTE dirty=true is mostly used during resize to empty all cells, because
      # `clear_last_rendered_pos` doesn't clear the correct area on resize (it
      # sees the resized values by the time it runs). This may mask an
      # underlying bug rather than be the real fix.
      old_height = @lines.size
      new_height = aheight

      old_width = @lines[0]?.try(&.size) || 0
      new_width = awidth

      if !dirty
        do_clear = false
      else
        do_clear = true
        # BOTH buffers must be reset: `add_row` below pushes to both, so
        # resetting one alone leaves them misaligned and corrupts the frame diff.
        @lines = Array(Row).new aheight
        @flushed_lines = Array(Row).new aheight
        old_height = 0
        old_width = 0
      end

      # If nr. of columns has changed, adjust width in existing rows
      if old_width != new_width
        do_clear = true

        Math.min(old_height, new_height).times do |i|
          adjust_width @lines[i], old_width, new_width, dirty
          adjust_width @flushed_lines[i], old_width, new_width, dirty
          @lines[i].dirty = dirty
          @flushed_lines[i].dirty = dirty
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

      # A full-screen clear is only correct when we own the whole screen; an
      # inline window must never wipe the terminal. It must still erase its own
      # region, though: `@flushed_lines` is now blank, so blank new cells compare equal
      # and the frame diff skips them, leaving whatever the terminal physically
      # shows there in place.
      #
      # On a shared device, only the device-active window may touch the
      # physical terminal: a non-active sibling's realloc (each window drains
      # its own debounced resize fiber) would wipe the active window's freshly
      # painted frame, whose `@flushed_lines` still claims the content is on
      # screen — so its next frame diff emits nothing and the terminal stays
      # blank. A non-active window is fully repainted via `Application#activate`
      # anyway, so it never needs the physical clear; the buffer resets above
      # stay unconditional.
      if do_clear && device_active_window?
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
      push_row @flushed_lines, dirty
    end

    # Appends one fresh, width-adjusted row to *buf*, marked `dirty`.
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
      @flushed_lines.pop
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
      # Both cell buffers are now blank, so the in-memory frame model matches
      # nothing: a selective composite with an empty dirty set would "succeed"
      # while repainting nothing, leaving the next render a blank-vs-blank
      # no-op. Force a full re-composite (no-op when damage tracking is off).
      damage_force_full
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

      # Disabling here clears the device's `mouse_enabled` flag, so a
      # subsequent `restore_terminal` doesn't redundantly disable again.
      disable_mouse if @screen.mouse_enabled?

      tput.normal_buffer
      if cursor._set
        reset_cursor
      end

      tput.flush

      # :-)
      {% if flag? :windows %}
        `cls`
      {% end %}
    end

    # Tears down an inline (non-alt) surface: restores keypad/mouse/cursor,
    # releases the scroll region, and parks the cursor just below the rendered
    # region so the shell prompt continues cleanly instead of overwriting the UI.
    private def leave_inline : Nil
      tput.disable_keypad
      disable_mouse if @screen.mouse_enabled?

      # An inline il/dl scroll op may have left the scroll region pinned to
      # `[offset, offset + aheight - 1]`; hand the whole terminal back.
      tput.set_scroll_region(0, tput.screen.height - 1)

      show_cursor
      # Park below the region's *actual* on-screen footprint (which, under
      # auto-grow, may be smaller than `aheight`).
      tput.cursor_pos render_row_offset + @inline_visible, 0
      reset_cursor if cursor._set

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
      #    vi_keys: true,
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

    # Politely closes the window (Qt's `QWindow#close`): disconnects, emits
    # `Event::WindowClosed`, and then tears it down with `#destroy`. Returns
    # whether the window was open (`false` if already destroyed).
    #
    # The counterpart to a hard `#destroy`: handlers get the signal *first*, so
    # they can save state, reattach the surface elsewhere (`Application.open
    # into: self`), or count it out of a multi-window run. Disconnecting before
    # emitting is exactly what the terminal-emulator-close watcher does
    # (`#on_window_closed`), so both close paths look identical to a handler —
    # and a handler that reattaches survives: the `#destroy` below is skipped
    # when the handler re-established a connection.
    #
    # Re-entrancy is safe: a handler that destroys the window itself — as
    # `Application.exec_all` does — just makes the `#destroy` below a no-op, so
    # there is no double teardown.
    def close : Bool
      return false if @destroyed
      disconnect
      emit Crysterm::Event::WindowClosed, self
      destroy unless @destroyed || @connected
      true
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
      # Stop the old input fiber FIRST: it is parked in a read on the very tty
      # the replacement opens (fresh default IO — the same STDIN/STDOUT), so it
      # would win the race for probe reply bytes and dispatch them as garbage
      # key events. A reader on unowned STDIN can't be joined (it only wakes on
      # the next bytes), so stopping alone isn't enough — the replacement is
      # also built unprobed (`probe: false`) and probed below, once the old
      # window and its claim on the tty are gone.
      was_listening = @screen.listening?
      @screen.stop_input
      # The replacement gets its own copy of the cursor (incl. its `Style`):
      # `#reparent_onto`'s destroy of THIS window runs `reset_cursor` on its
      # cursor object during `leave`, which would clobber a shared one back to
      # a default block. `_set` is cleared so the new window's `enter` applies
      # the carried shape/blink/color to the NEW terminal.
      carried_cursor = @cursor.dup
      carried_cursor.style = @cursor.style.dup
      carried_cursor._set = false
      replacement = Window.new(
        probe: false,
        terminfo: Unibilium.from_terminal(term),
        title: @title,
        # Carry the pin STATE, not the current size as unconditional pins:
        # passing plain Int32s set `explicit_width/height` on the new device,
        # so `adopt_terminal_size`/`refresh_size` no-op'd forever and the
        # replacement window stopped tracking terminal resizes, frozen at the
        # moment-of-switch size. Only an axis that was pinned stays pinned.
        width: (@screen.explicit_width? ? width : nil),
        height: (@screen.explicit_height? ? height : nil),
        # Surface mode/geometry knobs: without these an inline (`alternate:
        # false`) window came back as a full-screen alt-buffer window with
        # default padding and cursor. The new window re-captures its own inline
        # anchor for `alternate: false` in its initializer.
        alternate: @alternate, auto_grow: @auto_grow, max_height: @max_height,
        padding: @padding, cursor: carried_cursor,
        dock_borders: @dock_borders, dock_contrast: @dock_contrast,
        always_propagated_keys: @always_propagated_keys, propagate_keys: @propagate_keys,
        default_quit_keys: @default_quit_keys, tab_navigation: @tab_navigation,
        optimization: @optimization,
        force_unicode: force_unicode?, full_unicode: @screen.full_unicode?,
        resize_interval: @resize_interval,
      )
      # Carry an explicit runtime glyph-tier pin, like the size pins above:
      # without it the replacement device re-auto-detects and e.g. an Ascii pin
      # (accessibility / broken-font workaround) silently reverts to Unicode
      # chrome. An unpinned tier stays unpinned so detection runs as usual.
      replacement.glyph_tier = glyph_tier if @screen.glyph_tier_explicit?
      # The remaining runtime-settable options the constructor can't take; must
      # run before `start_input` below so its `enable_mouse(focus: send_focus?)`
      # sees the carried value.
      copy_runtime_options_onto replacement
      reparent_onto replacement
      # The deferred device probe (see `probe: false` above), now that no other
      # reader contends for the tty. `Screen#probe` refreshes draw_caps itself;
      # cell geometry (the CSS `px` anchor) and unit'd styles derive from probe
      # results, so re-run those too. Mirrors the ordering `#screen=` uses:
      # stop old input → probe → detect_cell_geometry → start_input.
      replacement.screen.probe
      replacement.screen.detect_cell_geometry
      replacement.restyle
      replacement.start_input if was_listening
      replacement
    end

    # Runtime-settable options the constructor can't take. THE single list —
    # add new runtime properties here, not as another inline patch (see the
    # size-pin / inline-knob / glyph-tier comments in `#switch_terminal` for
    # the history of piecemeal additions). Deliberately excluded: `grab_keys`
    # (transient grab state managed by the widget grab lifecycle),
    # `render_row_offset`/`anchor_row` (the replacement re-captures its own
    # inline anchor by design), and `application` (documented usage re-`exec`s
    # the returned window, which registers it).
    private def copy_runtime_options_onto(other : Window) : Nil
      other.hyperlinks = hyperlinks?
      other.synchronized_output = synchronized_output?
      other.send_focus = send_focus?
      other.frame_interval = frame_interval
      other.drag_two_click = drag_two_click?
      other.drag_ghost = drag_ghost?
      other.overflow = overflow
      other.default_attr = default_attr
      other.default_char = default_char
      other.mouse_cursor_shaping = mouse_cursor_shaping?
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

    # Total horizontal inset: `ileft + iright`. **Not** a width — the content
    # width is `awidth - ihorizontal`.
    def ihorizontal : Int32
      p = @padding
      p.left + p.right
    end

    # Total vertical inset: `itop + ibottom`. **Not** a height — the content
    # height is `aheight - ivertical`.
    def ivertical : Int32
      p = @padding
      p.top + p.bottom
    end
  end
end
