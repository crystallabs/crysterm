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
require "./window_region_focus"
require "./window_rows"
require "./window_capture"
require "./window_connection"
require "./window_inline"

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
        # The old device dies with this migration; its owned fds (spawned-
        # window IO) would otherwise leak, and the NEW device's
        # `detect_cell_geometry` below needs the CSS geometry anchor released
        # — see `#teardown_device_if_last` (shared with `#disconnect`).
        teardown_device_if_last
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
      # Pixel mouse (DEC 1016) and CSS `px` lengths read the cell geometry, and
      # a fresh `Screen` starts at 0. Must run before `start_input` below: the
      # fallback query is a synchronous read that would race the input fiber.
      # Skipped when adopting a device that already ran its live negotiation —
      # i.e. moving onto a shared device with a live sibling: the
      # re-probe would be redundant, its reply reads would race the sibling's
      # input fiber for the same bytes, and its query/cleanup writes would
      # paint over the sibling's frame.
      new_screen.reprobe_and_detect_geometry unless new_screen.probed?
      # An inline surface re-anchors at the NEW terminal's cursor row. Safe
      # here for the same no-input-fiber-yet reason — so skipped when the
      # adopted device's input fiber is already live: the synchronous
      # read would race it; the anchor keeps its row-0 fallback instead.
      capture_inline_anchor unless @alternate || new_screen.listening?
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
      cell_pixel_width, cell_pixel_height, to: @screen

    # `awidth`/`aheight` are aliases of `#width`/`#height` (the screen size),
    # widely used across the render/geometry hot path.
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
    delegate hardware_cursor?, hardware_cursor_styling?, hardware_cursor_color?,
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
    # An explicit size assignment **pins** that axis on the device
    # (`Screen#width=`), so a later terminal resize no longer overwrites it —
    # the same semantics as passing `width:`/`height:` at construction.
    def width=(value : Int32)
      @screen.width = value
    end

    # :ditto:
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

    # Optimization flags for rendering/drawing. Defaults to
    # `Config.render_optimization` (a static, user-tunable config value). Choosing
    # them dynamically per terminal (e.g. enabling BCE only where advertised) is a
    # possible enhancement, deferred: the flags are output-equivalent, so a wrong
    # static default costs performance, never correctness.
    Crystallabs::Helpers::Enums.enum_property optimization : OptimizationFlag = Config.render_optimization

    # What to do with "overflowing" (too large) widgets. `Overflow::Ignore`
    # (default) renders only the parts in view.
    Crystallabs::Helpers::Enums.enum_property overflow : Overflow = Config.window_overflow

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
      @always_propagated_chars = @always_propagated_chars,
      @propagate_keys = @propagate_keys,
      @default_quit_keys = @default_quit_keys,
      @tab_navigation = @tab_navigation,
      @cursor = @cursor,
      optimization : OptimizationFlag | Shorthands = @optimization,
      padding = nil,
      alternate : Bool = true,
      # Intent-named inverse of `alternate:` ↔ Qt's `showNormal` vs a full-screen
      # surface. `inline: true` runs the window inline in the normal buffer
      # (`@alternate = false`) instead of taking over the alternate screen. When
      # given, it wins over `alternate:` (the low-level knob it derives).
      inline : Bool = false,
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
      # `inline:` is the intent-named inverse of `alternate:`; when set it wins.
      @alternate = inline ? false : alternate

      # An auto-grow region starts one row tall and pinned, so the first render
      # only ever *adds* rows and never erases real terminal content.
      height = 1 if @auto_grow

      # Build (or adopt) the physical device — owns IO, `Tput`, `draw_caps`,
      # color depth, and cell size, all delegated back to this window.
      @screen = screen || Screen.new(
        input: input || Screen.default_input,
        output: output || Screen.default_output,
        error: error || Screen.default_error,
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

      # Only a device that has not yet run its live negotiation is probed
      # here. A device adopted via `screen:` that was already probed by its
      # first window's constructor must not be re-probed: the result is already
      # known, and on a device whose input fiber is live the probe's
      # synchronous reply reads would race that fiber for the same bytes —
      # replies stolen by the parked reader arrive as garbage key events while
      # the probe times out into degraded capabilities, and the probe's
      # query/cleanup writes paint over the sibling's frame. `listening?` also
      # covers the unprobed-but-live edge (first window built with
      # `probe: false`, input started): a reader already parked in a blocking
      # read on the fd would swallow reply bytes even if cooperatively
      # stopped, so skipping is the only sound choice there too. Computed once
      # so `probe` and `detect_cell_geometry` (below) stay paired.
      probe_device = probe && !@screen.probed? && !@screen.listening?

      # Must run after `register_instance` (an interrupted probe needs this screen registered
      # for `at_exit` to cook the tty back) and before `_listen_keys` (the probe
      # round-trips queries in raw mode and would race the input fiber for reply
      # bytes). No-op on a non-tty.
      @screen.probe if probe_device

      # `report_cursor` reads `@input` synchronously, so the anchor must be
      # captured before `_listen_keys` spawns the input fiber — and never on a
      # device whose input fiber is already live (a sibling's reader would race
      # it for the reply; the anchor keeps its row-0 fallback instead).
      capture_inline_anchor unless @alternate || @screen.listening?

      # In `connect`, not `enter`/`leave`: input listening belongs to the
      # *connection* lifecycle — the fiber is spawned once per connect and must
      # follow the synchronous `@input` reads above (`report_cursor`,
      # `capture_inline_anchor`) before it takes over the fd. `enter`/`leave` only
      # toggle the alt buffer and can cycle on suspend/resume while the connection
      # (and its listener) persist.
      _listen_keys

      enter # Full-screen (alt) or inline, per `@alternate`.

      # After `enter`, so the terminal background/palette probe the
      # `"terminal"` theme reads can complete.
      CSS.ensure_theme self
      # Apply the configured startup stylesheet over the theme, unless the app
      # already set one in code.
      apply_config_stylesheet
      # Seed CSS unit→cell divisors and cell aspect ratio before the first
      # restyle resolves unit'd geometry: config first (can pin the ratio),
      # then the terminal's measured cell size (won't override a pinned ratio).
      CSS::Length.apply_config
      # Deferred along with the probe (and gated with it): the fallback
      # cell-size query is a synchronous read the tty's previous reader could
      # swallow, and an already-probed shared device detected its geometry
      # when its first window was constructed.
      @screen.detect_cell_geometry if probe_device
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

    # Opens a real terminal-emulator window and returns the `Window` driving it —
    # a discoverable alias for `Application.open` (the factory's result type is a
    # `Window`, so it reads naturally here too). See `Application.open` for the
    # arguments.
    def self.open(**kwargs) : Window
      Application.open(**kwargs)
    end

    # Opens *window_count* emulator windows, builds each via the block, then
    # renders and runs them all under a shared quit — an alias for
    # `Application.run`. See it for the arguments.
    def self.run(**kwargs, &block : Window, Int32 -> _) : Nil
      Application.run(**kwargs) { |w, i| block.call w, i }
    end

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

    # Brings this window to the front of its device and makes it the app-active
    # surface ↔ `QWindow::requestActivate`. Delegates to the driving application
    # (the global one when never registered), so a window can raise itself
    # without the caller reaching for `Application#activate`. Returns `self`.
    #
    # (No `#raise` alias: an instance method named `raise` would shadow
    # Crystal's `raise` inside `Window`'s own code — `activate` is the safe
    # spelling of Qt's window raise here.)
    def activate : self
      (application || Application.global).activate self
      self
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
      # Hide the terminal's own cursor for the setup/first paint (the per-frame
      # cursor bracket in `#draw` re-shows it when appropriate). This must be
      # the HARDWARE hide, not `hide_cursor`: the latter dispatches on the
      # active cursor and, on the artificial branch, records `_hidden = true` —
      # clobbering a visibility the app (or a focused input's `_read_input`)
      # already established before `exec`, so an artificial cursor would enter
      # the first frame invisible. Mirrors `#leave`, which pairs `show_cursor`
      # with a direct `show_hardware_cursor` for the same reason.
      hide_hardware_cursor
      if @alternate
        tput.cursor_pos 0, 0
      else
        enter_inline
      end
      tput.enable_acs

      alloc
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

      # Order matters and is deliberate: `show_cursor` (the DECTCEM `\e[?25h`)
      # MUST run before `alloc`, whose tail emits the screen clear (`tput.clear`,
      # `\e[2J`) when this window owns the device. On the Linux VT console,
      # clearing first and only then re-showing the cursor leaves the cursor
      # hidden after the return to the normal buffer below — show-then-clear is
      # the order that reliably restores it there (xterm-family terminals tolerate
      # either). Do not reorder these two lines.
      show_cursor
      # `show_cursor` dispatches on the active cursor and its artificial branch
      # never reaches the terminal (it only records `_hidden`), while
      # `apply_cursor`'s artificial branch emits civis — and `tput.reset_cursor`
      # below resets only shape/color, not DECTCEM. Re-show the hardware cursor
      # directly so the tty isn't left cursorless after exit.
      show_hardware_cursor
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

      # Same for the resize fiber: flag it, then poke the channel
      # so it wakes and exits instead of looping forever on `receive`, pinning
      # this destroyed window and possibly resizing it after teardown.
      @resize_stop = true
      schedule_resize

      # Stop the stylesheet hot-reload monitor thread, if one is running.
      unwatch_stylesheet

      # Destroy the widget tree so resource-holding widgets release cleanly (a
      # `Terminal` PTY, `Media`/animation decode fibers, a `Log` fd) instead of
      # being dropped for the GC to reclaim whenever. Done BEFORE `disconnect`, so
      # each `#destroy` still runs against a connected window.
      #
      # Iterate a SNAPSHOT: a top-level widget's `#destroy` ends in
      # `detach_from_tree`, which removes it from `@children` mid-loop — the same
      # reason `Widget#destroy` dups its own children. The teardown is
      # bottom-up: `Widget#destroy` recurses into its children first, then
      # detaches.
      @children.dup.each &.destroy

      # Tear down the terminal connection (restores the terminal, stops the
      # input fiber, closes owned IO and any spawned window). For the
      # launching screen this is `leave` plus line-discipline restore;
      # for screens bound to spawned windows it also closes the window.
      disconnect

      # Uninstall every action shortcut installed on this window: the
      # class-level `Action` shortcut registry (`@@shortcut_maps`) holds the
      # window and its window-level `KeyPress` subscription, so without this a
      # destroyed window with installed actions stays pinned forever.
      # Idempotent — a no-op when nothing is (or is no longer) installed.
      Action.uninstall_shortcuts self

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
