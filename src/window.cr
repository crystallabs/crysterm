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
  # depth, draw caps, device cell size — to it. (Formerly named `Screen`; the
  # device split lets one app drive multiple ttys.)
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
      @screen = new_screen
      # Re-enter + repaint invalidates descendants' memoized device.
      enter
      realloc
      application.try do |app|
        # Back-link the new device to the dispatcher (mirrors `Application#add`)
        # so its input read fiber routes here.
        new_screen.application = app
        app.emit ::Crysterm::Event::ScreenRemoved, old unless app.screens.includes? old
        app.emit ::Crysterm::Event::ScreenAdded, new_screen
      end
      render
      new_screen
    end

    # Device concerns delegated to this window's `Screen`. `width`/`height` are
    # the device size — a `Window` is full-screen, so its surface size *is*
    # its screen's size.
    delegate input, output, error,
      tput, draw_caps, colors, truecolor?,
      force_unicode?, full_unicode?,
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

    # Rendering performance figures are no longer drawn by the screen itself.
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
    # ameba:disable Lint/UselessAssign
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
      @always_propagate = @always_propagate,
      @propagate_keys = @propagate_keys,
      @default_quit_keys = @default_quit_keys,
      @tab_navigation = @tab_navigation,
      @cursor = @cursor,
      optimization : OptimizationFlag | Shorthands = @optimization,
      padding = nil,
      # alt = true, # Unused
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

      # XXX Why here instead of in enter/leave?
      _listen_keys

      # The default quit keys (`q` / Ctrl-Q) are now an app-global hotkey
      # handled by `Application#route_input` (gated on `default_quit_keys?`),
      # not a per-window `Event::KeyPress` handler installed here.

      enter # if alt # Only clear/full-screen if user wants alternate buffer
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
      @_resize_handler = GlobalEvents.on(::Crysterm::Event::Resize) do |_|
        # When in-band resize (DEC 2048) is active, the terminal reports size
        # changes via the input stream, so ignore the SIGWINCH-driven global
        # signal to avoid double handling.
        schedule_resize unless _listened_in_band_resize?
      end
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
      # A pinned, explicitly-sized device ignores the terminal's reported size;
      # its dimensions only change when set directly (see
      # `Screen#explicit_size?`).
      e.size.try { |size|
        @screen.set_size(size.width, size.height)
      }

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
      # TODO make it possible to work without switching the whole app to alt
      # buffer.
      # return if tput.is_alt

      if !@cursor._set
        apply_cursor
      end

      {% if flag? :windows %}
        `cls`
      {% end %}

      tput.alternate_buffer
      tput.enable_keypad
      tput.set_scroll_region(0, aheight - 1)
      hide_cursor
      tput.cursor_pos 0, 0
      tput.enable_acs

      alloc
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
        @lines = Array(Row).new
        @olines = Array(Row).new
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

      tput.clear if do_clear
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
      col = Row.new
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
      # TODO make it possible to work without switching the whole app to alt
      # buffer (same note as in `enter`). Assumes `enter` activated alt mode.
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
