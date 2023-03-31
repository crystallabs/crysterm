require "./macros"
require "./widget"

require "./mixin/children"

require "./screen_resize"
require "./screen_interaction"

require "./screen_children"
require "./screen_angles"
require "./screen_attributes"
require "./screen_cursor"
require "./screen_decoration"
require "./screen_rendering"
require "./screen_drawing"
require "./screen_focus"
require "./screen_rows"
require "./screen_interaction"
require "./screen_screenshot"

module Crysterm
  # Represents a screen.
  class Screen
    include EventHandler
    include Mixin::Name
    include Mixin::Pos
    include Mixin::Children
    include Mixin::Instances

    # Input IO
    property input : IO = STDIN.dup

    # Output IO
    property output : IO = STDOUT.dup

    # Error IO. (Could be used for redirecting error output to a particular widget.)
    property error : IO = STDERR.dup

    # Force Unicode (UTF-8) even if terminfo auto-detection did not find support for it?
    property? force_unicode = false

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

    # Which position on the screen should be used to display FPS stats. Nil disables.
    # XXX Currently this is enabled since Crysterm is under development.
    property show_fps : Tput::Point? = Tput::Point[-1, 0]

    # Include displaying averages in FPS display. If this setting is false, only current/
    # individual frame rates are shown, without values for averages over 30 frames.
    property? show_avg = true

    # Optimization flags to use for rendering and/or drawing.
    # XXX See also a TODO item related to dynamically deciding on default flags.
    property optimization : OptimizationFlag = OptimizationFlag::None

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
    property overflow = Overflow::Ignore

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
      @cursor = @cursor,
      @optimization = @optimization,
      padding = nil,
      # alt = true, # Currently unused
      @show_fps = @show_fps,
      @force_unicode = @force_unicode,
      @resize_interval = @resize_interval,

      terminfo : Bool | Unibilium::Terminfo = true

      # Not needed for now. Also better not to couple with terminal specifics
      # @term = ENV["TERM"]? || "{% if flag?(:windows) %}windows-ansi{% else %}xterm{% end %}"
      # @use_buffer = false,
    )
      terminfo = case terminfo
                 in true
                   Unibilium::Terminfo.from_env
                 in false, nil
                   nil
                 in Unibilium::Terminfo
                   terminfo.as Unibilium::Terminfo
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
      # XXX Add those options too if needed:
      # term: @term,
      # padding: @padding,
      # extended: @extended,
      # termcap: @termcap,

      padding.try { |padding| @padding = Padding.from(padding) }
      title.try { |t| self.title = t }

      @_resize_fiber = Fiber.new "resize_loop" { resize_loop }

      handle ::Crysterm::Event::Attach
      handle ::Crysterm::Event::Detach
      handle ::Crysterm::Event::Destroy
      handle ::Crysterm::Event::Resize

      emit ::Crysterm::Event::Attach, self

      bind

      # ensure tput.zero_based = true, use_bufer=true
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

      enter # if alt # Only do clear-screen/full-screen if user wants alternate buffer
      post_enter

      # Spawning the loop does not start rendering until the first call to #render
      # is issued. Therefore, it seems OK to call this from initialize.
      spawn render_loop
    end

    def on_attach(e)
      @width = ::Term::Screen.cols || @width
      @height = ::Term::Screen.rows || @height

      # Push resize event to screens assigned to this display. We choose this approach
      # because it results in less links between the components (as opposed to pull model).
      @_resize_handler = GlobalEvents.on(::Crysterm::Event::Resize) do |e|
        schedule_resize
      end
    end

    def on_detach(e)
      @_resize_handler.try { |e| GlobalEvents.off ::Crysterm::Event::Resize, e }

      Screen.instances.each do |s|
        # s.leave # No need, done as part of Screen#destroy
        s.destroy
      end

      # TODO Don't do this unconditionally, but return to whatever
      # state it was in before.
      @input.try { |i|
        if i.responds_to? :"cooked!"
          i.cooked!
        end
      }
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
      tput.put(&.keypad_xmit?) # enter_keyboard_transmit_mode
      tput.put(&.change_scroll_region?(0, aheight - 1))
      hide_cursor
      tput.cursor_pos 0, 0
      tput.put(&.ena_acs?) # enable_acs

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
        @lines = Array(Row).new
        old_height = 0
        old_width = 0
      end

      # If nr. of columns has changed, adjust width in existing rows
      if old_width != new_width
        do_clear = true

        Math.min(old_height, new_height).times do |i|
          adjust_width @lines[i], old_width, new_width, dirty
          @lines[-1].dirty = dirty
          @olines[-1].dirty = dirty
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
    end

    @[AlwaysInline]
    private def adjust_width(line, old_width, new_width, dirty)
      diff = new_width - old_width
      if diff > 0
        diff.times do
          line.push Cell.new
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

      tput.put(&.keypad_local?)

      if (tput.scroll_top != 0) || (tput.scroll_bottom != aheight - 1)
        tput.set_scroll_region(0, tput.screen.height - 1)
      end

      # XXX For some reason if alloc/clear() is before this
      # line, it doesn't work on linux console.
      show_cursor
      alloc

      # TODO Enable all in this function
      # if (this._listened_mouse)
      #  display.disable_mouse
      # end

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
      #        inverse: true
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
      @render_flag.set 2

      # XXX Needs some small fix before enabling. Probably just the order of
      # destroyals needs to be bottom-up instead of top-down.
      # @children.each &.destroy

      leave

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

    # Reduces color if needed (minmal helper function)
    private def _reduce_color(col)
      Colors.reduce(col, tput.features.number_of_colors)
    end
  end
end
