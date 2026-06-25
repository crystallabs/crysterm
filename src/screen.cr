require "./macros"
require "./widget"

require "./mixin/children"

require "./screen_resize"
require "./screen_interaction"
require "./screen_mouse"
require "./screen_drag"

require "./screen_children"
require "./screen_attributes"
require "./screen_cursor"
require "./screen_decoration"
require "./screen_rendering"
require "./screen_damage"
require "./screen_drawing"
require "./screen_focus"
require "./screen_rows"
require "./screen_interaction"
require "./screen_capture"

module Crysterm
  # How a `Screen` built without explicit IO chooses between a real terminal and
  # a headless (in-memory) connection. See `Crysterm.headless?`.
  enum Headless
    Auto # Decide automatically: headless iff the app is non-interactive (output is not a TTY)
    Yes  # Always headless, even on a real terminal
    No   # Always use the real terminal, even when non-interactive
  end

  # Represents a screen.
  class Screen
    include EventHandler
    include Mixin::Name
    include Mixin::Pos
    include Mixin::Children
    include Mixin::Instances

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

    # Display width
    # TODO make these check @output, not STDOUT which is probably used. Also see how urwid does the size check
    property width = 1

    # Display height
    # TODO make these check @output, not STDOUT which is probably used. Also see how urwid does the size check
    property height = 1

    # Instance of `Tput`, used for generating term control sequences.
    getter tput : ::Tput

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
    Crystallabs::Helpers::Enums.enum_property optimization : OptimizationFlag = Config.render_optimization

    # Returns current screen width. This is now a local operation since we
    # expect Display to push-update us.
    def awidth
      @width
    end

    # Returns current screen height. This is now a local operation since we
    # expect Display to push-update us.
    def aheight
      @height
    end

    # And these are the absolute ones. These are all 0 because `Screen`s are always full screen.

    # Disabled since nothing is currently using it. But uncomment when it becomes relevant.
    # getter aleft = 0
    # getter atop = 0
    # getter aright = 0
    # getter abottom = 0

    # Specifies what to do with "overflowing" (too large) widgets. The default setting of
    # `Overflow::Ignore` simply ignores the overflow and renders the parts that are in view.
    Crystallabs::Helpers::Enums.enum_property overflow : Overflow = Config.screen_overflow

    def initialize(
      @input = @input,
      @output = @output,
      @error = @error,
      @title = @title,
      @width = @width,
      @height = @height,
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
      @force_unicode = @force_unicode,
      @full_unicode = @full_unicode,
      @resize_interval = @resize_interval,

      terminfo : Bool | Unibilium = true,

      # Not needed for now. Also better not to couple with terminal specifics
      # @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
      # @use_buffer = false,
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

      # XXX Should `error` fd be passed to tput as well?
      # (Probably not since we're not initializing anything on the error output?)
      @tput = ::Tput.new(
        terminfo: terminfo,
        input: @input,
        output: @output,
        force_unicode: @force_unicode,
        use_buffer: false,
      )
      # Derive the terminal's static draw capabilities once, here. They are
      # re-derived wherever `@tput` is rebuilt (see `#connect`).
      @draw_caps = compute_draw_caps
      # XXX Add those options too if needed:
      # term: @term,
      # padding: @padding,
      # extended: @extended,
      # termcap: @termcap,

      self.optimization = optimization
      padding.try { |padding| @padding = Padding.from(padding) }
      title.try { |t| self.title = t }

      @_resize_loop_fiber = spawn(name: "resize_loop") { resize_loop }

      handle ::Crysterm::Event::Attach
      handle ::Crysterm::Event::Detach
      handle ::Crysterm::Event::Destroy
      handle ::Crysterm::Event::Resize

      emit ::Crysterm::Event::Attach, self

      bind

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
      # Seed CSS unit→cell divisors from config (css.px_per_cell / css.unit_divisors)
      # before the first restyle resolves any unit'd geometry against them.
      CSS::Length.apply_config
      restyle

      # Spawning the loop does not start rendering until the first call to #render
      # is issued. Therefore, it seems OK to call this from initialize.
      spawn render_loop
    end

    def on_attach(e)
      # Take the size from *this* screen's own `tput`, which sized itself from
      # its own output fd. Using the global `::Term::Screen` here would probe
      # STDIN/STDOUT and give every screen the launching terminal's size.
      @width = self.tput.screen.width
      @height = self.tput.screen.height

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
      @_resize_handler.try { |e| GlobalEvents.off ::Crysterm::Event::Resize, e }

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
      e.size.try { |size|
        @width = size.width
        @height = size.height
      }

      realloc
      render

      # For children (`Widget`s). I'd say the size doesn't mean anything to
      # the child widgets so we remove it. Or well, since it's there let's try
      # leaving it.
      # e.size = nil
      emit_descendants e
    end

    # Displays the main screen, set up IO hooks, and starts the main loop.
    #
    # This is similar to how it is done in the Qt framework.
    #
    # This function will render the specified `screen` or the first `Screen` assigned to `Display`.
    def exec(screen : Crysterm::Screen? = nil)
      s = self

      # if s.display != self
      #  raise Exception.new "Screen does not belong to this Display."
      # end

      if s
        s.render
      else
        # XXX This part might be changed in the future, if we allow running line-
        # rather than screen-based apps, or if we allow something headless.
        raise Exception.new "No Screen exists, there is nothing to render and run."
      end

      listen

      # The main loop is currently just a sleep :)
      sleep

      # Shouldn't reach for now
      emit ::Crysterm::Event::Detach, self
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
      col = Row.new
      adjust_width col, 0, awidth, dirty
      @lines.push col
      @lines[-1].dirty = dirty

      col = Row.new
      adjust_width col, 0, awidth, dirty
      @olines.push col
      @olines[-1].dirty = dirty
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

      if @_listened_mouse
        disable_mouse
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
