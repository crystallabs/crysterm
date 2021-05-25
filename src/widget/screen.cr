require "./node"
require "../app"
require "./screen/*"

module Crysterm
  module Widget
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

      def self.global(create : Bool = true)
        (instances[0]? || (create ? new : nil)).not_nil!
      end

      @@_bound = false

      # Associated `Crysterm` instance. The default app object
      # will be created/used if it is not provided explicitly.
      property! app : App

      # Is focused element grabbing and receiving all keypresses?
      property grab_keys = false

      # Are keypresses prevented from being sent to any element?
      property lock_keys = false

      # Array of keys to ignore when keys are locked or grabbed. Useful for defining
      # keys that will always execute their action (e.g. exit a program) regardless of
      # whether keys are locked.
      property ignore_locked = Array(Tput::Key).new

      # Currently hovered element. Best set only if mouse events are enabled.
      @hover : Element? = nil

      property show_fps : Tput::Point? = Tput::Point[-1,0]
      property? show_avg = true

      property optimization : OptimizationFlag = OptimizationFlag::None

      def initialize(
        @app = App.global(true),
        @auto_padding = true,
        @tab_size = 4,
        @dock_borders = false,
        ignore_locked : Array(Tput::Key)? = nil,
        @lock_keys = false,
        title = nil,
        @cursor = Tput::Namespace::Cursor.new,
        optimization = nil
      )
        bind

        ignore_locked.try { |v| @ignore_locked += v }
        optimization.try { |v| @optimization = v }

        #@app = app || App.global true
        # ensure tput.zero_based = true, use_bufer=true
        # set resizeTimeout

        # Tput is accessed via app.tput

        super()

        @tabc = " " * @tab_size

        # _unicode is app.tput.features.unicode
        # full_unicode? is option full_unicode? + _unicode

        # Events:
        # addhander,

        self.title = title if title

        app.on(Crysterm::Event::Resize) do
          alloc
          render

          # XXX Can we replace this with each_descendant?
          f = uninitialized Node -> Nil
          f = ->(el : Node) {
            el.emit Crysterm::Event::Resize
            el.children.each { |c| f.call c }
          }
          f.call self
        end

        app.on(Crysterm::Event::Focus) do
          emit Crysterm::Event::Focus
        end
        app.on(Crysterm::Event::Blur) do
          emit Crysterm::Event::Blur
        end
        app.on(Crysterm::Event::Warning) do |e|
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
      #  app.on(Crysterm::Event::KeyPress) do |e|
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
        app.on(Crysterm::Event::KeyPress) do |e|
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
          Crysterm::App.key_events[e.key]?.try do |keycls|
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
        # app to alt buffer.
        return if app.tput.is_alt

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

        at = app.tput
        app.tput.alternate_buffer
        app.tput.put(&.keypad_xmit?) # enter_keyboard_transmit_mode
        app.tput.put(&.change_scroll_region?(0, height - 1))
        app.tput.hide_cursor
        app.tput.cursor_pos 0, 0
        app.tput.put(&.ena_acs?) # enable_acs

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

        app.tput.clear
      end

      # Reallocates screen buffers and clear the screen.
      def realloc
        alloc dirty: true
      end

      def leave
        # TODO make it possible to work without switching the whole
        # app to alt buffer. (Same note as in `enter`).
        return unless app.tput.is_alt

        app.tput.put(&.keypad_local?)

        if (app.tput.scroll_top != 0) || (app.tput.scroll_bottom != height - 1)
          app.tput.set_scroll_region(0, app.tput.screen.height - 1)
        end

        # XXX For some reason if alloc/clear() is before this
        # line, it doesn't work on linux console.
        app.tput.show_cursor
        alloc

        # TODO Enable all in this function
        # if (this._listened_mouse)
        #  app.disable_mouse
        # end

        app.tput.normal_buffer
        if cursor._set
          app.tput.cursor_reset
        end

        app.tput.flush

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
      # If no screens remain, the app is essentially reset to its initial state.
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
          emit Crysterm::Event::Destroy

          super
        end

        app.destroy
      end

      # Returns current screen width.
      # XXX Remove in favor of other ways to retrieve it.
      def columns
        # XXX replace with a per-screen method
        app.tput.screen.width
      end

      # Returns current screen height.
      # XXX Remove in favor of other ways to retrieve it.
      def rows
        # XXX replace with a per-screen method
        app.tput.screen.height
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

      # Relative positions are the default and are aliased to the
      # left/top/right/bottom methods.
      getter rleft = 0
      getter rtop = 0
      getter rright = 0
      getter rbottom = 0
      # And these are the absolute ones; they're also 0.
      getter aleft = 0
      getter atop = 0
      getter aright = 0
      getter abottom = 0

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
        @app.title
      end

      def title=(arg)
        @app.title = arg
      end

      def sigtstp(callback)
        app.sigtstp {
          alloc
          render
          app.lrestore_cursor :pause, true
          callback.call if callback
        }
      end
    end
  end
end
