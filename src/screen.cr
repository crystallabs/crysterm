require "./display"
require "./macros"
require "./widget"

require "./mixin/children"

require "./screen_children"
require "./screen_angles"
require "./screen_attributes"
require "./screen_cursor"
require "./screen_drawing"
require "./screen_focus"
require "./screen_rendering"
require "./screen_rows"

module Crysterm
  # Represents a screen.
  class Screen
    include EventHandler
    include Helpers

    include Mixin::Pos
    include Mixin::Children
    include Mixin::Instances

    # :nodoc: Flag indicating whether at least one `Screen` has called `#bind`.
    # Can potentially be removed; it appears only in this file.
    # @@_bound = false
    # XXX Currently disabled to remove it if it appears not needed.

    # Associated `Crysterm` instance. The default display
    # will be created and/or used if it is not provided explicitly.
    property display : Display = Display.global(true)

    # Is the focused element grabbing and receiving all keypresses?
    property grab_keys = false

    # Are keypresses (except ignored ones) prevented from being sent to any element?
    property lock_keys = false

    # Array of keys to ignore when keys are locked or grabbed. Useful for defining
    # keys that will always execute their action (e.g. exit a program) regardless of
    # whether keys are locked.
    property ignore_locked = Array(Tput::Key).new
    # XXX Maybe in the future this would not be just `Tput::Key`s (which indicate
    # special keys), but also chars (ordinary letters) as well as sequences (arbitrary
    # sequences of chars and keys).

    # Current element being hovered over on the screen. Best set only if mouse events are enabled.
    @hover : Widget? = nil

    # Which position on the screen should be used to display FPS stats. Nil disables.
    property show_fps : Tput::Point? = Tput::Point[-1, 0]

    # Include displaying averages in FPS display. If this setting is false, only current/
    # individual frame rates are shown, without values for averages over 30 frames.
    property? show_avg = true

    # Optimization flags to use for rendering and/or drawing.
    property optimization : OptimizationFlag = OptimizationFlag::None

    # Screen title
    getter title : String? = nil

    # :ditto:
    def title=(title : String)
      @display.try &.tput.title=(@title = title)
    end

    # For compatibility with widgets. But, as a side-effect, screens can have
    # padding.
    property padding : Padding

    # property border : Border?
    # TODO Right now `Screen`s can't have a border. But it would be amazing if they could.
    # The infrastructure is there because `Screen`s share many properties with `Widget`s.
    # Hopefully only minimal work would be needed to support it.

    # Inner/content positions. These are defined here instead of assumed to all be 0 due
    # to 2 reasons:
    # - Places where method `parent_or_screen` is called expect these to exist on both types
    # - And due to future improvement of supporting a border and possibly other features on
    # `Screen`s (like maybe shadow, or padding?) it will be very useful to have these variables.

    def ileft
      @padding.left
    end

    def itop
      @padding.top
    end

    def iright
      @padding.right
    end

    def ibottom
      @padding.bottom
    end

    # property iwidth = 0
    # property iheight = 0

    # Disabled since nothing is currently using it. But uncomment when it becomes relevant.
    # getter rleft = 0
    # getter rtop = 0
    # getter rright = 0
    # getter rbottom = 0

    # And these are the absolute ones. These are all 0 because `Screen`s are always the full
    # size of a `Display`. It would be interesting to see in the future if we could allow multiple
    # `Screen`s of varying sizes to be showing on a `Display` at the same time.

    # Disabled since nothing is currently using it. But uncomment when it becomes relevant.
    # getter aleft = 0
    # getter atop = 0
    # getter aright = 0
    # getter abottom = 0

    # Relative positions are the default and are aliased to the left/top/right/bottom methods.
    # TODO Consider if, next to these 3 already different values (ileft, rleft, aleft), the
    # default left/top/right/bottom, which are aliases for relative coordinates, are too much
    # and if we should just remove them in favor of explicitly using one of these 3.

    # Specifies what to do with "overflowing" (too large) widgets. The default setting of
    # `Overflow::Ignore` simply ignores the overflow and renders the parts that are in view.
    property overflow = Overflow::Ignore

    def initialize(
      @display = Display.global(true),
      @dock_borders = true,
      @dock_contrast = DockContrast::Ignore,
      ignore_locked : Array(Tput::Key)? = nil,
      @lock_keys = false,
      title = nil,
      @cursor = Cursor.new,
      optimization = OptimizationFlag::SmartCSR | OptimizationFlag::BCE,
      padding = Padding.new,
      alt = true,
      show_fps = true
    )
      @padding = parse_padding padding

      bind

      ignore_locked.try { |v| @ignore_locked += v }
      optimization.try { |v| @optimization = v }

      @show_fps = show_fps ? Tput::Point[-1, 0] : nil

      # @display = display || Display.global true
      # ensure tput.zero_based = true, use_bufer=true
      # set resizeTimeout

      # Tput is accessed via display.tput

      # super() No longer calling super, we are not subclass of Widget any more

      # _unicode is display.tput.features.unicode
      # full_unicode? is option full_unicode? + _unicode

      # Events:
      # addhander,

      if t = title || Display.global.title
        self.title = t
      end

      display.on(Crysterm::Event::Resize) do
        alloc
        render

        ev_resize = Crysterm::Event::Resize.new
        # For `self` (`Screen`)
        emit ev_resize
        # For children (`Widget`s)
        emit_descendants ev_resize
      end

      display.on(Crysterm::Event::Focus) do
        emit Crysterm::Event::Focus
      end

      display.on(Crysterm::Event::Blur) do
        emit Crysterm::Event::Blur
      end

      # display.on(Crysterm::Event::Warning) do |e|
      # emit e
      # end

      _listen_keys
      # _listen_mouse # XXX

      enter if alt # Only do clear-screen/full-screen if user wants alternate buffer
      post_enter

      spawn render_loop
    end

    def enter
      # TODO make it possible to work without switching the whole
      # app to alt buffer.
      return if display.tput.is_alt

      if !cursor._set
        apply_cursor
      end

      # XXX Livable, but boy no.
      {% if flag? :windows %}
        `cls`
      {% end %}

      display.tput.alternate_buffer
      display.tput.put(&.keypad_xmit?) # enter_keyboard_transmit_mode
      display.tput.put(&.change_scroll_region?(0, aheight - 1))
      hide_cursor
      display.tput.cursor_pos 0, 0
      display.tput.put(&.ena_acs?) # enable_acs

      alloc
    end

    # Allocates screen buffers (a new pending/staging buffer and a new output buffer).
    def alloc(dirty = false)
      # Here we could just call `@lines.clear` and then re-create rows and cols from scratch.
      # But to optimize a little bit, we try to just implement differences (i.e. enlarge or
      # shrink existing array).

      old_height = @lines.size
      new_height = aheight

      old_width = @lines[0]?.try(&.size) || 0
      new_width = awidth

      do_clear = false

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

      display.tput.clear if do_clear
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
      return unless display.tput.is_alt

      display.tput.put(&.keypad_local?)

      if (display.tput.scroll_top != 0) || (display.tput.scroll_bottom != aheight - 1)
        display.tput.set_scroll_region(0, display.tput.screen.height - 1)
      end

      # XXX For some reason if alloc/clear() is before this
      # line, it doesn't work on linux console.
      show_cursor
      alloc

      # TODO Enable all in this function
      # if (this._listened_mouse)
      #  display.disable_mouse
      # end

      display.tput.normal_buffer
      if cursor._set
        cursor_reset
      end

      display.tput.flush

      # :-)
      {% if flag? :windows %}
        `cls`
      {% end %}
    end

    def post_enter
      # Debug helpers/setup
    end

    # Returns current screen width.
    def awidth
      display.tput.screen.width
    end

    # Returns current screen height.
    def aheight
      display.tput.screen.height
    end

    # Returns current screen width.
    def iwidth
      @padding.left + @padding.right
    end

    # Returns current screen height.
    def iheight
      @padding.top + @padding.bottom
    end

    # TODO Instead of self, this should just return an object which reports the position.
    def last_rendered_position
      self
    end

    # This is for the bottom-up approach where the keys are
    # passed onto the focused widget, and from there eventually
    # propagated to the top.
    # def _listen_keys
    #  display.on(Crysterm::Event::KeyPress) do |e|
    #    el = focused || self
    #    while !e.accepted? && el
    #      # XXX emit only if widget enabled?
    #      el.emit e
    #      el = el.parent
    #    end
    #  end
    # end

    # Destroys self and removes it from the global list of `Screen`s.
    # Also remove all global events relevant to the object.
    # If no screens remain, the app is essentially reset to its initial state.
    def destroy
      @render_flag.set 2

      # XXX Needs some small fix before enabling. Probably just the order of
      # destroyals needs to be bottom-up instead of top-down.
      # @children.each &.destroy

      leave

      super
    end

    def enable_keys(el = nil)
      _listen_keys(el)
    end

    def enable_input(el = nil)
      # _listen_mouse(el)
      _listen_keys(el)
    end

    # And this is for the other/alternative method where the screen
    # first gets the keys, then potentially passes onto children
    # elements.
    def _listen_keys(el : Widget? = nil)
      if (el && !@keyable.includes? el)
        el.keyable = true
        @keyable.push el
      end

      return if @_listened_keys
      @_listened_keys = true

      # Note: The event emissions used to be reversed:
      # element + screen
      # They are now:
      # screen, element and el's parents until one #accept!s it.
      # After the first keypress emitted, the handler
      # checks to make sure grab_keys, lock_keys, and focused
      # weren't changed, and handles those situations appropriately.
      display.on(Crysterm::Event::KeyPress) do |e|
        if @lock_keys && !@ignore_locked.includes?(e.key)
          next
        end

        grab_keys = @grab_keys
        if !grab_keys || @ignore_locked.includes?(e.key)
          emit_key self, e
        end

        # If something changed from the screen key handler, stop.
        if (@grab_keys != grab_keys) || @lock_keys || e.accepted?
          next
        end

        # Here we pass the key press onto the focused widget. Then
        # we keep passing it through the parent tree until someone
        # `#accept!`s the key. If it reaches the toplevel Widget
        # and it isn't handled, we drop/ignore it.
        focused.try do |el2|
          while el2 && el2.is_a? Widget
            if el2.keyable?
              emit_key el2, e
            end

            if e.accepted?
              break
            end

            el2 = el2.parent
          end
        end
      end
    end

    # Emits a Event::KeyPress as usual and also emits an event for
    # the individual key, if any.
    #
    # This allows listeners to not only listen for a generic
    # `Event::KeyPress` and then check for `#key`, but they can
    # directly listen for e.g. `Event::KeyPress::CtrlP`.
    @[AlwaysInline]
    def emit_key(el, e : Event)
      if el.handlers(e.class).any?
        el.emit e
      end
      if e.key
        Crysterm::Event::KeyPress::KEYS[e.key]?.try do |keycls|
          if el.handlers(keycls).any?
            el.emit keycls.new e.char, e.key, e.sequence
          end
        end
      end
    end

    # TODO Empty for now
    def key(key, handler)
    end

    def once_key(key, handler)
    end

    def remove_key(key, wrapper)
    end

    def sigtstp(callback)
      display.sigtstp {
        alloc
        render
        display.lrestore_cursor :pause, true
        callback.call if callback
      }
    end
  end
end
