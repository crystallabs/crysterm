require "./macros"
require "./widget"

require "./mixin/children"

require "./screen"

require "./screen_resize"
require "./screen_interaction"
require "./screen_mouse"
require "./screen_drag"

require "./screen_children"
require "./screen_cursor"
require "./screen_decoration"
require "./screen_rendering"
require "./screen_damage"
require "./screen_drawing"
require "./screen_focus"
require "./screen_rows"
require "./screen_capture"
require "./screen_connection"

module Crysterm
  # The surface — the `QWindow` / top-level `QWidget` analogue of the Qt object
  # model (see QT-OBJECT-MODEL-PLAN.md). It owns the cell buffer/backing store,
  # the widget-tree root, focus, damage, rendering, and its geometry within its
  # `Screen`. It *has-a* `Screen` (the physical tty / device) and delegates all
  # device concerns — IO, `Tput`, color depth, draw capabilities, the device
  # cell size — to it. (This class was formerly named `Screen`; the device split
  # is what lets one app drive multiple ttys.)
  class Window
    include EventHandler
    include Mixin::Name
    include Mixin::Pos
    include Mixin::Children
    include Mixin::Instances

    # The physical terminal / device backing this surface (the `QScreen`). Owns
    # the IO, `Tput`, color depth, draw caps and device cell size; see `Screen`.
    getter screen : Screen

    # Moves this surface onto a different physical device ↔ `QWindow::setScreen()`.
    # The widget tree and cell content are kept; the window re-enters the new
    # terminal and fully repaints at its size. Notifies the owning `Application`
    # so it emits `ScreenRemoved`/`ScreenAdded` as the device set changes. No-op
    # if already on *new_screen*.
    def screen=(new_screen : Screen) : Screen
      return new_screen if new_screen.same? @screen
      old = @screen
      @screen = new_screen
      # Invalidate every descendant's memoized device (it derives `widget.screen`
      # through this window), then re-enter + repaint on the new terminal.
      enter
      realloc
      application.try do |app|
        app.emit ::Crysterm::Event::ScreenRemoved, old unless app.screens.includes? old
        app.emit ::Crysterm::Event::ScreenAdded, new_screen
      end
      render
      new_screen
    end

    # Device concerns delegated to this window's `Screen`. The surface code (and
    # external callers) keep calling these on the window; they resolve to the
    # device. `width`/`height` are the device size — a `Window` is full-screen,
    # so its surface size *is* its screen's size.
    delegate input, output, error,
      tput, draw_caps, colors, truecolor?,
      force_unicode?, full_unicode?,
      width, height, awidth, aheight,
      cell_pixel_width, cell_pixel_height,
      attr2code, code2attr, to: @screen

    # Setters are forwarded explicitly (`delegate` does not accept assignment
    # forms). The device size setters honor the surface being full-screen.
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
    # Can potentially be removed; it appears only in this file.
    # @@_bound = false
    # XXX Currently disabled to remove it if it appears not needed.

    # Screen title, if/when applicable
    getter title : String? = nil

    # :ditto:
    def title=(@title : String?)
      @title.try { |t| self.tput.title = t }
    end

    # Disabled since it seems unused atm
    # # XXX Rename to more intuitive name like `hovered_widget` or so. Or even remove since
    # # why just support one widget only? This looks like application-specific code.
    # # Current element being hovered over on the screen. Best set only if mouse events are enabled.
    # @hover : Widget? = nil

    # Rendering performance figures (R/D/FPS and terminal byte throughput) are no
    # longer drawn by the screen itself. Add a `Widget::Fps` to a screen to
    # display them; it reads the per-frame measurements exposed by
    # `screen_rendering.cr` (`#render_rate`, `#draw_rate`, `#frame_rate`,
    # `#throughput`, `#bytes_written`).

    # Optimization flags to use for rendering and/or drawing.
    # XXX See also a TODO item related to dynamically deciding on default flags.
    # ameba:disable Lint/UselessAssign
    Crystallabs::Helpers::Enums.enum_property optimization : OptimizationFlag = Config.render_optimization

    # `awidth`/`aheight` (the current device size) are delegated to `@screen`.

    # And these are the absolute ones. These are all 0 because `Screen`s are always full screen.

    # Disabled since nothing is currently using it. But uncomment when it becomes relevant.
    # getter aleft = 0
    # getter atop = 0
    # getter aright = 0
    # getter abottom = 0

    # Specifies what to do with "overflowing" (too large) widgets. The default setting of
    # `Overflow::Ignore` simply ignores the overflow and renders the parts that are in view.
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
      # alt = true, # Currently unused
      force_unicode : Bool = Config.screen_force_unicode,
      full_unicode : Bool = Config.screen_full_unicode,
      @resize_interval = @resize_interval,

      terminfo : Bool | Unibilium = true,

      # An already-built device may be passed directly (e.g. by `Application` or
      # a reattach). When omitted, one is constructed from the IO/terminfo args —
      # this is the "one app, one full-screen window on the default tty"
      # convenience that keeps `Window.new` a one-liner.
      screen : Screen? = nil,

      # Not needed for now. Also better not to couple with terminal specifics
      # @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
      # @use_buffer = false,
    )
      # Build (or adopt) the physical device. It owns IO, `Tput`, `draw_caps`,
      # color depth and the device cell size — all delegated back to this window.
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

      # Now that the screen is registered in `@@instances`, run the live terminal
      # probe that `Tput.new` skipped (see `probe: false` above). It round-trips
      # query sequences in raw mode; if a Ctrl+C interrupts it, `at_exit` ->
      # `Screen.instances.each &.destroy` -> `#restore_terminal` cooks the tty back
      # because this screen is now in the list. Runs before `_listen_keys` so it
      # does not race the input fiber for the reply bytes. Gated on the same config
      # flag `Tput.new` itself uses, and `probe!` no-ops on a non-tty.
      @screen.probe!

      # ensure tput.zero_based = true, use_buffer=true
      # set resizeTimeout

      # Tput is accessed via tput

      # super() No longer calling super, we are not subclass of Widget any more

      # _unicode is tput.features.unicode
      # full_unicode? is option full_unicode? + _unicode

      # Events:
      # addhander,

      # TODO These events are not for specific widgets, but when the whole program gets
      # those events. Enable and rework them as above ecample when we get to it.

      # on(Crysterm::Event::Focus) do
      #  emit Crysterm::Event::Focus
      # end

      # on(Crysterm::Event::Blur) do
      #  emit Crysterm::Event::Blur
      # end

      # on(Crysterm::Event::Warning) do |e|
      # emit e
      # end

      # XXX Why this is done here instead of in enter/leave?
      _listen_keys
      # _listen_mouse # XXX

      install_default_quit_keys if default_quit_keys?

      enter # if alt # Only do clear-screen/full-screen if user wants alternate buffer
      post_enter

      # Resolve and install the configured CSS theme (the default styling path).
      # Done after `enter`/`post_enter` so the terminal probe (background and
      # palette) the `"terminal"` theme reads has had a chance to complete.
      # `restyle` marks the tree dirty so the first render applies the theme.
      CSS.ensure_theme self
      # Apply the configured startup stylesheet (Config.colors_stylesheet), if
      # any, over the theme — unless the app already set one in code.
      apply_config_stylesheet
      # Seed CSS unit→cell divisors and the cell aspect ratio before the first
      # restyle resolves any unit'd geometry against them: config first (it can
      # pin the ratio), then the terminal's measured cell size (which still records
      # the pixel dimensions for media, but won't override a pinned ratio).
      CSS::Length.apply_config
      @screen.detect_cell_geometry
      restyle

      # Spawning the loop does not start rendering until the first call to #render
      # is issued. Therefore, it seems OK to call this from initialize.
      spawn render_loop
    end

    # The terminal cell-size detection now lives on the device `Screen`
    # (`#detect_cell_geometry` / `#refresh_cell_geometry`).

    def on_attach(e)
      # Adopt the size from this window's device, which sized itself from its own
      # output fd. Skipped when the size was pinned explicitly at construction
      # (headless / fixed-size), so it isn't replaced by a probed terminal size.
      @screen.adopt_terminal_size

      # Push resize event to screens assigned to this display. We choose this approach
      # because it results in less links between the components (as opposed to pull model).
      @_resize_handler = GlobalEvents.on(::Crysterm::Event::Resize) do |_|
        # When in-band resize (DEC 2048) is active, the terminal reports size
        # changes through the input stream, so ignore the SIGWINCH-driven global
        # signal — avoiding double handling and any dependence on SIGWINCH.
        schedule_resize unless _listened_in_band_resize?
      end
    end

    def on_detach(e)
      @_resize_handler.try { |handler| GlobalEvents.off ::Crysterm::Event::Resize, handler }

      # NOTE Per-screen teardown only. We deliberately do NOT cascade-destroy the
      # other `Screen.instances` here: with multiple emulator windows each screen
      # has an independent lifecycle, so closing/destroying one must not take the
      # others down. Whole-app shutdown is handled by `at_exit` (in `crysterm.cr`)
      # and by `Screen.exec_all`'s shared quit. Terminal-mode restore (`leave`,
      # `cooked!`) now happens in `#disconnect`, which `#destroy` calls.
    end

    # Destroys current `Display`.
    def on_destroy(e)
      on_detach(e)
    end

    def on_resize(e)
      # A pinned, explicitly-sized device ignores the terminal's reported size;
      # its dimensions only change when set directly (see `Screen#explicit_size?`).
      e.size.try { |size|
        @screen.set_size(size.width, size.height)
      }

      realloc
      render

      # For children (`Widget`s). I'd say the size doesn't mean anything to
      # the child widgets so we remove it. Or well, since it's there let's try
      # leaving it.
      # e.size = nil
      emit_descendants e
    end

    # The `Application` this window is being driven by, if any. Set when the
    # window is run via `Application#exec` (or added to an app). Lets `#exec` find
    # its app, and the window reach app-level services (clipboard, quit).
    property application : Application? = nil

    # Renders this window and runs the main loop. The actual loop lives on
    # `Application#exec` (the `QApplication::exec()` analogue); this convenience
    # delegates to the current application (creating one if none exists) so a
    # single-window program stays the one-liner `Window.new(...).exec`.
    #
    # This is similar to how it is done in the Qt framework.
    def exec : Nil
      (application || Application.global).exec self
    end

    # When any of `CRYSTERM_SHOT` / `CRYSTERM_DUMP` / `CRYSTERM_ANIM` is set, each
    # names a file to write the current screen to — a still PNG, a text `#dump`
    # golden, and/or an APNG (with `CRYSTERM_ANIM_SECS` / `CRYSTERM_ANIM_FPS`
    # tuning duration/rate). Renders one frame, writes whichever artifacts were
    # requested, and returns `true` so `exec` skips the interactive loop. Returns
    # `false` (the normal interactive case) when no capture var is set. This is
    # what makes every Crysterm program self-capturable headlessly.
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
      # TODO make it possible to work without switching the whole app to alt buffer.
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
    # 'Dirty' typically indicates that lines have to be redrawn. In this function's current implementation,
    # if dirty is true it will re-crete the field of screen cells, not adjust the size of existing one.
    def alloc(dirty = false)
      # If dirty=true, we just call `@lines.clear` and then re-create rows and cols from scratch.
      # In other cases, to optimize a little bit we try to just implement differences (i.e. enlarge
      # or shrink existing array).
      #
      # NOTE
      # dirty=true is mostly used during resizing to empty all cells, because `clear_last_rendered_pos`
      # seems to not clear the correct area in case of resize (it sees the resized values by the
      # time it runs).
      # It is also quite possible that the above finding is an indication of an error which
      # is causing dirty=true (and/or the logic how it is applied below) to not work correctly, so that
      # a re-creation was necessary on resize. Remains to be checked whether any further errors related
      # to this code and/or dirty= will come up or not.
      old_height = @lines.size
      new_height = aheight

      old_width = @lines[0]?.try(&.size) || 0
      new_width = awidth

      if !dirty
        do_clear = false
      else
        do_clear = true
        # Reset BOTH buffers. Resetting only `@lines` left `@olines` at its old
        # size while `add_row` below pushes to both, so after every resize
        # `@olines` grew unbounded (leak) and its rows no longer lined up with
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

      # If nr. of rows has changed, add or remove changed rows as appropriate.
      # When adding/extending, columns in the rows are created from scratch, of course.
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

    # Appends one fresh, width-adjusted row to *buf*, marked `dirty` — the block
    # `add_row` runs identically for `@lines` and `@olines` to grow them in
    # lock-step.
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
      # TODO make it possible to work without switching the whole
      # app to alt buffer. (Same note as in `enter`).
      # This assumes that enter activated alt mode.
      return unless tput.is_alt

      tput.disable_keypad

      if (tput.scroll_top != 0) || (tput.scroll_bottom != aheight - 1)
        tput.set_scroll_region(0, tput.screen.height - 1)
      end

      # XXX For some reason if alloc/clear() is before this
      # line, it doesn't work on linux console.
      show_cursor
      alloc

      # `leave` owns disabling the mouse on the alt-screen teardown path: clear
      # the flag too so a subsequent `restore_terminal` sees it false and does
      # not redundantly call `disable_mouse` again. On the non-alt path this
      # method early-returns above and never reaches here, leaving the flag set
      # so `restore_terminal` still disables the mouse itself.
      if @_listened_mouse
        disable_mouse
        @_listened_mouse = false
      end

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

    # Destroys self and removes it from the global list of `Screen`s.
    # Also remove all global events relevant to the object.
    # If no screens remain, the app is essentially reset to its initial state.
    def destroy
      return if @destroyed
      @destroyed = true

      # Signal the render fiber to exit, then wake it so it notices.
      @render_stop = true
      schedule_render

      # Stop the stylesheet hot-reload monitor thread, if one is running.
      unwatch_stylesheet

      # XXX Needs some small fix before enabling. Probably just the order of
      # destroyals needs to be bottom-up instead of top-down.
      # @children.each &.destroy

      # Tear down the terminal connection (restores the terminal, stops the input
      # fiber, closes owned IO and any spawned window). For the launching screen
      # this is the old `leave` plus line-discipline restore; for screens bound to
      # spawned windows it also closes the window.
      disconnect

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
    # This is the single call that does it: it constructs a new screen on
    # *term*'s terminfo (copying this screen's salient options — but not its IO,
    # which the new screen opens fresh, since `#destroy` closes this one's),
    # reparents every widget onto it, destroys this screen, and returns the new
    # one. Re-`render`/`exec` the returned screen.
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
    # screen, and returns *other*. The migration half of `#switch_terminal`; also
    # usable on its own to move a whole UI between two existing screens.
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

  end
end
