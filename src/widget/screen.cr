require "./node"
require "../application"
require "./screen/*"

module Crysterm
  # Represents a screen. `Screen` and `Element` are two lowest-level classes after `EventEmitter` and `Node`.
  class Screen < Node
    include Screen::Focus
    include Screen::Attributes
    include Screen::Angles
    include Screen::Rendering
    include Screen::Drawing
    include Screen::Cursor
    include Element::Pos

    class_getter instances = [] of self

    def self.total
      @@instances.size
    end

    def self.global
      instances[0]?.not_nil!
    end

    @@_bound = false

    # Associated `Crysterm` instance. The default application object
    # will be created/used if it is not provided explicitly.
    property! application : Application

    # Array of keys to ignore when keys are locked or grabbed. Useful for defining
    # keys that will always execute their action (e.g. exit a program) regardless of
    # whether keys are locked.
    property ignore_locked = Array(Tput::Key).new

    # Currently hovered element. Best set only if mouse events are enabled.
    @hover : Element? = nil

    property show_fps : Point? = Point[-1,0]
    property? show_avg = true

    property optimization : OptimizationFlag = OptimizationFlag::None

    def initialize(
      application = nil,
      @auto_padding = true,
      @tab_size = 4,
      @dock_borders = false,
      ignore_locked : Array(Tput::Key)? = nil,
      title = nil,
      @cursor = Tput::Namespace::Cursor.new,
      optimization = nil
    )
      bind

      ignore_locked.try { |v| @ignore_locked.push v }
      optimization.try { |v| @optimization = v }

      @application = application ||= Application.new
      # ensure tput.zero_based = true, use_bufer=true
      # set resizeTimeout

      # Tput is accessed via application.tput

      super()

      @tabc = " " * @tab_size

      # _unicode is application.tput.features.unicode
      # full_unicode? is option full_unicode? + _unicode

      # Events:
      # addhander,

      self.title = title if title

      application.on(ResizeEvent) do
        alloc
        render

        # XXX Can we replace this with each_descendant?
        f = uninitialized Node -> Nil
        f = ->(el : Node) {
          el.emit ResizeEvent
          el.children.each { |c| f.call c }
        }
        f.call self
      end

      application.on(FocusEvent) do
        emit FocusEvent
      end
      application.on(BlurEvent) do
        emit BlurEvent
      end
      application.on(WarningEvent) do |e|
        emit e
      end

      _listen_keys
      # _listen_mouse # XXX

      enter
      post_enter

      spawn render_loop
    end

    # This is for the bottom-up approach where the keys are
    # passed onto the focused widget, and from there eventually
    # propagated to the top.
    # def _listen_keys
    #  application.on(KeyPressEvent) do |e|
    #    el = focused || self
    #    while !e.accepted? && el
    #      # XXX emit only if widget enabled?
    #      el.emit e
    #      el = el.parent
    #    end
    #  end
    # end

    # And this is for the other/alternative method where the screen
    # first gets the keys, then potentially passes onto children
    # elements.
    def _listen_keys(el : Element? = nil)
      if (el && !@keyable.includes? el)
        el.keyable = true
        @keyable.push el
      end

      return if @_listenedKeys
      @_listenedKeys = true

      # NOTE: The event emissions used to be reversed:
      # element + screen
      # They are now:
      # screen, element and el's parents until one #accept!s it.
      # After the first keypress emitted, the handler
      # checks to make sure grab_keys, lock_keys, and focused
      # weren't changed, and handles those situations appropriately.
      application.on(KeyPressEvent) do |e|
        if @lock_keys && !@ignore_locked.includes?(e.key)
          next
        end

        grab_keys = @grab_keys
        if !grab_keys || @ignore_locked.includes?(e.key)
          emit_key self, e
        end

        # If something changed from the screen key handler, stop.
        if (@grab_keys != grab_keys) || @lock_keys
          next
        end

        # Here we pass the key press onto the focused widget. Then
        # we keep passing it through the parent tree until someone
        # `#accept!`s the key. If it reaches the toplevel Element
        # and it isn't handled, we drop/ignore it.
        focused.try do |el|
          while el && el.is_a? Element
            if el.keyable?
              emit_key el, e
            end

            if e.accepted?
              break
            end

            el = el.parent
          end
        end
      end
    end

    # Emits a KeyPressEvent as usual and also emits an event for
    # the individual key, if any.
    #
    # This allows listeners to not only listen for a generic
    # `KeyPressEvent` and then check for `#key`, but they can
    # directly listen for e.g. `KeyPressEvent::CtrlP`.
    @[AlwaysInline]
    def emit_key(el, e : Event)
      if el.handlers(e.class).any?
        el.emit e
      end
      if e.key
        Crysterm::Application.key_events[e.key]?.try do |keycls|
          if el.handlers(keycls).any?
            el.emit keycls.new e.char, e.key, e.sequence
          end
        end
      end
    end

    def enable_keys(el = nil)
      _listen_keys(el)
    end

    def enable_input(el = nil)
      # _listen_mouse(el)
      _listen_keys(el)
    end

    # TODO Empty for now
    def key(key, handler)
    end

    def once_key(key, handler)
    end

    def remove_key(key, wrapper)
    end

    def bind
      @@global = self unless @@global

      @@instances << self # unless @@instances.includes? self

      return if @@_bound
      @@_bound = true

      # TODO Enable
      # ['SIGTERM', 'SIGINT', 'SIGQUIT'].each do |signal|
      #  name = '_' + signal.toLowerCase() + 'Handler'
      #  Signal::<>.trap do
      #    if listeners(signal).size > 1
      #      return;
      #    end
      #    process.exit(0);
      #  end
      # end
    end

    def enter
      # TODO make it possible to work without switching the whole
      # application to alt buffer.
      return if application.tput.is_alt

      if !cursor._set
        if cursor.shape
          cursor_shape cursor.shape, cursor.blink
        end
        if cursor.color
          cursor_color cursor.color
        end
      end

      # XXX Livable, but boy no.
      {% if flag? :windows %}
        `cls`
      {% end %}

      at = application.tput
      application.tput.alternate_buffer
      application.tput.put(&.keypad_xmit?) # enter_keyboard_transmit_mode
      application.tput.put(&.change_scroll_region?(0, height - 1))
      application.tput.hide_cursor
      application.tput.cursor_pos 0, 0
      application.tput.put(&.ena_acs?) # enable_acs

      alloc
    end

    # Allocates screen buffers (a new pending/staging buffer and a new output buffer).
    def alloc(dirty = false)
      # Initialize @lines better than this.
      rows.times do |i|
        col = Row.new
        columns.times do
          col.push Cell.new
        end
        @lines.push col
        @lines[-1].dirty = dirty
      end

      # Initialize @lines better than this.
      rows.times do |i|
        col = Row.new
        columns.times do
          col.push Cell.new
        end
        @olines.push col
        @olines[-1].dirty = dirty
      end

      application.tput.clear
    end

    # Reallocates screen buffers and clear the screen.
    def realloc
      alloc dirty: true
    end

    def leave
      # TODO make it possible to work without switching the whole
      # application to alt buffer. (Same note as in `enter`).
      return unless application.tput.is_alt

      application.tput.put(&.keypad_local?)

      if (application.tput.scroll_top != 0) || (application.tput.scroll_bottom != height - 1)
        application.tput.set_scroll_region(0, application.tput.screen.height - 1)
      end

      # XXX For some reason if alloc/clear() is before this
      # line, it doesn't work on linux console.
      application.tput.show_cursor
      alloc

      # TODO Enable all in this function
      # if (this._listened_mouse)
      #  application.disable_mouse
      # end

      application.tput.normal_buffer
      if cursor._set
        application.tput.cursor_reset
      end

      application.tput.flush

      # :-)
      {% if flag? :windows %}
        `cls`
      {% end %}
    end

    # Debug helpers/setup
    def post_enter
    end

    # Destroys self and removes it from the global list of `Screen`s.
    # Also remove all global events relevant to the object.
    # If no screens remain, the application is essentially reset to its initial state.
    def destroy
      leave

      @render_flag.set 2

      if @@instances.delete self
        if @@instances.any?
          @@global = @@instances[0]
        else
          @@global = nil
          # TODO remove all signal handlers set up on the app's process
          @@_bound = false
        end

        @destroyed = true
        emit DestroyEvent

        super
      end

      application.destroy
    end

    # Returns current screen width.
    # XXX Remove in favor of other ways to retrieve it.
    def columns
      # XXX replace with a per-screen method
      application.tput.screen.width
    end

    # Returns current screen height.
    # XXX Remove in favor of other ways to retrieve it.
    def rows
      # XXX replace with a per-screen method
      application.tput.screen.height
    end

    # Returns current screen width.
    # XXX Remove in favor of other ways to retrieve it.
    def width
      columns
    end

    # Returns current screen height.
    # XXX Remove in favor of other ways to retrieve it.
    def height
      rows
    end

    def _get_pos
      self
    end

    ##### Unused parts: just compatibility with `Node` interface.
    def clear_pos
    end

    property border : Border?

    # Inner/content positions:
    # XXX Remove when possible
    property ileft = 0
    property itop = 0
    property iright = 0
    property ibottom = 0
    #property iwidth = 0
    #property iheight = 0

    property overflow = Overflow::Ignore

    ##### End of unused parts.

    def hidden?
      false
    end

    def child_base
      0
    end

    # XXX for now, this just forwards to parent. But in reality,
    # it should be able to have its own title, and when it goes
    # in/out of focus, that title should be set/restored.
    def title
      @application.title
    end

    def title=(arg)
      @application.title = arg
    end

    def sigtstp(callback)
      application.sigtstp {
        alloc
        render
        application.lrestore_cursor :pause, true
        callback.call if callback
      }
    end
  end
end
